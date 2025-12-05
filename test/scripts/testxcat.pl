#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';
use Data::Dumper qw(Dumper);
use Getopt::Long qw(GetOptions);
use File::Slurper qw(read_text write_text);

my %opts = (
    releasever => int(`rpm --eval '%{rhel}'`),
    verbose => 0,
    setuprepos => 0,
    installxcat => 0,
    uninstallxcat => 0,
    reinstallxcat => 0,
    validatexcat => 0,
    quiet => 0,
    all => 0,
);

GetOptions(
    'releasever=i' => \$opts{releasever},
    verbose => \$opts{verbose},
    quiet => \$opts{quiet},
    quiet => \$opts{quiet},
    setuprepos => \$opts{setuprepos},
    installxcat => \$opts{installxcat},
    uninstallxcat => \$opts{uninstallxcat},
    reinstallxcat => \$opts{reinstallxcat},
    validatexcat => \$opts{validatexcat},
    all => \$opts{all},
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
    say STDERR "usage $0: [--releasever=9] [--verbose] [--quiet] {--setuprepos|--isntallxcat|--uninstallxcat|--reinstallxcat|--validatexcat|--all}";
}

sub setuprepos {
    say "Setting up repositories"
        unless $opts{quiet};
    my $releasever = $opts{releasever};
    my $content = <<"EOF";
[xcat3]
name=xcat3
baseurl=http://host.containers.internal:8080/rhel+epel-$releasever-x86_64/
gpgcheck=0
enabled=1

[xcat3-deps]
name=xcat3-deps
baseurl=http://host.containers.internal:8080/xcat-dep/el$releasever/x86_64/
gpgcheck=0
enabled=1
EOF
    write_text("/etc/yum.repos.d/xcat-repos.repo", $content);
    sh("dnf makecache --repo=xcat3 --repo=xcat3-deps");
}

sub uninstallxcat {
    sh("dnf remove -y xCAT");
    sh("rm -rf /opt/xcat /etc/xcat /var/run/xcat /root/.xcat /install /tftpboot");
}

sub installxcat {
    sh("dnf install -y xCAT");
}

sub validatexcat {
    # Put commands to validate xcat installation here
    sh("systemctl is-active xcatd") == 0 or die("xcatd not running?");
    sh("lsdef") == 0 or die("lsdef not working");
}

sub main {
    return setuprepos() if $opts{setuprepos};
    return installxcat() if $opts{installxcat};
    return uninstallxcat() if $opts{uninstallxcat};
    return validatexcat() if $opts{validatexcat};

    return do {
        setuprepos();
        uninstallxcat()
            if ($opts{reinstallxcat} or $opts{uninstallxcat});
        installxcat();
        validatexcat();
    } if $opts{all};

    return do {
        uninstallxcat();
        installxcat();
    } if $opts{reinstallxcat};

    usage();
}

main();

