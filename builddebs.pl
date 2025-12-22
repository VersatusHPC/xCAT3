#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';

use Carp qw(croak);
use Cwd qw(cwd);
use Data::Dumper qw(Dumper);
use File::Basename qw(basename fileparse dirname);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
use Pod::Usage;
use Time::HiRes qw(gettimeofday tv_interval);

use lib "$Bin/test/lib/";

use Sh;
use Utils qw(grep_file sed_file cartesian_product is_in);


my @DEPS = qw(
    libparallel-forkmanager-perl
    libscalar-list-utils-perl
    libfile-slurper-perl
    apt-cacher-ng
);

eval {
    my $dep = "";
    require Parallel::ForkManager;
    Parallel::ForkManager->import();
    require List::Util;
    List::Utils->import();
    require File::Slurper;
    File::Slurper->import(qw(read_text write_text));
    1;
} or die(<<"EOF");
Error while loading dependencies: $!, run

    apt install -y @{[ join " ", @DEPS ]}

and try again.
EOF

my $VERSION = read_text("$Bin/Version");
my $RELEASE = lc read_text("$Bin/Release");
chomp $VERSION; chomp $RELEASE;

my @PACKAGES = qw(
    perl-xCAT
    xCAT
    xCATsn
    xCAT-client
    xCAT-server
    xCAT-vlan
    xCAT-test
    xCAT-genesis-scripts
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
    init_nginx => 0,
    init_reprerpo => 0,
    nproc => int(`nproc --all`),
    output => "$Bin/dist",
    kill_timeout => 30,
    keep_going => 0,
    build_num => 1,
    repos_path => "/var/www/html/repos/xcat-core",
    create_repos => 0,
    nginx_port => 8080,
    xcat_dep_mirror => "https://mirror.versatushpc.com.br/xcat/apt/xcat-dep"
);

GetOptions(
    "help" => \$opts{help},
    "force" => \$opts{force},
    "verbose" => \$opts{verbose},
    "create-tarball=s" => \$opts{create_tarball},
    "build-source-package=s" => \$opts{build_source_package},
    "build-package=s" => \$opts{build_package},
    "build-all" => \$opts{build_all},
    "create-repos" => \$opts{create_repos},
    "target=s@" => \$opts{targets},
    "package=s@" => \$opts{packages},
    "init=s" => \$opts{init},
    "init-all" => \$opts{init_all},
    "init-nginx" => \$opts{init_nginx},
    "init-reprepro" => \$opts{init_reprepro},
    "nproc=i" => \$opts{nproc},
    "output=s" => \$opts{output},
    "kill-timeout=i" => \$opts{kill_timeout},
    "keep-going" => \$opts{keep_going},
    "build-num=i" => \$opts{build_num},
    "repos-path=s" => \$opts{repos_path},
    "nginx-port=i" => \$opts{nginx_port},
) or pod2usage(2);

exit(main());

sub script_opts {
    my (%func_opts) = @_;

    my $script_opts;
    if ($opts{verbose}) {
        $script_opts .= "set -x"
    } else {
        $script_opts .= "exec > /dev/null; ";
        $script_opts .= "exec 2> /dev/null; "
            if $func_opts{-disable_stderr};
    }
    return $script_opts;
}

sub validate_targets {
    for (@_) {
        die "Invalid target: $_, expect one of: ", join ", ", @TARGETS
            unless (defined($_) && is_in($_, \@TARGETS));
    }
}

sub validate_packages {
    for (@_) {
        die "Invalid package: $_, expect one of: ", join ", ", @PACKAGES
            unless (defined($_) && is_in($_, \@TARGETS));
    }
}

sub init {
    my $target = shift // $opts{init};
    validate_targets($target);

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
    --include=build-essential,devscripts \\
    $target \\
    $path \\
    http://127.0.0.1:3142/archive.ubuntu.com/ubuntu < /dev/null
    # disables stdin
EOF
}
sub init_reprepro {
    my ($repos_path) = @_;
    $repos_path //= $opts{repos_path};
    make_path("$repos_path/conf/");
    return -1 unless -d "$repos_path/conf/";
    my $template = <<"EOF";
Origin: xCAT3 - Ubuntu 26.04
Label: Stable Repository
Suite: xcat/test
Codename: resolute
Architectures: amd64
Components: main universe
Description: Stable Repository

Origin: xCAT3 - Ubuntu 24.04
Label: Stable Repository
Suite: xcat/test
Codename: noble
Architectures: amd64
Components: main universe
Description: Stable Repository

Origin: xCAT3 - Ubuntu 22.04
Label: Stable Repository
Suite: xcat/test
Codename: jammy
Architectures: amd64
Components: main universe
Description: Stable Repositor
EOF
    write_text("$repos_path/conf/distributions", $template);
    return 0;
}

