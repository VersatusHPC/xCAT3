
use strict;
use warnings;
use feature 'say';
use FindBin qw($Bin);
use Test::More;
use Test::Exception;
use File::Slurper qw(write_text read_text read_lines);
use File::Temp qw(tempfile);
use Data::Dumper qw(Dumper);


use lib "$Bin";

use Utils qw(sed_file grep_file cartesian_product contains);

sub test_sed_file {
    # UNLINK => 1: remove the file during exit (not at close)
    my ($tmp_fh, $tmp_file) = tempfile(UNLINK => 1);
    print $tmp_fh <<"EOF";
listen 80;
listen 8080;
listen 1234;
EOF
    close $tmp_fh;

    sed_file { s/listen 80;/listen 8080;/ } $tmp_file;
    my @lines = read_lines($tmp_file);
    is($lines[0], "listen 8080;");
    is($lines[1], "listen 8080;");
    is($lines[2], "listen 1234;");
    sed_file { s/listen 80;/listen 8080;/ } $tmp_file;
    @lines = read_lines($tmp_file);
    is($lines[0], "listen 8080;");
    is($lines[1], "listen 8080;");
    is($lines[2], "listen 1234;");
}

sub test_grep_file {
    my ($tmp_fh, $tmp_path) = tempfile();
    write_text($tmp_path, <<"EOF");
    foo: bar
    tar: zar
    tick: tack toe
EOF

    my $matches = grep_file(
        $tmp_path,
        qr/foo: (?<foo>\w+)/,
        qr/tar: (?<tar>\w+)/);

    is_deeply($matches, {
            foo => "bar",
            tar => "zar"
        });

    my ($tack, $toe) = grep_file(
        $tmp_path,
        qr/tick: (\w+) (\w+)/
    );
    is($tack, "tack");
    is($toe, "toe");
}

sub test_cartesian_product {
    is_deeply(cartesian_product([1,2], ['a', 'b']),
        [[1, 'a'], [1, 'b'], [2, 'a'], [2, 'b']]);
}

sub test_contains {
    is(contains(0, [9,9,9,9,0]), 1);
}

# test_sed_file;
# test_grep_file;
# test_cartesian_product;
test_contains;
done_testing;

