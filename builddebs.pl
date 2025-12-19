#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';

use Data::Dumper qw(Dumper);
use Getopt::Long qw(GetOptions);
use File::Basename qw(basename);
use Cwd qw(cwd);
use Carp qw(croak);
use FindBin qw();
use Test::More;

use lib "$FindBin::Bin/test/lib/";

use Sh;

my @DEPS = qw(
    libparallel-forkmanager-perl
    libscalar-list-utils-perl
);

eval {
    my $dep = "";
    require Parallel::ForkManager;
    require List::Util;
    Parallel::ForkManager->import();
    List::Utils->import();
    1;
} or die(<<"EOF");
Error while loading dependencies, run

    apt install -y @{[ join " ", @DEPS ]}

and try again.
EOF


my @PACKAGES = qw(
    perl-xCAT
    xCAT
    xCATsn
    xCAT-client
    xCAT-server
    xCAT-vlan
    xCAT-test
);
# xCAT-genesis-scripts

my @TARGETS = qw(
    jammy
    noble
    resolute
);

my %opts = (
    help => 0,
    create_tarball => "",
    build_source_package => "",
    build_package => "",
    build_all => 0,
    targets => \@TARGETS,
    packages => \@PACKAGES,
    verbose => 0,
    force => 0,
    init_all => 0,
    init => "",
    nproc => int(`nproc --all`),
    test => 0,
);

GetOptions(
    "help" => \$opts{help},
    "force" => \$opts{force},
    "verbose" => \$opts{verbose},
    "create-tarball=s" => \$opts{create_tarball},
    "build-source-package=s" => \$opts{build_source_package},
    "build-package=s" => \$opts{build_package},
    "build-all" => \$opts{build_all},
    "target=s@" => \$opts{targets},
    "package=s@" => \$opts{packages},
    "init=s" => \$opts{init},
    "init-all" => \$opts{init_all},
    "test" => \$opts{test},
) or usage();


main();


sub usage {
    say STDERR "Usage:";
    say STDERR "$0 --help ............................... Displays this help message";
    say STDERR "$0 --create-tarball <path> .............. Create the pristine tarball for <path>";
    say STDERR "$0 --init <target> ...................... Setup distro caches (run once)";
    say STDERR "         where <target> := @{[ join '|', @TARGETS ]}";
    say STDERR "$0 --init-all ........................... Call --init for all targets in parallel";
    say STDERR "$0 --build-source-package <path> ........ Build source package for <path>";
    say STDERR "$0 --build-package <package.dsc> \\ ..... Build package <package.dsc> for ";
    say STDERR "     --target <target> .................... <target>";
    say STDERR "$0 --build-all .......................... Build all packages for all targets";
    say STDERR "";
    say STDERR "Other options:";
    say STDERR "";
    say STDERR "     --nproc <N> .......................... The amount of cores to use as parallelism";
    say STDERR "     --force .............................. Override previous builds in the disk";
    say STDERR "     --verbose ............................ More output";
    say STDERR "$0 --build-all --target T1 --target T2 \\ Build only for the targets and packages";
    say STDERR "         --package P1 --package P2 .......... specified in the command line";

    exit -1;
}

sub cartesian_product {
    my ($A, $B) = @_;
    return [ map {
            my $x = $_;
            map [ $x, $_ ], $B->@*;
    } $A->@* ];
}

sub test_cartesian_product {
    is_deeply(cartesian_product([1,2], ['a', 'b']),
        [[1, 'a'], [1, 'b'], [2, 'a'], [2, 'b']]);
}
            
sub contains {
    my $needle = shift;
    for (@_) {
        return 1 if $needle eq $_;
    }

    return 0;
}

sub test_contains {
    is(contains(0, 9,9,9,9,0), 1);
}

sub init {
    my $target = shift // $opts{init};
    croak "Invalid target $target" unless 
        $target && contains($target, @TARGETS);

    my $cmdopts = "";
    $cmdopts .= " --quiet" if !$opts{verbose};
    $cmdopts .= " --verbose" if $opts{verbose};

    my $basepath = "$ENV{HOME}/.cache/sbuild";
    `mkdir -p $basepath`
        unless -d $basepath;
    my $path = "$basepath/$target-amd64-sbuild.tar.zst";

    return if -e $path && ! $opts{force};
    say "Initializing $path";
    return Sh::run(<<"EOF");
mmdebstrap \\
    $cmdopts \\
    --arch=amd64 \\
    --skip=output/mknod \\
    --components=main,universe \\
    --format=tar \\
    $target \\
    $path \\
    http://archive.ubuntu.com/ubuntu < /dev/null
                                                                     # disables stdin
EOF
}

sub init_all {
    my $pm = shift // Parallel::ForkManager->new($opts{nproc});
    for my $target (@TARGETS) {
        $pm->start and next;
        init($target);
        $pm->finish;
    }

    $pm->wait_all_children;
}

