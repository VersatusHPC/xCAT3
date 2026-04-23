use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use File::Temp qw/tempdir/;
use JSON;
use Test::More;

use xCAT::DHCP::Backend::Kea;

my $backend = xCAT::DHCP::Backend::Kea->new();
my $json = $backend->render_dhcp4_config(
    {
        interfaces     => ['eth0'],
        valid_lifetime => '600',
        subnets        => [
            {
                id           => '1',
                subnet       => '10.0.0.0/24',
                interface    => 'eth0',
                dynamicrange => '10.0.0.100-10.0.0.120;10.0.0.130,10.0.0.140',
                next_server  => '10.0.0.1',
                option_data  => [
                    { name => 'routers',             data => '10.0.0.1' },
                    { name => 'domain-name-servers', data => '10.0.0.2, 10.0.0.3' },
                    { name => 'domain-name',         data => 'cluster.example.com' },
                ],
                reservations => [
                    {
                        'hw-address' => 'aa:bb:cc:dd:ee:ff',
                        'ip-address' => '10.0.0.10',
                        hostname     => 'node01',
                    },
                ],
            },
        ],
        'client-classes' => [
            {
                name             => 'xcat-uefi-x64',
                test             => 'option[93].hex == 0x0007',
                'boot-file-name' => 'xcat/xnba.efi',
            },
        ],
    }
);

my $config = decode_json($json);
ok( $config->{Dhcp4}, 'renderer creates a Dhcp4 document' );
is_deeply( $config->{Dhcp4}{'interfaces-config'}{interfaces}, ['eth0'], 'interfaces are rendered' );
is( $config->{Dhcp4}{'valid-lifetime'}, 600, 'valid lifetime is rendered' );
is( $config->{Dhcp4}{'lease-database'}{type}, 'memfile', 'memfile lease backend is the default' );

my $subnet = $config->{Dhcp4}{subnet4}[0];
is( $subnet->{id}, 1, 'subnet id is rendered' );
is( $subnet->{subnet}, '10.0.0.0/24', 'subnet CIDR is rendered' );
is( $subnet->{interface}, 'eth0', 'subnet interface is rendered' );
is( $subnet->{'next-server'}, '10.0.0.1', 'next-server is rendered' );

is_deeply(
    $subnet->{pools},
    [
        { pool => '10.0.0.100 - 10.0.0.120' },
        { pool => '10.0.0.130 - 10.0.0.140' },
    ],
    'dynamicrange is rendered as Kea pools'
);

is_deeply(
    $subnet->{'option-data'},
    [
        { name => 'routers',             data => '10.0.0.1' },
        { name => 'domain-name-servers', data => '10.0.0.2, 10.0.0.3' },
        { name => 'domain-name',         data => 'cluster.example.com' },
    ],
    'subnet option-data is preserved'
);

is_deeply(
    $subnet->{reservations},
    [
        {
            'hw-address' => 'aa:bb:cc:dd:ee:ff',
            'ip-address' => '10.0.0.10',
            hostname     => 'node01',
        },
    ],
    'host reservations are preserved'
);

is_deeply(
    $config->{Dhcp4}{'client-classes'},
    [
        {
            name             => 'xcat-uefi-x64',
            test             => 'option[93].hex == 0x0007',
            'boot-file-name' => 'xcat/xnba.efi',
        },
    ],
    'client classes are preserved'
);

my $empty_boot_json = $backend->render_dhcp4_config(
    {
        subnets => [
            {
                id             => 2,
                subnet         => '10.0.1.0/24',
                pools          => [],
                next_server    => '0.0.0.0',
                boot_file_name => '',
            },
        ],
    }
);
my $empty_boot_subnet = decode_json($empty_boot_json)->{Dhcp4}{subnet4}[0];
is( $empty_boot_subnet->{'next-server'}, '0.0.0.0', 'false-looking next-server value is preserved' );
is( $empty_boot_subnet->{'boot-file-name'}, '', 'empty boot-file-name is preserved' );

