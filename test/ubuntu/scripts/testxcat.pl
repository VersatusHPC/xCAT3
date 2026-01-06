#!/usr/bin/perl
use strict;
use warnings;
use v5.10;

use Getopt::Long qw(GetOptions);
use Pod::Usage;

my %opts = (
    nginx_port => "8080",
    run_local => 0,
    verbose => 0,
);

GetOptions(
    "nginx-port=i" => \$opts{nginx_port},
    "run-local" => \$opts{run_local},
    "verbose" => \$opts{verbose},
) or pod2usage(2);

exit(main());

sub write_text {
    my ($fpath, $text) = @_;
    open my $fh, ">", $fpath
        or die "open $fpath: $!";
    print {$fh} $text;
}

sub sh {
    my ($cmd) = @_;
    my $bashopts = "";
    $bashopts .= "set -x; "
        if $opts{verbose};
    system(<<"EOF")
bash -lc '
$bashopts
$cmd
'
EOF
}

sub setup_local_repos {
    my $host = $opts{run_local}
        ? "localhost"
        : "host.containers.internal";

    my $LOCAL_REPOS_LIST = <<"EOF";
deb [trusted=yes; allow-insecure=yes] http://$host:$opts{nginx_port}/repos/xcat-core jammy main
deb [trusted=yes; allow-insecure=yes] http://$host:$opts{nginx_port}/repos/xcat-dep focal main
EOF
    write_text("/etc/apt/sources.list.d/local-repos.list", $LOCAL_REPOS_LIST);
    sh("apt update -y");
}

sub install_packages {
    sh("apt update -y && apt install -y --allow-unauthenticated xcat xcat-test");
}

sub run_ci_tests {
    sh("bash -lec 'xcattest -s ci_test'");
}

sub main {
    my $exit = setup_local_repos();
    return $exit unless $exit == 0;
    $exit = install_packages();
    return $exit unless $exit == 0;
    $exit = run_ci_tests();
    return $exit unless $exit == 0;
}

__END__

=head1 NAME

testxcat.pl - Run xCAT tests in Debian/Ubuntu environments

=head1 SYNOPSIS

./testxat.pl

=head1 DESCRIPTION

Setup local repositories, install xCAT and run CI tests.

Assumptions:

1. To run over a container created from test/ubuntu/Container file.
2. A debian repository served by container's hosts at 
   localhost:8080/repos/. (builddebs.pl can setup these)

=head1 OPTIONS

=over 4 
=item B<--nginx-port> I<port>

Change the default nginx port used, 8080 by default.

=back