# Returns 1 if $source_dir changed
# before $target. $target is expected to be a
# file, not a directory
sub source_changed {
    my ($target, $source_dir) = @_;
    my $result = `
        find $target $source_dir \\
            -type f -printf '%T@ %p\n' \\
            | sort -nrk1 | head -1 | \\
            awk '{print \$2}' | xargs realpath`;
    chomp $result;
    return $result ne $target;
}

sub create_tarball {
    my $path = shift // $opts{create_tarball};
    my ($name) = Sh::grep_file "$path/debian/control", qr/Source: (.*)/;
    my ($version) =
        Sh::grep_file "$path/debian/changelog", qr/$name\s+\(([^\-]+)/;

    my $tarname = "$FindBin::Bin/${name}_$version.orig.tar.gz";
    return if -e $tarname && !source_changed($tarname, $path) && ! $opts{force};

    say "Building $tarname";

    return Sh::run(<<"EOF");
git log -n1 --pretty=%h > $FindBin::Bin/Gitinfo
cp $FindBin::Bin/Gitinfo $path/
tar --exclude './debian' -czf $tarname    -C $path .
EOF
}

sub build_source_package {
    my $path = shift // $opts{build_source_package};

    my ($name) = Sh::grep_file "$path/debian/control", qr/Source: (.*)/;
    my ($version) =
        Sh::grep_file "$path/debian/changelog", qr/$name\s+\(([^)]+)/;
    my $pkgname = "${name}_${version}";

    my @files = (
        "$path/../$pkgname.dsc",
        "$path/../$pkgname.debian.tar.xz",
    );

    my $all_files_exists = List::Util::all { -e } @files;

    return if $all_files_exists && !$opts{force};

    say "Building source package $pkgname";

    create_tarball($path);

    return Sh::run(<<"EOF");
cd $path; dh_clean; dpkg-buildpackage -S -uc -us
EOF
}

sub package_to_dsc {
    my $path = shift // $opts{build_source_package};

    my ($name) = Sh::grep_file "$path/debian/control", qr/Source: (.*)/;
    my ($version) =
        Sh::grep_file "$path/debian/changelog", qr/$name\s+\(([^)]+)/;
    my $pkgname = "${name}_${version}";

    return "$FindBin::Bin/$pkgname.dsc";
}

sub build_package {
    my ($dsc, $target) = @_;
    die "--build-package expect a single --target"
        if !defined($target) && $opts{targets}->@* > 1;
    $dsc //= $opts{build_package};
    $target //= $opts{targets}->[0];

    say "Building package $dsc for $target";

    my $cmdopts = "";
    $cmdopts .= " --verbose" if $opts{verbose};

    `mkdir -p dist/ubuntu/$target`
        unless -d "dist/ubuntu/$target"; 

    return Sh::run(<<"EOF");
sbuild -d $target $cmdopts --build-dir dist/ubuntu/$target/ $dsc 
EOF
}

sub build_all {
    my ($packages, $targets) = @_;
    $packages //= $opts{packages};
    $targets //= $opts{targets};

    my $all = cartesian_product($packages, $targets);
    my $pm = Parallel::ForkManager->new($opts{nproc});

    # Set this process as the process group leader
    setpgrp(0, 0);

    # Ignore SIGTERM, we'll use it to kill child processes
    $SIG{'TERM'} = 'IGNORE';

    # Install finish callback, it should terminate
    # other children processes if one of them fail
    $pm->run_on_finish(sub {
        my ($pid, $exit, $name, $signal, $core, $data) = @_;
        if ($exit != 0) {
            say STDERR "!!!FAILURE!!! Build process $name, failed with exit status: $exit, aborting ...";
            # a child process failed, cancel all the
            # running process in the current process
            # group
            kill 'SIGTERM', 0;
            $pm->wait_all_children;
            exit($exit);
        }
    });

    for my $package ($packages->@*) {
        $pm->start("build_source_package($package)") and next;
        $SIG{'TERM'} = 'DEFAUT';
        $pm->finish(build_source_package($package));
    };
    $pm->wait_all_children;

    for my $pair ($all->@*) {
        my ($package, $target) = $pair->@*;
        my $dsc = package_to_dsc($package);
        $pm->start("build_package($dsc, $target)") and next;
        $SIG{'TERM'} = 'DEFAUT';
        $pm->finish(build_package($dsc, $target));
    };
    $pm->wait_all_children;
}

sub test {
    test_contains();
    test_cartesian_product();
    done_testing();
}

sub main {
    return usage if $opts{help};
    return create_tarball if $opts{create_tarball};
    return build_source_package if $opts{build_source_package};
    return build_package if $opts{build_package};
    return init if $opts{init};
    return init_all if $opts{init_all};
    return test if $opts{test};
    return build_all if $opts{build_all};

    usage();
};


