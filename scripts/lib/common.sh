#!/usr/bin/env bash
# Shared shell helpers.
#
# This file is sourced by every entry script.  Entry scripts are responsible
# for `set -Eeuo pipefail`; this file only defines functions.

# Directory of the repository (two levels up from scripts/lib).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC2034  # consumed by the sourcing scripts
LIB_DIR="${REPO_ROOT}/scripts/lib"

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }

die() {
    log "ERROR $*"
    exit 1
}

section() {
    printf '\n==> %s\n' "$*" >&2
}

group_start() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::group::%s\n' "$*"
    else
        section "$*"
    fi
}

group_end() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::endgroup::\n'
    fi
}

require_cmd() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This step needs root (loop devices and mounts). Re-run with: sudo -E $0 $*"
    fi
}

# Run a command as root when the script itself is not root.  The image build
# scripts require root and call require_root, but helpers such as cleanup may
# be invoked from contexts where escalation is convenient.
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -- "$@"
    fi
}

ensure_dir() {
    mkdir -p "$1"
}

retry() {
    local attempts="$1"
    shift
    local i
    for i in $(seq 1 "$attempts"); do
        if "$@"; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            warn "Command failed (attempt ${i}/${attempts}), retrying in $((i * 5))s: $*"
            sleep $((i * 5))
        fi
    done
    return 1
}

sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
    local file="$1" expected="$2" actual
    [ -n "$expected" ] || return 0
    [ -f "$file" ] || die "Cannot verify missing file: $file"
    actual="$(sha256_of "$file")"
    if [ "$actual" != "$expected" ]; then
        die "SHA256 mismatch for $file: expected $expected, got $actual"
    fi
    info "SHA256 OK: $(basename "$file")"
}

free_bytes() {
    df -B1 --output=avail "$1" | tail -n 1 | tr -d ' '
}

human_bytes() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"
}

# Write a GitHub Actions output.  Falls back to stdout for local runs.
set_output() {
    local name="$1" value="$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        {
            printf '%s<<__EOF__\n' "$name"
            printf '%s\n' "$value"
            printf '__EOF__\n'
        } >>"$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$name" "$value"
    fi
}

# Quote a value for safe inclusion in a generated shell env file.
shell_quote() {
    printf '%q' "$1"
}

write_env_var() {
    local file="$1" name="$2" value="$3"
    printf '%s=%s\n' "$name" "$(shell_quote "$value")" >>"$file"
}

# Return the <file> part of a `<sha256>  <file>` checksum line.
checksum_file_name() {
    awk '{ $1=""; sub(/^[[:space:]]+/, ""); print }' "$1"
}

timestamp_version() {
    TZ=Asia/Shanghai date +V%Y%m%d%H%M%S
}

utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Populate a variable from a shell-style config file without leaking the
# caller's existing value.  Usage: load_config <file> <var>
config_value() {
    local file="$1" var="$2"
    (
        # shellcheck disable=SC1090
        source "$file"
        printf '%s' "${!var:-}"
    )
}
