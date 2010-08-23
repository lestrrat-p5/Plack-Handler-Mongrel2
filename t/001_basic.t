use strict;
use warnings;
use Test::Requires qw(
    Data::UUID
    Test::TCP
    URI::Escape
);
use t::Mongrel2Test qw(gen_config run_mongrel2 run_plack SIGINT SIGTERM);
use Test::More;
use Plack;
use Plack::Handler::Mongrel2;
use Plack::Test::Suite;
use Test::TCP qw(wait_port);

{
    # XXX Currently I have a problem with the test not ending.
    # need to fix it.

    my $config      = gen_config();
    my $mongrel_pid = run_mongrel2($config);
    my $plack_pid   = run_plack($config);

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

    # I need to send a signal to both m2sh and mongrel2, so sending
    # this signal to the process group (that's why I'm doing my own
    # fork + exec)
    kill SIGINT() * -1 => getpgrp($mongrel_pid);
    kill SIGTERM() => $plack_pid;
}

done_testing();

