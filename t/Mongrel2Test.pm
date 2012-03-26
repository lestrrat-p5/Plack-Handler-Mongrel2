package t::Mongrel2Test;
use strict;
use Exporter 'import';
use Config;
use Test::TCP ();
use Test::More;
use Plack::Test::Suite;
use HTTP::Request::Common qw(POST);
use Data::UUID;

BEGIN {
    push @Plack::Test::Suite::TEST, [
        'Upload big file',
        sub {
            my $cb = shift;
            my $file = File::Temp->new( UNLINK => 1 );
    
            $file->print( "1" x 1_200_000 );
            $file->flush;
    
            $cb->(
                POST "http://127.0.0.1/",
                    Content_Type => 'form-data',
                    Content => [ file => "$file" ]
            );
            ok(1);
        },
        sub {
            return [
                200,
                [ "Content-Type" => "text/plain" ],
                [ "Test" ],
            ]
        }
    ];
}

our @EXPORT_OK = qw(
    SIGKILL SIGTERM SIGINT 
    clean_files gen_config fork_process run_mongrel2 run_plack stop_mongrel2
    pid_for_mongrel2
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

sub clean_files {
    unlink "t/mongrel2.sqlite";
    unlink "t/run/mongrel2.pid";
    while (<t/tmp/*>) {
        unlink $_;
    }
}

my $uuid = Data::UUID->new();
sub gen_uuid {
    $uuid->create_from_name_str( __PACKAGE__, join ".", time(), {}, rand, $$, @_ );
}

sub gen_config() {
    # mongrel2 is a lazy bastard, and it won't create run, log, tmp directories
    foreach my $dir (qw(t/run t/log t/tmp)){
        if (! -d $dir) {
            mkdir $dir or die "Couldn't create dir $dir: $!";
            chmod 0777, $dir;
        }
    }

    my $check     = sub {
        my $port = shift;
        my $remote = IO::Socket::INET->new(
            Proto    => 'tcp',
            PeerAddr => '127.0.0.1',
            PeerPort => $port,
        );
        if ($remote) {
            close $remote;
            return 1;
        } else {
            return 0;
        }
    };

    my $port = 50_000 + int(rand() * 1000);
    my @ports;
    while ( @ports < 3 && $port++ < 60_000 ) {
        next if $check->($port);
        my $sock = IO::Socket::INET->new(
            Listen    => 5,
            LocalAddr => '127.0.0.1',
            LocalPort => $port,
            Proto     => 'tcp',
            (($^O eq 'MSWin32') ? () : (ReuseAddr => 1)),
        );
        push @ports, $port;
    }

    my ($mong_port, $send_port, $recv_port) = @ports;

    my %config = (
        uuid          => gen_uuid(),
        port          => $mong_port,
        chroot        => "./t",
        access_log    => "/logs/access.log",
        error_log     => "/logs/error.log",
        send_spec     => "tcp://127.0.0.1:$send_port",
        send_ident    => gen_uuid(),
        recv_spec     => "tcp://127.0.0.1:$recv_port",
        recv_ident    => gen_uuid(),
        max_workers   => $ENV{MAX_WORKERS} || 1,
        max_reqs_per_child => $ENV{MAX_REQS_PER_CHILD} || 1,
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

sub pid_for_mongrel2() {
    my $m2sh_bin = $ENV{M2SH_BIN} || `which m2sh`;
    chomp $m2sh_bin;
    die "please set M2SH_BIN or place m2sh in PATH" 
        if (! $m2sh_bin || ! -x $m2sh_bin);

    my $dbfile = "t/mongrel2.sqlite";
    my @cmd = ($m2sh_bin, "running", "-db", $dbfile, "-host", "127.0.0.1");
    my $output = qx/@cmd/;
    if ( $output =~ /mongrel2 at PID (\d+) running/ ) {
        return $1;
    }
}
    

sub stop_mongrel2() {
    my $m2sh_bin = $ENV{M2SH_BIN} || `which m2sh`;
    chomp $m2sh_bin;
    die "please set M2SH_BIN or place m2sh in PATH" 
        if (! $m2sh_bin || ! -x $m2sh_bin);

    my $dbfile = "t/mongrel2.sqlite";
    system($m2sh_bin, "stop", "-db", $dbfile, "-host", "127.0.0.1");
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

    if (system($m2sh_bin, "load", "-db", $dbfile, "-config", $conffile) != 0) {
        fail("Could not load config");
        exit 1;
    }

    return fork_process $m2sh_bin, "start", "-db", $dbfile, "-host", "127.0.0.1";
}

sub render_mongrel2_conf($) {
    my $env = shift;
    my $route = $ENV{PLACK_TEST_SCRIPT_NAME} || "/";
    return <<EOM;
# generated automatically at @{[ scalar localtime ]}
main = Server(
    uuid="$env->{uuid}",
    chroot="$env->{chroot}",
    access_log="$env->{access_log}",
    error_log="$env->{error_log}",
    default_host="127.0.0.1",
    name="test",
    pid_file="/t/run/mongrel2.pid",
    port=$env->{port},
    hosts = [
        Host(name="127.0.0.1", routes={
            '$route': Handler(
                send_spec="$env->{send_spec}",
                send_ident="$env->{send_ident}",
                recv_spec="$env->{recv_spec}",
                recv_ident="$env->{recv_ident}")
        })
    ]
)
settings = {
    "control_port": "ipc://t/run/control",
    "limits.content_length": 100000,
    "upload.temp_store": "t/tmp/uploadXXXXXX"
}
servers = [main]
EOM
}

sub run_plack($) {
    my $config = shift;

    my $access_log = $config->{access_log} || do {
        # find the top most caller
        my $i = 1;
        while (my @list = caller($i++)) {
            die "call stack too deep" if $i > 100;
        }
        my @topmost = caller($i - 2);
        "$topmost[1].log";
    };

    return fork_process
        "plackup", "-s", "Mongrel2",
        "-M", "blib",
        "--send_spec", $config->{send_spec},
        "--send_ident", $config->{send_ident},
        "--recv_spec", $config->{recv_spec},
        "--recv_ident", $config->{recv_ident},
        "--max_reqs_per_child", $config->{max_reqs_per_child},
        "--max_workers", $config->{max_workers},
#        "--access-log", $access_log,
        "-M", "Plack::Test::Suite",
        "-M", "t::Mongrel2Test",
        "-e", "Plack::Test::Suite->test_app_handler"
    ;
}

1;