sub init_nginx {
    my ($port) = @_;
    $port //= $opts{nginx_port};

    make_path($opts{repos_path});
    my ($mirror_url, $mirror_path) = split '/', $opts{xcat_dep_mirror}, 2;
    $mirror_path =~ s|/$||;

    write_text("/etc/nginx/conf.d/local-repos.conf", <<"EOF");
proxy_cache_path /var/cache/nginx/apt/xcat-dep
    levels=1:2
    keys_zone=xcatdep_cache:100m
    max_size=20g
    inactive=30d
    use_temp_path=off;

server {
    listen $port;
    listen [::]:$port;
    root /var/www/html/;

    location /repos/xcat-dep/ {
      	proxy_pass $mirror_url/$mirror_path/;
        proxy_cache xcatdep_cache;
        proxy_cache_valid 200 301 302 30d;
        proxy_cache_lock on;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_set_header Host $mirror_url;
        proxy_ignore_headers Cache-Control Expires;
        add_header X-Cache \$upstream_cache_status;
    }

    location /repos/xcat-core/ {
        autoindex on;
        index off;
        allow all;
    }
}
EOF

    return Sh::run(<<"EOF");
@{[ script_opts ]}
systemctl restart nginx
EOF
}

sub init_all {
    my $pm = shift // Parallel::ForkManager->new($opts{nproc});

    init_nginx or return -1;
    init_reprepro or return -2;

    my $exit_code = 0;
    $pm->run_on_finish(sub {
        my ($pid, $exit, $name) = @_;
        if ($exit != 0) {
            say STDERR "Initialization of $name failed with status $exit";
            $exit_code = $exit
                unless $exit_code;
        }
    });
    for my $target (@TARGETS) {
        $pm->start($target) and next;
        $pm->finish(init($target));
    }

    $pm->wait_all_children;


    return $exit_code;
}

# Returns 1 if $source_dir changed
# after $target. $target is expected to be a
# file, not a directory
sub source_changed {
    my ($target, $source_dir) = @_;
    croak "source_changed: invalid arguments $target, $source_dir"
        unless -f $target && -d $source_dir;

    # print <timestamp> <file> list
    # sort by <timestamp> descending
    # return the first <file> in the list
    # resolve its path
    my $result = `
        find $target $source_dir \\
            -type f -printf '%T@ %p\n' \\
            | sort -nrk1 | head -1 | \\
            awk '{print \$2}' | xargs realpath`;
    chomp $result;
    return $result ne $target;
}

sub fmt_version {
    my ($target) = @_;
    return "$VERSION~$target~$RELEASE-$opts{build_num}"
}