my $reservation_config = decode_json(
    $backend->render_dhcp4_config(
        {
            subnets => [
                {
                    id     => 10,
                    subnet => '10.10.0.0/24',
                    pools  => [],
                },
            ],
        }
    )
);

$backend->upsert_reservations(
    $reservation_config,
    [
        {
            'subnet-id'  => 10,
            'hw-address' => '00:11:22:33:44:55',
            'ip-address' => '10.10.0.12',
            hostname     => 'node12',
        },
    ]
);
is( scalar @{ $reservation_config->{Dhcp4}{subnet4}[0]{reservations} }, 1, 'reservation is added to matching subnet' );

$backend->upsert_reservations(
    $reservation_config,
    [
        {
            'subnet-id'  => 10,
            'hw-address' => '00:11:22:33:44:55',
            'ip-address' => '10.10.0.13',
            hostname     => 'node12',
        },
    ]
);
is( scalar @{ $reservation_config->{Dhcp4}{subnet4}[0]{reservations} }, 1, 'matching reservation is replaced, not duplicated' );
is( $reservation_config->{Dhcp4}{subnet4}[0]{reservations}[0]{'ip-address'}, '10.10.0.13', 'replacement reservation is stored' );

my $subnet_id = $backend->subnet_id_for_ip( $reservation_config, '10.10.0.13' );
is( $subnet_id, 10, 'subnet lookup by IPv4 address finds the reservation subnet' );

my $found = $backend->query_reservations( $reservation_config, { hostname => 'node12' } );
is( scalar @$found, 1, 'reservation query finds hostname match' );
is( $found->[0]{'subnet-id'}, 10, 'reservation query includes subnet id' );

my $deleted = $backend->delete_reservations( $reservation_config, { 'hw-address' => '00:11:22:33:44:55' } );
is( scalar @$deleted, 1, 'reservation delete returns deleted reservation' );
is( scalar @{ $reservation_config->{Dhcp4}{subnet4}[0]{reservations} }, 0, 'reservation is removed from config' );

my $hookdir = tempdir(CLEANUP => 1);
my $hook = "$hookdir/libdhcp_host_cmds.so";
open(my $hookfh, '>', $hook) or die "Unable to create fake hook: $!";
close($hookfh);
is( $backend->host_cmds_hook_path($hook), $hook, 'host commands hook lookup accepts an explicit existing path' );
my $backend_without_default_hooks = xCAT::DHCP::Backend::Kea->new(host_cmds_hook_paths => []);
is( $backend_without_default_hooks->host_cmds_hook_path("$hookdir/missing.so"), undef, 'host commands hook lookup returns undef when no hook exists' );

my $backupdir = tempdir(CLEANUP => 1);
my $config_path = "$backupdir/kea-dhcp4.conf";
open(my $configfh, '>', $config_path) or die "Unable to create fake config: $!";
print $configfh '{"old":true}';
close($configfh);
my $write_result = $backend->write_dhcp4_json('{"new":true}', path => $config_path, skip_validate => 1, backup_existing => 1);
ok( !$write_result->{error}, 'write_dhcp4_json succeeds with backup_existing' );
is( $write_result->{backup}, "$config_path.xcatbak", 'backup path is reported' );
my $config_mode = ( stat($config_path) )[2] & 07777;
ok( $config_mode == 0640 || $config_mode == 0644, 'written config is readable by the Kea service user' );
open(my $backupfh, '<', "$config_path.xcatbak") or die "Unable to read backup config: $!";
my $backup_content = <$backupfh>;
close($backupfh);
is( $backup_content, '{"old":true}', 'existing Kea config is backed up before replacement' );

