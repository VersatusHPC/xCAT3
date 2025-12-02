#!/bin/bash
# Dracut module for xCAT Stateless Boot
# /opt/xcat/.../dracut_105/stateless/module-setup.sh

check() {
    # Always allow this module to load
    return 0
}

depends() {
    echo "network nfs"
    # EL10 may require network-manager explicitly if selected
    return 0
}

install() {
    # Install required binaries
    dracut_install \
        curl cpio gzip modprobe wc touch echo cut \
        grep ifconfig hostname awk egrep dirname expr \
        parted mke2fs bc mkswap swapon chmod \
        mkfs mkfs.ext4 mkfs.xfs xfs_db \
        ethtool

    # Install updateflag helper
    inst_simple "$moddir/xcat-updateflag" "/sbin/xcat-updateflag"

    # Hooks
    inst_hook pre-mount  50 "$moddir/xcat-premount.sh"
    inst_hook pre-pivot  50 "$moddir/xcat-prepivot.sh"

    # Install xCAT udev rules
    for f in /etc/udev/rules.d/*; do
        if grep -qi xcat "$f"; then
            inst_rules "$f"
        fi
    done
}
