package t::Mongrel2Test;
use strict;
use Exporter 'import';
use Config;
use Test::TCP qw(empty_port);

our @EXPORT_OK = qw(
    SIGKILL SIGTERM SIGINT
    gen_config fork_process run_mongrel2 run_plack
);

BEGIN {
    my ($signum, $sigkill, $sigterm, $sigint);
    $signum = 0;
    foreach my $sig (split(/ /, $Config{sig_name})) {
        if ($sig eq 'KILL') {
            $sigkill = $signum;
        } elsif ($sig eq 'TERM') {
            $sigterm = $signum;
        } elsif ($sig eq 'INT') {
            $sigint = $signum;
        }
        $signum++;
    }

    {
        no strict 'refs';
        *SIGKILL = sub { $sigkill };
        *SIGTERM = sub { $sigterm };
        *SIGINT  = sub { $sigint };
    }
}

sub gen_config() {
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

sub fork_process (@) {
    my @cmd = @_;

    my $pid = fork();
    die "fork failed $!" unless defined $pid;
    if ($pid == 0) { # child
        require POSIX;
        POSIX::setsid;
        exec @cmd;
        die "Could not exec '@cmd': $!";
    }
    return $pid;
}

sub run_mongrel2($) {
    my $config = shift;

    my $m2sh_bin = $ENV{M2SH_BIN} || `which m2sh`;
    chomp $m2sh_bin;
    die "please set M2SH_BIN or place m2sh in PATH" 
        if (! $m2sh_bin || ! -x $m2sh_bin);

    my $conffile = "t/mongrel2.py";
    my $dbfile = "t/mongrel2.sqlite";
    open( my $fh, '>', $conffile ) or
        die "Could not open file $conffile: $!";
    print $fh render_mongrel2_conf($config);
    close $fh;

    if (system($m2sh_bin, "init", "-db", $dbfile) != 0) {
        fail("Could not init db");
        exit 1;
    }

    if (system($m2sh_bin, "load", "-db", $dbfile, "-config", $conffile) != 0) {
        fail("Could not load config");
        exit 1;
    }

    return fork_process $m2sh_bin, "start", "-db", $dbfile, "-host", "localhost";
}

sub render_mongrel2_conf($) {
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
        Host(name="localhost", routes={
            r'/': Handler(
                send_spec="$env->{send_spec}",
                send_ident="$env->{send_ident}",
                recv_spec="$env->{recv_spec}",
                recv_ident="$env->{recv_ident}")
        })
    ]
)
settings = {"limits.content_length": 1024 * 100}

commit([main], settings =settings)
EOM
}

sub run_plack($) {
    my $config = shift;

    return fork_process
        "plackup", "-s", "Mongrel2",
        "-M", "blib",
        "--send_spec", $config->{send_spec},
        "--send_ident", $config->{send_ident},
        "--recv_spec", $config->{recv_spec},
        "--recv_ident", $config->{recv_ident},
        "-M", "Plack::Test::Suite", "-e", "Plack::Test::Suite->test_app_handler"
    ;
}

1;
