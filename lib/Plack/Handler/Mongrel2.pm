package Plack::Handler::Mongrel2;
use strict;
use base qw(Plack::Handler);
our $VERSION = '0.01000_02';
use ZeroMQ::Raw;
use ZeroMQ::Constants qw(
    ZMQ_POLLIN
    ZMQ_UPSTREAM
    ZMQ_PULL
    ZMQ_PUB
    ZMQ_IDENTITY
    ZMQ_RCVMORE
);
use JSON qw(decode_json);
use HTTP::Status qw(status_message);
use Plack::Util ();
use Plack::Util::Accessor
    qw(send_spec send_ident recv_spec recv_ident max_workers max_reqs_per_child);
use URI::Escape ();
use constant DEBUG => $ENV{PLACK_HANDLER_MONGREL2_DEBUG} ? 1 : 0;

# TODO
#   - check and fix what the correct way is to handle content-length
#     (mongrel2 chokes on simple requests if you don't responed with
#      content-length -- as of 8/20/2010)

sub _parse_netstring {
    my ($len, $rest) = split /:/, $_[0], 2;
    my $data = substr $rest, 0, $len, '';
    $rest =~ s/^,//;
    return ($data, $rest);
}

sub _parse_headers {
    my $headers = shift;

    my %hdrs;

    # XXX when the client sends multiple headers of the same name, mongrel2 
    # currently sends them like { ... "Foo": "Value1", "Foo": "Value2" ... }
    # which is valid, but when decoded the first value gets mangled
#    $headers =~ s/{/[/;
#    $headers =~ s/}/]/;
#    $headers =~ s/":"/","/g;
    if (DEBUG()) {
        print STDERR "[Mongrel2.pm] Decoding JSON '$headers'\n";
    }
    return decode_json $headers;
=head1
    my $hdrs_as_list = decode_json $headers;
    while (@$hdrs_as_list) {
        my $key = shift @$hdrs_as_list;
        my $value = shift @$hdrs_as_list;

        if (exists $hdrs{$key}) {
            if (ref $hdrs{$key} ne 'ARRAY') {
                $hdrs{$key} = [ $hdrs{$key}, $value ];
            } else {
                push @{$hdrs{$key}}, $value;
            }
        } else {
            $hdrs{$key} = $value;
        }
    }
    return \%hdrs;
=cut
}


sub mongrel2_req_to_psgi {
    my ($self, $data) = @_;
    my ($rest, $headers, $body);

    if (DEBUG()) {
        print STDERR "[Mongrel2.pm] Deparsing zmq message:\n",
            "    data: $data\n";
    }

    my %env = (
        'psgi.version'      => [ 1, 1 ],
        'psgi.url_scheme'   => 'http', # XXX TODO
        'psgi.errors'       => *STDERR,
        'psgi.multithread'  => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 0,
        'psgi.nonblocking'  => 0,
    );

    ($env{MONGREL2_SENDER_ID}, $env{MONGREL2_CONN_ID}, $env{PATH_INFO}, $rest) =
        split / /, $data, 4;

    $env{PATH_INFO} = URI::Escape::uri_unescape($env{PATH_INFO});

    ($headers, $rest) = _parse_netstring($rest);

    my $hdrs = _parse_headers($headers);

    $env{QUERY_STRING}    = delete $hdrs->{QUERY} || '';
    $env{REQUEST_METHOD}  = delete $hdrs->{METHOD};
    $env{REQUEST_URI}     = delete $hdrs->{URI};
    $env{SCRIPT_NAME}     = delete $hdrs->{PATH} || '';
    if ($env{SCRIPT_NAME} eq '/') {
        $env{SCRIPT_NAME} = '';
    }
    $env{SERVER_PROTOCOL} = delete $hdrs->{VERSION};
    ($env{SERVER_NAME}, $env{SERVER_PORT}) = split /:/, delete $hdrs->{host}, 2;

    foreach my $key (keys %$hdrs) {
        my $new_key = uc $key;
        $new_key =~ s/-/_/g;
        if ($new_key !~ /^(?:CONTENT_LENGTH|CONTENT_TYPE)$/) {
            $new_key = "HTTP_$new_key";
        }

        # XXX See parse_headers for why this is necessary
        my $value = $hdrs->{$key};
        if (ref $value eq 'ARRAY') {
            $value = join(', ', @$value);
        }

        if (exists $env{$new_key}) {
            $env{$new_key} .= ", $value";
        } else {
            $env{$new_key} = $value;
        }
    }

    ($body) = _parse_netstring($rest);

    if ( $env{REQUEST_METHOD} eq 'JSON' ) {
        my $json_body = decode_json $body;
        if ($json_body->{type} eq 'disconnect') {
            # noop 
        } else {
            # noop
        }
        if (DEBUG()) {
            print STDERR "[Mongrel2.pm] Method is JSON, which is internal. Dropping request...\n";
        }
        return ();
    }

    my $buf = Plack::TempBuffer->new( $env{CONTENT_LENGTH} );
    $buf->print($body);
    $env{'psgi.input'} = $buf->rewind;

    return \%env;
}

