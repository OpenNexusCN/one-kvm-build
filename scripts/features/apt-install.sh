#!/usr/bin/env bash
# Install extra Debian/Ubuntu packages into a mounted target root filesystem.
#
# The package list is provided by the board config (APT_PACKAGES) and the
# workflow_dispatch input (apt_packages).  Installation happens in the
# qemu-user chroot, with policy-rc.d masking service starts.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/chroot.sh
source "${SCRIPT_DIR}/../lib/chroot.sh"

usage() {
    cat <<'EOF'
Usage: apt-install.sh --root DIR [options]

Options:
  --packages "pkg1 pkg2"    Space-separated Debian package names
  --recommends true|false   Install recommended packages (default: false)
EOF
}

ROOT=""
PACKAGES=""
RECOMMENDS="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:-}"; shift 2 ;;
        --packages) PACKAGES="${2:-}"; shift 2 ;;
        --recommends) RECOMMENDS="${2:-false}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$ROOT" ] || die "--root is required"
[ -d "$ROOT" ] || die "Root filesystem not found: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
RECOMMENDS="${RECOMMENDS:-false}"
case "$RECOMMENDS" in true|false) ;; *) die "--recommends must be true or false" ;; esac

packages=()
PACKAGES="${PACKAGES//$'\n'/ }"
PACKAGES="${PACKAGES//$'\t'/ }"
read -r -a raw_packages <<<"$PACKAGES"
for pkg in "${raw_packages[@]}"; do
    [ -n "$pkg" ] || continue
    [[ "$pkg" =~ ^[A-Za-z0-9][A-Za-z0-9+.-]*$ ]] \
        || die "Invalid apt package name: ${pkg}"
    packages+=("$pkg")
done

if [ "${#packages[@]}" -eq 0 ]; then
    info "No extra apt packages requested"
    exit 0
fi

require_cmd dpkg-query

install_script="${ROOT}/tmp/onekvm-apt-install.sh"
policy="${ROOT}/usr/sbin/policy-rc.d"
policy_backup=""

if [ -f "$policy" ]; then
    policy_backup="$(mktemp)"
    cp -f "$policy" "$policy_backup"
fi

cleanup() {
    rm -f "$install_script"
    if [ -n "$policy_backup" ]; then
        cp -f "$policy_backup" "$policy"
        rm -f "$policy_backup"
    else
        rm -f "$policy"
    fi
}
trap cleanup EXIT

printf '#!/bin/sh\nexit 101\n' >"$policy"
chmod 755 "$policy"

{
    echo '#!/bin/bash'
    echo 'set -e'
    echo 'export DEBIAN_FRONTEND=noninteractive'
    echo 'apt-get update'
    printf 'apt-get install -y'
    if [ "$RECOMMENDS" != "true" ]; then
        printf ' --no-install-recommends'
    fi
    printf ' %q' "${packages[@]}"
    printf '\n'
    echo 'apt-get clean'
} >"$install_script"
chmod 755 "$install_script"

group_start "Install apt packages: ${packages[*]}"
chroot_run "$ROOT" /tmp/onekvm-apt-install.sh
group_end

for pkg in "${packages[@]}"; do
    status="$(dpkg-query --root="$ROOT" -W -f='${Status}' "$pkg" 2>/dev/null || true)"
    case "$status" in
        *"install ok installed"*) ;;
        *) die "Package ${pkg} is not installed after apt-get" ;;
    esac
done

info "Installed apt packages: ${packages[*]}"
