#!/usr/bin/env bash
# Resolve every external input once and emit the GitHub Actions build plan.
#
# Outputs (to $GITHUB_OUTPUT when running in Actions):
#   matrix, version, kernel_tag, one_kvm_tag, one_kvm_version,
#   one_kvm_deb_name, one_kvm_deb_url, one_kvm_deb_sha256, create_release
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
# shellcheck source=lib/base_image.sh
source "${SCRIPT_DIR}/lib/base_image.sh"

usage() {
    cat <<'EOF'
Usage: plan-build.sh [options]

Options:
  --boards LIST|all          Boards to build (default: all)
  --kernel-release TAG|latest
  --one-kvm-repo OWNER/REPO  Override the One-KVM repository
  --one-kvm-release TAG|latest
  --one-kvm-wait-minutes N   Wait for a One-KVM release with an arm64 deb
  --create-release true|false
  --version V...             Release version (default: current timestamp)
  --output-dir DIR           Write plan.json here
EOF
}

BOARDS="all"
KERNEL_RELEASE_IN="latest"
ONE_KVM_REPO_IN=""
ONE_KVM_RELEASE_IN="latest"
ONE_KVM_WAIT_MINUTES="0"
CREATE_RELEASE="true"
VERSION=""
PLAN_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --boards) BOARDS="${2:-}"; shift 2 ;;
        --kernel-release) KERNEL_RELEASE_IN="${2:-}"; shift 2 ;;
        --one-kvm-repo) ONE_KVM_REPO_IN="${2:-}"; shift 2 ;;
        --one-kvm-release) ONE_KVM_RELEASE_IN="${2:-}"; shift 2 ;;
        --one-kvm-wait-minutes) ONE_KVM_WAIT_MINUTES="${2:-}"; shift 2 ;;
        --create-release) CREATE_RELEASE="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --output-dir) PLAN_DIR="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# Empty workflow inputs (push/repository_dispatch) fall back to safe defaults.
BOARDS="${BOARDS:-all}"
KERNEL_RELEASE_IN="${KERNEL_RELEASE_IN:-latest}"
ONE_KVM_RELEASE_IN="${ONE_KVM_RELEASE_IN:-latest}"
if [ -z "$ONE_KVM_WAIT_MINUTES" ]; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        ONE_KVM_WAIT_MINUTES="30"
    else
        ONE_KVM_WAIT_MINUTES="0"
    fi
fi
CREATE_RELEASE="${CREATE_RELEASE:-true}"

[[ "$ONE_KVM_WAIT_MINUTES" =~ ^[0-9]+$ ]] || die "--one-kvm-wait-minutes must be an integer"
case "$CREATE_RELEASE" in
    true|false) ;;
    *) die "--create-release must be true or false" ;;
esac

VERSION="${VERSION:-$(timestamp_version)}"
DEFAULTS="${REPO_ROOT}/config/defaults.conf"
# shellcheck disable=SC1090
source "$DEFAULTS"
if [ -n "$ONE_KVM_REPO_IN" ]; then
    ONE_KVM_REPO="$ONE_KVM_REPO_IN"
fi

require_cmd jq python3
bash "${SCRIPT_DIR}/validate-boards.sh"

group_start "Select boards"
basic_matrix="$(bash "${SCRIPT_DIR}/prepare-matrix.sh" --boards "$BOARDS")"
info "Boards: $(printf '%s' "$basic_matrix" | jq -r 'map(.board) | join(", ")')"
group_end

group_start "Resolve base images"
enriched=()
while IFS= read -r entry; do
    board="$(printf '%s' "$entry" | jq -r '.board')"
    config="$(printf '%s' "$entry" | jq -r '.config')"
    resolved="$(
        # shellcheck disable=SC1090
        source "$DEFAULTS"
        # shellcheck disable=SC1090
        source "$config"
        resolve_base_image_asset
        jq -nc \
            --arg board "$board" \
            --arg name "${BOARD_NAME:-}" \
            --arg config "$config" \
            --arg url "$BASE_URL" \
            --arg image "$BASE_NAME" \
            --arg sha "$BASE_SHA" \
            --arg release "$BASE_RELEASE_TAG" \
            --arg dtb "${KERNEL_DTB:-}" \
            --arg onekvm "${ONE_KVM_ENABLED:-true}" \
            '{board: $board, name: $name, config: $config,
              base_image_url: $url, base_image_name: $image,
              base_image_sha256: $sha, base_image_release: $release,
              kernel_dtb: $dtb, one_kvm_enabled: $onekvm}'
    )" || die "Cannot resolve the base image for board ${board}"
    enriched+=("$resolved")
    info "${board}: $(printf '%s' "$resolved" | jq -r '.base_image_release + "/" + .base_image_name')"
