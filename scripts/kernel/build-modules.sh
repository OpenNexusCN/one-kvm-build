#!/usr/bin/env bash
# Rebuild kernel modules for an already-published Image.
#
# The released Image was built from a git tag that is not a mainline kernel
# version tag, so setlocalversion appends "+" to the release string.  This
# script recreates the exact KERNELRELEASE deterministically:
#
#   * put the expected suffix in a `localversion` file,
#   * clear CONFIG_LOCALVERSION in the copied .config,
#   * export LOCALVERSION="" so setlocalversion does not add git state.
#
# The resulting vermagic is verified against the released Image name before
# the modules are packaged.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
    cat <<'EOF'
Usage: build-modules.sh --repo-url URL --tag TAG --config FILE \
       --expected-version VER --output-dir DIR [options]

Options:
  --arch ARCH            Kernel arch (default: arm64)
  --cross-compile PREFIX Cross compiler prefix (default: aarch64-linux-gnu-)
  --jobs N               Parallel jobs (default: nproc)
  --keep-source          Keep the cloned kernel source tree
EOF
}

REPO_URL=""
TAG=""
CONFIG_FILE=""
EXPECTED=""
OUT_DIR=""
ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"
JOBS="$(nproc)"
KEEP_SOURCE="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo-url) REPO_URL="${2:?}"; shift 2 ;;
        --tag) TAG="${2:?}"; shift 2 ;;
        --config) CONFIG_FILE="${2:?}"; shift 2 ;;
        --expected-version) EXPECTED="${2:?}"; shift 2 ;;
        --output-dir) OUT_DIR="${2:?}"; shift 2 ;;
        --arch) ARCH="${2:?}"; shift 2 ;;
        --cross-compile) CROSS_COMPILE="${2:?}"; shift 2 ;;
        --jobs) JOBS="${2:?}"; shift 2 ;;
        --keep-source) KEEP_SOURCE="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$REPO_URL" ] || die "--repo-url is required"
[ -n "$TAG" ] || die "--tag is required"
[ -n "$CONFIG_FILE" ] || die "--config is required"
[ -n "$EXPECTED" ] || die "--expected-version is required"
[ -n "$OUT_DIR" ] || die "--output-dir is required"
[ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

require_cmd git make tar find xz

TARBALL="${OUT_DIR}/modules-${EXPECTED}.tar.gz"
if [ -f "$TARBALL" ]; then
    info "Reusing existing ${TARBALL}"
    exit 0
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/one-kvm-modules.XXXXXX")"
KSRC="${WORK_DIR}/linux"
cleanup() {
    if [ "$KEEP_SOURCE" != "true" ]; then
        rm -rf "$WORK_DIR"
    else
        info "Kernel source kept at ${KSRC}"
    fi
}
trap cleanup EXIT

group_start "Clone kernel source ${TAG}"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git clone --depth 1 --branch "$TAG" "$REPO_URL" "$KSRC" \
    || die "Cannot clone ${REPO_URL} at ${TAG}"
group_end

base_version="$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{print v"."p"."s}' "$KSRC/Makefile")"
suffix="${EXPECTED#"$base_version"}"
if [ "$suffix" = "$EXPECTED" ]; then
    die "Expected version ${EXPECTED} does not start with kernel base version ${base_version}"
fi

info "Kernel base ${base_version}, expected release ${EXPECTED}, suffix '${suffix}'"

cp -f "$CONFIG_FILE" "${KSRC}/.config"
sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=""|' "${KSRC}/.config"
sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set|' "${KSRC}/.config"
printf '%s' "$suffix" >"${KSRC}/localversion"

# Remove stale generated config files so olddefconfig definitely rereads .config.
rm -f "${KSRC}/include/config/auto.conf" \
      "${KSRC}/include/config/auto.conf.cmd" \
      "${KSRC}/include/config/kernel.release" \
      "${KSRC}/include/generated/utsrelease.h"

export ARCH="$ARCH"
export CROSS_COMPILE="$CROSS_COMPILE"
export LOCALVERSION=""

make -C "$KSRC" olddefconfig >/dev/null

actual="$(make -s -C "$KSRC" kernelrelease)"
if [ "$actual" != "$EXPECTED" ]; then
    die "Kernel release mismatch after configuration: expected '${EXPECTED}', got '${actual}'"
fi

group_start "Build modules (${JOBS} jobs)"
make -C "$KSRC" -j"$JOBS" modules_prepare

actual="$(make -s -C "$KSRC" kernelrelease)"
if [ "$actual" != "$EXPECTED" ]; then
    die "Kernel release changed during prepare: expected '${EXPECTED}', got '${actual}'"
fi

make -C "$KSRC" -j"$JOBS" modules
group_end

group_start "Install and package modules"
INSTALL_ROOT="${WORK_DIR}/modules-root"
(make -C "$KSRC" INSTALL_MOD_PATH="$INSTALL_ROOT" modules_install)
MODULE_DIR="${INSTALL_ROOT}/lib/modules/${EXPECTED}"
[ -d "$MODULE_DIR" ] || die "modules_install did not create ${MODULE_DIR}"

rm -f "${MODULE_DIR}/build" "${MODULE_DIR}/source"

sample="$(find "$MODULE_DIR" -type f -name '*.ko*' | head -n1)"
[ -n "$sample" ] || die "No kernel modules were built"
vermagic="$(modinfo -F vermagic "$sample" | awk '{print $1}')"
if [ "$vermagic" != "$EXPECTED" ]; then
    die "Module vermagic '${vermagic}' does not match expected '${EXPECTED}'"
fi

tar -C "$INSTALL_ROOT" -czf "$TARBALL" lib/modules
tar -tzf "$TARBALL" | grep -F "lib/modules/${EXPECTED}/" >/dev/null \
    || die "Packaged modules tarball does not contain lib/modules/${EXPECTED}"
info "Modules packaged: ${TARBALL} ($(human_bytes "$(stat -c %s "$TARBALL")"))"
group_end
