use strict;
use warnings;
use Test::Requires qw(
    Data::UUID
    Proc::Guard
    URI::Escape
);
use Test::More;
use Plack;
use Plack::Handler::Mongrel2;
use Plack::Test::Suite;
use Test::TCP qw(empty_port wait_port);

{
    # XXX Currently I have a problem with the test not ending.
    # need to fix it.

    my $config        = gen_config();
    my $mongrel_guard = run_mongrel2($config);
    my $plack_guard   = run_plack($config);

    wait_port($config->{port});
    sleep 5;

    my $ua = LWP::UserAgent->new;
    my $i  = 0;
    Plack::Test::Suite->runtests( sub {
        my ($name, $client) = @_;
        note $name;
        TODO: {
            # as of this writing (8/21) mongrel2 has a hardcoded maximum
            # content-size set, which fails some plack tests, so we must
            # todo_skip that test :/
            if ($name eq 'big POST') {
                $i++;
                todo_skip "'$name': wait until mongrel2's max post size becomes configurable (http://mongrel2.org/tktview?name=9e180d04e9)", 4;
                return;
            } elsif ($name eq 'multi headers (request)') {
                $i++;
                todo_skip "'$name': wait until mongrel2's request format for handlers are changed (http://mongrel2.org/tktview?name=195e303fb7)", 1; 
                return;
            }

            my $cb = sub {
                my $req = shift;

                $req->uri->port($config->{port});
                $req->header('X-Plack-Test' => $i++);
                return $ua->request($req);
            };

            $client->($cb);
        }
    });
}


done_testing();

sub gen_config {
    # mongrel2 is a lazy bastard, and it won't create run, log, tmp directories
    foreach my $dir qw(t/run t/log t/tmp) {
        if (! -d $dir) {
            mkdir $dir or die "Couldn't create dir $dir: $!";
            chmod 0777, $dir;
        }
    }

    my $mong_port = empty_port();
    my $send_port = empty_port($mong_port);
    my $recv_port = empty_port($send_port);

    my $uuid = Data::UUID->new();
    my %config = (
        port          => $mong_port,
        mongrel2_uuid => $uuid->create_str(),
        send_spec     => "tcp://127.0.0.1:$send_port",
        send_ident    => $uuid->create_str(),
        recv_spec     => "tcp://127.0.0.1:$recv_port",
        recv_ident    => $uuid->create_str(),
    );
    return \%config;
}


sub run_mongrel2 {
    my $config =shift;

    my $conffile = "t/mongrel2.py";
    my $dbfile = "t/mongrel2.sqlite";
    open( my $fh, '>', $conffile ) or
        die "Could not open file $conffile: $!";
    print $fh render_mongrel2_conf($config);
    close $fh;

    if (system("m2sh", "init", "-db", $dbfile) != 0) {
        fail("Could not init db");
        exit 1;
    }

    if (system("m2sh", "load", "-db", $dbfile, "-config", $conffile) != 0) {
        fail("Could not load config");
        exit 1;
    }

    return proc_guard( "m2sh", "start", "-db", $dbfile, "-host", "localhost");
}

sub render_mongrel2_conf {
    my $env = shift;
    return <<EOM;
from mongrel2.config import *

main = Server(
    uuid="$env->{mongrel2_uuid}",
    access_log="/t/logs/access.log",
    error_log="/t/logs/error.log",
    chroot="./",
    default_host="localhost",
    pid_file="/t/run/mongrel2.pid",
    port=$env->{port},
    hosts = [
        Host(name="127.0.0.1", routes={
            r'/': Handler(
                send_spec="$env->{send_spec}",
                send_ident="$env->{send_ident}",
                recv_spec="$env->{recv_spec}",
                recv_ident="$env->{recv_ident}")
        })
    ]
)

commit([main])
EOM
}

sub run_plack {
    my $config = shift;

    return proc_guard( "plackup", "-s", "Mongrel2",
        "-M", "blib",
        "--send_spec", $config->{send_spec},
        "--send_ident", $config->{send_ident},
        "--recv_spec", $config->{recv_spec},
        "--recv_ident", $config->{recv_ident},
        "-M", "Plack::Test::Suite", "-e", "Plack::Test::Suite->test_app_handler"
    );
}


