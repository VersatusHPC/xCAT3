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

my %opts = (
  help => 0,
  create_tarball => "",
  verbose => 0,
  force => 0,
);

GetOptions(
  "help" => \$opts{help},
  "force" => \$opts{force},
  "verbose" => \$opts{verbose},
  "create-tarball=s" => \$opts{create_tarball},
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
  say STDERR "                          (expects a debian/ directory inside <path>)";

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

sub create_tarball {
  my ($path) = $opts{create_tarball};
  my ($name) = grep_file {/Source: (.*)/} "$path/debian/control";
  my ($version) =
    grep_file {/$name\s+\(([^\-]+)/} "$path/debian/changelog";

  my $tarname = "$FindBin::Bin/${name}_$version.orig.tar.gz";
  return if -e $tarname && ! $opts{force};

  say "Building $tarname";

  sh(<<"EOF");
git log -n1 --pretty=%h > $FindBin::Bin/Gitinfo
cp $FindBin::Bin/Gitinfo $path/
tar --exclude './debian' -czf $tarname  -C $path .
EOF
}

sub main {
  return create_tarball if $opts{create_tarball};
};


