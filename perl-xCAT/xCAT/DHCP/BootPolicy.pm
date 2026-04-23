package xCAT::DHCP::BootPolicy;

use strict;
use warnings;

sub kea_client_classes {
    my ( $class, %opts ) = @_;

    my $bios_boot = $opts{xnba_kpxe} ? 'xcat/xnba.kpxe' : 'pxelinux.0';
    my $uefi_boot = $opts{xnba_efi}  ? 'xcat/xnba.efi'  : '';
    my @classes;

    if ( $opts{xnba_kpxe} ) {
        push @classes, {
            name             => 'xcat-xnba-bios',
            test             => "option[77].text == 'xNBA' and option[93].hex == 0x0000",
            'boot-file-name' => 'xcat/xnba.kpxe',
        };
    }

    push @classes, (
        {
            name             => 'xcat-bios',
            test             => 'option[93].hex == 0x0000',
            'boot-file-name' => $bios_boot,
        },
    );

    if ($uefi_boot ne '') {
        push @classes, {
            name             => 'xcat-uefi-x64',
            test             => 'option[93].hex == 0x0007 or option[93].hex == 0x0009',
            'boot-file-name' => $uefi_boot,
        };
    }

    push @classes, (
        {
            name             => 'xcat-aarch64',
            test             => 'option[93].hex == 0x000b',
            'boot-file-name' => 'boot/grub2/grub2.aarch64',
        },
        {
            name             => 'xcat-ppc64',
            test             => 'option[93].hex == 0x000c',
            'boot-file-name' => '/boot/grub2/grub2.ppc',
        },
        {
            name             => 'xcat-ia64',
            test             => 'option[93].hex == 0x0002',
            'boot-file-name' => 'elilo.efi',
        },
    );

    return \@classes;
}

1;
