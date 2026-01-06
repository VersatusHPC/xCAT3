# Testing Workflow for `builddebs.pl`

## Overview

Requirements:

_The host that builds the DEBs and runs the tests must already have the following software installed._

* Ubuntu 22.04 or later with `sbuild`, `mmdebstrap`, `devscripts`, `debhelper`, `quilt`, `reprepro`, and `apt-cacher-ng`.
* `nginx` for serving the apt repositories and caching `xcat-dep`.
* `podman` to build and run the Ubuntu test containers defined under `test/ubuntu/`.
* `mmdebstrap` access to the Ubuntu archive (through `apt-cacher-ng` if you want to reuse downloads).
* This workflow has been validated on Ubuntu 24.04.

`builddebs.pl` is the entry point for generating all xCAT `.deb` packages needed for the Jammy, Noble, and Resolute targets. Each target maps to an `sbuild` chroot and, later on, to a container image used by the automated tests. The high-level flow is:

1. (Once) Bootstrap the `sbuild` caches and initialize nginx/reprepro helpers.
2. Run `builddebs.pl --build-all` to build (or reuse) DEBs and publish an apt repo under `/var/www/html/repos/xcat-core/<codename>`.
3. Provision a testing container for the same Ubuntu release.
4. Execute the automated test suite inside that container.

The steps are idempotent. Pass `--force` when you need to recreate chroots, rebuild packages, or regenerate the nginx configuration.

## xCAT Runtime Dependencies (`../xcat-dep`)

- The dependency repository is served from `../xcat-dep`, but instead of copying the packages locally we cache the VersatusHPC mirror through nginx.
- Run `./builddebs.pl --init-nginx` once (repeat it anytime you change ports or cache settings). It writes `/etc/nginx/conf.d/local-repos.conf`, exposes `/repos/xcat-core/` from `/var/www/html`, and configures `/repos/xcat-dep/` as a caching proxy to `https://mirror.versatushpc.com.br/xcat/apt/xcat-dep`.
- The cache lives in `/var/cache/nginx/apt/xcat-dep`; nginx automatically pulls artifacts on demand and serves them to the test containers. You do not need to maintain a local tarball of the dependency DEBs as long as the VersatusHPC mirror is reachable.
- `builddebs.pl` defaults to port `8080`. Use `--nginx-port` if you have a conflicting service, and pass the same value later to the test harness.

## Building DEBs for a Target

```bash
./builddebs.pl --build-all \
    [--target jammy|noble|resolute ...] \
    [--package perl-xCAT|xCAT|xCATsn|xCAT-client|xCAT-server|xCAT-vlan|xCAT-test ...] \
    [--nproc N] [--force] [--repos-path /var/www/html/repos/xcat-core] \
    [--init-all] [--init-reprepro] [--create-repos]
```

- Run `./builddebs.pl --init-all` once to create cached `sbuild` tarballs for every supported release. Add `--force` when you want to refresh a cache.
- `--build-all` can be restricted via repeated `--target` and `--package` flags. Packages are built in parallel (default: `nproc --all` workers).
- Artifacts go into `dist/ubuntu/<codename>/`. After each build the script runs `reprepro` under `/var/www/html/repos/xcat-core` (configurable via `--repos-path`) to publish the apt repo consumed by the tests.
- `--keep-going` lets the build continue after failures; otherwise the script aborts the remaining workers and prints a summary.

Example – rebuild `xCAT-server` for Noble and refresh the repository:

```bash
./builddebs.pl --build-all --package xCAT-server --target noble --force
```

## nginx on Port 8080

- Ensure nginx listens on port `8080` (or your chosen port) and that `/var/www/html/repos/xcat-core` exists. `./builddebs.pl --init-reprepro` creates the initial `reprepro` configuration so nginx can index the repository.
- `./builddebs.pl --init-nginx --nginx-port 8080` generates a config that:
  - Serves `http://<host>:8080/repos/xcat-core/<codename>` directly from `/var/www/html/repos/xcat-core`.
  - Exposes `http://<host>:8080/repos/xcat-dep/` as a caching proxy for the VersatusHPC dependency mirror, reducing the time needed to spin up test containers.
- Restart nginx after changes and make sure the cached repo is reachable from the containers via `http://host.containers.internal:8080/repos/...`.

## Preparing the Test Container

```bash
test/common/scripts/setuptesthost.pl --setup-container --distro ubuntu --releasever 24.04 [--force]
```

- This builds the image from `test/ubuntu/Containerfile` and creates a container named `xcattest-ubuntu24.04` (adjust the release to `22.04` or `26.04` as needed).
- The container setup binds `test/ubuntu/scripts` into `/workspace/scripts` and enables `systemd`, matching what the test harness expects. Re-run with `--force` to rebuild the image or recreate the container.

## Running the Automated Tests

With the container running and nginx serving `/repos/xcat-core` and `/repos/xcat-dep`:

```bash
podman exec -it xcattest-ubuntu24.04 \
    /workspace/scripts/testxcat.pl
```

- The script writes `/etc/apt/sources.list.d/local-repos.list` that points to `http://host.containers.internal:<port>/repos/xcat-core jammy main` and `.../repos/xcat-dep focal main`, runs `apt update`, installs `xcat` and `xcat-test`, then executes `xcattest -s ci_test`.
- Pass `--nginx-port` when your nginx instance listens on a non-default port. The run is idempotent: it leaves the container configured so rerunning the script skips steps that already completed.

## End-to-End Checklist

- `./builddebs.pl --init-all`, `--init-reprepro`, and `--init-nginx` completed successfully.
- `./builddebs.pl --build-all [--target ...]` produced the DEBs and populated `/var/www/html/repos/xcat-core/<codename>`.
- nginx listens on the chosen port, serves `/repos/xcat-core`, and proxies `/repos/xcat-dep` to the VersatusHPC mirror.
- `test/common/scripts/setuptesthost.pl --setup-container --distro ubuntu --releasever <version>` created or updated the `xcattest-ubuntu<version>` container.
- `podman exec -it xcattest-ubuntu<version> /workspace/scripts/testxcat.pl --nginx-port <port>` installs xCAT inside the container and runs the CI test suite end-to-end.