sub new {
    my ($class, %opts) = @_;

    $opts{max_workers} ||= 10;
    $opts{max_reqs_per_child} ||= 1000;

    bless { %opts }, $class;
}

sub run {
    my ($self, $app) = @_;

    foreach my $field qw(send_spec send_ident recv_spec recv_ident) {
        if (length $self->$field == 0) {
            die "Argument $field is required";
        }
    }

    my $max_workers = $self->max_workers;
    if ($max_workers > 1) {
        require Paralell::Prefork;
        my $pm = Parallel::Prefork->new({
            max_workers => $max_workers,
            trap_signals => {
                HUP  => 'TERM',
            },
        });

        local $SIG{INT} = sub {
            $pm->signal_received('TERM');
            $pm->signal_all_children('INT');
        };
        local $SIG{TERM} = $SIG{INT};

        while ($pm->signal_received ne 'TERM') {
            $pm->start and next;
            local $SIG{TERM} = sub {
                warn "child $$ received signal";
                $pm->finish;
            };
            my @zmq = $self->prepare_zmq();
            $self->accept_loop($app, @zmq);
            $self->finalize_zmq(@zmq);
            $pm->finish;
        }
        $pm->wait_all_children;
    } else {
        if (DEBUG()) {
            print STDERR "[Mongrel2.pm] mac_workers = 1, so not loading Parallel::Prefork\n";
        }
        my @zmq = $self->prepare_zmq();
        while (1) {
            $self->accept_loop($app, @zmq);
        }
        $self->finalize_zmq(@zmq);
    }
}

sub prepare_zmq {
    my ($self) = @_;
    my $ctxt     = zmq_init();
    my $incoming = zmq_socket( $ctxt, ZMQ_UPSTREAM );
    my $outgoing = zmq_socket( $ctxt, ZMQ_PUB );

    zmq_connect( $incoming, $self->send_spec );
    if (DEBUG()) {
        print STDERR "[Mongrel2.pm] Connected incoming socket to ",
            $self->send_spec, "\n";
    }
    zmq_connect( $outgoing, $self->recv_spec );
    if (DEBUG()) {
        print STDERR "[Mongrel2.pm] Connected outcoming socket to ",
            $self->recv_spec, "\n";
    }
    zmq_setsockopt( $outgoing, ZMQ_IDENTITY, $self->send_spec );
    if (DEBUG()) {
        print STDERR "[Mongrel2.pm] outgoing socket sets identity to ",
            $self->send_ident, "\n";
    }

    return ($ctxt, $incoming, $outgoing);
}

sub finalize_zmq {
    my ($self, $ctxt, $incoming, $outgoing) = @_;
    zmq_close( $incoming );
    zmq_close( $outgoing );
    zmq_term( $ctxt );
}

