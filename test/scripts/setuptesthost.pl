#!/usr/bin/perl 

use strict;
use warnings;
use feature 'say';
use Getopt::Long qw(GetOptions);
use Cwd qw(cwd);

my $PWD = cwd();

sub sh {
    my ($cmd) = @_;
    say "Running: $cmd";
    open my $fh, "-|", $cmd or die "cannot run $cmd: $!";

    while (my $line = <$fh>) {
        print $line;
    }
    close $fh;
    return $? >> 8;
}

sub usage {
    say STDERR "Usage: $0 [--setupcontainer --target rhel+epel-9-x86_64]";
    exit -1;
}

sub parseopts {
    my %opts = (
        target => "",
        setupcontainer => 0,
        force => 0,
    );

    GetOptions(
        "target=s" => \$opts{target},
        "setupcontainer" => \$opts{setupcontainer},
        "force" => \$opts{force},
    ) or usage();

    usage() 
        if $opts{setupcontainer}
            and not $opts{target};


    return \%opts;
};

sub containerexists {
    my ($name) = @_;
    return sh("podman container exists $name") == 0;
}

sub imageexists {
    my ($imagename) = @_;
    return sh("podman image exists $imagename") == 0;
}

sub cleanupcontainerandimage {
    my ($container, $image) = @_;
    return sh(<<"EOF");
podman kill $container
podman rm -f $container
podman rmi -f $image
EOF
}

sub setupcontainer {
    my ($opts) = @_;
    my $target = $opts->{target};


    my $releasever = int((split /-/, $target, 3)[1]);
    my $name = "xcattest-el$releasever";

    cleanupcontainerandimage($name, "$name-image")
        if $opts->{force};

    sh("podman build -t $name-image --build-arg RELEASEVER=$releasever test/")
        unless imageexists("$name-image");
    my $script = <<"EOF";
podman create --name $name \\
    --privileged    \\
    --systemd=true  \\
    --cap-add=ALL  \\
    -v "$PWD/test/scripts:/workspace/scripts:Z" \\
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro  \\
    --tmpfs /tmp  \\
    --tmpfs /run \\
    $name-image 
podman start $name
EOF
    sh($script) unless containerexists($name);
}

sub main {
    my $opts = parseopts();

    return setupcontainer($opts) if $opts->{setupcontainer};


    usage();
};

main();
