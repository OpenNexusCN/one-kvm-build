#!/usr/bin/env bash
# Rockchip image family.
#
# Covers the Armbian/ophub Rockchip images used by the FMX1 boards:
#   * GPT image with an ext4 BOOT partition and an ext4 ROOTFS partition
#   * U-Boot loads /Image, /uInitrd and dtb/<fdtfile> via boot.scr, and
#     extlinux/extlinux.conf is provided as the distro-boot alternative
#
# The functions operate on globals set by scripts/build-image.sh:
#   IMG ROOT_MNT BOOT_MNT LOOP_DEV KERNEL_BUNDLE KERNEL_VERSION
#   KERNEL_IMAGE KERNEL_CONFIG KERNEL_SYSTEMMAP KERNEL_MODULES KERNEL_DTB
#   IMAGE_EXTRA_MB PRUNE_OLD_KERNEL REQUIRE_INITRD_REGEN IMAGE_HOSTNAME

ROOT_PART_NUM=""
BOOT_PART_NUM=""
ROOT_FS=""
BOOT_FS=""
ROOT_UUID=""
EXTLINUX_CONF=""

# ---------------------------------------------------------------------------
# Loop device / partition helpers
# ---------------------------------------------------------------------------

_loop_attach() {
    local img="$1"
    LOOP_DEV="$(losetup -Pf --show "$img")" || die "Cannot attach ${img} to a loop device"
    local _
    for _ in $(seq 1 40); do
        if compgen -G "${LOOP_DEV}p*" >/dev/null; then
            return 0
        fi
        sleep 0.25
    done
    die "Loop partitions did not appear for ${LOOP_DEV}"
}

_loop_detach() {
    if [ -n "${LOOP_DEV:-}" ]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
        LOOP_DEV=""
    fi
}

_part_num() {
    local part="$1" base
    base="$(basename "$part")"
    printf '%s' "${base#"$(basename "$LOOP_DEV")"p}"
}

