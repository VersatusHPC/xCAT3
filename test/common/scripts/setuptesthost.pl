#!/usr/bin/perl 

use strict;
use warnings;
use feature 'say';
use Data::Dumper;
use Getopt::Long qw(GetOptions);
use File::Basename qw(basename dirname);
use Cwd qw(cwd abs_path);
use FindBin qw($Bin);
use Pod::Usage;

my $PWD = cwd();

my %opts = (
    setup_container => 0,
    distro => "",
    releasever => "",
    force => 0,
    verbose => 0,
);

my @DISTROS = qw(ubuntu el);
my %RELEASEVERS = (
    ubuntu => [ qw(22.04 24.04 26.04) ],
    el => [ 8 .. 10 ],
);

sub sh {
    my ($script, %funcopts) = @_;

    my $shopts = "set -e; ";
    $shopts .= "set -x; " if $opts{verbose};
    $shopts .= "exec 2> /dev/null; " if !$opts{verbose} && $funcopts{-mayfail};
    $shopts .= "exec > /dev/null; " if !$opts{verbose};

    my $exit = system(<<"EOF");
$shopts
$script    
EOF

    exit($exit) 
        if !$funcopts{-mayfail} && $exit != 0;

    return $exit;
}


GetOptions(
    "setup-container" => \$opts{setup_container},
    "distro=s" => \$opts{distro},
    "releasever=s" => \$opts{releasever},
    "force" => \$opts{force},
    "verbose" => \$opts{verbose},
) or pod2usage(2);


package Valid {
    sub distro { 
        my ($distro) = @_;
        if (!$distro) {
            warn "No distro provided";
            return 0;
        }
        my $result = 1 == grep { $_ eq $distro } @DISTROS;
        warn "Invalid distro $distro" unless $result;
        $result;
    }

    sub releasever {
        my ($distro, $releasever) = @_;
        return 0 unless Valid::distro($distro);
        if (!$releasever) {
            warn "No releasever provided";
            return 0;
        }
        my $result = 
            1 == grep { $_ eq $releasever} @{ $RELEASEVERS{$distro} };
        warn "Invalid releasever $releasever"
            unless $result;
        $result;
    }
}
sub containerexists {
    my ($name) = @_;
    return sh("podman container exists $name", -mayfail => 1) == 0;
}

sub imageexists {
    my ($imagename) = @_;
    return sh("podman image exists $imagename", -mayfail => 1) == 0;
}

sub cleanupcontainerandimage {
    my ($container, $image) = @_;
    return sh(<<"EOF", -mayfail => 1);
set +e
podman kill $container
podman rm -f $container
podman rmi -f $image
EOF
}

sub setup_container {
    my $distro = $opts{distro};
    my $releasever = $opts{releasever};
    pod2usage(1)
        unless Valid::releasever($distro, $releasever);
    my $containerfile_path = abs_path "$Bin/../../$distro/";
    my $name = "xcattest-${distro}${releasever}";
    my $image = "$name-image";

    cleanupcontainerandimage($name, $image)
        if $opts{force};

    say "Building the image: $image";
    sh("podman build -t $image --build-arg RELEASEVER=$releasever $containerfile_path")
        unless imageexists("$image");
    say "Creating the container: $name";
    my $script = <<"EOF";
podman create --name $name \\
    --privileged    \\
    --systemd=true  \\
    --cap-add=ALL  \\
    -v "$containerfile_path/scripts:/workspace/scripts:Z" \\
    -v /sys/fs/cgroup:/sys/fs/cgroup:ro  \\
    --tmpfs /tmp  \\
    --tmpfs /run \\
    $image 
podman start $name
EOF
    sh($script) unless containerexists($name);
}

sub main {
    return setup_container() if $opts{setup_container};

    pod2usage(1);
};

exit(main());

__END__

=head1 NAME

setuptesthost.pl - Setup test host before running the tests.

=head1 SYNOPSIS

setuptesthost.pl [options]

  --setup-container
  --distro ubuntu|el
  --releasever VERSION
  [--force]

=head1 OPTIONS

=over 4

=item B<--setup-container>

Create the testing container

=item B<--distro>

One of: ubuntu, el

=item B<--releasever>

Depends on distro

    for el:     One of:   8     9     10
    for ubuntu: One of: 22.04 24.04 26.04


=item B<--force>

The default behavior is to not recreate the images
and containers if they already exists. Use --force
to change this.

=item B<--verbose>

Enable verbose output

=back
