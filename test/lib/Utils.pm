package Utils;

use feature 'say';

use Data::Dumper qw(Dumper);
use Exporter qw(import);
use Carp; qw(croak);

use File::Slurper qw(write_text read_lines read_text);
use List::Util qw(first);

our @EXPORT_OK = qw(
    cartesian_product
    sed_file
    grep_file
    is_in
);

=head1 NAME

Utils - Small utility functions used during building and testing

=head1 SYNOPSIS

  This module provides simple utility functions that are used
  during building and testing. Since we build for Ubuntu and
  RHEL, there are some common code shared between both build
  scripts

=head1 FUNCTIONS
=cut

=head3 cartesian_product(\@A, \@B)

    Returns the cartesian product of @A and @B

=cut
sub cartesian_product {
    my ($A, $B) = @_;
    return [ map {
            my $x = $_;
            map [ $x, $_ ], $B->@*;
    } $A->@* ];
}

=head3 sed_file BLOCK $PATH

    Apply the BLOCK to each line of file PATH

    The BLOCK should read & update the value of $_

    Example:
        sed_file {s/foo/bar/} "myfile.txt";

=cut
sub sed_file(&$) { 
    my ($block, $file) = @_;
    my @lines;
    open my $fh, "<", $file
        or die "open $file error: $!";

    for (<$fh>) {
        # block reads & modifies $_
        $block->();
        push @lines, $_;
    }
    close $fh;
    write_text($file, join "", @lines);
    return 0;
}


=head3 is_in $NEEDLE, \@HAYSTACK

    Returns 1 if $NEEDLE occurs in \@HAYSTACK, 0 otherwise

=cut
sub is_in {
    my $needle = shift;
    my $haystack_ref = shift;
    return defined(first { $needle == $_ } $haystack_ref->@*);
}


=head3 grep_file($path, $regex1, $regex2, ...)

    scalar context: Returns a hashref with all named matches accumulated.
    list context: Return the first group match

    Example: 

    # Returning a hash with all the matches
    my $mem = grep_file(
        "/proc/meminfo", 
        qr/MemTotal: (?<total>\d+)/
        qr/MemFree: (?<free>\d+)/);

    print "memory free % ", $mem->{free} / $mem->{total}, "\n";

    # Returning the first match as a group
    my ($cache_size) = grep_file("/proc/cpuinfo", 
        qr/cache_size\s+:\s+(\d+)/);

=cut
sub grep_file {
    my ($path, @regexps) = @_;

    open my $fh, "<", $path
        or croak "open $path failed: $!";

    my %out;
    for my $line (<$fh>) {
        for my $regexp (@regexps) {
            if (wantarray) {
                my @found = $line =~ $regexp;
                return @found if @found;
            } else {
                if (my $match = $line =~ $regexp) {
                    # accumulate the named matches in out
                    %out = (%out, %+);
                }
            }
        }
    }

    return wantarray ? () : \%out;
}

1;