sub create_tarball {
    my $path = shift // $opts{create_tarball};
    my ($name) = grep_file "$path/debian/control", qr/Source: (.*)/;
    my ($version) =
        grep_file "$path/debian/changelog", qr/$name\s+\(([^\-]+)/;

    my $tarname = "$Bin/${name}_$version.orig.tar.gz";
    return if !$opts{force} && -e $tarname && !source_changed($tarname, $path);

    say "Building ", File::Spec->abs2rel($tarname);

    my $exit = Sh::run(<<"EOF");
git log -n1 --pretty=%h > $Bin/Gitinfo
cp $Bin/Gitinfo $path/
cp $Bin/Release $path/
cp $Bin/Version $path/
tar --exclude './debian' -czf $tarname    -C $path .
EOF
    return $exit unless $exit == 0;
    
    -e $tarname or return -1;
    return 0;
}

sub build_source_package {
    my $path = shift // $opts{build_source_package};

    my $targets = $opts{targets};

    for my $target ($targets->@*) {
        my ($name) = grep_file "$path/debian/control", qr/Source: (.*)/;
        my $script_opts = script_opts(-disable_stderr => 1);

        `cp $path/debian/changelog $path/debian/changelog.orig`
            unless -f "debian/changelog.orig";

        my $exit = Sh::run(<<"EOF");
$script_opts
cd $path
cp debian/changelog.orig debian/changelog
rm debian/changelog.dch 2> /dev/null || :
dch -D $target -b -v "$VERSION~$target~$RELEASE-$opts{build_num}" "Rebuild for Ubuntu ($target)
"

EOF
        return $exit unless $exit == 0;

        my $version = fmt_version($target);
        my $pkgname = "${name}_${version}";

        my @files = (
            "$path/../$pkgname.dsc",
            "$path/../$pkgname.debian.tar.xz",
        );

        my $all_files_exists = List::Util::all { -e } @files;

        next if $all_files_exists && !$opts{force};

        my $fpath = File::Spec->abs2rel("$Bin/$pkgname.dsc");

        say "Building $fpath";

        create_tarball($path);

        $exit = Sh::run(<<"EOF");
$script_opts
cd $path; dh_clean; dpkg-buildpackage -S -uc -us
EOF
        return $exit unless $exit == 0;

        if (!-e $fpath) {
            say STDERR "Build $fpath finished but no file was created, aborting ...";
            return -1;
        }
    }

    return 0;
}

sub package_to_dsc {
    my $path = shift // $opts{build_source_package};
    my $target = shift;

    my ($name) = grep_file "$path/debian/control", qr/Source: (.*)/;
    my ($version) = fmt_version($target);
    my $pkgname = "${name}_${version}";

    return "$Bin/$pkgname.dsc";
}

sub build_package {
    my ($dsc, $target) = @_;
    die "--build-package expect a single --target"
        if !defined($target) && $opts{targets}->@* > 1;
    $dsc //= $opts{build_package};
    $target //= $opts{targets}->[0];

    die "Invalid argument expected '$dsc' to be a .dsc file"
        unless $dsc =~ /\.dsc$/ && -f $dsc;

    my ($name) = fileparse($dsc, ".dsc");
    my $arch = $name =~ /^(?:xcat|xcatsn)_/
        ? "amd64" 
        : "all";

    my $deb = "${name}_$arch.deb";
    my $path = "$opts{output}/ubuntu/$target/$deb";
    return if -e $path && !$opts{force};

    say "Building ", File::Spec->abs2rel($path), " for $target";


    my $cmdopts = "";
    $cmdopts .= " --verbose" if $opts{verbose};

    my $builddir = dirname($path);

    unless (-d $builddir) {
        say STDERR "Build directory does not exists, $builddir, aborting ...";
        return 255;
    }

    my $exit = Sh::run(<<"EOF");
@{[ script_opts ]}

sbuild -d $target $cmdopts --build-dir '$builddir' '$dsc'
EOF

    return $exit
        unless ($exit == 0);

    if (!-e $path) {
        say STDERR "Build $path finished, but no file was generated, aborting ...";
        return 254;
    }

    return 0;
}

sub fmt_human_interval {
    my $s = shift;

    my $h = int($s / 3600);
    my $m = int(($s % 3600) / 60);
    my $sec = $s % 60;

    my @out;
    push @out, "${h}h" if $h;
    push @out, "${m}m" if $m;
    push @out, sprintf "%.fs", $sec if $sec || !@out;

    return sprintf "%12s", join " ", @out;
}

sub print_summary {
    my ($summary, $times) = @_;

    for my $s (values $summary->%*) {
        my $time = fmt_human_interval($times->{$s->{pid}});
        say sprintf("Build finished: %-20s in $time (exit %d) (signal %d)", 
            $s->{name}, $s->{exit}, $s->{signal});
    }
}

sub create_target_directories {
    my $basedir = "$opts{output}/ubuntu";
    my @paths = map { "$basedir/$_" } @_;
    make_path(@paths);
    return List::Util::all { -d  } @paths;
}

sub setup_reprepro {
    die "TODO";
}

sub create_repos {
    my ($targets, $out_path) = @_;
    $targets //= $opts{targets};
    $out_path //= $opts{repos_path};

    my $exit = 0;
    for my $target ($targets->@*) {
        say "Building repository $target at $out_path";
        my $src_path = "$opts{output}/ubuntu/$target";
        my $exit_tmp = Sh::run(<<"EOF");
@{[ script_opts ]}
cd $out_path
reprepro removematched $target '*'
reprepro includedeb $target $src_path/*.deb
EOF
        if ($exit_tmp != 0) { 
            say STDERR "Building repository failed with status $exit_tmp";
            exit($exit_tmp) if !$opts{keep_going};
            $exit = $exit_tmp
                unless $exit;
        }
    }
    return $exit;
}


sub build_all {
    say "Build dir: ", Cwd::cwd();

    my ($packages, $targets) = @_;
    $packages //= $opts{packages};
    $targets //= $opts{targets};

    validate_targets($targets->@*);
    validate_packages($packages->@*);

    for my $pkg ($packages->@*) {
        die("Invalid package $pkg, expect one of: ", join ", ", @PACKAGES)
            unless List::Util::any { $pkg eq $_ } @PACKAGES;
    }

    create_target_directories($targets->@*)
        or die("ERROR Creating directories");

    Sh::run("rm -rf /tmp/tmp.sbuild.*");

    my $all = cartesian_product($packages, $targets);
    my $pm = Parallel::ForkManager->new($opts{nproc});

    # Ignore SIGTERM, we'll use it to kill child processes
    $SIG{'TERM'} = 'IGNORE';

    my %summary;
    my %times;
    my $aborting = 0;

    $pm->run_on_start(sub {
        my ($pid, $name) = @_;
        $times{$pid} = gettimeofday();
    });

    # Install finish callback, it should terminate
    # other children processes if one of them fail
    $pm->run_on_finish(sub {
        my ($pid, $exit, $name, $signal, $core, $data) = @_;
        $summary{$pid} = {
            pid => $pid,
            exit => $exit,
            signal => $signal,
            core => $core,
            name => $name,
        };
        $times{$pid} = tv_interval([$times{$pid}]);
        return if $aborting;
        if ($exit != 0 && !$opts{keep_going}) {
            $aborting = 1;
            say STDERR "!!!FAILURE!!! Build process $name, failed with exit status: $exit, aborting ...";

            # Setup timeout handlers. We're going to kill all children process
            # with SIGTERM, if they do not exit after --kill-timeout, we kill
            # them with SIGKILL signal, then wait all them to exit and print
            # the summary
            my $handle_timeout = sub { 
                say STDERR '!!!TIMEOUT!!! Killing the reimaing processes with SIGKILL: ',
                    join ', ', values {$pm->running_procs_with_identifiers}->%*;
                # set signal fields to 9 (except for our own pid)
                for ($pm->running_procs) {
                    next if $_ == $pid;
                    $summary{$_}->{signal} = 9;
                    $times{$_} = tv_interval([$times{$pid}]);;
                    kill 'SIGKILL', $_;
                }
            };

            my $timeout = $opts{kill_timeout};
            if ($timeout > 0) {
                local $SIG{'ALRM'} = $handle_timeout;
                alarm $opts{kill_timeout};

                # Send SIGTERM to all chlid process
                kill 'SIGTERM', 0;
            } elsif ($timeout == 0) {
                # kill all processes with SIGKILL immediately
                $handle_timeout->();
            }
            $pm->wait_all_children;
            print_summary(\%summary, \%times);
            exit($exit);

        }
    });

    for my $package ($packages->@*) {
        $pm->start(lc $package . ":source") and next;
        # This is required because we set it to IGNORE in the parent
        $SIG{'TERM'} = 'DEFAULT';
        $pm->finish(build_source_package($package));
    };
    $pm->wait_all_children;

    for my $pair ($all->@*) {
        my ($package, $target) = $pair->@*;
        my $dsc = package_to_dsc($package, $target);
        $pm->start(lc $package . ":$target") and next;
        $SIG{'TERM'} = 'DEFAULT';
        $pm->finish(build_package($dsc, $target));
    };
    $pm->wait_all_children;

    # Create repositories serially to make reprepro life easier
    my $exit = create_repos($targets);
    print_summary(\%summary, \%times);
    return $exit;
}

sub main {
    return pod2usage(1) if $opts{help};

    return create_tarball if $opts{create_tarball};
    return build_source_package if $opts{build_source_package};
    return build_package if $opts{build_package};
    return create_repos if $opts{create_repos};
    return init if $opts{init};
    return init_all if $opts{init_all};
    return init_nginx if $opts{init_nginx};
    return init_reprepro if $opts{init_reprepro};
    return build_all if $opts{build_all};

    pod2usage(2);
    return -1;
};

__END__

=head1 NAME

builddebs.pl - Build xCAT Debian/Ubuntu packages across multiple releases

=head1 SYNOPSIS

builddebs.pl [options]

  builddebs.pl --help

  builddebs.pl --create-tarball <path>

  builddebs.pl --build-source-package <path>

  builddebs.pl --build-package <package.dsc> --target <target>

  builddebs.pl --build-all
      [--target <target>]...
      [--package <package>]...

  builddebs.pl --init <target>
  builddebs.pl --init-all

=head1 DESCRIPTION

This tool automates the build pipeline for xCAT Debian packages across
multiple Ubuntu releases. With B<--build-all> it builds all the Ubuntu
packages for all releases, in parallel.

During the build, if any process fails (exit with non-zero status code)
the entire build is canceled, and the running build processes are killed.
This is "by design", to make the CI fails fast.

It supports:

=over 4

=item *

Creating pristine upstream tarballs

=item *

Building Debian source packages (.dsc)

=item *

Building binary packages via sbuild

=item *

Parallel multi-package / multi-release builds

=item *

Bootstrap and caching of sbuild environments using mmdebstrap

=back

Parallelism is controlled via C<--nproc>.  
Failures abort the remaining build jobs and print a timing summary.

=head1 OPTIONS

=head2 Primary actions (exactly one required)

=over 4

=item B<--create-tarball> I<path>

Create the pristine upstream tarball (C<.orig.tar.gz>) for the package
located at I<path>. The Debian directory is excluded.

=item B<--build-source-package> I<path>

Build a Debian source package (C<.dsc>, C<.debian.tar.xz>) for the package
located at I<path>.

=item B<--build-package> I<package.dsc>

Build a binary package from an existing source package. Requires exactly
one C<--target>.

=item B<--build-all>

Build all configured packages for all configured targets.  
Respects C<--package> and C<--target> filters if provided.

=item B<--init> I<target>

Initialize and cache (mmdebstrap) an sbuild environment for the given Ubuntu release.

=item B<--init-all>

Initialize sbuild environments for all supported targets in parallel.

=item B<--help>

Display this help message and exit.

=back

=head2 Target and package selection

=over 4

=item B<--target> I<name>

Ubuntu release target. May be specified multiple times.

Supported targets:

  jammy
  noble
  resolute

Default: all targets.

=item B<--package> I<name>

Limit operations to specific packages. May be specified multiple times.

Default packages:

  perl-xCAT
  xCAT
  xCATsn
  xCAT-client
  xCAT-server
  xCAT-vlan
  xCAT-test

=back

=head2 Build behavior

=over 4

=item B<--nproc> I<N>

Maximum number of parallel jobs.  
Defaults to the number of available CPU cores (returned from `nproc --all`)

=item B<--output> I<path>

Change the output directory where backages are generated,
which is "dist" by default. The path will be created if
does not exists, but the user running this script need
permission to create it. Should not end with '/'

=item B<--kill-timeout> I<seconds>

When a build process fails the other running processes receive
a SIGTERM. If they do not exit uppon a timeout, they are
killed with SIGKILL. Use this option to change the timeout
beforing sending SIGKILL. It is 30 by default.

This is to avoid having builds hanging in the CI.

=item B<--keep-going>

As said above the default behavior is to fail fast and abort
the build as soon as the first failure occurs. This option
enable the builds to keep running even after a failure.

=item B<--verbose>

This script will call debian build tools in parallel which
will generate a lot of intermixed output if not supressed.
Because of that the sbuild STDOUT is supressed, also note
that for B<dpkg-buildpackage> STDERR is also supressed because
it outputs non-sense to it.

You can use B<--verbose> to NOT suppress STDOUT and STDERR at
all, then all commands will be echoed to the STDOUT, together
with its output and errors.

Since sbuild STDERR is not suppressed, if you'll see if any
error is printed to it, by default.

=back

=head1 EXAMPLES

=over 4

Run once to create the mmdebstrap caches.

  ./builddebs.pl --init-all

If you do not do this the builds will work but it runs
mmdebstrap at each build which is inneficient.

Then run everytime you need to build the packages

  ./builddebs.pl --build-all

If you want to rebuild a single package

  ./builddebs.pl --build-all --package <path>

Where <path> is of the subdirectories in the repository
like xCAT, xCAT-server, xCAT-client, etc ...

If you want to build a single package for a single target:

  ./builddebs.pl --build-all --package <path> --target <target>

If you want to rebuild a single package for a single target, overriding
previous build:

  ./builddebs.pl --build-all --package <path> --target <target> --force

If you want to debug the output of the reuibld of a single package
for a single target, overriding the previous builds

  ./builddebs.pl --build-all --package <path> --target <target> --force --verbose

=back
