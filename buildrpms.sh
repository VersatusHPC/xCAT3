#!/bin/bash -e

# Build xCAT rpms for multiple targets using mock for
# chroot encapsulation. There are multiple packages and
# multiple targets. A package is a xCAT package, like
# xCAT-server, a target is a mock chroot, like rhel+epel-9-x86_64.
#
# This script has two modes:
#   ./buildrpms.sh all
#   ./buildrpms.sh single <PACKAGE> <TARGET>
#
# In 'all' mode it builds ALL packages for ALL targets, this
# is, a cartesian product PKGS x TARGETS, a RPM is a pair 
# (PKG, TARGET).
#
# In 'single' mode a single RPM is built. It is intented for
# reproducing failing builds and for debugging.
#
# In order to make 'all' mode faster the builds are parallelized. Since mock
# lock chroots a distinct chroot is created for each RPM with name
# <PKG>-<TARGET>, then multiple mock processes are spawn, each with its own
# chroot.
#
# The output is generated at dist/ folder, both .src.rpm and .rpm files are
# in this folder.
#
# Notes:
# - `xargs` requires shell functions and variables to be exported
# - Because `buildall` is executed by xargs, I updated it to accept a single
#   argument <pkg>:<target> intead of two arguments <pkg> <target> 

# pkgs built by default
PACKAGES=(xCAT-{server,client,probe,openbmc-py,rmc,test,vlan,confluent} perl-xCAT xCAT)

# All targets
TARGETS=(rhel+epel-{8,9,10}-x86_64)

SOURCES=${SOURCES:-/root/rpmbuild/SOURCES/}
VERSION=$(cat Version)
RELEASE=$(cat Release)
GITINFO=$(cat Gitinfo)

NPROC=${NPROC:-$(nproc --all)}

export SOURCES VERSION RELEASE GITINFO

# Holds all RPMS to be built
declare -a RPMS=()
for target in ${TARGETS[@]}; do
  for pkg in ${PACKAGES[@]}; do
    RPMS+=("$pkg:$target")
  done
done

# Create the mock chroot configurations for each $pkg $target
function createmockchroot() {
  local pkg=$1
  local target=$2
  local chroot="$pkg-$target"
  if [ ! -f "/etc/mock/$chroot.cfg" ]; then
    cp "/etc/mock/$target.cfg" "/etc/mock/$chroot.cfg"
    sed -e "s/config_opts\['root'\]\s\+=.*/config_opts['root'] = \"$chroot\"/" \
      -i "/etc/mock/$chroot.cfg"
  fi
}
export -f createmockchroot

# Create a tarball of the source code into $SOURCES/. These tarballs
# are then read by the .spec files
function buildsources() {
  local pkg=$1

  case $1 in
    xCAT)
      # shipping bmcsetup and getipmi scripts as part of postscripts
      files=("bmcsetup" "getipmi")
      for f in "${files[@]}"; do
        cp "xCAT-genesis-scripts/usr/bin/"$f ${pkg}/postscripts/$f
        sed -i  "s/xcat.genesis.$f/$f/g" ${pkg}/postscripts/$f
      done
      cd xCAT
      tar --exclude upflag -czf $SOURCES/postscripts.tar.gz  postscripts LICENSE.html
      tar -czf $SOURCES/prescripts.tar.gz  prescripts
      tar -czf $SOURCES/templates.tar.gz templates
      tar -czf $SOURCES/winpostscripts.tar.gz winpostscripts
      tar -czf $SOURCES/etc.tar.gz etc
      cp xcat.conf $SOURCES
      cp xcat.conf.apach24 $SOURCES
      cp xCATMN $SOURCES
      cd ..
      ;;
    *)
      tar -czf "$SOURCES/$pkg-$VERSION.tar" $pkg
      ;;
  esac
}
export -f buildsources

# Build the .src.rpm files
function buildspkgs() {
  local pkg=$1
  local target=$2
  local chroot="$pkg-$target"
  mock -r $chroot \
    -N \
    --quiet \
    --define "version $VERSION" \
    --define "release $RELEASE" \
    --define "gitinfo $GITINFO" \
    --buildspkg \
    --spec $pkg/$pkg.spec \
    --sources $SOURCES \
    --resultdir "dist/$target/$pkg/"
}
export -f buildspkgs

# Build the .noarch.rpm files
function buildpkgs() {
  local pkg=$1
  local target=$2
  local chroot="$pkg-$target"
  mock -r $chroot \
    -N \
    --quiet \
    --define "version $VERSION" \
    --define "release $RELEASE" \
    --define "gitinfo $GITINFO" \
    --resultdir "dist/$target/$pkg/" \
    dist/$target/$pkg/$pkg-${VERSION}-${RELEASE}.src.rpm
}
export -f buildpkgs

# Receive a single argument with the format <pkg>:<target>
# Call each step required to build <pkg> for <target>
function buildall() {
  IFS=: read -r pkg target <<< "$1"
  createmockchroot $pkg $target
  buildsources $pkg $target
  buildspkgs $pkg $target
  buildpkgs $pkg $target
}
export -f buildall

function usage() {
  echo "usage:. $0 single <PKG> <TARGET>"
  echo "usage:. $0 all"
  echo "  where:"
  echo "    PKG    = one of xCAT-server,xCAT-client,.."
  echo '    TARGET = one of `mock --list-chroots`'
  echo '    all    = build all combinations'
  exit -1
}
  
test -d dist/ || mkdir dist/

if [ $# -ne 1 ] && [ $# -ne 3 ]; then
  usage
fi

case $1 in 
  'single')
    buildall "$2:$3"
    ;;
  'all')
    echo -n ${RPMS[@]} | xargs -d ' ' -I% -P $NPROC -t bash -euc "buildall %"
    ;;
  *)
    usage
    ;;
esac
