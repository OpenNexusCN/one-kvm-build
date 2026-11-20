#!/usr/bin/env bash
# Validate board configuration files.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DEFAULTS="${REPO_ROOT}/config/defaults.conf"
BOARDS_DIR="${REPO_ROOT}/boards"

errors=0
declare -A seen=()

err() {
    printf 'ERROR: %s\n' "$*" >&2
    errors=$((errors + 1))
}

shopt -s nullglob
files=("${BOARDS_DIR}"/*.conf)
shopt -u nullglob
[ "${#files[@]}" -gt 0 ] || die "No board configs found in ${BOARDS_DIR}"

for config in "${files[@]}"; do
    base="$(basename "$config" .conf)"
    printf 'Checking %s ...\n' "$config"

    if ! bash -n "$config"; then
        err "${config}: shell syntax error"
        continue
    fi

    meta="$(
        # shellcheck disable=SC1090
        source "$DEFAULTS"
        # shellcheck disable=SC1090
        source "$config"
        jq -nc \
            --arg id "${BOARD_ID:-}" \
            --arg name "${BOARD_NAME:-}" \
            --arg family "${SOC_FAMILY:-}" \
            --arg base_repo "${BASE_IMAGE_REPO:-}" \
            --arg base_release "${BASE_IMAGE_RELEASE:-}" \
            --arg base_pattern "${BASE_IMAGE_ASSET_PATTERN:-}" \
            --arg base_url "${BASE_IMAGE_URL:-}" \
            --arg dtb "${KERNEL_DTB:-}" \
            --arg dtb_from_base "${KERNEL_DTB_FROM_BASE_IMAGE:-false}" \
            --arg android_enabled "${ANDROID_TOOLS_ENABLED:-true}" \
            --arg scrcpy_mode "${ANDROID_SCRCPY_MODE:-prebuilt}" \
            --arg scrcpy_suite "${ANDROID_SCRCPY_APT_SUITE:-}" \
            --arg scrcpy_server_version "${ANDROID_SCRCPY_SERVER_VERSION:-}" \
            --arg onekvm "${ONE_KVM_ENABLED:-true}" \
            --arg onekvm_pattern "${ONE_KVM_ASSET_PATTERN:-}" \
            '{id: $id, name: $name, family: $family, base_repo: $base_repo,
              base_release: $base_release, base_pattern: $base_pattern,
              base_url: $base_url, dtb: $dtb,
              dtb_from_base: $dtb_from_base,
              android_enabled: $android_enabled,
              scrcpy_mode: $scrcpy_mode, scrcpy_suite: $scrcpy_suite,
              scrcpy_server_version: $scrcpy_server_version,
              onekvm: $onekvm, onekvm_pattern: $onekvm_pattern}'
    )" || { err "${config}: cannot be sourced"; continue; }

    id="$(printf '%s' "$meta" | jq -r '.id')"
    name="$(printf '%s' "$meta" | jq -r '.name')"
    family="$(printf '%s' "$meta" | jq -r '.family')"
    base_repo="$(printf '%s' "$meta" | jq -r '.base_repo')"
    base_release="$(printf '%s' "$meta" | jq -r '.base_release')"
    base_pattern="$(printf '%s' "$meta" | jq -r '.base_pattern')"
    base_url="$(printf '%s' "$meta" | jq -r '.base_url')"
    dtb="$(printf '%s' "$meta" | jq -r '.dtb')"
    dtb_from_base="$(printf '%s' "$meta" | jq -r '.dtb_from_base')"
    android_enabled="$(printf '%s' "$meta" | jq -r '.android_enabled')"
    scrcpy_mode="$(printf '%s' "$meta" | jq -r '.scrcpy_mode')"
    scrcpy_suite="$(printf '%s' "$meta" | jq -r '.scrcpy_suite')"
    scrcpy_server_version="$(printf '%s' "$meta" | jq -r '.scrcpy_server_version')"
    onekvm="$(printf '%s' "$meta" | jq -r '.onekvm')"
    onekvm_pattern="$(printf '%s' "$meta" | jq -r '.onekvm_pattern')"

    [ -n "$id" ] || err "${config}: BOARD_ID is empty"
    [ "$id" = "$base" ] || err "${config}: BOARD_ID '${id}' must match file name '${base}'"
    [ -n "$name" ] || err "${config}: BOARD_NAME is empty"
    [ -n "$family" ] || err "${config}: SOC_FAMILY is empty"
    [ -f "${REPO_ROOT}/scripts/families/${family}.sh" ] \
        || err "${config}: no family hook scripts/families/${family}.sh"
    if [ -z "$base_url" ]; then
        [ -n "$base_repo" ] || err "${config}: BASE_IMAGE_REPO is empty and BASE_IMAGE_URL is not set"
        [ -n "$base_pattern" ] || err "${config}: BASE_IMAGE_ASSET_PATTERN is empty"
    fi
    [[ "$dtb" == *.dtb ]] || err "${config}: KERNEL_DTB must name a .dtb file"
    case "$dtb_from_base" in
        true|false) ;;
        *) err "${config}: KERNEL_DTB_FROM_BASE_IMAGE must be true or false" ;;
    esac
    case "$scrcpy_mode" in
        prebuilt|distro) ;;
        *) err "${config}: ANDROID_SCRCPY_MODE must be prebuilt or distro" ;;
    esac
    if [ -n "$scrcpy_suite" ]; then
        [[ "$scrcpy_suite" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
            || err "${config}: ANDROID_SCRCPY_APT_SUITE is not a valid apt suite"
    fi
    if [ -n "$scrcpy_server_version" ]; then
        [[ "$scrcpy_server_version" =~ ^[0-9A-Za-z][0-9A-Za-z.+~-]*$ ]] \
            || err "${config}: ANDROID_SCRCPY_SERVER_VERSION is not a valid version string"
    fi

    # The prebuilt client is built against noble's FFmpeg 6; trixie needs
    # the distribution scrcpy package (FFmpeg 7).  Keep the mode tied to
    # the base image codename so a new board cannot silently mismatch.
    codename=""
    case "$base_release $base_pattern" in
        *trixie*) codename="trixie" ;;
        *noble*) codename="noble" ;;
    esac
    if [ "$android_enabled" = "true" ] && [ -n "$codename" ]; then
        case "${codename}:${scrcpy_mode}" in
            trixie:prebuilt)
                err "${config}: trixie base image must use ANDROID_SCRCPY_MODE=distro (prebuilt links FFmpeg 6)" ;;
            noble:distro)
                err "${config}: noble base image should use ANDROID_SCRCPY_MODE=prebuilt (distro 1.25 crashes on Android 14+)" ;;
        esac
        if [ "$scrcpy_mode" = "distro" ] && [ -z "$scrcpy_suite" ]; then
            err "${config}: distro scrcpy requires ANDROID_SCRCPY_APT_SUITE (e.g. trixie-backports)"
        fi
    fi
    if [ "$onekvm" = "true" ]; then
        [ -n "$onekvm_pattern" ] || err "${config}: ONE_KVM_ASSET_PATTERN is empty"
    fi

    if [ -n "${seen[$id]:-}" ]; then
        err "Duplicate BOARD_ID '${id}' in ${config} and ${seen[$id]}"
    else
        seen[$id]="$config"
    fi
done

if [ "$errors" -ne 0 ]; then
    die "Board validation failed with ${errors} error(s)"
fi
info "Board configuration OK (${#files[@]} board(s))"
