#!/usr/bin/perl

use strict;
use warnings;

use feature 'say';

use Data::Dumper;
use File::Copy ();
use File::Slurper qw(read_text write_text);
use Parallel::ForkManager;
use Getopt::Long qw(GetOptions);
use Cwd qw();

my $SOURCES = "$ENV{HOME}/rpmbuild/SOURCES";
my $VERSION = read_text("Version");
my $RELEASE = read_text("Release");
my $GITINFO = read_text("Gitinfo");
my $PWD = Cwd::cwd();

chomp($VERSION);
chomp($RELEASE);
chomp($GITINFO);


my @PACKAGES = qw(
    perl-xCAT
    xCAT
    xCAT-buildkit
    xCAT-client
    xCAT-confluent
    xCAT-openbmc-py
    xCAT-probe
    xCAT-rmc
    xCAT-server
    xCAT-test
    xCAT-vlan);

my @TARGETS = qw(
    rhel+epel-8-x86_64
    rhel+epel-9-x86_64
    rhel+epel-10-x86_64);


my %opts = (
    targets => \@TARGETS,
    packages => \@PACKAGES,
    nproc => int(`nproc --all`),
    force => 0,
    verbose => 0,
    deps => "$PWD/../xcat-dep/",
);

GetOptions(
    "target=s@" => \$opts{targets},
    "package=s@" => \$opts{packages},
    "nproc=i" => \$opts{nproc},
    "verbose" => \$opts{verbose},
    "force" => \$opts{force},
    "deps=s" => \$opts{deps},
) or usage();

sub sh {
    my ($cmd) = @_;
    say "Running: $cmd"
        if $opts{quiet};
    open my $fh, "-|", "bash -lc '$cmd'" or die "cannot run $cmd: $!";

    while (my $line = <$fh>) {
        print $line
            if $opts{verbose};
    }
    close $fh;
    return $? >> 8;
}

# cp $src, $dst copies $src to $dst or aborts with an error message
sub cp {
    my ($src, $dst) = @_;
    File::Copy::copy($src, $dst) or die "copy $src, $dst failed: $!";
}

# sed { s/foo/bar/ } $filepath applies s/foo/bar/ to the file at $filepath
sub sed (&$) {
    my ($block, $path) = @_;
    my $content = read_text($path);
    local $_ = $content;
    $block->();
    $content = $_;
    write_text($path, $content);
}

# product(\@A, \@B) returns the catersian product of \@A and \@B
sub product {
    my ($a, $b) = @_;
    return map {
        my $x = $_;
        map [ $x, $_ ], @$b;
    } @$a
}

sub createmockconfig {
    my ($pkg, $target) = @_;
    my $chroot = "$pkg-$target";
    my $cfgfile = "/etc/mock/$chroot.cfg";
    return if -f $cfgfile && ! $opts{force};
    cp "/etc/mock/$target.cfg", $cfgfile;
    my $contents = read_text($cfgfile);
    $contents =~ s/config_opts\['root'\]\s\+=.*/config_opts['root'] = \"$chroot\"/;
    if ($pkg eq "perl-xCAT") {
        # perl-generators is required for having perl(xCAT::...) symbols
        # exported by the RPM 
        $contents .= "config_opts['chroot_additional_packages'] = 'perl-generators'\n";
    }
    write_text($cfgfile, $contents);
}

