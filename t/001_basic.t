use strict;
use warnings;
use Test::Requires qw(
    Data::UUID
    Test::TCP
    URI::Escape
);
use t::Mongrel2Test qw(
    clean_files
    gen_config
    run_mongrel2
    run_plack
    stop_mongrel2
    pid_for_mongrel2
    SIGINT
    SIGTERM
    SIGKILL
);
use Test::More;
use Plack;
use Plack::Handler::Mongrel2;
use Plack::Test::Suite;
use Test::TCP qw(wait_port);

{
    # XXX Currently I have a problem with the test not ending.
    # need to fix it.
    clean_files();

    foreach my $prefix ( '' ) { # , '/route_prefix/' ) { 
        local $ENV{PLACK_TEST_SCRIPT_NAME} = $prefix;

        my $config    = gen_config();
        my $m2sh_pid  = run_mongrel2($config);
        my $plack_pid = run_plack($config);

        wait_port($config->{port});
        sleep 1;

        local $SIG{ INT } = sub {
            kill SIGTERM() => $plack_pid;
            kill SIGTERM() => $m2sh_pid;
        };

        my $ua = LWP::UserAgent->new(timeout => 5);
        my $i  = 0;
        my %tests;
        Plack::Test::Suite->runtests( sub {
            my ($name, $client) = @_;
            note "TEST $i $name";
            my $count = exists $tests{$name} ? $tests{$name} :
                $tests{$name} ||= $i++;
            my $cb = sub {
                my $req = shift;
                $req->uri->port($config->{port});
                if ($ENV{PLACK_TEST_SCRIPT_NAME}) {
                    $req->uri->path($ENV{PLACK_TEST_SCRIPT_NAME} . $req->uri->path)
                }

                $req->header('X-Plack-Test' => $count);
                return $ua->request($req);
            };
            $client->($cb);
        });

        note "Stopping mongrel2";
        my $mongrel_pid = `cat t/run/mongrel2.pid`; # pid_for_mongrel2();

        stop_mongrel2();
        note "Killing plack on $plack_pid";
        kill SIGTERM() => $plack_pid;
        kill SIGTERM() => $m2sh_pid;

        if ($mongrel_pid) {
            if (kill 0 => $mongrel_pid) {
                diag "Sending KILL to $mongrel_pid";
                sleep 5;
                kill SIGKILL() => $mongrel_pid;
            }
        }
    }
}

done_testing();

