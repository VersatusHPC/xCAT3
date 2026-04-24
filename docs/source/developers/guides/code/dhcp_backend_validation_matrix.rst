DHCP Backend Validation Matrix
==============================

Purpose
-------

This document defines the default validation matrix for xCAT DHCP backend
changes.

Use this matrix for:

* backend selection changes
* DHCP renderer changes
* reservation add, delete, or query changes
* DDNS and service-management changes
* PXE, xNBA, or boot-policy changes

Backend Policy
--------------

The default backend split is:

* EL9, Ubuntu 22.04 LTS, and older supported releases: ``ISC DHCP``
* EL10, Ubuntu 24.04 LTS, and newer supported releases: ``Kea``

``site.dhcpbackend=auto`` must follow that rule. Explicit ``isc`` and ``kea``
overrides remain available for development and troubleshooting.

Always-Run Checks
-----------------

Run these checks for every DHCP backend change before live validation:

* Perl syntax checks for changed DHCP modules
* unit tests for backend selection, range handling, boot policy, and renderer
  behavior
* Kea version-aware renderer checks when client classification is touched:

  * Kea 2.4 output must use ``only-if-required`` and
    ``require-client-classes``
  * Kea 3.x output must use ``only-in-additional-list`` and
    ``evaluate-additional-classes``

* backend-native configuration validation:

  * ``dhcpd -t -cf <config>`` for ISC
  * ``kea-dhcp4 -t <config>`` for Kea DHCPv4
  * ``kea-dhcp6 -t <config>`` for Kea DHCPv6 when used
  * ``kea-ctrl-agent -t <config>`` for Control Agent when used
  * ``kea-dhcp-ddns -t <config>`` for D2 when used

Default Live Matrix
-------------------

The following matrix is the default live validation gate for DHCP backend work.

.. list-table::
   :header-rows: 1
   :widths: 14 10 10 18 48

   * - Platform
     - Arch
     - Backend
     - Boot Validation
     - Minimum Required Checks
   * - EL9
     - ``x86_64``
     - ``ISC``
     - ``xNBA shell``
     - ``makedhcp -n``; ``dhcpd -t``; reservation add/query/delete; DHCP/TFTP;
       node-specific xNBA handoff; Genesis fetch
   * - Ubuntu 22.04 LTS
     - ``x86_64``
     - ``ISC``
     - ``xNBA shell``
     - ``makedhcp -n``; ``dhcpd -t``; reservation add/query/delete; DHCP/TFTP;
       node-specific xNBA handoff; Genesis fetch
   * - EL10
     - ``x86_64``
     - ``Kea``
     - ``xNBA shell`` and ``full netboot image``
     - ``makedhcp -n``; ``kea-dhcp4 -t``; reservation add/query/delete;
       xNBA shell boot; full compute-image boot through kernel, initrd, and
       root image
   * - Ubuntu 24.04 LTS
     - ``x86_64``
     - ``Kea``
     - ``xNBA shell`` and ``full netboot image``
     - ``makedhcp -n``; ``kea-dhcp4 -t``; reservation add/query/delete;
       xNBA shell boot; full compute-image boot through kernel, initrd, and
       root image

Extended Architecture Matrix
----------------------------

Run the extended matrix when a change touches architecture-specific boot logic,
client classification, firmware-specific file paths, or non-``x86_64`` code
paths.

.. list-table::
   :header-rows: 1
   :widths: 14 10 10 18 48

   * - Platform
     - Arch
     - Backend
     - Boot Validation
     - Minimum Required Checks
   * - EL10
     - ``ppc64le``
     - ``Kea``
     - ``Genesis handoff``
     - DHCP offer; boot file handoff; xCAT Genesis reachability; POWER boot-path
       correctness

Current Lab Baseline
--------------------

The current KVM validation hosts are:

* ``rome01.local.versatushpc.com.br`` for ``x86_64``
* ``power.local.versatushpc.com.br`` for ``ppc64le``

Validation access should use the ``builder`` account and the
``id_ed25519_reposync`` SSH key. Avoid relying on ad-hoc root login or
one-off cloud-init keys when recording repeatable validation procedure.

Known Exceptions
----------------

Known blockers do not remove the matrix requirement. They must be recorded
explicitly in the validation result.

Current exceptions:

* Ubuntu 22.04 LTS ISC OMAPI/``omshell`` host reservation updates are blocked by
  issue ``#11``. The failure reproduces on upstream ``master`` and is not caused
  by the Kea backend work.
* EL10 ``ppc64le`` Kea configuration and DHCP unit validation pass. Full POWER
  image boot validation can still be blocked by a preexisting
  ``genesis.kernel.ppc64`` invalid-ELF issue unrelated to Kea.

Current PR Validation Snapshot
------------------------------

As of April 23, 2026, the ``kea-dhcp-backend`` PR has the following DHCP
backend validation result:

.. list-table::
   :header-rows: 1
   :widths: 16 10 10 20 44

   * - Platform
     - Arch
     - Backend
     - Result
     - Notes
   * - EL9
     - ``x86_64``
     - ``ISC``
     - Pass
     - ``site.dhcpbackend=auto`` selected ``isc``; legacy DHCP unit subset
       passed.
   * - Ubuntu 22.04 LTS
     - ``x86_64``
     - ``ISC``
     - Pass with known exception
     - ``site.dhcpbackend=auto`` selected ``isc``; legacy DHCP unit subset
       passed. OMAPI reservation updates remain tracked by issue ``#11``.
   * - EL10
     - ``x86_64``
     - ``Kea 3.0.1``
     - Pass
     - Renderer emitted ``evaluate-additional-classes`` and
       ``only-in-additional-list``; ``kea-dhcp4 -t`` passed.
   * - Ubuntu 24.04 LTS
     - ``x86_64``
     - ``Kea 2.4.1``
     - Pass
     - Renderer emitted ``require-client-classes`` and ``only-if-required``;
       full DHCP unit suite and ``kea-dhcp4 -t`` passed.
   * - EL10
     - ``ppc64le``
     - ``Kea 3.0.1``
     - Pass
     - Renderer emitted ``evaluate-additional-classes`` and
       ``only-in-additional-list``; full DHCP unit suite and ``kea-dhcp4 -t``
       passed.

Reporting Rule
--------------

Every DHCP backend PR should summarize validation using this matrix:

* what rows were run
* what passed
* what failed
* what was blocked by a known external issue

If a row was skipped, the PR should state why.
