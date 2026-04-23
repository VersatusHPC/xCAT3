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

Known Exceptions
----------------

Known blockers do not remove the matrix requirement. They must be recorded
explicitly in the validation result.

Current exceptions:

* Ubuntu 22.04 LTS ISC OMAPI/``omshell`` host reservation updates are blocked by
  issue ``#11``. The failure reproduces on upstream ``master`` and is not caused
  by the Kea backend work.
* EL10 ``ppc64le`` currently reaches xCAT Genesis, but full POWER validation is
  blocked by a preexisting ``genesis.kernel.ppc64`` issue unrelated to Kea.

Reporting Rule
--------------

Every DHCP backend PR should summarize validation using this matrix:

* what rows were run
* what passed
* what failed
* what was blocked by a known external issue

If a row was skipped, the PR should state why.
