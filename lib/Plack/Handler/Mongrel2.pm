package Plack::Handler::Mongrel2;
use strict;
use base qw(Plack::Handler);
our $VERSION = '0.01000';
use ZeroMQ qw( ZMQ_UPSTREAM ZMQ_PUB ZMQ_IDENTITY );
use JSON qw(decode_json);
use HTTP::Status qw(status_message);
use Plack::Util ();
use Plack::Util::Accessor
    qw(ctxt incoming outgoing send_spec send_ident recv_spec recv_ident);

# TODO
#   - psgi.url_scheme
#   - psgi.input should be a string buffer
#   - check and fix what the correct way is to handle content-length
#     (mongrel2 chokes on simple requests if you don't responed with
#      content-length -- as of 8/20/2010)

sub _parse_netstring {
    my ($len, $rest) = split /:/, $_[0], 2;
    my $data = substr $rest, 0, $len, '';
    return ($data, $rest);
}

ZeroMQ::register_read_type( mongrel_req_to_psgi => sub {
    my ($rest, $headers, $body);

    my %env = (
        'psgi.version'      => [ 1, 1 ],
        'psgi.url_scheme'   => 'http', # XXX TODO
        'psgi.errors'       => *STDERR,
        'psgi.input'        => *STDOUT, # XXX TODO
        'psgi.multithread'  => 0,
        'psgi.multiprocess' => 0,
        'psgi.run_once'     => 0,
        'psgi.streaming'    => 0,
        'psgi.nonblocking'  => 0,
    );

    ($env{MONGREL2_SENDER_ID}, $env{MONGREL2_CONN_ID}, $env{PATH_INFO}, $rest) =
        split / /, $_[0], 4;

    ($headers, $rest) = _parse_netstring($rest);

    my $hdrs = decode_json $headers;
    $env{SCRIPT_NAME}     = delete $hdrs->{PATH};
    $env{REQUEST_METHOD}  = delete $hdrs->{METHOD};
    $env{REQUEST_URI}     = delete $hdrs->{URI};
    $env{QUERY_STRING}    = delete $hdrs->{QUERY};
    $env{SERVER_PROTOCOL} = delete $hdrs->{VERSION};
    ($env{SERVER_NAME}, $env{SERVER_PORT}) = split /:/, delete $hdrs->{Host}, 2;

    foreach my $key (keys %$hdrs) {
        if ($key =~ /^X-(.+)$/i) {
            my $new_key = 'HTTP_' . uc $key;
            $new_key =~ s/-/_/g;
            $env{$new_key} = $hdrs->{$key};
        } else {
            $env{$key} = $hdrs->{$key};
        }
    }

    ($body) = _parse_netstring($rest);

    return \%env;
} );

sub new {
    my ($class, %opts) = @_;

    $opts{ctxt} ||= ZeroMQ::Context->new();
    $opts{incoming} ||= $opts{ctxt}->socket( ZMQ_UPSTREAM );
    $opts{outgoing} ||= $opts{ctxt}->socket( ZMQ_PUB );

    bless { %opts }, $class;
}

sub run {
    my ($self, $app) = @_;

    foreach my $field qw(send_spec send_ident recv_spec recv_ident) {
        if (length $self->$field == 0) {
            die "Argument $field is required";
        }
    }


    $self->incoming->connect( $self->send_spec );
    $self->outgoing->connect( $self->recv_spec );
    $self->outgoing->setsockopt( ZMQ_IDENTITY, $self->send_ident );

    my $loop = 1;
    local $ENV{INT} = sub {
        $loop = 0;
    };
    while ( $loop ) {
        my $env = $self->incoming->recv_as( 'mongrel_req_to_psgi' );
        eval {
            my $res = $app->( $env );
            $self->reply( $env, $res );
        };
        if ($@) {
            $self->reply( $env, [ 500, [ "Content-Type" => "text/plain" ], [ "Internal Server Error" ] ] );
        }
    }
}

sub reply {
    my ($self, $env, $res) = @_;

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
        if (my $cl = length $body) {
            push @$hdrs, "Content-Length", $cl;
        }
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
    $self->outgoing->send( $mongrel_resp );
}

1;

__END__

=head1 NAME

Plack::Handler::Mogrel2 - Plack Handler For Mongrel2 

=head1 SYNOPSIS

    plackup -s Mongrel2 \
        --send_spec=tcp://127.0.0.1:9999 \
        --send_ident=D807E984-AC0B-11DF-979C-3C4975AD5E34 \
        --recv_spec=tcp://127.0.0.1:9998 \
        --recv_ident=E80576A8-AC0B-11DF-A841-3D4975AD5E34

=head1 DESCRIPTION

EXTERMELY ALPHA CODE!

=head1 METHODS

=head2 send_spec

The ZeroMQ spec for mongrel2-to-handler socket. Your handler will be
receiving requests from this socket.

=head2 send_ident

A unique identifier for the mongrel2-to-handler socket.

=head2 recv_spec

The ZeroMQ spec for handler-to-mongrel2 socket. Your handler will be
sending responses from this socket. 

=head2 recv_ident

A unique identifier for the handler-to-mongrel2 socket.

=head1 LICENSE

This library is available under Artistic License v2, and is:

    Copyright (C) 2010  Daisuke Maki C<< <daisuke@endeworks.jp> >>

=head1 AUTHOR

Daisuke Maki C<< <daisuke@endeworks.jp> >>

=cut