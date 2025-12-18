use strict;
use warnings;
use feature 'say';
use FindBin qw($Bin);
use Test::More;
use Test::Exception;
use File::Slurper qw(write_text read_text);
use File::Temp qw(tempfile);
use Data::Dumper qw(Dumper);

use lib "$Bin";

use Sh;

# Synchronous commands

# run_pipe return exit code and captures output and error
{
    my ($exit, $out_fh, $err_fh) = Sh::run_pipe("echo ok; echo nok >&2; exit 1");
    local $/ = undef;
    (my $out = <$out_fh>) =~ s/\n+//;
    (my $err = <$err_fh>) =~ s/\n+//;

    is($exit, 1);
    is($out, "ok");
    is($err, "nok");
}

# run returns exit status
is(Sh::run("echo 1"), 0);
is(Sh::run("exit 123"), 123);

# output returns the output without trailing line breaks
is(Sh::output("echo 'hello\nworld'"), "hello\nworld");

# ok and output dies on failure
dies_ok { Sh::ok("exit -1"); };
dies_ok { Sh::output("exit -1"); };

# Asynchronous commands

# bg_pipe return exit code and catpures stdout and stderr
{
    my ($pid, $out, $err) = Sh::bg_pipe("echo ok; echo nok >&2; sleep 0.2; exit 1");
    ok(kill 0, $pid); # $pid is running
    waitpid($pid, 0);
    ok(! kill 0, $pid); # $pid is not running anymore
    {
        local $/ = undef;
        (my $output = <$out>) =~ s/\n+//;
        (my $error = <$err>) =~ s/\n+//;
        is($output, "ok");
        is($error, "nok");
    }
}

# bg retursn its exit code
{
    my $pid = Sh::bg("exit 1");
    ok(kill 0, $pid); # $pid is running
    waitpid($pid, 0);
    is($? >> 8, 1); # exit code honored
    ok(! kill 0, $pid); # $pid is not running anymore
}

# grep_file test
{
    my ($tmp_fh, $tmp_path) = tempfile();
    write_text($tmp_path, <<"EOF");
    foo: bar
    tar: zar
EOF

    my $matches = Sh::grep_file(
        $tmp_path,
        qr/foo: (?<foo>\w+)/,
        qr/tar: (?<tar>\w+)/);

    is_deeply($matches, {
            foo => "bar",
            tar => "zar"
        });
}

done_testing;
