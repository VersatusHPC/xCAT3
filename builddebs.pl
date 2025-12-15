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

my @PACKAGES = qw(
  perl-xCAT
  xCAT
  xCAT-client
  xCAT-server
  xCAT-vlan

  xCATsn
  xCAT-test
);
# xCAT-genesis-scripts

my @RELEASES = qw(
  jammy
  noble
  resolute
);

my %opts = (
  help => 0,
  create_tarball => "",
  verbose => 0,
  force => 0,
  init => "",
);

GetOptions(
  "help" => \$opts{help},
  "force" => \$opts{force},
  "verbose" => \$opts{verbose},
  "create-tarball=s" => \$opts{create_tarball},
  "init=s" => \$opts{init},
) or usage();


main();

sub sh {
    my ($cmd) = @_;
    my $debug = "";
    $debug = "set -x;" if $opts{verbose};
    open my $fh, "-|", "bash -lc '$debug $cmd'" or die "cannot run $cmd: $!";

    while (my $line = <$fh>) {
        print $line
            if $opts{verbose};
    }
    close $fh;
    return $? >> 8;
}

sub usage {
  say STDERR "Usage:";
  say STDERR "$0 --help .............. displays this help message";
  say STDERR "$0 --force ............. recreate files";
  say STDERR "$0 --create-tarball <path> .... create the pristine tarball for <path>";
  say STDERR "$0 --init <release> .... Setup distro caches (run once)";
  say STDERR "     where <release> := @{[ join '|', @RELEASES ]}";

  exit -1;
}

# grep_file {/PATTERN/} $file returns the first match groups in $file
sub grep_file (&$%) {
  my ($block, $path, %opts) = @_;
  open my $fh, "<", $path
     or die "open $path failed: $1";
  for (<$fh>) {
    my @results = $block->();
    return @results if @results;
  }

  croak "grep_file failed: $path"
    unless $opts{-noerr};
}

sub contains {
  my $needle = shift;
  for (@_) {
    return 1 if $needle eq $_;
  }

  return 0;
}

sub init {
  my $release = $opts{init};
  croak "Invalid release $release" unless 
    $release && contains($release, @RELEASES);

  my $path = "~/.cache/sbuild/$release-amd64-sbuild.tar";
  return if -e $path && ! $opts{force};
  say "Initializing $path";
  sh(<<"EOF");
mmdebstrap \\
  --arch=amd64 \\
  --skip=output/mknod \\
  --components=main,universe \\
  --format=tar \\
  $release \\
  $path \\
  http://archive.ubuntu.com/ubuntu
EOF
}

# Receives a build target and a source directory
# Find the most recent file in the source directory
# and the target. If the target has newest modification
# time we can skip the build, otherwise we must rebuild
# as the source changed
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
  my ($path) = $opts{create_tarball};
  my ($name) = grep_file {/Source: (.*)/} "$path/debian/control";
  my ($version) =
    grep_file {/$name\s+\(([^\-]+)/} "$path/debian/changelog";

  my $tarname = "$FindBin::Bin/${name}_$version.orig.tar.gz";
  return if -e $tarname && !source_changed($tarname, $path) && ! $opts{force};

  say "Building $tarname";

  sh(<<"EOF");
git log -n1 --pretty=%h > $FindBin::Bin/Gitinfo
cp $FindBin::Bin/Gitinfo $path/
tar --exclude './debian' -czf $tarname  -C $path .
EOF
}


sub main {
  return create_tarball if $opts{create_tarball};
  return init if $opts{init};
};