sub accept_loop {
    my ($self, $app, $ctxt, $incoming, $outgoing) = @_;

    my $proc_req_count = 0;
    my $max_reqs_per_child = $self->max_reqs_per_child;
    my $loop = 1;

    local $SIG{ INT } = sub {
        $loop = 0;
        zmq_close($incoming);
        zmq_close($outgoing);
        exit 0;
    };
    local $SIG{TERM} = $SIG{INT};
    while ( $loop && (!defined $max_reqs_per_child || $proc_req_count < $max_reqs_per_child ) ) {
        if (DEBUG()) {
            print STDERR "[Mongrel2.pm] Waiting for next request\n";
        }
        zmq_poll( [
            {
                socket => $incoming,
                events => ZMQ_POLLIN,
                callback => sub {
                    while ( my $msg = zmq_recv( $incoming, ZMQ_RCVMORE ) ) {
                        my $env = $self->mongrel2_req_to_psgi( zmq_msg_data( $msg ) );
                        next unless $env;

                        eval {
                            my $res = $app->( $env );
                            $self->reply( $outgoing, $env, $res );
                        };
                        if ($@) {
                            $self->reply( $outgoing, $env, [ 500, [ "Content-Type" => "text/plain" ], [ "Internal Server Error" ] ] );
                        }
                        $proc_req_count++;
                    }
                }
            }
        ], 1000000 );
    }
}

sub reply {
    my ($self, $outgoing, $env, $res) = @_;

    my ($status, $hdrs, $body) = @$res;
    if (ref $body eq 'ARRAY') {
        $body = join '', @$body;
    } elsif ( defined $body) {
        local $/ = \65536 unless ref $/;
        my $x = '';
        while ( defined( my $line = $body->getline ) ) {
            $x .= $line;
        }
        $body->close;
        $body = $x;
    } else {
        die "unimplmented";
    }

    if ( ! Plack::Util::status_with_no_entity_body($status) ) {
        push @$hdrs, "Content-Length", length $body;
    }

    my $mongrel_resp = sprintf( "%s %d:%s, %s %d %s\r\n%s\r\n\r\n%s",
        $env->{MONGREL2_SENDER_ID},
        length $env->{MONGREL2_CONN_ID},
        $env->{MONGREL2_CONN_ID},
        $env->{SERVER_PROTOCOL},
        $status,
        status_message($status),
        join("\r\n", map { sprintf( '%s: %s', $hdrs->[$_ * 2], $hdrs->[$_ * 2 + 1] ) } (0.. (@$hdrs/2 - 1) ) ),
        $body,
    );

    if (DEBUG) {
        print STDERR "[Mongrel2.pm]: Sending\n";
        print STDERR 
            join "\\r\\n\n", map { "    $_" } (split /\r\n/, $mongrel_resp);
        print STDERR "\n";
    }

    zmq_send( $outgoing, $mongrel_resp );
}

1;

__END__

=head1 NAME

Plack::Handler::Mongrel2 - Plack Handler For Mongrel2 

=head1 SYNOPSIS

    plackup -s Mongrel2 \
        --max_workers=10 \
        --max_reqs_per_child=1000 \
        --send_spec=tcp://127.0.0.1:9999 \
        --send_ident=D807E984-AC0B-11DF-979C-3C4975AD5E34 \
        --recv_spec=tcp://127.0.0.1:9998 \
        --recv_ident=E80576A8-AC0B-11DF-A841-3D4975AD5E34

=head1 DESCRIPTION

EXTERMELY ALPHA CODE! Tested using morengrel2-1.0rc1.

=head1 METHODS

=head2 new

Creates a new server. Accepts the following options:

=over 4

=item max_workers [default 10]

Number of worker processes to spawn.

=item max_reqs_per_child [default 1000]

Number of requests that a child processes before exiting.

=item send_spec [required]

The ZeroMQ spec for mongrel2-to-handler socket. Your handler will be
receiving requests from this socket.

=item send_ident [required]

A unique identifier for the mongrel2-to-handler socket.

=item recv_spec [required]

The ZeroMQ spec for handler-to-mongrel2 socket. Your handler will be
sending responses from this socket. 

=item recv_ident [required]

A unique identifier for the handler-to-mongrel2 socket.

=back

=head2 run

Starts the server.

=head2 reply

Replies back to mongrel2

=head2 accept_loop

Runs the process loop

=head1 LICENSE

This library is available under Artistic License v2, and is:

    Copyright (C) 2010  Daisuke Maki C<< <daisuke@endeworks.jp> >>

=head1 AUTHOR

Daisuke Maki C<< <daisuke@endeworks.jp> >>

=cut