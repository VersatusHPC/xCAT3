#!/usr/bin/env bash
#
# ci/vm-test.sh — Create a test VM, install xCAT from a local repo, validate, and clean up.
#
# Usage:
#   ./ci/vm-test.sh --releasever 10 --repo-path /path/to/rpms --repo-target rhel+epel-10-x86_64
#
# The script tracks every VM it creates in a state file so that only VMs
# from that file are ever touched (started, stopped, or destroyed).
#
set -euo pipefail

# ── tunables ─────────────────────────────────────────────────────────────────
RELEASEVER="${RELEASEVER:-10}"
KEEP_VM=0
STATE_DIR="/var/lib/xcat3-ci"
STATE_FILE="$STATE_DIR/managed-vms.txt"
ARCH="$(uname -m)"
VM_PREFIX="xcat3-ci"
CLOUD_IMG_DIR="/var/lib/libvirt/images"
SSH_TIMEOUT=300
LIBVIRT_NET="default"
REPO_TARGET="${REPO_TARGET:-}"
REPO_PATH="${REPO_PATH:-}"
XCAT_DEP_PATH="${XCAT_DEP_PATH:-/opt/xcat-dep}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)           KEEP_VM=1; shift ;;
        --releasever)     RELEASEVER="$2"; shift 2 ;;
        --repo-target)    REPO_TARGET="$2"; shift 2 ;;
        --repo-path)      REPO_PATH="$2"; shift 2 ;;
        --xcat-dep-path)  XCAT_DEP_PATH="$2"; shift 2 ;;
        *)                echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$REPO_TARGET" ]]; then
    DISTRO=$(. /etc/os-release && echo "$ID")
    case "$DISTRO" in
        almalinux) DISTRO="alma" ;;
        rocky)     DISTRO="rocky" ;;
    esac
    REPO_TARGET="${DISTRO}+epel-${RELEASEVER}-${ARCH}"
fi

VM_NAME="${VM_PREFIX}-el${RELEASEVER}-${ARCH}-$$"
VM_DISK="${CLOUD_IMG_DIR}/${VM_NAME}.qcow2"
SSH_KEY="$STATE_DIR/ci-ssh-key"

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [vm-test] $*"; }
die()  { log "FATAL: $*"; exit 1; }

state_init() {
    sudo mkdir -p "$STATE_DIR"
    sudo touch "$STATE_FILE"
    sudo chmod 666 "$STATE_FILE"
    if [[ ! -f "$SSH_KEY" ]]; then
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
        log "Generated CI SSH key at $SSH_KEY"
    fi
}

state_add() {
    echo "$1" >> "$STATE_FILE"
    log "Registered VM $1 in $STATE_FILE"
}

state_remove() {
    local tmp
    tmp=$(mktemp)
    grep -vxF "$1" "$STATE_FILE" > "$tmp" || true
    mv "$tmp" "$STATE_FILE"
    log "Unregistered VM $1 from $STATE_FILE"
}

is_managed() {
    grep -qxF "$1" "$STATE_FILE" 2>/dev/null
}

# ── cloud image ──────────────────────────────────────────────────────────────
ensure_cloud_image() {
    local base_img
    if [[ "$ARCH" == "x86_64" ]]; then
        base_img="$CLOUD_IMG_DIR/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
        if [[ ! -f "$base_img" ]]; then
            log "Downloading Rocky 9 GenericCloud x86_64..."
            sudo curl -sL -o "$base_img" \
                "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
        fi
    elif [[ "$ARCH" == "ppc64le" ]]; then
        base_img="$CLOUD_IMG_DIR/Rocky-9-GenericCloud-Base.latest.ppc64le.qcow2"
        if [[ ! -f "$base_img" ]]; then
            log "Downloading Rocky 9 GenericCloud ppc64le..."
            sudo curl -sL -o "$base_img" \
                "https://dl.rockylinux.org/pub/rocky/9/images/ppc64le/Rocky-9-GenericCloud-Base.latest.ppc64le.qcow2"
        fi
    else
        die "Unsupported architecture: $ARCH"
    fi
    echo "$base_img"
}

