#!/usr/bin/env bash
# Install the One-KVM arm64 .deb into a mounted aarch64 root filesystem.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/chroot.sh
source "${SCRIPT_DIR}/../lib/chroot.sh"

usage() {
    cat <<'EOF'
Usage: install-one-kvm.sh --root DIR (--deb FILE | --url URL) [options]

Options:
  --enabled true|false     Skip installation when false (default: true)
  --version VERSION        Expected package version (recorded)
  --sha256 SHA256          Verify the deb before installing
  --kernel-version VER     Kernel release for module sanity checks
EOF
}

ROOT=""
DEB=""
URL=""
SHA256=""
VERSION=""
KERNEL_VERSION=""
ENABLED="true"

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 ;;
        --deb) DEB="${2:-}"; shift 2 ;;
        --url) URL="${2:-}"; shift 2 ;;
        --sha256) SHA256="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --kernel-version) KERNEL_VERSION="${2:-}"; shift 2 ;;
        --enabled) ENABLED="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

if [ "$ENABLED" != "true" ]; then
    info "One-KVM installation disabled for this build"
    exit 0
fi

[ -n "$ROOT" ] || die "--root is required"
[ -d "$ROOT" ] || die "Root filesystem not found: $ROOT"
[ -n "$DEB" ] || [ -n "$URL" ] || die "Provide --deb or --url"
ENABLED="${ENABLED:-true}"

require_cmd curl sha256sum mktemp

host_deb=""
cleanup_deb() {
    if [ -n "$host_deb" ]; then
        rm -f "$host_deb"
    fi
}
trap cleanup_deb EXIT

mkdir -p "$ROOT/tmp"
if [ -n "$URL" ]; then
    host_deb="$(mktemp "${TMPDIR:-/tmp}/one-kvm.XXXXXX.deb")"
    DEB="$host_deb"
    info "Downloading One-KVM package ${URL}"
    retry 5 curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
        -o "$DEB" "$URL" \
        || die "Failed to download One-KVM package"
fi
[ -f "$DEB" ] || die "One-KVM package not found: $DEB"
verify_sha256 "$DEB" "$SHA256"

dest_deb="${ROOT}/tmp/one-kvm.deb"
if [ "$(readlink -f "$DEB")" != "$(readlink -f "$dest_deb")" ]; then
    cp -f "$DEB" "$dest_deb"
fi
cat >"${ROOT}/tmp/one-kvm-install.sh" <<'INSTALL_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
if ! dpkg -i /tmp/one-kvm.deb; then
    echo "dpkg reported missing dependencies; resolving with apt" >&2
    apt-get update
    apt-get -y --no-install-recommends -f install
    dpkg -i /tmp/one-kvm.deb
fi
dpkg --configure -a
dpkg -s one-kvm >/dev/null
INSTALL_EOF
chmod 755 "${ROOT}/tmp/one-kvm-install.sh"

group_start "Install One-KVM package"
chroot_run "$ROOT" /tmp/one-kvm-install.sh
group_end

rm -f "${ROOT}/tmp/one-kvm.deb" "${ROOT}/tmp/one-kvm-install.sh"

# The deb enables the unit only when systemd is running.  A chroot is not a
# running systemd, so create the enablement symlink explicitly.
if [ -f "${ROOT}/lib/systemd/system/one-kvm.service" ]; then
    unit="/lib/systemd/system/one-kvm.service"
elif [ -f "${ROOT}/usr/lib/systemd/system/one-kvm.service" ]; then
    unit="/usr/lib/systemd/system/one-kvm.service"
else
    die "One-KVM deb did not install a systemd unit"
fi
mkdir -p "${ROOT}/etc/systemd/system/multi-user.target.wants"
ln -sfn "$unit" "${ROOT}/etc/systemd/system/multi-user.target.wants/one-kvm.service"
mkdir -p "${ROOT}/var/lib/one-kvm/ventoy" "${ROOT}/var/log/one-kvm"

[ -x "${ROOT}/usr/bin/one-kvm" ] || die "One-KVM binary is missing after installation"

if [ -n "$KERNEL_VERSION" ]; then
    module_root="${ROOT}/usr/lib/modules/${KERNEL_VERSION}"
    for module in configfs libcomposite usb_f_hid usb_f_uvc usb_f_mass_storage; do
        if ! find "$module_root" -type f -name "${module}.ko*" -print -quit 2>/dev/null | grep -q .; then
            warn "Kernel module ${module} not found (may be built into the kernel)"
        fi
    done
fi

info "One-KVM ${VERSION:-package} installed and enabled"
