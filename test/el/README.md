# Testing Workflow for buildrpms.pl

## Overview

Requirements:

_The following software are assumed to be instaled in the host responsible for building the RPMs and running the tests._

* [mock](https://rpm-software-management.github.io/mock/) for building the RPMs
* nginx for serving RPM repositories
* [podman](https://podman.io)
* This was tested on a RHEL9.7 host.


_Note: Before start, ensure nginx is listening 8080. (the script will not do that for you, you need to change the nginx.conf and restart it), more on this below_

Workflow:

`buildrpms.pl` is the entry point for generating all xCAT RPMs required for a specific [mock](https://rpm-software-management.github.io/mock/) target (for example  `rhel+epel-9-x86_64`, `rhel+epel-10-x86_64`). Use `mock --list-chroots` to see all possible postions. _But note that only `rhle+epel-{8,9,10}` are being tested now_. Each target corresponds to a mock chroot and eventually to a container image used by the test harness. The high-level flow is:

1. Prepare the dependency repositories (`../xcat-dep`) for the target (more on this below)
2. Run `buildrpms.pl` to build or reuse RPMs for the target and export a repository.
3. Provision the testing container for the same target.
4. Execute the automated test suite inside the container.

All  are idempotent. They only rebuild or reinstall what is missing. Pass `--force` to any step when you want to overwrite existing content.

## xCAT Runtime Dependencies (`../xcat-dep`)
- The dependency repositories must live one directory above this repo, in `../xcat-dep`.
- We keep a tarball that already includes the EL 8, EL 9 and EL 10 dependency RPMs. Extract the tarball so that the directory tree looks like `../xcat-dep/<el version>/<arch>/`.
- Dependencies are only required to run xCAT. Building does not require xcat-dep.

The expected structure is like this

    xcat-dep/
    ├── el10
    │   └── x86_64
    │       └──  repodata
    |       └──  *.rpm
    ├── el9
    │   └── x86_64
    │       └──  repodata
    |       └──  *.rpm
    └── el8
        └── x86_64
            └──  repodata
            └──  *.rpm


## Building RPMs for a Target
```bash
./buildrpms.pl [--target <target>] [--package <pkg>] [--force] [--nproc N] [--xcat_dep_path /path/to/xcat-dep] [--nginx_port 8080]
```

- `--target` may be repeated; by default all supported targets (`rhel+epel-{8,9,10}-x86_64`) are built.
- `--package` narrows the build to specific RPM names; the default list contains every xCAT component.
- `--force` rebuilds even if the corresponding SRPM/RPM already exists under `dist/<target>/`.
- `--nproc N` controls the amount of parallel mock jobs (defaults to `nproc --all`).
- `--xcat_dep_path` tells the nginx helper where the dependency repos live (defaults to `../xcat-dep`).
- `--nginx_port` changes the port used when generating `/etc/nginx/conf.d/xcat-repos.conf`.
- Passing `--configure_nginx` alone regenerates the nginx configuration without building.

Example – rebuild only `perl-xCAT` for EL9 and overwrite previous artifacts:

```bash
./buildrpms.pl --target rhel+epel-9-x86_64 --package perl-xCAT --force
```

Under the hood the script invokes [mock](https://rpm-software-management.github.io/mock/) to build SRPMs and RPMs, skips work when files already exist (unless `--force` is used), runs `createrepo dist/<target>/rpms`, and finally rewrites the nginx configuration so the repo is served automatically.

All builds run in parallel according to `--nproc`. Be aware that mock consumes significant disk space (plan for at least ~50 GB between `/var/lib/mock` and `/var/cache/mock`).

### nginx on Port 8080
- `buildrpms.pl` assumes nginx exposes the generated repository on port 8080. Manually update the main nginx configuration (for example `/etc/nginx/nginx.conf`) so that it listens on `8080` port. The  will create a `/etc/nginx/conf.d/xcat-repos.conf` file with all the repositories configured and restart
nginx at each run.

## Preparing the Test Container
```bash
test/common/setuptesthost.pl --setup-container --distro el --releasever 9 [--force]
```

- This builds a container image and creates a container named `xcattest-elX` (X is 8, 9 or 10 depending on the `--releasever`).
- The container setup is idempotent: it checks for an existing container/image and skips recreation unless you provide `--force`.


## Running the Automated Tests
Once the container exists and nginx is serving the repo:

```bash
podman exec -it xcattest-el10 /testxcat.pl --all
```

- Replace `xcattest-el10` with the appropriate container name. The script configures the repository inside the container, installs xCAT, ensures `xcatd` is running, and finally runs `lsdef` to verify daemon connectivity.
- The tester exposes additional knobs: use `--setup_repos`, `--install`, `--uninstall`, `--reinstall`, `--validate`, or `--all` (default in the example) plus `--nginx_port` if your repo is served on a different port. Combine these as needed to drive just one phase or the entire install/validate pass.
- You can safely rerun the command; it will reuse the container state unless `--force` is supplied to the helper , and `--reinstall` forces a clean uninstall/install cycle inside the container.

## End-to-End Checklist
- Dependencies extracted to `../xcat-dep` for all EL versions you plan to build.
- `buildrpms.pl` completes successfully for the target and produces a repository.
- nginx listens on port 8080 and serves the generated repository.
- `test/common/setuptesthost.pl --setupcontainer --target <target>` creates or updates the `xcattest-elX` container.
- `podman exec -it xcattest-elX /testxcat.pl --all` runs to completion and verifies the xCAT stack inside the container.