# ── cloud-init ───────────────────────────────────────────────────────────────
make_cloud_init_iso() {
    local ci_dir="$STATE_DIR/$VM_NAME-ci"
    mkdir -p "$ci_dir"

    cat > "$ci_dir/user-data" << USERDATA
#cloud-config
hostname: $VM_NAME
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  users:
    - name: root
      password: xcat3ci
      type: text

ssh_authorized_keys:
  - $(cat "${SSH_KEY}.pub")

packages:
  - epel-release

runcmd:
  - sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  - setenforce 0 || true
  - touch /var/lib/cloud-init-done
USERDATA

    cat > "$ci_dir/meta-data" << METADATA
instance-id: $VM_NAME
local-hostname: $VM_NAME
METADATA

    cat > "$ci_dir/network-config" << NETCFG
version: 2
ethernets:
  eth0:
    dhcp4: true
NETCFG

    local iso_path="$STATE_DIR/${VM_NAME}-cidata.iso"
    if command -v genisoimage &>/dev/null; then
        genisoimage -output "$iso_path" -volid cidata -joliet -rock \
            "$ci_dir/user-data" "$ci_dir/meta-data" "$ci_dir/network-config" 2>/dev/null
    elif command -v mkisofs &>/dev/null; then
        mkisofs -output "$iso_path" -volid cidata -joliet -rock \
            "$ci_dir/user-data" "$ci_dir/meta-data" "$ci_dir/network-config" 2>/dev/null
    elif command -v xorrisofs &>/dev/null; then
        xorrisofs -output "$iso_path" -volid cidata -joliet -rock \
            "$ci_dir/user-data" "$ci_dir/meta-data" "$ci_dir/network-config" 2>/dev/null
    else
        die "No ISO creation tool found (genisoimage/mkisofs/xorrisofs)"
    fi
    echo "$iso_path"
}

# ── VM lifecycle ─────────────────────────────────────────────────────────────
create_vm() {
    local base_img ci_iso
    base_img=$(ensure_cloud_image)
    log "Creating COW disk from $base_img"
    sudo qemu-img create -f qcow2 -b "$base_img" -F qcow2 "$VM_DISK" 50G

    ci_iso=$(make_cloud_init_iso)
    log "Cloud-init ISO: $ci_iso"

    local osinfo="rocky9"
    local machine_type
    if [[ "$ARCH" == "ppc64le" ]]; then
        machine_type="pseries"
    else
        machine_type="q35"
    fi

    log "Creating VM $VM_NAME"
    sudo virt-install \
        --connect qemu:///system \
        --name "$VM_NAME" \
        --memory 4096 \
        --vcpus 2 \
        --cpu host-passthrough \
        --machine "$machine_type" \
        --import \
        --disk "$VM_DISK" \
        --disk "$ci_iso,device=cdrom" \
        --network network="$LIBVIRT_NET" \
        --osinfo name="$osinfo" \
        --noautoconsole \
        --noreboot

    state_add "$VM_NAME"
    sudo virsh start "$VM_NAME"
    log "VM $VM_NAME started"
}

wait_for_ssh() {
    log "Waiting for VM to get an IP (up to ${SSH_TIMEOUT}s)..."
    local elapsed=0 vm_ip=""
    while [[ $elapsed -lt $SSH_TIMEOUT ]]; do
        vm_ip=$(sudo virsh domifaddr "$VM_NAME" 2>/dev/null \
            | grep -oP '(\d+\.){3}\d+' | head -1) || true
        if [[ -n "$vm_ip" ]]; then
            log "VM IP: $vm_ip — waiting for SSH..."
            if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                   -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
                   root@"$vm_ip" 'true' 2>/dev/null; then
                echo "$vm_ip"
                return 0
            fi
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    die "Timed out waiting for SSH on $VM_NAME"
}

ssh_cmd() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"
}

