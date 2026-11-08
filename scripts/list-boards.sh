#!/usr/bin/env bash
# Print a short board inventory.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DEFAULTS="${REPO_ROOT}/config/defaults.conf"
BOARDS_DIR="${REPO_ROOT}/boards"

printf '%-16s %-8s %-10s %-28s %s\n' "BOARD" "ENABLED" "SOC" "DTB" "NAME"
shopt -s nullglob
for config in "${BOARDS_DIR}"/*.conf; do
    (
        # shellcheck disable=SC1090
        source "$DEFAULTS"
        # shellcheck disable=SC1090
        source "$config"
        printf '%-16s %-8s %-10s %-28s %s\n' \
            "${BOARD_ID:-?}" "${ENABLED:-true}" "${SOC:-?}" \
            "${KERNEL_DTB:-?}" "${BOARD_NAME:-}"
    )
done