sub buildsources {
    my ($pkg, $target) = @_;

    if ($pkg eq "xCAT") {
        my @files = ("bmcsetup", "getipmi");
        for my $f (@files) {
            cp "xCAT-genesis-scripts/usr/bin/$f", "$pkg/postscripts/$f";
            sed { s/xcat.genesis.$f/$f/ } "${pkg}/postscripts/$f";
        }
        qx {bash -c '
          cd xCAT
          tar --exclude upflag -czf $SOURCES/postscripts.tar.gz  postscripts LICENSE.html
          tar -czf $SOURCES/prescripts.tar.gz  prescripts
          tar -czf $SOURCES/templates.tar.gz templates
          tar -czf $SOURCES/winpostscripts.tar.gz winpostscripts
          tar -czf $SOURCES/etc.tar.gz etc
          cp xcat.conf $SOURCES
          cp xcat.conf.apach24 $SOURCES
          cp xCATMN $SOURCES
        '};
    } else {
      `tar -czf "$SOURCES/$pkg-$VERSION.tar.gz" $pkg`;
    }
}

sub buildspkgs {
    my ($pkg, $target) = @_;
    my $chroot = "$pkg-$target";

    my $diskcache = "dist/$target/srpms/$pkg-$VERSION-$RELEASE.src.rpm";
    return if -f $diskcache and not $opts{force};

    my @opts;
    push @opts, "--quiet" unless $opts{verbose};

    say "Building $diskcache";

    sh(<<"EOF");
mock -r $chroot \\
    -N \\
    @{[ join "  ", @opts ]} \\
    --define "version $VERSION" \\
    --define "release $RELEASE" \\
    --define "gitinfo $GITINFO" \\
    --buildsrpm \\
    --spec $pkg/$pkg.spec \\
    --sources $SOURCES \\
    --resultdir "dist/$target/srpms/"
EOF
}

sub buildpkgs {
    my ($pkg, $target) = @_;
    my $optsref = \%opts;
    my $chroot = "$pkg-$target";

    my $targetarch = (split /-/, $target, 3)[2];
    my $arch = $pkg eq "xCAT" ? $targetarch : "noarch";

    my $diskcache = "dist/$target/rpms/$pkg-$VERSION-$RELEASE.$arch.rpm";
    return if -f $diskcache and not $opts{force};

    my @opts;
    push @opts, "--quiet" unless $opts{verbose};

    say "Building $diskcache";

    sh(<<"EOF");
mock -r $chroot \\
    -N \\
    @{[ join "  ", @opts ]} \\
    --define "version $VERSION" \\
    --define "release $RELEASE" \\
    --define "gitinfo $GITINFO" \\
    --resultdir "dist/$target/rpms/" \\
    --rebuild dist/$target/srpms/$pkg-${VERSION}-${RELEASE}.src.rpm
EOF
}

sub buildall {
    my ($pkg, $target) = @_;
    createmockconfig($pkg, $target);
    buildsources($pkg, $target);
    buildspkgs($pkg, $target);
    buildpkgs($pkg, $target);
}

sub configure_nginx {
    my $deps = $opts{deps};
    my $conf = <<"EOF";
server {
    listen 8080;
    listen [::]:8080;
EOF
    for my $target ($opts{targets}->@*) {
        my $fullpath = "$PWD/dist/$target/rpms";
        $conf .= <<"EOF";
    location /$target/ {
        alias $fullpath/; 
        autoindex on;
        index off;
        allow all;
    }
EOF
    }
    # TODO:I need one xcat-dep for each target
    $conf .= <<"EOF";
    location /xcat-dep/ {
        alias $deps; 
        autoindex on;
        index off;
        allow all;
    }
}
EOF
    write_text("/etc/nginx/conf.d/xcat-repos.conf", $conf);
}

sub update_repo {
    my ($target) = @_;
    say "Creating repository dist/$target/rpms";
    `find dist/$target/rpms -name ".src.rpm" -delete`;
    `createrepo --update dist/$target/rpms`;
}


sub usage {
    my ($errmsg) = @_;
    say STDERR "Usage: $0 [--package=<pkg1>] [--target=<tgt1>] [--package=<pgk2>] [--target=<tgt2>] ...";

    say STDERR $errmsg if $errmsg;
    exit -1;
}

sub main {
    my @rpms = product($opts{packages}, $opts{targets});
    my $pm = Parallel::ForkManager->new($opts{nproc});

    for my $pair (@rpms) {
        my ($pkg, $target) = $pair->@*;
        $pm->start and next;

        buildall($pkg, $target);

        $pm->finish;
    }

    $pm->wait_all_children;

    for my $target ($opts{targets}->@*) {
        $pm->start and next;

        update_repo($target);

        $pm->finish;
    }
    $pm->wait_all_children;

    configure_nginx();

    `systemctl restart nginx`;
}

main();

