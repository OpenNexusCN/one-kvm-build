#!/usr/bin/env bash
# Decompile the NanoPC-T4 DTB, add the OTG peripheral configuration, and
# recompile it.
#
# One-KVM needs a USB peripheral UDC that can expose HID (virtual keyboard
# and mouse), mass storage (virtual CD-ROM / disk) and UVC (video).  The
# stock rk3399-nanopc-t4.dtb has dr_mode="otg" but no role-switch wiring, so
# on 6.18 no UDC is registered.  The stock "peripheral" dr_mode is also not
# usable: the RK3399 PHY then forces its GRF IDDIG override, which breaks
# the D+ pull-up.  The fragment keeps dr_mode="otg" and defaults the dwc3
# role switch to peripheral, with a sink-only usb-c-connector under the
# FUSB302 so TCPM presents Rd on CC.
set -Eeuo pipefail

ROOT="${ROOT:?ROOT is not set}"
BOOT="${BOOT:?BOOT is not set}"
KVER="${KVER:?KVER is not set}"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="${HOOK_DIR}/../dts/otg-fragment.dtsi"
DTB="${BOOT}/dtb/rockchip/rk3399-nanopc-t4.dtb"
KCONFIG="${BOOT}/config-${KVER}"

[ -f "$DTB" ] || { echo "ERROR: missing device tree ${DTB}" >&2; exit 1; }
[ -f "$FRAGMENT" ] || { echo "ERROR: missing DTS fragment ${FRAGMENT}" >&2; exit 1; }
[ -f "$KCONFIG" ] || { echo "ERROR: missing kernel config ${KCONFIG}" >&2; exit 1; }
command -v dtc >/dev/null 2>&1 \
    || { echo "ERROR: dtc is required (install device-tree-compiler)" >&2; exit 1; }
command -v fdtget >/dev/null 2>&1 \
    || { echo "ERROR: fdtget is required (install device-tree-compiler)" >&2; exit 1; }

# The kernel must really provide the gadget functions this board relies on:
# virtual CD-ROM, keyboard/mouse and (for One-KVM video) UVC.
module_present() {
    local name="$1"
    find "${ROOT}/usr/lib/modules/${KVER}" -type f \
        \( -name "${name}.ko" -o -name "${name}.ko.xz" \
           -o -name "${name}.ko.zst" -o -name "${name}.ko.gz" \) \
        -print -quit 2>/dev/null | grep -q .
}

require_gadget() {
    local sym="$1" module="$2" line
    line="$(grep -E "^${sym}=" "$KCONFIG" || true)"
    case "$line" in
        *"=y")
            return 0
            ;;
        *"=m")
            module_present "$module" \
                || { echo "ERROR: ${sym}=m but ${module}.ko is missing from /usr/lib/modules/${KVER}" >&2; exit 1; }
            ;;
        *)
            echo "ERROR: ${sym} is not enabled (${line:-unset}); One-KVM cannot expose the gadget" >&2
            exit 1
            ;;
    esac
}

require_gadget CONFIG_USB_GADGET udc-core
require_gadget CONFIG_CONFIGFS_FS configfs
require_gadget CONFIG_USB_CONFIGFS libcomposite
require_gadget CONFIG_USB_LIBCOMPOSITE libcomposite
require_gadget CONFIG_USB_F_HID usb_f_hid
require_gadget CONFIG_USB_F_MASS_STORAGE usb_f_mass_storage
require_gadget CONFIG_USB_F_UVC usb_f_uvc

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 1. Decompile the base-image DTB to DTS.
dtc -q -I dtb -O dts -o "${tmpdir}/base.dts" "$DTB"

# 2. Append the OTG fragment.  It targets nodes by path (&{/...}), so the
#    decompiled tree does not need labels.
cp "${tmpdir}/base.dts" "${tmpdir}/patched.dts"
{ echo; cat "$FRAGMENT"; } >>"${tmpdir}/patched.dts"

# 3. Recompile and verify the result before replacing the boot DTB.
dtc -q -I dts -O dtb -o "${tmpdir}/patched.dtb" "${tmpdir}/patched.dts"

dwc="/usb@fe800000/usb@fe800000"
conn="/i2c@ff3d0000/typec-portc@22/connector"
dtb="${tmpdir}/patched.dtb"
[ "$(fdtget -t s "$dtb" "$dwc" dr_mode)" = "otg" ] \
    || { echo "ERROR: patched DTB dr_mode is not otg" >&2; exit 1; }
fdtget "$dtb" "$dwc" usb-role-switch >/dev/null \
    || { echo "ERROR: patched DTB has no dwc3 usb-role-switch" >&2; exit 1; }
[ "$(fdtget -t s "$dtb" "$dwc" role-switch-default-mode)" = "peripheral" ] \
    || { echo "ERROR: patched DTB role-switch-default-mode is not peripheral" >&2; exit 1; }
[ "$(fdtget -t s "$dtb" "$conn" data-role)" = "device" ] \
    || { echo "ERROR: patched DTB connector data-role is not device" >&2; exit 1; }
[ "$(fdtget -t s "$dtb" "$conn" power-role)" = "sink" ] \
    || { echo "ERROR: patched DTB connector power-role is not sink" >&2; exit 1; }
fdtget "$dtb" "$conn" usb-role-switch >/dev/null \
    || { echo "ERROR: patched DTB connector has no usb-role-switch" >&2; exit 1; }

cp -f "$dtb" "$DTB"

echo "Patched ${DTB}: dwc3_0 -> peripheral UDC (HID/MSD/UVC) for ${KVER}"