copy_repos_to_vm() {
    local vm_ip="$1"
    [[ -z "$REPO_PATH" ]] && die "--repo-path is required"

    log "Copying xcat-core repo from $REPO_PATH to $vm_ip:/opt/xcat3-repo/"
    ssh_cmd root@"$vm_ip" 'mkdir -p /opt/xcat3-repo'
    tar -C "$REPO_PATH" -cf - . \
        | ssh_cmd root@"$vm_ip" 'tar -C /opt/xcat3-repo -xf -'

    local dep_dir="$XCAT_DEP_PATH/el${RELEASEVER}/${ARCH}"
    if [[ -d "$dep_dir" ]]; then
        log "Copying xcat-dep from $dep_dir to $vm_ip:/opt/xcat-dep/"
        ssh_cmd root@"$vm_ip" 'mkdir -p /opt/xcat-dep'
        tar -C "$dep_dir" -cf - . \
            | ssh_cmd root@"$vm_ip" 'tar -C /opt/xcat-dep -xf -'
    else
        log "WARNING: xcat-dep not found at $dep_dir — skipping"
    fi

    log "Repos copied successfully"
}

run_tests() {
    local vm_ip="$1"
    log "Running tests on $vm_ip"

    copy_repos_to_vm "$vm_ip"

    ssh_cmd root@"$vm_ip" bash -s "$RELEASEVER" "$ARCH" << 'TEST_SCRIPT'
set -euo pipefail
RELEASEVER="$1"
ARCH="$2"
echo "=== Test VM: $(hostname) / $(uname -m) / EL${RELEASEVER} ==="

echo "--- Waiting for cloud-init to finish ---"
timeout 300 bash -c 'while [ ! -f /var/lib/cloud-init-done ]; do sleep 5; done' \
    || { echo "cloud-init did not finish in time"; exit 1; }

echo "--- Enabling CRB repo ---"
dnf config-manager --set-enabled crb 2>/dev/null || true

echo "--- Configuring local repos ---"
cat > /etc/yum.repos.d/xcat3-local.repo << 'REPO'
[xcat3-core]
name=xCAT3 CI Build (local)
baseurl=file:///opt/xcat3-repo/
gpgcheck=0
enabled=1

[xcat3-dep]
name=xCAT3 Dependencies (local)
baseurl=file:///opt/xcat-dep/
gpgcheck=0
enabled=1
REPO

dnf makecache || true

echo "--- Installing xCAT ---"
dnf install -y xCAT || { echo "FAIL: dnf install xCAT failed"; exit 1; }

echo "--- Sourcing xCAT profile ---"
source /etc/profile.d/xcat.sh 2>/dev/null || true

echo "--- Validating xcatd ---"
systemctl is-active xcatd || { echo "FAIL: xcatd is not running"; exit 1; }

echo "--- Validating lsdef ---"
lsdef || { echo "FAIL: lsdef did not work"; exit 1; }

echo "=== ALL TESTS PASSED ==="
TEST_SCRIPT
}

destroy_vm() {
    local name="$1"
    if ! is_managed "$name"; then
        log "REFUSING to destroy $name — not in managed VMs file"
        return 1
    fi
    log "Destroying VM $name"
    sudo virsh destroy "$name" 2>/dev/null || true
    sudo virsh undefine "$name" --remove-all-storage 2>/dev/null || true
    rm -rf "$STATE_DIR/${name}-ci" "$STATE_DIR/${name}-cidata.iso"
    state_remove "$name"
    log "VM $name destroyed and cleaned up"
}

cleanup_all_managed() {
    log "Cleaning up all managed VMs..."
    if [[ ! -f "$STATE_FILE" ]]; then
        return
    fi
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        destroy_vm "$name" || true
    done < "$STATE_FILE"
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    state_init
    trap 'if [[ $KEEP_VM -eq 0 ]]; then destroy_vm "$VM_NAME" || true; fi' EXIT

    create_vm
    local vm_ip
    vm_ip=$(wait_for_ssh)
    run_tests "$vm_ip"

    log "Test run complete for $VM_NAME"
}

main "$@"
