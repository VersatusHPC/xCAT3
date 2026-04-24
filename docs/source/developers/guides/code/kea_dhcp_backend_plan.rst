Kea DHCP Backend Plan
=====================

Purpose
-------

xCAT currently integrates DHCP through ISC DHCP. That behavior should remain the
default on platforms where ISC DHCP is still available and supported. Kea DHCP
will be added as a second backend for platforms that need it, starting with EL10
and Ubuntu 24.04.

The public xCAT contract remains ``makedhcp``. The implementation underneath
``makedhcp`` will select an ISC or Kea backend based on site configuration and
platform support.

Branch Status
-------------

The ``kea-dhcp-backend`` work implements the Kea backend foundation:

* backend selection through ``site.dhcpbackend``
* ISC as the preserved default on platforms that still support it
* Kea as the automatic default for EL10 and Ubuntu 24.04+
* Kea DHCPv4 and DHCPv6 JSON rendering with Perl's ``JSON`` module
* Kea DHCPv4, DHCPv6, Control Agent, and DHCP-DDNS configuration validation
  before install
* backend-aware service mapping for ISC and Kea services
* Kea host reservations through JSON render, validate, backup, and
  restart
* optional Control Agent socket, host-commands hook configuration, and live
  reservation add/delete through ``reservation-add`` and ``reservation-del``
  when ``site.keacontrolagent`` is enabled and the hook library exists
* Kea D2/DHCP-DDNS config generation using the existing ``xcat_key`` material
  created by ``makedns``/``ddns``
* shared dynamic range parsing for ISC and Kea output
* centralized Kea boot client classes for BIOS, x86_64 UEFI, ARM64, xNBA, and
  IA64
* updates for ``dhcpop``, probes, service monitoring, packaging, man pages, and
  site table documentation
* unit tests for backend selection, range parsing, Kea rendering, boot policy,
  Kea config validation, and an opt-in live Control Agent smoke test

Remaining work is validation and hardening:

* semantic parity tests against production xCAT tables
* full PXE boot validation on real hardware or nested guests for every
  supported architecture
* complete service-node and disjoint-DHCP scenario validation
* CI integration for EL10 and Ubuntu 24.04 containers

Backend Selection
-----------------

Add a site attribute:

``site.dhcpbackend=auto|isc|kea``

Selection rules:

* ``auto`` keeps ISC DHCP on existing supported platforms such as EL8, EL9,
  older Ubuntu/Debian releases, and SLES.
* ``auto`` selects Kea DHCP on EL10 and Ubuntu 24.04.
* ``isc`` forces the ISC backend.
* ``kea`` forces the Kea backend.
* A forced backend that is unavailable must fail with a clear error.

This avoids replacing ISC globally while still allowing Kea testing on platforms
where both implementations can be installed.

Architecture
------------

Refactor ``xCAT-server/lib/xcat/plugins/dhcp.pm`` into shared orchestration plus
backend-specific modules.

Suggested modules:

* ``xCAT::DHCP::Backend::ISC``
* ``xCAT::DHCP::Backend::Kea``
* ``xCAT::DHCP::Intent``
* ``xCAT::DHCP::BootPolicy``

``dhcp.pm`` should continue to own:

* ``makedhcp`` option parsing
* service node eligibility checks
* xCAT table reads
* common validation
* lock handling
* callback and error formatting

Shared code should build normalized DHCP intent:

* DHCP interfaces
* subnets
* address pools
* host reservations
* DHCP options
* boot rules
* DDNS intent

Backends render and apply that intent using provider-specific mechanisms.

ISC Backend
-----------

The ISC backend preserves current behavior:

* ``dhcpd.conf`` and ``dhcpd6.conf`` generation
* OMAPI and ``omshell`` host operations
* ``dhcpd`` and optional ``dhcpd6`` service handling
* existing older distribution behavior

The first implementation step should extract the ISC backend with minimal
behavior change and add regression tests before Kea code is introduced.

Kea Static Configuration
------------------------

The Kea backend should generate:

* ``/etc/kea/kea-dhcp4.conf``
* ``/etc/kea/kea-dhcp6.conf`` when IPv6 is configured
* ``/etc/kea/kea-ctrl-agent.conf`` only when REST/control-agent operations are
  enabled
* ``/etc/kea/kea-dhcp-ddns.conf`` only when Kea DDNS/D2 support is enabled

Use Kea ``memfile`` leases initially for parity with ISC lease files. Database
lease backends can be considered later if there is a concrete requirement.

Configuration Validation
------------------------

Generated configuration must be validated before any reload or restart.

ISC validation:

``dhcpd -t -cf <config>``

Kea validation:

``kea-dhcp4 -t <config>``