my $dhcp6_json = $backend->render_dhcp6_config(
    {
        interfaces       => ['eth0'],
        valid_lifetime   => '700',
        preferred_lifetime => '500',
        subnets    => [
            {
                id           => '11',
                subnet       => '2001:db8:1::/64',
                dynamicrange => '2001:db8:1::100/120',
                option_data  => [
                    { name => 'dns-servers',   data => '2001:db8:1::1' },
                    { name => 'domain-search', data => 'cluster.example.com' },
                ],
                reservations => [
                    {
                        duid           => '00:04:52:54:00:12:34:56',
                        'ip-addresses' => ['2001:db8:1::50'],
                        hostname       => 'nodev6',
                    },
                ],
            },
        ],
    }
);
my $dhcp6_config = decode_json($dhcp6_json);
ok( $dhcp6_config->{Dhcp6}, 'renderer creates a Dhcp6 document' );
is( $dhcp6_config->{Dhcp6}{subnet6}[0]{subnet}, '2001:db8:1::/64', 'DHCPv6 subnet is rendered' );
is( $dhcp6_config->{Dhcp6}{'valid-lifetime'}, 700, 'DHCPv6 valid lifetime is numeric' );
is( $dhcp6_config->{Dhcp6}{'preferred-lifetime'}, 500, 'DHCPv6 preferred lifetime is numeric' );
is( $dhcp6_config->{Dhcp6}{subnet6}[0]{id}, 11, 'DHCPv6 subnet id is numeric' );
is( $dhcp6_config->{Dhcp6}{subnet6}[0]{reservations}[0]{duid}, '00:04:52:54:00:12:34:56', 'DHCPv6 DUID reservation is rendered' );

my $ddns_json = $backend->render_ddns_config(
    {
        port => '53001',
        'dns-server-timeout' => '500',
        'tsig-keys' => [
            { name => 'xcat_key', algorithm => 'HMAC-SHA256', secret => 'abc123==' },
        ],
        forward_domains => [
            {
                name          => 'cluster.example.com.',
                'key-name'    => 'xcat_key',
                'dns-servers' => [ { 'ip-address' => '10.0.0.1', port => 53 } ],
            },
        ],
        reverse_domains => [
            {
                name          => '0.0.10.in-addr.arpa.',
                'key-name'    => 'xcat_key',
                'dns-servers' => [ { 'ip-address' => '10.0.0.1', port => 53 } ],
            },
        ],
    }
);
my $ddns_config = decode_json($ddns_json);
ok( $ddns_config->{DhcpDdns}, 'renderer creates a DhcpDdns document' );
is( $ddns_config->{DhcpDdns}{port}, 53001, 'DDNS port is numeric' );
is( $ddns_config->{DhcpDdns}{'dns-server-timeout'}, 500, 'DDNS timeout is numeric' );
is( $ddns_config->{DhcpDdns}{'forward-ddns'}{'ddns-domains'}[0]{name}, 'cluster.example.com.', 'DDNS forward domain is rendered' );

my $ctrl_agent_config = decode_json($backend->render_ctrl_agent_config({ 'http-port' => '8000' }));
is( $ctrl_agent_config->{'Control-agent'}{'http-port'}, 8000, 'Control Agent HTTP port is numeric' );

my @commands;
my $ca_backend = xCAT::DHCP::Backend::Kea->new(
    control_agent_handler => sub {
        my ($payload) = @_;
        push @commands, $payload;
        return { ok => 1, result => 0, response => { result => 0 } };
    },
);
my $live_result = $ca_backend->live_upsert_reservations(
    [
        {
            'subnet-id'      => 10,
            'hw-address'     => '00:11:22:33:44:55',
            'ip-address'     => '10.10.0.20',
            hostname         => 'node20',
            'boot-file-name' => 'pxelinux.0',
        },
    ]
);
ok( !$live_result->{error}, 'live reservation upsert succeeds through injected Control Agent handler' );
is( $commands[0]{command}, 'reservation-del', 'live upsert deletes any existing reservation first' );
is( $commands[0]{arguments}{'operation-target'}, 'memory', 'live delete targets runtime memory' );
is( $commands[1]{command}, 'reservation-add', 'live upsert adds reservation through host-commands' );
is( $commands[1]{arguments}{reservation}{'subnet-id'}, 10, 'live add includes subnet id in reservation body' );
is_deeply( $commands[1]{service}, ['dhcp4'], 'live add targets dhcp4 service by default' );

done_testing();
