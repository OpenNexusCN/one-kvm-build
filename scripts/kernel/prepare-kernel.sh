#!/usr/bin/env bash
# Fetch (or rebuild) a kernel bundle for one released kernel tag.
#
# Output layout:
#   <out>/Image-<ver>          kernel image
#   <out>/config-<ver>         release config
#   <out>/System.map-<ver>     symbols
#   <out>/*.dtb                all release DTBs
#   <out>/modules-<ver>.tar.gz matching modules (release asset or rebuilt)
#   <out>/kernel.env           machine-readable summary for the image build
#   <out>/manifest.json        provenance
#
# The current kernel workflow publishes Image/DTBs only.  When no modules
# asset exists, the modules are rebuilt from the exact released source tag
# with the exact released config, so vermagic matches the Image.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/github.sh
source "${SCRIPT_DIR}/../lib/github.sh"

usage() {
    cat <<'EOF'
Usage: prepare-kernel.sh --repo OWNER/REPO --release TAG|latest --output-dir DIR [options]

Options:
  --tag-pattern GLOB          Release tag filter (default: V*)
  --image-pattern GLOB        Kernel image asset (default: Image-*)
  --config-pattern GLOB       Config asset (default: config-*)
  --systemmap-pattern GLOB    System.map asset (default: System.map-*)
  --dtb-pattern GLOB          DTB asset (default: *.dtb)
  --modules-pattern GLOB      Optional release modules asset (default: modules-*.tar.gz)
  --git-url URL               Kernel source URL for the module fallback
  --arch ARCH                 Kernel arch (default: arm64)
  --cross-compile PREFIX      Cross compiler prefix (default: aarch64-linux-gnu-)
  --jobs N                    Parallel build jobs
  --no-fallback-modules       Fail instead of rebuilding missing modules
EOF
}

REPO=""
RELEASE="latest"
OUT_DIR=""
TAG_PATTERN="V*"
IMAGE_PATTERN="Image-*"
CONFIG_PATTERN="config-*"
SYSTEMMAP_PATTERN="System.map-*"
DTB_PATTERN="*.dtb"
MODULES_PATTERN="modules-*.tar.gz"
GIT_URL=""
ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"
JOBS=""
FALLBACK_MODULES="true"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:-}"; shift 2 ;;
        --release) RELEASE="${2:-}"; shift 2 ;;
        --output-dir) OUT_DIR="${2:-}"; shift 2 ;;
        --tag-pattern) TAG_PATTERN="${2:-}"; shift 2 ;;
        --image-pattern) IMAGE_PATTERN="${2:-}"; shift 2 ;;
        --config-pattern) CONFIG_PATTERN="${2:-}"; shift 2 ;;
        --systemmap-pattern) SYSTEMMAP_PATTERN="${2:-}"; shift 2 ;;
        --dtb-pattern) DTB_PATTERN="${2:-}"; shift 2 ;;
        --modules-pattern) MODULES_PATTERN="${2:-}"; shift 2 ;;
        --git-url) GIT_URL="${2:-}"; shift 2 ;;
        --arch) ARCH="${2:-}"; shift 2 ;;
        --cross-compile) CROSS_COMPILE="${2:-}"; shift 2 ;;
        --jobs) JOBS="${2:-}"; shift 2 ;;
        --no-fallback-modules) FALLBACK_MODULES="false"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$REPO" ] || die "--repo is required"
[ -n "$OUT_DIR" ] || die "--output-dir is required"
RELEASE="${RELEASE:-latest}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
[ -n "$GIT_URL" ] || GIT_URL="https://github.com/${REPO}.git"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

require_cmd git jq python3 tar sha256sum find

group_start "Resolve kernel release ${REPO}@${RELEASE}"
release_json="$(resolve_release "$REPO" "$RELEASE" "$TAG_PATTERN" \
    "$IMAGE_PATTERN" "$CONFIG_PATTERN" "$DTB_PATTERN")"
tag="$(printf '%s' "$release_json" | jq -r '.tag_name')"
[ -n "$tag" ] && [ "$tag" != "null" ] || die "Could not resolve a kernel release tag"
info "Kernel release: ${tag}"
group_end

group_start "Download kernel assets"
mapfile -t asset_names < <(printf '%s' "$release_json" | jq -r '.assets[].name')
[ "${#asset_names[@]}" -gt 0 ] || die "Release ${tag} has no assets"

for name in "${asset_names[@]}"; do
    # The variables below are intentionally unquoted globs.
    # shellcheck disable=SC2254
    case "$name" in
        $IMAGE_PATTERN|$CONFIG_PATTERN|$SYSTEMMAP_PATTERN|$DTB_PATTERN|$MODULES_PATTERN|Module.symvers-*|SHA256SUMS)
            digest="$(printf '%s' "$release_json" \
                | jq -r --arg n "$name" '.assets[] | select(.name == $n) | .digest // empty')"
            digest="${digest#sha256:}"
            download_asset "$REPO" "$tag" "$name" "$OUT_DIR" "$digest"
            ;;
        *)
            info "Skipping unrelated asset: ${name}"
            ;;
    esac
done

if [ -f "${OUT_DIR}/SHA256SUMS" ]; then
    (cd "$OUT_DIR" && sha256sum -c --ignore-missing SHA256SUMS) \
        || die "Kernel release checksum verification failed"