``kea-dhcp6 -t <config>``

Invalid configuration must leave the running service untouched and return a
clear error.

Service Management
------------------

Service control must be backend-aware. Do not add Kea service names blindly to
the generic ``dhcp`` service map.

ISC services:

* ``dhcpd``
* optional ``dhcpd6``

Kea services:

* ``kea-dhcp4``
* optional ``kea-dhcp6``
* optional ``kea-ctrl-agent``
* optional ``kea-dhcp-ddns``

Control Agent must be running before REST operations are attempted. D2 should
only be managed when Kea DDNS support is configured.

Boot Policy
-----------

Boot policy is the riskiest migration area. Existing ISC code uses nested
conditionals and provider-specific statements. Kea uses client classes, test
expressions, and JSON option data.

Do not translate ISC strings directly to Kea strings. Instead, represent boot
behavior once as normalized rules, then render them per backend.

Backends render the same intent as:

* ISC: ``if option ...`` blocks, ``filename``, ``next-server``, and custom
  option statements.
* Kea: ``client-classes``, test expressions, ``boot-file-name``,
  ``next-server``, and ``option-data``.

Boot coverage must include:

* x86 BIOS
* x86_64 UEFI
* ARM64
* OpenPOWER/OPAL
* ONIE
* Cumulus ZTP
* petitboot
* xNBA
* iSCSI boot options

Host Reservations
-----------------

Baseline Kea behavior should be deterministic and not depend on optional hooks:

* render xCAT-owned host reservations into Kea JSON
* validate generated configuration
* reload Kea

Optimized behavior can use Kea Control Agent plus host-commands when available.
This requires verifying that the target distribution packages include the host
commands hook library, such as ``libdhcp_host_cmds.so``. Do not assume this
library is present in EL10 or Ubuntu 24.04 without testing the actual packages.

If host-commands are unavailable, the JSON render and reload path must still
work.

DDNS and D2
-----------

ISC inline DDNS configuration does not map directly to Kea. Kea uses the
separate DHCP-DDNS daemon.

Kea DDNS support uses D2 and should stay separate from the DHCP server config:

* generate ``kea-dhcp-ddns.conf``
* use the existing ``xcat_key`` material from ``/etc/xcat/ddns.key`` or the
  ``passwd`` table
* render the DHCP server's D2 connection block separately from the global DDNS
  behavior flags
* start D2 before the DHCP service when DDNS is enabled

Basic Kea DHCP and PXE support should not depend on DDNS unless a target
deployment explicitly enables ``site.dnshandler=ddns``.

Packaging
---------

Packaging must keep ISC dependencies for platforms using ISC and add Kea
dependencies only for platforms using Kea.

Known areas:

* ``xCAT.spec`` and ``xCATsn.spec`` currently depend on ``/usr/sbin/dhcpd``.
* EL10 and Ubuntu 24.04 packaging should depend on the correct Kea server
  packages.
* ``dhclient`` and ``dhcp-client`` are separate client-side genesis/netboot
  issues and should not be conflated with the server backend.

Tools, Probes, UI, and Docs
---------------------------

Areas that currently assume ISC DHCP must become backend-aware:

* ``xCAT-server/share/xcat/tools/dhcpop``
* DHCP monitoring in xCAT RMC resources
* ``xCAT-probe`` checks for ``dhcpd``, ``dhcpd.conf``, and ``dhcpd.leases``
* UI paths that run ``service dhcpd restart``
* administrator and developer documentation

Testing Strategy
----------------

The standing validation baseline for DHCP backend work is maintained in
``dhcp_backend_validation_matrix.rst``. Use that matrix as the default gate for
future DHCP backend changes.

Unit tests:

* normalized DHCP intent creation
* ISC renderer regression coverage
* Kea JSON renderer coverage
* host reservation formatting
* subnet and pool mapping
* backend selection and override behavior

Configuration validation tests:

* ``dhcpd -t`` for ISC output
* ``kea-dhcp4 -t`` and ``kea-dhcp6 -t`` for Kea DHCP output
* ``kea-dhcp-ddns -t`` for D2 output
* ``kea-ctrl-agent -t`` for Control Agent output
* Kea client-class renderer output for both supported syntax generations:

  * Kea 2.4 uses ``only-if-required`` and ``require-client-classes``
  * Kea 3.x uses ``only-in-additional-list`` and
    ``evaluate-additional-classes``

Backend selection tests:

* ``auto`` uses ISC on EL9
* ``auto`` uses Kea on EL10
* ``auto`` uses Kea on Ubuntu 24.04
* forced ``kea`` works on EL9 when Kea packages are installed
* forced unavailable backend fails clearly

Integration matrix:

* EL9 plus ISC
* EL9 plus forced Kea
* EL10 plus Kea
* Ubuntu 24.04 plus Kea

Semantic parity tests:

* compare normalized DHCP intent, not raw ISC and Kea configuration text
* verify subnets, pools, reservations, routers, DNS, NTP, log servers, lease
  times, client classes, and boot rules

Functional smoke tests:

* ``makedhcp -n`` generates valid configuration
* backend services start successfully
* ``makedhcp <node>`` adds a reservation
* ``makedhcp -d <node>`` removes a reservation
* ``makedhcp -q <node>`` returns expected data
* ``XCAT_KEA_LIVE_SMOKE=1`` validates live Control Agent host-commands when
  Kea and the host-commands hook are installed
* DHCP offers contain expected boot options
* real PXE boot behavior is validated for each supported architecture

Test Infrastructure
-------------------

Existing container-based EL8, EL9, and EL10 tests should be extended for backend
coverage. The libvirt/KVM infrastructure on ``rome01.local.versatushpc.com.br``
can be used for network and PXE smoke tests that are difficult to validate in
ordinary containers.

Open test infrastructure details to confirm:

* SSH access method and user for ``rome01.local.versatushpc.com.br``
* available base images for EL9, EL10, and Ubuntu 24.04
* libvirt network names and whether isolated DHCP test networks are already
  available
* whether nested or privileged test guests can run DHCP client and PXE tests
* cleanup expectations for temporary VMs, networks, and storage volumes
* the ``builder`` account and ``id_ed25519_reposync`` SSH key are available for
  repeatable validation access

Manual Validation Snapshot
--------------------------

As of April 23, 2026, the branch has been exercised on KVM guests across ISC
and Kea backends:

* EL10 plus Kea on x86_64: passed end-to-end xNBA netboot with a Rocky 10.1
  compute image. The node fetched the xNBA script, kernel, initrd, and rootimg,
  then reached xCAT ``netbooting`` state.
* Ubuntu 24.04 plus Kea on x86_64: passed xNBA shell boot and full netboot
  image fetch. The node downloaded the node script, Genesis artifacts, and the
  generated root image, and Kea reservation queries succeeded.
* EL9 plus ISC on x86_64: passed legacy ISC plus xNBA shell boot, including
  DHCP, TFTP, node-script handoff, and Genesis fetch.
* Ubuntu 22.04 plus ISC on x86_64: passed legacy ISC DHCP, TFTP, generated
  xNBA network script, and Genesis fetch. Per-node OMAPI reservation updates on
  Jammy still fail with ``omshell`` descriptor errors and appear to be a
  preexisting Ubuntu-specific ISC issue outside the Kea scope.
* EL10 plus Kea on ppc64le: passed Kea 3.x renderer validation with
  ``evaluate-additional-classes`` and ``only-in-additional-list``; passed
  ``kea-dhcp4 -t``; passed the full DHCP unit suite on ppc64le after installing
  the Perl test harness packages on the VM. Earlier full POWER image boot
  validation reached xCAT Genesis, then failed loading ``genesis.kernel.ppc64``
  because of a Genesis kernel issue unrelated to Kea. Initial triage showed
  the installed ``/tftpboot/xcat/genesis.kernel.ppc64`` is a
  PowerPC/OpenPOWER ELF, not an ``x86_64`` binary, and comes from
  ``xCAT-genesis-base-ppc64-2.18.0-RC1`` built on
  ``xcat-dev-server-ppc.cluster.local`` on March 30, 2026. The likely change
  area is the Genesis rebuild work merged before this PR, especially PR ``#8``
  / merge ``40a7e4c43`` and commits ``d691c5ccd`` (Genesis base source
  package generation), ``4a1905171`` (ppc64le Genesis boot changes), and
  ``baa2380cd`` (moving the dracut call into the spec).

Implementation Order
--------------------

1. Add backend selection model and interface.
2. Extract ISC backend with minimal behavior change.
3. Add ISC regression tests.
4. Add normalized DHCP intent and boot policy structures.
5. Add Kea static JSON renderer.
6. Add config validation.
7. Add backend-aware service handling.
8. Add Kea boot class rendering.
9. Add baseline Kea reservation render and reload path.
10. Verify host-commands packaging and add Control Agent optimization if
    available.
11. Add DDNS/D2 support as a separate phase.
12. Update packaging.
13. Update tools, probes, UI, and documentation.
14. Expand CI and KVM smoke tests.

Guiding Rule
------------

``makedhcp`` remains the stable xCAT interface. ISC remains the default backend
where it works. Kea is added as a backend for platforms that need it, with shared
DHCP intent and backend-specific rendering and control.
