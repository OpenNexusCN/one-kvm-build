#!/usr/bin/env bash
# Resolve the One-KVM arm64 .deb from a GitHub release.
#
# Outputs JSON on stdout and optionally writes GitHub Actions outputs:
#   one_kvm_tag, one_kvm_version, one_kvm_deb_name, one_kvm_deb_url,
#   one_kvm_deb_sha256
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/github.sh
source "${SCRIPT_DIR}/../lib/github.sh"

usage() {
    cat <<'EOF'
Usage: resolve-one-kvm.sh [options]

Options:
  --repo OWNER/REPO        Default: mofeng-git/One-KVM
  --release TAG|latest     Default: latest
  --asset-pattern GLOB     Default: one-kvm_*_arm64.deb
  --min-version VERSION    Ignore releases older than this (e.g. 0.2.9)
  --wait-seconds N         Poll for a matching release (0 = single attempt)
  --github-output          Write outputs to $GITHUB_OUTPUT
EOF
}

REPO="mofeng-git/One-KVM"
RELEASE="latest"
ASSET_PATTERN="one-kvm_*_arm64.deb"
MIN_VERSION=""
WAIT_SECONDS="0"
GITHUB_OUTPUT_MODE="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:-}"; shift 2 ;;
        --release) RELEASE="${2:-}"; shift 2 ;;
        --asset-pattern) ASSET_PATTERN="${2:-}"; shift 2 ;;
        --min-version) MIN_VERSION="${2:-}"; shift 2 ;;
        --wait-seconds) WAIT_SECONDS="${2:-}"; shift 2 ;;
        --github-output) GITHUB_OUTPUT_MODE="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

require_cmd jq python3
REPO="${REPO:-mofeng-git/One-KVM}"
RELEASE="${RELEASE:-latest}"
ASSET_PATTERN="${ASSET_PATTERN:-one-kvm_*_arm64.deb}"
WAIT_SECONDS="${WAIT_SECONDS:-0}"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "--wait-seconds must be an integer"

version_too_old() {
    local version="$1"
    [ -n "$MIN_VERSION" ] || return 1
    # sort -V puts the lower version first.
    [ "$(printf '%s\n%s\n' "$MIN_VERSION" "$version" | sort -V | head -n1)" != "$MIN_VERSION" ]
}

deadline=$((SECONDS + WAIT_SECONDS))
release_json=""
tag=""
asset_json=""
name=""
version=""

while :; do
    if release_json="$(resolve_release "$REPO" "$RELEASE" "*" "$ASSET_PATTERN" 2>/dev/null)"; then
        tag="$(printf '%s' "$release_json" | jq -r '.tag_name')"
        asset_json="$(select_asset "$release_json" "$ASSET_PATTERN")"
        name="$(asset_field "$asset_json" name)"
        if [[ "$name" =~ ^one-kvm_(.+)_arm64\.deb$ ]]; then
            version="${BASH_REMATCH[1]}"
            if ! version_too_old "$version"; then
                break
            fi
            warn "Release ${tag} provides ${version}, older than ${MIN_VERSION}; waiting"
        else
            warn "Unexpected One-KVM asset name: ${name}; waiting"
        fi
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
        die "No ${REPO} release (${RELEASE}) with ${ASSET_PATTERN} >= ${MIN_VERSION:-any}"
    fi
    info "Waiting for ${REPO} release with ${ASSET_PATTERN} ..."
    sleep 30
done

url="$(asset_field "$asset_json" browser_download_url)"
digest="$(asset_field "$asset_json" digest)"
digest="${digest#sha256:}"

result="$(jq -n \
    --arg tag "$tag" \
    --arg version "$version" \
    --arg name "$name" \
    --arg url "$url" \
    --arg sha256 "$digest" \
    '{tag: $tag, version: $version, asset: $name, url: $url, sha256: $sha256}')"

if [ "$GITHUB_OUTPUT_MODE" = "true" ]; then
    set_output one_kvm_tag "$tag"
    set_output one_kvm_version "$version"
    set_output one_kvm_deb_name "$name"
    set_output one_kvm_deb_url "$url"
    set_output one_kvm_deb_sha256 "$digest"
fi

printf '%s\n' "$result"