# Recognize a dedicated boot partition that may use extlinux, boot.scr,
# armbianEnv.txt, uEnv.txt, or a plain Image + dtb layout.
_boot_partition_like() {
    local mnt="$1"
    [ -f "${mnt}/extlinux/extlinux.conf" ] && return 0
    [ -f "${mnt}/boot/extlinux/extlinux.conf" ] && return 0
    [ -f "${mnt}/boot.scr" ] && return 0
    [ -f "${mnt}/boot.cmd" ] && return 0
    [ -f "${mnt}/armbianEnv.txt" ] && return 0
    [ -f "${mnt}/uEnv.txt" ] && return 0
    [ -f "${mnt}/boot/boot.scr" ] && return 0
    [ -f "${mnt}/boot/boot.cmd" ] && return 0
    [ -f "${mnt}/boot/armbianEnv.txt" ] && return 0
    [ -f "${mnt}/boot/uEnv.txt" ] && return 0
    if { [ -f "${mnt}/Image" ] || compgen -G "${mnt}/vmlinuz-*" >/dev/null; } \
        && [ -d "${mnt}/dtb" ]; then
        return 0
    fi
    if { [ -f "${mnt}/boot/Image" ] || compgen -G "${mnt}/boot/vmlinuz-*" >/dev/null; } \
        && [ -d "${mnt}/boot/dtb" ]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Inspect / grow / mount
# ---------------------------------------------------------------------------

family_inspect_image() {
    local img="$1" inspect_root="${WORK}/inspect"
    rm -rf "$inspect_root"
    mkdir -p "$inspect_root"

    _loop_attach "$img"
    local part mnt
    for part in "${LOOP_DEV}"p*; do
        [ -b "$part" ] || continue
        mnt="${inspect_root}/$(basename "$part")"
        mkdir -p "$mnt"
        mount -o ro "$part" "$mnt" 2>/dev/null || continue
        if [ -z "$ROOT_PART_NUM" ] && [ -f "${mnt}/etc/os-release" ] \
            && [ -d "${mnt}/usr/lib/modules" ]; then
            ROOT_PART_NUM="$(_part_num "$part")"
            ROOT_FS="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
            ROOT_UUID="$(blkid -o value -s UUID "$part" 2>/dev/null || true)"
        elif [ -z "$BOOT_PART_NUM" ] && _boot_partition_like "$mnt"; then
            BOOT_PART_NUM="$(_part_num "$part")"
            BOOT_FS="$(blkid -o value -s TYPE "$part" 2>/dev/null || true)"
        fi
        umount "$mnt"
    done
    _loop_detach

    [ -n "$ROOT_PART_NUM" ] || die "Cannot find the root filesystem partition in ${img}"
    if [ -z "$BOOT_PART_NUM" ]; then
        info "No separate boot partition; using /boot inside the root filesystem"
        BOOT_PART_NUM="$ROOT_PART_NUM"
        BOOT_FS="$ROOT_FS"
    fi
    info "Root partition: ${ROOT_PART_NUM} (${ROOT_FS}, UUID ${ROOT_UUID:-unknown})"
    info "Boot partition: ${BOOT_PART_NUM} (${BOOT_FS})"
}

family_grow_image() {
    local extra_mb="${IMAGE_EXTRA_MB:-0}"
    [ "$extra_mb" -gt 0 ] || return 0

    local root_start last_entry
    root_start="$(sfdisk -J "$IMG" \
        | jq -r --argjson n "$ROOT_PART_NUM" '.partitiontable.partitions[$n - 1].start')"
    [ -n "$root_start" ] && [ "$root_start" != "null" ] || die "Cannot read the root partition start"

    # sfdisk -N can only extend a partition into free space at the end of
    # the disk.  Require the root partition to be the one with the highest
    # start sector; the GPT backup area after it is handled by sfdisk.
    last_entry="$(sfdisk -J "$IMG" \
        | jq -r '.partitiontable.partitions | to_entries | sort_by(.value.start) | last | .key')"
    if [ "$last_entry" != "$((ROOT_PART_NUM - 1))" ]; then
        die "Root partition ${ROOT_PART_NUM} is not the last partition; cannot grow it safely"
    fi

    info "Growing root partition by ${extra_mb} MiB"
    truncate -s "+${extra_mb}M" "$IMG"
    echo ',+' | sfdisk --force -N "$ROOT_PART_NUM" "$IMG" >/dev/null \
        || die "sfdisk failed to grow partition ${ROOT_PART_NUM}"

    _loop_attach "$IMG"
    local part="${LOOP_DEV}p${ROOT_PART_NUM}" rc=0
    e2fsck -f -y "$part" >/dev/null 2>&1 || rc=$?
    [ "$rc" -le 1 ] || die "e2fsck failed on ${part} (exit ${rc})"
    resize2fs "$part" >/dev/null || die "resize2fs failed on ${part}"
    _loop_detach
}

family_mount_image() {
    mkdir -p "$ROOT_MNT"
    _loop_attach "$IMG"
    if ! mount -o rw "${LOOP_DEV}p${ROOT_PART_NUM}" "$ROOT_MNT"; then
        _loop_detach
        die "Cannot mount root partition"
    fi
    if [ "$BOOT_PART_NUM" != "$ROOT_PART_NUM" ]; then
        mkdir -p "${ROOT_MNT}/boot"
        if ! mount -o rw "${LOOP_DEV}p${BOOT_PART_NUM}" "${ROOT_MNT}/boot"; then
            umount "$ROOT_MNT"
            _loop_detach
            die "Cannot mount boot partition"
        fi
    fi
    BOOT_MNT="${ROOT_MNT}/boot"

    # Some single-partition images keep the boot files at the root of the
    # root filesystem instead of /boot.
    if [ ! -f "${BOOT_MNT}/extlinux/extlinux.conf" ] \
        && [ ! -f "${BOOT_MNT}/boot.scr" ] && [ ! -f "${BOOT_MNT}/armbianEnv.txt" ] \
        && { [ -f "${ROOT_MNT}/extlinux/extlinux.conf" ] \
             || [ -f "${ROOT_MNT}/boot.scr" ] \
             || [ -f "${ROOT_MNT}/armbianEnv.txt" ]; }; then
        BOOT_MNT="$ROOT_MNT"
    fi

    # Some images put the boot files in a boot/ subdirectory of the boot
    # partition; flatten it when that is the actual boot root.
    if [ ! -f "${BOOT_MNT}/extlinux/extlinux.conf" ] \
        && [ ! -f "${BOOT_MNT}/boot.scr" ] && [ ! -f "${BOOT_MNT}/armbianEnv.txt" ] \
        && { [ -f "${BOOT_MNT}/boot/boot.scr" ] \
             || [ -f "${BOOT_MNT}/boot/armbianEnv.txt" ]; }; then
        BOOT_MNT="${BOOT_MNT}/boot"
    fi

    EXTLINUX_CONF=""
    if [ -f "${BOOT_MNT}/extlinux/extlinux.conf" ]; then
        EXTLINUX_CONF="${BOOT_MNT}/extlinux/extlinux.conf"
    elif [ -f "${BOOT_MNT}/boot/extlinux/extlinux.conf" ]; then
        EXTLINUX_CONF="${BOOT_MNT}/boot/extlinux/extlinux.conf"
        BOOT_MNT="${BOOT_MNT}/boot"
    elif [ -f "${BOOT_MNT}/boot.scr" ] || [ -f "${BOOT_MNT}/boot.cmd" ] \
        || [ -f "${BOOT_MNT}/armbianEnv.txt" ] || [ -f "${BOOT_MNT}/uEnv.txt" ]; then
        info "No extlinux; using boot.scr/armbianEnv/uEnv boot configuration"
    else
        family_cleanup
        die "Cannot find extlinux.conf, boot.scr or armbianEnv.txt on the boot partition"
    fi
    if [ -n "$EXTLINUX_CONF" ]; then
        info "extlinux config: ${EXTLINUX_CONF}"
    fi
}

family_cleanup() {
    sync || true
    if [ -n "${ROOT_MNT:-}" ] && mountpoint -q "$ROOT_MNT" 2>/dev/null; then
        # Recursively unmount /boot and any chroot helper mounts.  Fall back
        # to a lazy unmount so a busy helper mount cannot leave the image
        # attached on the runner.
        _umount_tree "$ROOT_MNT"
    fi
    _loop_detach
}

# ---------------------------------------------------------------------------
# Kernel / DTB / modules
# ---------------------------------------------------------------------------

family_install_kernel() {
    local KVER="$KERNEL_VERSION"
    [ -f "${KERNEL_BUNDLE}/${KERNEL_IMAGE}" ] || die "Missing ${KERNEL_IMAGE}"
    [ -f "${KERNEL_BUNDLE}/${KERNEL_CONFIG}" ] || die "Missing ${KERNEL_CONFIG}"
    [ -f "${KERNEL_BUNDLE}/${KERNEL_SYSTEMMAP}" ] || die "Missing ${KERNEL_SYSTEMMAP}"
    [ -f "${KERNEL_BUNDLE}/${KERNEL_MODULES}" ] || die "Missing ${KERNEL_MODULES}"

    info "Installing kernel ${KVER}"
    cp -f "${KERNEL_BUNDLE}/${KERNEL_IMAGE}" "${BOOT_MNT}/Image-${KVER}"
    cp -f "${KERNEL_BUNDLE}/${KERNEL_CONFIG}" "${BOOT_MNT}/config-${KVER}"
    cp -f "${KERNEL_BUNDLE}/${KERNEL_SYSTEMMAP}" "${BOOT_MNT}/System.map-${KVER}"

    rm -f "${BOOT_MNT}/Image"
    cp -f "${BOOT_MNT}/Image-${KVER}" "${BOOT_MNT}/Image"
    if [ "${BOOT_FS:-}" = "ext4" ] || [ "${BOOT_FS:-}" = "ext3" ]; then
        ln -sfn "Image-${KVER}" "${BOOT_MNT}/vmlinuz-${KVER}"
    else
        cp -f "${BOOT_MNT}/Image-${KVER}" "${BOOT_MNT}/vmlinuz-${KVER}"
    fi

    mkdir -p "${BOOT_MNT}/dtb/rockchip"
    shopt -s nullglob
    local dtbs=("${KERNEL_BUNDLE}"/*.dtb)
    shopt -u nullglob
    [ "${#dtbs[@]}" -gt 0 ] || die "No DTBs in the kernel bundle"
    cp -f "${dtbs[@]}" "${BOOT_MNT}/dtb/rockchip/"
    [ -f "${BOOT_MNT}/dtb/rockchip/${KERNEL_DTB}" ] \
        || die "Selected DTB ${KERNEL_DTB} is not in the kernel bundle"

    local module_tmp
    module_tmp="$(mktemp -d "${WORK}/modules.XXXXXX")"
    tar -xzf "${KERNEL_BUNDLE}/${KERNEL_MODULES}" -C "$module_tmp"
    local module_src="${module_tmp}/lib/modules/${KVER}"
    [ -d "$module_src" ] || die "Modules tarball does not contain lib/modules/${KVER}"

    local needed avail
    needed="$(du -sb "$module_src" | awk '{print $1}')"
    avail="$(free_bytes "$ROOT_MNT")"
    if [ "$avail" -lt $((needed + 64 * 1024 * 1024)) ]; then
        die "Not enough space in root filesystem: need $(human_bytes "$needed"), have $(human_bytes "$avail")"
    fi

    rm -rf "${ROOT_MNT}/usr/lib/modules/${KVER}"
    mkdir -p "${ROOT_MNT}/usr/lib/modules"
    cp -a "$module_src" "${ROOT_MNT}/usr/lib/modules/"
    rm -rf "$module_tmp"
    rm -f "${ROOT_MNT}/usr/lib/modules/${KVER}/build" \
          "${ROOT_MNT}/usr/lib/modules/${KVER}/source"

    if ! depmod -b "$ROOT_MNT" "$KVER"; then
        warn "Host depmod failed; retrying inside the target root"
        chroot_run "$ROOT_MNT" "depmod -a '${KVER}'" || die "depmod failed for ${KVER}"
    fi

    if [ "${PRUNE_OLD_KERNEL:-false}" = "true" ]; then
        _prune_old_kernel "$KVER"
    fi
}

_prune_old_kernel() {
    local keep="$1" dir version
    info "Pruning old kernel files"
    for dir in "${ROOT_MNT}"/usr/lib/modules/*; do
        [ -d "$dir" ] || continue
        version="$(basename "$dir")"
        if [ "$version" = "$keep" ]; then
            continue
        fi
        rm -rf "$dir"
    done
    shopt -s nullglob
    local files=("${BOOT_MNT}"/Image-* "${BOOT_MNT}"/vmlinuz-* \
                 "${BOOT_MNT}"/initrd.img-* "${BOOT_MNT}"/uInitrd-* \
                 "${BOOT_MNT}"/config-* "${BOOT_MNT}"/System.map-*)
    shopt -u nullglob
    local file
    for file in "${files[@]}"; do
        case "$file" in
            *"${keep}"*) ;;
            *) rm -f "$file" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Boot configuration / initramfs
# ---------------------------------------------------------------------------

family_configure_boot() {
    local KVER="$KERNEL_VERSION"
    if [ -n "${EXTLINUX_CONF:-}" ]; then
        info "Patching ${EXTLINUX_CONF}"
        python3 -I "${LIB_DIR}/extlinux_patch.py" \
            --file "$EXTLINUX_CONF" \
            --kernel /Image \
            --fdt "/dtb/rockchip/${KERNEL_DTB}" \
            --initrd /uInitrd
    else
        info "No extlinux; boot.scr/uEnv will use ${KERNEL_DTB}"
    fi

    # Update both armbianEnv.txt and uEnv.txt.  The generic replacement
    # covers fdtfile, FDTFILE, or a bare rockchip/... path.
    local env_file
    for env_file in armbianEnv.txt uEnv.txt; do
        [ -f "${BOOT_MNT}/${env_file}" ] || continue
        info "Updating ${env_file} device tree path"
        sed -i -E "s|rockchip/[A-Za-z0-9._+-]+\.dtb|rockchip/${KERNEL_DTB}|g" \
            "${BOOT_MNT}/${env_file}"
        if [ "$env_file" = "armbianEnv.txt" ]; then
            if grep -q '^fdtfile=' "${BOOT_MNT}/${env_file}"; then
                sed -i -E "s|^fdtfile=.*|fdtfile=rockchip/${KERNEL_DTB}|" \
                    "${BOOT_MNT}/${env_file}"
            else
                printf 'fdtfile=rockchip/%s\n' "$KERNEL_DTB" \
                    >>"${BOOT_MNT}/${env_file}"
            fi
        fi
    done

    if [ -z "${EXTLINUX_CONF:-}" ] \
        && [ ! -f "${BOOT_MNT}/boot.scr" ] && [ ! -f "${BOOT_MNT}/boot.cmd" ]; then
        die "No extlinux.conf and no boot.scr on the boot partition"
    fi

    # Keep the Armbian release file consistent for tools that inspect it.
    if [ -f "${ROOT_MNT}/etc/armbian-release" ]; then
        sed -i -E "s|^LINUXFAMILY=.*|LINUXFAMILY=rk3399|" "${ROOT_MNT}/etc/armbian-release" || true
    fi
    info "Boot configuration now uses ${KERNEL_DTB}"
}

family_create_initrd() {
    local KVER="$KERNEL_VERSION"
    local initrd="${BOOT_MNT}/initrd.img-${KVER}"
    local ok="false"

    if [ -x "${ROOT_MNT}/usr/sbin/update-initramfs" ] \
        || [ -x "${ROOT_MNT}/usr/bin/update-initramfs" ]; then
        info "Regenerating initramfs for ${KVER}"
        if chroot_run "$ROOT_MNT" "update-initramfs -c -k '${KVER}'"; then
            ok="true"
        fi
    else
        warn "update-initramfs is not installed in the root filesystem"
    fi

    if [ "$ok" != "true" ] || [ ! -s "$initrd" ]; then
        if [ "${REQUIRE_INITRD_REGEN:-true}" = "true" ]; then
            die "Failed to regenerate initramfs for ${KVER}"
        fi
        warn "Keeping the base image initramfs (initrd regeneration disabled/failed)"
        return 0
    fi

    local compression
    case "$(file -b "$initrd")" in
        *gzip*) compression="gzip" ;;
        *Zstandard*) compression="zstd" ;;
        *XZ*) compression="xz" ;;
        *LZ4*) compression="lz4" ;;
        *) compression="none" ;;
    esac

    require_cmd mkimage
    mkimage -A arm64 -O linux -T ramdisk -C "$compression" -n "uInitrd" \
        -d "$initrd" "${BOOT_MNT}/uInitrd-${KVER}" >/dev/null
    rm -f "${BOOT_MNT}/uInitrd"
    if [ "${BOOT_FS:-}" = "ext4" ] || [ "${BOOT_FS:-}" = "ext3" ]; then
        ln -sfn "uInitrd-${KVER}" "${BOOT_MNT}/uInitrd"
    else
        cp -f "${BOOT_MNT}/uInitrd-${KVER}" "${BOOT_MNT}/uInitrd"
    fi
    info "initramfs ready: $(basename "$initrd") (${compression})"
}

# ---------------------------------------------------------------------------
# System customisation
# ---------------------------------------------------------------------------

family_configure_system() {
    local hostname="${IMAGE_HOSTNAME:-}"
    if [ -n "$hostname" ]; then
        printf '%s\n' "$hostname" >"${ROOT_MNT}/etc/hostname"
        if [ -f "${ROOT_MNT}/etc/hosts" ]; then
            sed -i -E "s|^127\.0\.1\.1[[:space:]].*|127.0.1.1 ${hostname}|" "${ROOT_MNT}/etc/hosts"
            grep -q "^127\.0\.1\.1[[:space:]]" "${ROOT_MNT}/etc/hosts" \
                || printf '127.0.1.1 %s\n' "$hostname" >>"${ROOT_MNT}/etc/hosts"
        fi
    fi

    # Let systemd generate a unique machine id and SSH host keys on first boot.
    if [ -f "${ROOT_MNT}/etc/machine-id" ]; then
        : >"${ROOT_MNT}/etc/machine-id"
    fi
    if [ -f "${ROOT_MNT}/var/lib/dbus/machine-id" ]; then
        : >"${ROOT_MNT}/var/lib/dbus/machine-id"
    fi
    rm -f "${ROOT_MNT}/etc/ssh/ssh_host_"* 2>/dev/null || true

    rm -rf "${ROOT_MNT}/var/cache/apt/archives/"*.deb 2>/dev/null || true
    rm -rf "${ROOT_MNT}/tmp/"* 2>/dev/null || true
}
