#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use Data::Dumper qw(Dumper);
use Getopt::Long qw(GetOptions);

sub write_text {
    my ($fpath, $text) = @_;
    open my $fh, ">", $fpath
        or die "open $fpath: $!";
    print $fh $text;
}


my %opts = (
    releasever => int(`rpm --eval '%{rhel}'`),
    verbose => 0,
    setup_repos => 0,
    install => 0,
    uninstall => 0,
    reinstall => 0,
    validate => 0,
    quiet => 0,
    all => 0,
    nginx_port => 8080,
);

GetOptions(
    'releasever=i' => \$opts{releasever},
    verbose => \$opts{verbose},
    quiet => \$opts{quiet},
    "setup-repos" => \$opts{setup_repos},
    install => \$opts{install},
    uninstall => \$opts{uninstall},
    reinstall => \$opts{reinstall},
    validate => \$opts{validate},
    all => \$opts{all},
    "nginx-port" => \$opts{nginx_port},
) or usage();

sub sh {
    my ($cmd) = @_;
    say "Running: $cmd"
        unless $opts{quiet};
    open my $fh, "-|", "bash -lc '$cmd'" or die "cannot run $cmd: $!";

    while (my $line = <$fh>) {
        print $line
            unless $opts{quiet};
    }
    close $fh;
    return $? >> 8;
}

sub usage {
    say STDERR "usage $0: [--releasever=9] [--verbose] [--quiet] {--setup-repos|--install|--uninstall|--reinstall|--validate|--all} [--nginx-port=8080]";
}

sub setup_repos {
    say "Setting up repositories"
        unless $opts{quiet};
    my $releasever = $opts{releasever};
    my $port = $opts{nginx_port};
    my $content = <<"EOF";
[xcat3]
name=xcat3
baseurl=http://host.containers.internal:$port/rhel+epel-$releasever-x86_64/
gpgcheck=0
enabled=1

[xcat3-deps]
name=xcat3-deps
baseurl=http://host.containers.internal:$port/xcat-dep/el$releasever/x86_64/
gpgcheck=0
enabled=1
EOF
    write_text("/etc/yum.repos.d/xcat-repos.repo", $content);
    sh("dnf makecache --repo=xcat3 --repo=xcat3-deps");
}

sub uninstall {
    sh("dnf remove -y xCAT xCAT-test");
    sh("rm -rf /opt/xcat /etc/xcat /var/run/xcat /root/.xcat /install /tftpboot");
}

sub install {
    sh("dnf install -y xCAT xCAT-test");
}

sub validate {
    sh("xcattest -s ci_test");
}

sub main {
    return setup_repos() if $opts{setup_repos};
    return install() if $opts{install};
    return uninstall() if $opts{uninstall};
    return validate() if $opts{validate};

    return do {
        setup_repos();
        uninstall()
            if ($opts{reinstall} or $opts{uninstall});
        install();
        validate();
    } if $opts{all};

    return do {
        uninstall();
        install();
    } if $opts{reinstall};

    usage();
}

main();

