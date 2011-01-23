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
    SIGINT
    SIGTERM
    SIGKILL
);
use Test::More;
use Plack;
use Plack::Handler::Mongrel2;
use Plack::Test::Suite;
use Test::TCP qw(wait_port);

my $i = 0;
foreach my $test (@Plack::Test::Suite::TEST) {
    diag "$i. $test->[0]";
    $i++;
}

{
    # XXX Currently I have a problem with the test not ending.
    # need to fix it.
    clean_files();

    my $config      = gen_config();
    my $mongrel_pid = run_mongrel2($config);
    my $plack_pid   = run_plack($config);

    wait_port($config->{port});
    sleep 1;

    $SIG{ INT } = sub {
        kill SIGTERM() => $plack_pid;
        kill SIGTERM() => $mongrel_pid;
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
                $req->uri->path($ENV{PLACK_TEST_SCRIPT_NAME} . $req->uri->path);
            }

            $req->header('X-Plack-Test' => $count);
            return $ua->request($req);
        };

        $client->($cb);
    });

    stop_mongrel2();
    kill SIGTERM() => $plack_pid;
    kill SIGINT()  => getpgrp($mongrel_pid);
}

done_testing();

