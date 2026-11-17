#!/usr/bin/env bash
# Install the One-KVM ISO fix tool into a mounted target root filesystem.
#
# Some repacked Windows ISOs ship an empty ISO9660 shell and keep the real
# files in a UDF partition.  The One-KVM virtual USB CD-ROM does not expose
# UDF to Windows guests, so those images are unreadable there.  The bundled
# tool rewrites them as ISO9660 + Joliet while preserving the El Torito
# entries (BIOS and UEFI).
#
# The apt packages (xorriso, genisoimage, udftools) are installed separately
# by scripts/features/apt-install.sh; this feature installs the script and
# verifies both the packages and the kernel filesystem support.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    cat <<'EOF'
Usage: iso-fix.sh --root DIR [options]

Options:
  --kernel-config FILE      Kernel .config used to check filesystem support
  --require-udf true|false  Fail when UDF images cannot be mounted (default: true)
  --skip-deps-check         Do not verify the support packages inside ROOT
EOF
}

ROOT=""
KERNEL_CONFIG=""
REQUIRE_UDF="true"
SKIP_DEPS="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 ;;
        --kernel-config) KERNEL_CONFIG="${2:-}"; shift 2 ;;
        --require-udf) REQUIRE_UDF="${2:-}"; shift 2 ;;
        --skip-deps-check) SKIP_DEPS="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$ROOT" ] || die "--root is required"
[ -d "$ROOT" ] || die "Root filesystem not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
case "$REQUIRE_UDF" in
    true|false) ;;
    *) die "--require-udf must be true or false" ;;
esac

check_deps() {
    require_cmd dpkg-query
    local pkg status
    for pkg in xorriso genisoimage udftools; do
        status="$(dpkg-query --root="$ROOT" -W -f='${Status}' "$pkg" 2>/dev/null || true)"
        case "$status" in
            *"install ok installed"*) ;;
            *) die "Package ${pkg} is not installed in the target root (required by onekvm-iso-fix)" ;;
        esac
    done
}

# check_kernel_fs <config> <CONFIG_OPTION> <module-relative-path> <label>
# A built-in (=y) option is always available.  For =m the matching module must
# be present in the installed module tree.  Returns 1 when the option cannot
# provide the filesystem.
check_kernel_fs() {
    local cfg="$1" option="$2" module_glob="$3" label="$4"
    local setting found
    [ -f "$cfg" ] || die "Kernel config not found: $cfg"

    setting="$(awk -F= -v opt="$option" '$1 == opt { print $2; exit }' "$cfg")"
    case "${setting:-}" in
        y) return 0 ;;
        m)
            found="$(compgen -G "${ROOT}/usr/lib/modules/${module_glob}" || true)"
            [ -n "$found" ] && return 0
            warn "${option}=m but the ${label} module is missing under ${ROOT}/usr/lib/modules"
            return 1
            ;;
        *)
            warn "${option} is not enabled in ${cfg}"
            return 1
            ;;
    esac
}

check_kernel() {
    local cfg="$1"
    if ! check_kernel_fs "$cfg" CONFIG_UDF_FS '*/kernel/fs/udf/udf.ko*' udf; then
        if [ "$REQUIRE_UDF" = "true" ]; then
            die "Kernel cannot mount UDF; onekvm-iso-fix would not be able to fix UDF-only ISOs"
        fi
        warn "UDF is unavailable; onekvm-iso-fix will only handle images with a complete ISO9660 tree"
    fi
    if ! check_kernel_fs "$cfg" CONFIG_ISO9660_FS '*/kernel/fs/isofs/isofs.ko*' isofs; then
        warn "ISO9660 is unavailable; onekvm-iso-fix cannot mount ISO9660 images"
    fi
}

[ "$SKIP_DEPS" = "true" ] || check_deps

src_script="${REPO_ROOT}/files/iso-fix/onekvm-iso-fix.sh"
src_readme="${REPO_ROOT}/docs/iso-fix/README.md"
[ -f "$src_script" ] || die "Missing ${src_script}"
[ -f "$src_readme" ] || die "Missing ${src_readme}"

install -D -m 755 "$src_script" "${ROOT}/usr/local/sbin/onekvm-iso-fix"
ln -sfn onekvm-iso-fix "${ROOT}/usr/local/sbin/onekvm-iso-fix.sh"
install -D -m 644 "$src_readme" "${ROOT}/usr/share/doc/onekvm-iso-fix/README.md"

if [ -n "$KERNEL_CONFIG" ]; then
    check_kernel "$KERNEL_CONFIG"
fi

info "ISO fix tool installed (onekvm-iso-fix, docs in /usr/share/doc/onekvm-iso-fix)"
