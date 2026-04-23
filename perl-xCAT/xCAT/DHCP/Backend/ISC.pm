package xCAT::DHCP::Backend::ISC;

use strict;
use warnings;

sub new {
    my ( $class, %args ) = @_;
    return bless \%args, $class;
}

sub name {
    return 'isc';
}

sub implemented {
    return 1;
}

1;