fi
group_end

mapfile -t images < <(find "$OUT_DIR" -maxdepth 1 -type f -name "$IMAGE_PATTERN" -printf '%f\n' | sort)
[ "${#images[@]}" -eq 1 ] || die "Expected exactly one kernel image matching ${IMAGE_PATTERN}, found ${#images[@]}"
kernel_image="${images[0]}"
KVER="${kernel_image#Image-}"
[ -n "$KVER" ] || die "Cannot derive kernel version from ${kernel_image}"

config_asset="$(find "$OUT_DIR" -maxdepth 1 -type f -name "$CONFIG_PATTERN" -printf '%f\n' | head -n1)"
[ -n "$config_asset" ] || die "Missing config asset matching ${CONFIG_PATTERN}"
case "$config_asset" in
    "config-${KVER}") ;;
    *) die "Config asset ${config_asset} does not match kernel ${KVER}" ;;
esac

systemmap_asset="$(find "$OUT_DIR" -maxdepth 1 -type f -name "$SYSTEMMAP_PATTERN" -printf '%f\n' | head -n1)"
[ -n "$systemmap_asset" ] || die "Missing System.map asset matching ${SYSTEMMAP_PATTERN}"
case "$systemmap_asset" in
    "System.map-${KVER}") ;;
    *) die "System.map asset ${systemmap_asset} does not match kernel ${KVER}" ;;
esac

mapfile -t dtbs < <(find "$OUT_DIR" -maxdepth 1 -type f -name '*.dtb' -printf '%f\n' | sort)
[ "${#dtbs[@]}" -gt 0 ] || die "Release ${tag} has no DTBs"

info "Kernel version: ${KVER}"

group_start "Prepare kernel modules"
modules_source="release"
modules_asset="$(find "$OUT_DIR" -maxdepth 1 -type f -name "$MODULES_PATTERN" -printf '%f\n' | head -n1)"
if [ -n "$modules_asset" ]; then
    info "Using modules from release: ${modules_asset}"
    if ! tar -tzf "$OUT_DIR/$modules_asset" | grep -F "lib/modules/${KVER}/" >/dev/null; then
        die "Modules asset ${modules_asset} does not contain lib/modules/${KVER}"
    fi
else
    [ "$FALLBACK_MODULES" = "true" ] || die \
        "Release ${tag} has no modules asset. Re-run the kernel workflow with modules enabled, or allow the fallback."
    warn "Release ${tag} has no modules asset; rebuilding modules from ${tag}"
    modules_source="built"
    extra_args=()
    if [ -n "$JOBS" ]; then
        extra_args+=(--jobs "$JOBS")
    fi
    bash "${SCRIPT_DIR}/build-modules.sh" \
        --repo-url "$GIT_URL" \
        --tag "$tag" \
        --config "$OUT_DIR/$config_asset" \
        --expected-version "$KVER" \
        --output-dir "$OUT_DIR" \
        --arch "$ARCH" \
        --cross-compile "$CROSS_COMPILE" \
        "${extra_args[@]}"
    modules_asset="modules-${KVER}.tar.gz"
    [ -f "$OUT_DIR/$modules_asset" ] || die "Module rebuild did not produce ${modules_asset}"
fi
group_end

source_commit="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git ls-remote "$GIT_URL" "refs/tags/${tag}^{}" 2>/dev/null | awk 'NR==1{print $1}')"
[ -n "$source_commit" ] || source_commit="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git ls-remote "$GIT_URL" "refs/tags/${tag}" 2>/dev/null | awk 'NR==1{print $1}')"
source_commit="${source_commit:-unknown}"

{
    write_env_var "$OUT_DIR/kernel.env" KERNEL_RELEASE_TAG "$tag"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_VERSION "$KVER"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_REPO "$REPO"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_GIT_URL "$GIT_URL"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_SOURCE_COMMIT "$source_commit"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_IMAGE "$kernel_image"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_CONFIG "$config_asset"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_SYSTEMMAP "$systemmap_asset"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_MODULES "$modules_asset"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_MODULES_SOURCE "$modules_source"
    write_env_var "$OUT_DIR/kernel.env" KERNEL_DTB_COUNT "${#dtbs[@]}"
}

jq -n \
    --arg tag "$tag" \
    --arg version "$KVER" \
    --arg repo "$REPO" \
    --arg commit "$source_commit" \
    --arg image "$kernel_image" \
    --arg modules "$modules_asset" \
    --arg modules_source "$modules_source" \
    --arg generated_at "$(utc_now)" \
    '{tag: $tag, version: $version, repo: $repo, commit: $commit,
      image: $image, modules: $modules, modules_source: $modules_source,
      generated_at: $generated_at}' >"$OUT_DIR/manifest.json"

{
    echo "### Kernel bundle"
    echo
    echo "- Release: \`${tag}\`"
    echo "- Version: \`${KVER}\`"
    echo "- Source commit: \`${source_commit}\`"
    echo "- Modules: ${modules_source} (\`${modules_asset}\`)"
    echo "- DTBs: ${#dtbs[@]}"
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

info "Kernel bundle ready in ${OUT_DIR}"
