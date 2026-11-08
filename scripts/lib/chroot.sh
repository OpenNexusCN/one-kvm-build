#!/usr/bin/env bash
# Chroot helpers for aarch64 root filesystems on an x86_64 runner.
#
# The kernel, initramfs tooling and dpkg maintainer scripts are all target
# architecture binaries.  They run through qemu-user-static + binfmt_misc.
# Keep the environment minimal: do not leak host tokens into the chroot.

# chroot_mounts <root>
chroot_mounts() {
    local root="$1"
    mkdir -p "${root}/proc" "${root}/sys" "${root}/dev" "${root}/dev/pts" "${root}/run"
    mountpoint -q "${root}/proc" || mount -t proc proc "${root}/proc"
    mountpoint -q "${root}/sys" || mount --rbind /sys "${root}/sys"
    mountpoint -q "${root}/dev" || mount --rbind /dev "${root}/dev"
    mountpoint -q "${root}/dev/pts" || mount --rbind /dev/pts "${root}/dev/pts"
    mountpoint -q "${root}/run" || mount -t tmpfs tmpfs "${root}/run"
}

# _umount_tree <mountpoint>
# Recursively unmount a tree, falling back to a lazy unmount.  Used by the
# chroot helpers and by family cleanup so a busy helper mount cannot keep the
# image mounted.
_umount_tree() {
    local mnt="$1"
    mountpoint -q "$mnt" 2>/dev/null || return 0
    umount -R "$mnt" 2>/dev/null || umount -lR "$mnt" 2>/dev/null || true
}

# chroot_umounts <root>
chroot_umounts() {
    local root="$1"
    _umount_tree "${root}/run"
    _umount_tree "${root}/dev/pts"
    _umount_tree "${root}/dev"
    _umount_tree "${root}/sys"
    _umount_tree "${root}/proc"
}

# install_qemu <root>
# Sets QEMU_COPIED=true when the static binary had to be added to the image,
# so the caller can remove it afterwards.
install_qemu() {
    local root="$1"
    QEMU_COPIED="false"
    if [ "$(uname -m)" = "aarch64" ]; then
        return 0
    fi
    if [ ! -e "${root}/usr/bin/qemu-aarch64-static" ]; then
        if [ -x /usr/bin/qemu-aarch64-static ]; then
            cp -f /usr/bin/qemu-aarch64-static "${root}/usr/bin/qemu-aarch64-static"
            chmod 755 "${root}/usr/bin/qemu-aarch64-static"
            QEMU_COPIED="true"
        else
            die "qemu-aarch64-static is not installed on the host"
        fi
    fi
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        die "binfmt_misc handler for qemu-aarch64 is not registered (install qemu-user-static)"
    fi
}

# chroot_run <root> <command...>
# Runs a bash command string inside the target root with a scrubbed environment.
chroot_run() {
    local root="$1"
    shift
    local command="$*"
    [ -d "$root" ] || die "chroot_run: missing root $root"

    install_qemu "$root"

    # Armbian ships /etc/resolv.conf as a symlink to the systemd-resolved
    # stub.  Replace it with a real file while apt/update-initramfs run, then
    # restore the original state.
    local resolv_was_symlink="false" resolv_link_target="" resolv_backup="" resolv_existed="false"
    if [ -L "${root}/etc/resolv.conf" ]; then
        resolv_existed="true"
        resolv_was_symlink="true"
        resolv_link_target="$(readlink "${root}/etc/resolv.conf")"
        rm -f "${root}/etc/resolv.conf"
    elif [ -f "${root}/etc/resolv.conf" ]; then
        resolv_existed="true"
        resolv_backup="$(mktemp)"
        cp -f "${root}/etc/resolv.conf" "$resolv_backup"
    fi
    if [ -f /etc/resolv.conf ]; then
        cp -f /etc/resolv.conf "${root}/etc/resolv.conf"
    fi

    chroot_mounts "$root"
    local rc=0
    chroot "$root" /usr/bin/env -i \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root LANG=C LC_ALL=C DEBIAN_FRONTEND=noninteractive \
        /bin/bash -c "$command" || rc=$?
    chroot_umounts "$root"

    if [ "${QEMU_COPIED:-false}" = "true" ]; then
        rm -f "${root}/usr/bin/qemu-aarch64-static"
    fi
    rm -f "${root}/etc/resolv.conf"
    if [ "$resolv_was_symlink" = "true" ]; then
        ln -s "$resolv_link_target" "${root}/etc/resolv.conf"
    elif [ -n "$resolv_backup" ]; then
        cp -f "$resolv_backup" "${root}/etc/resolv.conf"
        rm -f "$resolv_backup"
    elif [ "$resolv_existed" != "true" ]; then
        : # leave the image without resolv.conf, as it was
    fi

    return "$rc"
}

# check_target_arch <root>
check_target_arch() {
    local root="$1" desc
    desc="$(file -b "${root}/bin/bash" 2>/dev/null || true)"
    case "$desc" in
        *ARM*|*aarch64*) return 0 ;;
        *) die "Root filesystem is not aarch64: ${desc:-unknown}" ;;
    esac
}
