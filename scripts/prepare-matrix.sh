#!/usr/bin/env bash
# Build the GitHub Actions matrix from boards/*.conf.
#
# Output: a JSON array of {board, name, config}.  This script does not touch
# the network; plan-build.sh enriches the entries with resolved image URLs.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

BOARDS_ARG="all"
OUTPUT_FILE=""
GITHUB_OUTPUT_MODE="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --boards) BOARDS_ARG="${2:?}"; shift 2 ;;
        --output) OUTPUT_FILE="${2:?}"; shift 2 ;;
        --github-output) GITHUB_OUTPUT_MODE="true"; shift ;;
        -h|--help)
            echo "Usage: prepare-matrix.sh [--boards all|id1,id2] [--output FILE] [--github-output]"
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

DEFAULTS="${REPO_ROOT}/config/defaults.conf"
BOARDS_DIR="${REPO_ROOT}/boards"

board_meta() {
    local config="$1"
    (
        # shellcheck disable=SC1090
        source "$DEFAULTS"
        # shellcheck disable=SC1090
        source "$config"
        jq -nc \
            --arg board "${BOARD_ID:-}" \
            --arg name "${BOARD_NAME:-}" \
            --arg config "boards/$(basename "$config")" \
            --arg enabled "${ENABLED:-true}" \
            '{board: $board, name: $name, config: $config, enabled: $enabled}'
    )
}

entries=()

if [ "$BOARDS_ARG" = "all" ]; then
    shopt -s nullglob
    files=("${BOARDS_DIR}"/*.conf)
    shopt -u nullglob
    [ "${#files[@]}" -gt 0 ] || die "No board configs found in ${BOARDS_DIR}"
    for config in "${files[@]}"; do
        meta="$(board_meta "$config")"
        [ "$(printf '%s' "$meta" | jq -r '.enabled')" = "true" ] || continue
        entries+=("$meta")
    done
else
    IFS=',' read -r -a requested <<<"$BOARDS_ARG"
    for id in "${requested[@]}"; do
        id="${id//[[:space:]]/}"
        [ -n "$id" ] || continue
        [[ "$id" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid board id: ${id}"
        config="${BOARDS_DIR}/${id}.conf"
        [ -f "$config" ] || die "Unknown board '${id}' (missing ${config})"
        meta="$(board_meta "$config")"
        [ "$(printf '%s' "$meta" | jq -r '.enabled')" = "true" ] \
            || die "Board '${id}' is disabled (ENABLED=false)"
        entries+=("$meta")
    done
fi

[ "${#entries[@]}" -gt 0 ] || die "No enabled boards selected"

matrix="$(printf '%s\n' "${entries[@]}" | jq -c -s '.')"
matrix="$(printf '%s' "$matrix" | jq -c 'map(del(.enabled))')"

if [ -n "$OUTPUT_FILE" ]; then
    printf '%s\n' "$matrix" >"$OUTPUT_FILE"
fi
if [ "$GITHUB_OUTPUT_MODE" = "true" ]; then
    set_output matrix "$matrix"
fi
printf '%s\n' "$matrix"
