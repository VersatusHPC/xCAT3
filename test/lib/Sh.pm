package Sh;

use strict;
use warnings;

use Exporter qw(import);
use Carp;

use POSIX qw(dup2);

our @EXPORT_OK = qw(
    bg
    bg_pipe
    run
    run_pipe
    output
    ok
    grep_file
);

=head1 NAME

Utils - Utilities functions during building and testing

=head1 SYNOPSIS

  This module provide multiple utility functions to execute shell commands and
  get it's exit status and reading output and errors in an efficient way.

=head1 FUNCTIONS
=cut


=head3 bg($cmd)

    Start $cmd in background using bash.

    Returns the child PID, the caller should call 
    waitpid($pid, 0) to wait for it.

    STDOUT and STDERR is inherited from parent process.
    This means that child echo its stdout and stderr in
    the parent's terminal. Use it for long runnning commands,
    when you want to see the output (for debugging purpose)
    but do not want to capture it.
=cut
sub bg {
    my ($cmd) = @_;

    my $pid = fork();
    if ($pid == 0) {
        # child
        exec "bash", "-lec", $cmd;
    }
    return $pid;
}

=head3 bg_pipe($cmd)

    Start $cmd in background using C<bash.

    Create pipes capturing child stdout and
    stderr.

    Returns ($pid, $out_fh, $err_fh)
    where:
    - $exit: The child's exit code.
    - $out_fh: A filehandle used to read stdout from the child.
    - $err_fh: A filehandle used to read stderr from the child.
=cut
sub bg_pipe {
    my ($cmd) = @_;
    pipe(my $out_r, my $out_w);
    pipe(my $err_r, my $err_w);
    my $pid = fork();
    my $close = sub { close $_ for @_; };

    if ($pid == 0) {
        # child
        $close->($out_r, $err_r);
        dup2(fileno($out_w), 1);
        dup2(fileno($err_w), 2);
        exec "bash", "-lec", $cmd;
    }
    $close->($out_w, $err_w);
    return ($pid, $out_r, $err_r);
}

=head3 run($cmd)

    Start $cmd, wait for it to finish.

    Return its exit code.
=cut
sub run {
    my ($cmd) = @_;
    my $pid = bg($cmd);
    waitpid($pid, 0);
    return $? >> 8;
}

=head3 run_pipe($cmd)

    Start $cmd, wait for it to finish.

    Returns ($pid, $out_fh, $err_fh)
    where:
    - $exit: The child's exit code.
    - $out_fh: A filehandle used to read stdout from the child.
    - $err_fh: A filehandle used to read stderr from the child.
=cut
sub run_pipe {
    my ($cmd) = @_;
    my ($pid, $out_fh, $err_fh) = bg_pipe($cmd);
    waitpid($pid, 0);
    my $exit = $? >> 8;
    return ($exit, $out_fh, $err_fh);
}

=head3 output($cmd)

    Run $cmd in bash and return its output as a string

    Dies if child exit with non-zero status. Print stderr on failure before
    exiting.
=cut
sub output {
    my ($cmd) = @_;
    my ($pid, $out_fh, $err_fh) = bg_pipe($cmd);
    waitpid($pid, 0);
    my $exit = $? >> 8;
    local $/ = undef;
    if ($exit != 0) {
        my $error = <$err_fh>;
        croak "Command $cmd failed with status $exit: and error: $error";
    }
    my $output = <$out_fh>;
    $output =~ s/\n+$//;
    return $output;
}

=head3 ok($cmd)

    Run $cmd in bash, die if it exits with non-zero status.

    Print stderr on failure before exiting.
=cut
sub ok {
    my ($cmd) = @_;
    my ($pid, $out_fh, $err_fh) = bg_pipe($cmd);
    waitpid($pid, 0);
    my $exit = $? >> 8;
    local $/ = undef;
    if ($exit != 0) {
        my $error = <$err_fh>;
        croak "Command $cmd failed with status $exit: and error: $error";
    }
    return;
}
1;
