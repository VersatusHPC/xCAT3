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

All scripts are idempotent. They only rebuild or reinstall what is missing. Pass `--force` to any step when you want to overwrite existing content.

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
./buildrpms.pl --target <target> [--force]
```

- The script invokes [mock](https://rpm-software-management.github.io/mock/) for the requested target to build *all* RPMs listed for that target. The target name maps to the chroot definition under `/etc/mock/`.
- Before building `X.rpm`, the script checks whether the file already exists and skips it; use `--force` to rebuild the RPM even if the file is present **this is important if the source code changed since the last build!**.
- When the build finishes, the script collects the RPMs, runs `createrepo` and writes an nginx configuration snippet so the repo can be served.

You can build a single package by specifying in the command line for example

```bash
./buildrpms.pl --target rhel+epel-9-x86_64 --package perl-xCAT --force
```

All builds run in parallel, use `--nproc N` to control the number of jobs. Also note that this will use a lot of disk space, at last 50G is required since the last run. The directories that grow are `/var/lib/mock` and `/var/cache/mock`.

### nginx on Port 8080
- `buildrpms.pl` assumes nginx exposes the generated repository on port 8080. Manually update the main nginx configuration (for example `/etc/nginx/nginx.conf`) so that it listens on `8080` port. The scripts will create a `/etc/nginx/conf.d/xcat-repos.conf` file with all the repositories configured and restart
nginx at each run.

## Preparing the Test Container
```bash
test/scripts/setuptesthost.pl --setupcontainer --target <target> [--force]
```

- This builds a container image and creates a container named `xcattest-elX` (X is 8, 9 or 10 depending on the target).
- The container setup is idempotent: it checks for an existing container/image and skips recreation unless you provide `--force`.
- The EL `RELEASEVER` (8, 9 or 10) is deduced from the target which is expected to be a triple in the format `<DISTRO>-<RELEASEVER>-<ARCH>` and it is used to as `--build-arg RELEASEVER=<RELEASEVER>` during the container image building.

## Running the Automated Tests
Once the container exists and nginx is serving the repo:

```bash
podman exec -it xcattest-el10 scripts/testxcat.pl --all
```

- Replace `xcattest-el10` with the appropriate container name. The script configures the repository inside the container, installs xCAT, ensures `xcatd` is running, and finally runs `lsdef` to verify daemon connectivity.
- You can safely rerun the command; it will reuse the container state unless `--force` is supplied to the helper scripts.
- In this case you call combine `--force` with `--reinstallxcat` to make it remove xCAT completely and reinstalling again.

## End-to-End Checklist
- Dependencies extracted to `../xcat-dep` for all EL versions you plan to build.
- `buildrpms.pl` completes successfully for the target and produces a repository.
- nginx listens on port 8080 and serves the generated repository.
- `test/scripts/setuptesthost.pl --setupcontainer --target <target>` creates or updates the `xcattest-elX` container.
- `podman exec -it xcattest-elX scripts/testxcat.pl --all` runs to completion and verifies the xCAT stack inside the container.