done < <(printf '%s' "$basic_matrix" | jq -c '.[]')
matrix="$(printf '%s\n' "${enriched[@]}" | jq -c -s '.')"
group_end

group_start "Resolve kernel release"
kernel_json="$(resolve_release "$KERNEL_REPO" "$KERNEL_RELEASE_IN" \
    "$KERNEL_TAG_PATTERN" "$KERNEL_IMAGE_PATTERN" "$KERNEL_CONFIG_PATTERN" "$KERNEL_DTB_PATTERN")"
kernel_tag="$(printf '%s' "$kernel_json" | jq -r '.tag_name')"
info "Kernel release: ${kernel_tag}"
group_end

one_kvm_tag=""
one_kvm_version=""
one_kvm_deb_name=""
one_kvm_deb_url=""
one_kvm_deb_sha256=""

need_one_kvm="$(printf '%s' "$matrix" \
    | jq -r '[.[] | select(.one_kvm_enabled == "true")] | length')"
if [ "$need_one_kvm" -gt 0 ]; then
    group_start "Resolve One-KVM release"
    one_json="$(bash "${SCRIPT_DIR}/one-kvm/resolve-one-kvm.sh" \
        --repo "$ONE_KVM_REPO" \
        --release "$ONE_KVM_RELEASE_IN" \
        --asset-pattern "$ONE_KVM_ASSET_PATTERN" \
        --min-version "${ONE_KVM_MIN_VERSION:-}" \
        --wait-seconds "$((ONE_KVM_WAIT_MINUTES * 60))")"
    one_kvm_tag="$(printf '%s' "$one_json" | jq -r '.tag')"
    one_kvm_version="$(printf '%s' "$one_json" | jq -r '.version')"
    one_kvm_deb_name="$(printf '%s' "$one_json" | jq -r '.asset')"
    one_kvm_deb_url="$(printf '%s' "$one_json" | jq -r '.url')"
    one_kvm_deb_sha256="$(printf '%s' "$one_json" | jq -r '.sha256')"
    info "One-KVM: ${one_kvm_tag} (${one_kvm_deb_name})"
    group_end
else
    warn "No selected board enables One-KVM"
fi

plan="$(jq -n \
    --arg version "$VERSION" \
    --arg kernel_tag "$kernel_tag" \
    --arg one_kvm_tag "$one_kvm_tag" \
    --arg one_kvm_version "$one_kvm_version" \
    --arg one_kvm_deb_name "$one_kvm_deb_name" \
    --arg one_kvm_deb_url "$one_kvm_deb_url" \
    --arg one_kvm_deb_sha256 "$one_kvm_deb_sha256" \
    --argjson boards "$matrix" \
    '{version: $version, kernel_tag: $kernel_tag, boards: $boards,
      one_kvm: {tag: $one_kvm_tag, version: $one_kvm_version,
                asset: $one_kvm_deb_name, url: $one_kvm_deb_url,
                sha256: $one_kvm_deb_sha256}}')"

if [ -n "$PLAN_DIR" ]; then
    mkdir -p "$PLAN_DIR"
    printf '%s\n' "$plan" >"${PLAN_DIR}/plan.json"
fi
mkdir -p "${REPO_ROOT}/work"
printf '%s\n' "$plan" >"${REPO_ROOT}/work/plan.json"

set_output matrix "$matrix"
set_output version "$VERSION"
set_output kernel_tag "$kernel_tag"
set_output one_kvm_tag "$one_kvm_tag"
set_output one_kvm_version "$one_kvm_version"
set_output one_kvm_deb_name "$one_kvm_deb_name"
set_output one_kvm_deb_url "$one_kvm_deb_url"
set_output one_kvm_deb_sha256 "$one_kvm_deb_sha256"
set_output create_release "$CREATE_RELEASE"

{
    echo "### Build plan ${VERSION}"
    echo
    echo "| Board | Base image | DTB | One-KVM |"
    echo "|---|---|---|---|"
    printf '%s' "$matrix" | jq -r '.[] | "| \(.board) | \(.base_image_release)/\(.base_image_name) | \(.kernel_dtb) | \(.one_kvm_enabled) |"'
    echo
    echo "- Kernel release: \`${kernel_tag}\`"
    echo "- One-KVM: \`${one_kvm_tag}\` (${one_kvm_version})"
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

info "Plan written to ${REPO_ROOT}/work/plan.json"
