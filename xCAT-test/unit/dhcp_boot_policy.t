use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

use xCAT::DHCP::BootPolicy;

my $fallback_classes = xCAT::DHCP::BootPolicy->kea_client_classes();
is( scalar @$fallback_classes, 4, 'Kea boot policy omits xNBA classes when xNBA loaders are unavailable' );
my %fallback_by_name = map { $_->{name} => $_ } @$fallback_classes;
is( $fallback_by_name{'xcat-bios'}{'boot-file-name'}, 'pxelinux.0', 'BIOS clients fall back to pxelinux.0 without xNBA loaders' );
ok( !exists $fallback_by_name{'xcat-xnba-bios'}, 'xNBA user-class is not advertised without xNBA kpxe' );

my $classes = xCAT::DHCP::BootPolicy->kea_client_classes(xnba_kpxe => 1, xnba_efi => 1);
is( scalar @$classes, 6, 'Kea boot policy renders expected xNBA client classes' );

my %by_name = map { $_->{name} => $_ } @$classes;
is( $by_name{'xcat-bios'}{'boot-file-name'}, 'xcat/xnba.kpxe', 'BIOS clients receive xNBA kpxe' );
like( $by_name{'xcat-uefi-x64'}{test}, qr/0x0007/, 'UEFI x64 class matches architecture 7' );
like( $by_name{'xcat-uefi-x64'}{test}, qr/0x0009/, 'UEFI x64 class matches architecture 9' );
is( $by_name{'xcat-aarch64'}{'boot-file-name'}, 'boot/grub2/grub2.aarch64', 'AArch64 clients receive grub2 boot file' );
is( $by_name{'xcat-ppc64'}{'boot-file-name'}, '/boot/grub2/grub2.ppc', 'POWER clients receive grub2 Open Firmware boot file' );

done_testing();
