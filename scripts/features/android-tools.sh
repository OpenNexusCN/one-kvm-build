#!/usr/bin/env bash
# Install adb + scrcpy support into a mounted target root filesystem.
#
# Two scrcpy sources are supported:
#   prebuilt - the client from 3rd/scrcpy-3.3-aarch64 (built against noble's
#              FFmpeg 6 ABI), installed to /usr/local/bin.
#   distro   - the distribution scrcpy package, used on Debian trixie where
#              FFmpeg 7 is not ABI-compatible with the prebuilt client
#              (trixie-backports provides scrcpy 3.3.4).
#
# The distro scrcpy 1.25 on noble crashes against Android 14+, which is why
# noble boards use the prebuilt client.  adb, ffmpeg and the runtime
# libraries are installed separately by scripts/features/apt-install.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    cat <<'EOF'
Usage: android-tools.sh --root DIR [options]

Options:
  --mode prebuilt|distro   scrcpy source (default: prebuilt)
  --source DIR             Prebuilt scrcpy tree (prebuilt mode)
  --min-version VERSION    Minimum scrcpy version (distro mode, default: 3.3)
  --server-version VERSION One-KVM scrcpy-server version (default: auto)
  --skip-deps-check        Do not verify packages/libraries inside ROOT
EOF
}

ROOT=""
SOURCE=""
MODE="prebuilt"
MIN_VERSION="3.3"
SERVER_VERSION=""
SKIP_DEPS="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --source) SOURCE="${2:-}"; shift 2 ;;
        --min-version) MIN_VERSION="${2:-}"; shift 2 ;;
        --server-version) SERVER_VERSION="${2:-}"; shift 2 ;;
        --skip-deps-check) SKIP_DEPS="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$ROOT" ] || die "--root is required"
[ -d "$ROOT" ] || die "Root filesystem not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
case "$MODE" in
    prebuilt|distro) ;;
    *) die "--mode must be prebuilt or distro" ;;
esac

check_packages() {
    require_cmd dpkg-query
    local pkg status
    for pkg in "$@"; do
        status="$(dpkg-query --root="$ROOT" -W -f='${Status}' "$pkg" 2>/dev/null || true)"
        case "$status" in
            *"install ok installed"*) ;;
            *) die "Package ${pkg} is not installed in the target root" ;;
        esac
    done
}

# SONAMEs of the prebuilt client, as reported by `readelf -d`.  A base image
# with a newer FFmpeg/SDL2 would otherwise install fine and fail only at
# runtime on the device.
check_runtime_libs() {
    local lib found
    for lib in libavformat.so.60 libavcodec.so.60 libavutil.so.58 \
               libswresample.so.4 libSDL2-2.0.so.0 libavdevice.so.60 \
               libusb-1.0.so.0; do
        found="$(find "$ROOT/usr/lib" "$ROOT/lib" -maxdepth 3 \
            -name "${lib}*" -print -quit 2>/dev/null || true)"
        [ -n "$found" ] || die "Missing runtime library ${lib} for the prebuilt scrcpy"
    done
}

# One-KVM launches the scrcpy server with ONE_KVM_SCRCPY_SERVER_VERSION
# (default 3.3).  The trixie package is 3.3.4, so without a drop-in the
# server aborts with "server version (3.3.4) does not match the client
# (3.3)".  Write the matching version into the image at build time.
write_onekvm_dropin() {
    local version="$1"
    [ -n "$version" ] || return 0
    local dir="${ROOT}/etc/systemd/system/one-kvm.service.d"
    mkdir -p "$dir"
    cat >"${dir}/scrcpy-version.conf" <<EOF
[Service]
Environment=ONE_KVM_SCRCPY_SERVER_VERSION=${version}
EOF
    chmod 0644 "${dir}/scrcpy-version.conf"
    info "One-KVM scrcpy server version: ${version}"
}

if [ "$MODE" = "distro" ]; then
    ver=""
    if [ "$SKIP_DEPS" != "true" ]; then
        check_packages adb ffmpeg scrcpy
        ver="$(dpkg-query --root="$ROOT" -W -f='${Version}' scrcpy 2>/dev/null || true)"
        [ -n "$ver" ] || die "scrcpy package is not installed in the target root"
        if [ -n "$MIN_VERSION" ] \
            && ! dpkg --compare-versions "$ver" ge "$MIN_VERSION"; then
            die "scrcpy ${ver} is older than ${MIN_VERSION}"
        fi
    fi
    server_version="$SERVER_VERSION"
    if [ -z "$server_version" ] && [ -n "$ver" ]; then
        # Strip the Debian revision: 3.3.4-1~bpo13+1 -> 3.3.4.
        server_version="${ver%%-*}"
    fi
    write_onekvm_dropin "$server_version"
    info "Using distribution scrcpy package (${ver:-unknown}); no prebuilt client installed"
    exit 0
fi

SOURCE="${SOURCE:-${REPO_ROOT}/3rd/scrcpy-3.3-aarch64}"
[ -d "$SOURCE" ] || die "scrcpy source directory not found: $SOURCE"
SOURCE="$(cd "$SOURCE" && pwd)"

require_cmd file sha256sum

for name in SHA256SUMS scrcpy scrcpy-server; do
    [ -f "${SOURCE}/${name}" ] || die "Missing ${SOURCE}/${name}"
done

# The bitstream comes from the repository, but verify it anyway so a bad
# copy or a partial checkout cannot silently ship a broken client.
( cd "$SOURCE" && sha256sum -c --strict SHA256SUMS >/dev/null ) \
    || die "scrcpy checksums do not match ${SOURCE}/SHA256SUMS"

arch="$(file -b "${SOURCE}/scrcpy")"
case "$arch" in
    *aarch64*) ;;
    *) die "scrcpy is not an aarch64 binary: ${arch}" ;;
esac

if [ "$SKIP_DEPS" != "true" ]; then
    check_packages adb ffmpeg
    check_runtime_libs
fi

install -D -m 0755 "${SOURCE}/scrcpy" "${ROOT}/usr/local/bin/scrcpy"
install -D -m 0644 "${SOURCE}/scrcpy-server" \
    "${ROOT}/usr/local/share/scrcpy/scrcpy-server"
write_onekvm_dropin "${SERVER_VERSION:-3.3}"

info "scrcpy 3.3 installed (client /usr/local/bin/scrcpy, server /usr/local/share/scrcpy/scrcpy-server)"
