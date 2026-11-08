#!/usr/bin/env bash
# Build one One-KVM board image.
#
# Pipeline:
#   1. resolve/download/verify an Armbian base image
#   2. obtain a kernel bundle (release assets or a rebuilt module set)
#   3. mount the image, replace kernel/DTB/modules, regenerate initramfs
#   4. install the One-KVM .deb, apply board components, write metadata
#   5. compress, checksum and emit a manifest
#
# Requires root (loop devices and mounts).  In CI it is invoked through sudo.
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"
# shellcheck source=lib/base_image.sh
source "${SCRIPT_DIR}/lib/base_image.sh"
# shellcheck source=lib/chroot.sh
source "${SCRIPT_DIR}/lib/chroot.sh"

usage() {
    cat <<'EOF'
Usage: build-image.sh --board BOARD [options]

Required:
  --board BOARD             Board id from boards/<id>.conf

Kernel:
  --kernel-bundle DIR       Use an already prepared bundle (skips downloads)
  --kernel-release TAG      Kernel release tag or "latest" (default from board)

Base image:
  --base-image-url URL      Override the resolved base image URL
  --base-image-name NAME    Asset name for the output template tokens
  --base-image-sha256 SHA   Verify the base image

One-KVM:
  --one-kvm-url URL         Download the package from this URL
  --one-kvm-version VER     Package version (recorded)
  --one-kvm-sha256 SHA      Verify the package
  --one-kvm-tag TAG         Release tag when resolving automatically
  --skip-one-kvm            Do not install One-KVM

Customisation:
  --apt-packages "pkg ..."  Extra packages installed with apt (also APT_PACKAGES)

Output:
  --build-version V...      Release version (default: V<timestamp>)
  --compress gz|xz|zst      Output compression (default: from board)
  --output-dir DIR
  --work-dir DIR
  --keep-uncompressed       Keep the raw .img after compression
  --keep-work               Keep the work directory
EOF
}

ARG_BOARD=""
ARG_CONFIG=""
ARG_KERNEL_BUNDLE=""
ARG_KERNEL_RELEASE=""
ARG_BASE_URL=""
ARG_BASE_NAME=""
ARG_BASE_SHA=""
ARG_ONE_KVM_URL=""
ARG_ONE_KVM_VERSION=""
ARG_ONE_KVM_SHA=""
ARG_ONE_KVM_TAG=""
ARG_SKIP_ONE_KVM="false"
ARG_APT_PACKAGES=""
ARG_BUILD_VERSION=""
ARG_COMPRESS=""
ARG_OUTPUT_DIR=""
ARG_WORK_DIR=""
KEEP_UNCOMPRESSED="false"
KEEP_WORK="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --board) ARG_BOARD="${2:-}"; shift 2 ;;
        --config) ARG_CONFIG="${2:-}"; shift 2 ;;
        --kernel-bundle) ARG_KERNEL_BUNDLE="${2:-}"; shift 2 ;;
        --kernel-release) ARG_KERNEL_RELEASE="${2:-}"; shift 2 ;;
        --base-image-url) ARG_BASE_URL="${2:-}"; shift 2 ;;
        --base-image-name) ARG_BASE_NAME="${2:-}"; shift 2 ;;
        --base-image-sha256) ARG_BASE_SHA="${2:-}"; shift 2 ;;
        --one-kvm-url) ARG_ONE_KVM_URL="${2:-}"; shift 2 ;;
        --one-kvm-version) ARG_ONE_KVM_VERSION="${2:-}"; shift 2 ;;
        --one-kvm-sha256) ARG_ONE_KVM_SHA="${2:-}"; shift 2 ;;
        --one-kvm-tag) ARG_ONE_KVM_TAG="${2:-}"; shift 2 ;;
        --skip-one-kvm) ARG_SKIP_ONE_KVM="true"; shift ;;
        --apt-packages) ARG_APT_PACKAGES="${2:-}"; shift 2 ;;
        --build-version) ARG_BUILD_VERSION="${2:-}"; shift 2 ;;
        --compress) ARG_COMPRESS="${2:-}"; shift 2 ;;
        --output-dir) ARG_OUTPUT_DIR="${2:-}"; shift 2 ;;
        --work-dir) ARG_WORK_DIR="${2:-}"; shift 2 ;;
        --keep-uncompressed) KEEP_UNCOMPRESSED="true"; shift ;;
        --keep-work) KEEP_WORK="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$ARG_BOARD" ] || { usage >&2; die "--board is required"; }
require_root "$@"

# shellcheck disable=SC1091
source "${REPO_ROOT}/config/defaults.conf"
BOARD_FILE="${ARG_CONFIG:-${REPO_ROOT}/boards/${ARG_BOARD}.conf}"
if [ ! -f "$BOARD_FILE" ] && [ -f "${REPO_ROOT}/${BOARD_FILE}" ]; then
    BOARD_FILE="${REPO_ROOT}/${BOARD_FILE}"
fi
[ -f "$BOARD_FILE" ] || die "Board config not found: ${BOARD_FILE}"
# shellcheck disable=SC1090
source "$BOARD_FILE"

[ "${BOARD_ID:-}" = "$ARG_BOARD" ] \
    || die "Board config ${BOARD_FILE} defines BOARD_ID=${BOARD_ID:-<empty>}, expected ${ARG_BOARD}"
[ -n "${SOC_FAMILY:-}" ] || die "SOC_FAMILY is not set for ${ARG_BOARD}"
FAMILY_FILE="${REPO_ROOT}/scripts/families/${SOC_FAMILY}.sh"
[ -f "$FAMILY_FILE" ] || die "Unsupported SOC_FAMILY=${SOC_FAMILY} (missing ${FAMILY_FILE})"

ARG_KERNEL_RELEASE="${ARG_KERNEL_RELEASE:-$KERNEL_RELEASE}"
ARG_COMPRESS="${ARG_COMPRESS:-$OUTPUT_COMPRESS}"
ARG_OUTPUT_DIR="${ARG_OUTPUT_DIR:-${REPO_ROOT}/${OUTPUT_DIR}}"
ARG_WORK_DIR="${ARG_WORK_DIR:-${REPO_ROOT}/${WORK_DIR}}"
BUILD_VERSION="${ARG_BUILD_VERSION:-$(timestamp_version)}"
if [ "$ARG_SKIP_ONE_KVM" = "true" ]; then
    ONE_KVM_ENABLED="false"
fi

case "$ARG_COMPRESS" in
    gz|xz|zst) ;;
    *) die "--compress must be one of gz, xz, zst" ;;
esac

WORK="${ARG_WORK_DIR}/${BOARD_ID}"
OUT="${ARG_OUTPUT_DIR}"
IMG="${WORK}/image.img"
ROOT_MNT="${WORK}/root"
BOOT_MNT=""
KERNEL_BUNDLE=""
mkdir -p "$WORK" "$OUT"
if [ "$KEEP_WORK" != "true" ]; then
    rm -rf "${WORK:?}/"*
    mkdir -p "$WORK"
fi

info "Board: ${BOARD_ID} (${BOARD_NAME:-})"
info "Build version: ${BUILD_VERSION}"
info "Work dir: ${WORK}"

# ---------------------------------------------------------------------------
# Base image
# ---------------------------------------------------------------------------

resolve_base_image() {
    if [ -n "$ARG_BASE_URL" ]; then
        BASE_IMAGE_URL="$ARG_BASE_URL"
    fi
    if [ -n "$ARG_BASE_SHA" ]; then
        BASE_IMAGE_SHA256="$ARG_BASE_SHA"
    fi
    group_start "Resolve base image"
    if [ -n "$ARG_BASE_NAME" ]; then
        # A caller-provided name and URL fully describe the base image.
        BASE_NAME="$ARG_BASE_NAME"
        if [ -n "$BASE_IMAGE_URL" ]; then
            BASE_URL="$BASE_IMAGE_URL"
            BASE_SHA="${BASE_IMAGE_SHA256:-}"
            BASE_RELEASE_TAG="${BASE_IMAGE_RELEASE}"
        else
            resolve_base_image_asset
        fi
    else
        resolve_base_image_asset
    fi
    group_end
    info "Base image: ${BASE_RELEASE_TAG}/${BASE_NAME}"
}

download_base_image() {
    local dest="${WORK}/base/${BASE_NAME}"
    mkdir -p "$(dirname "$dest")"
    group_start "Download base image"
    download_url "$BASE_URL" "$dest" "$BASE_SHA"
    BASE_FILE="$dest"
    group_end
}

parse_base_metadata() {
    BASE_ARMBIAN_VERSION="unknown"
    BASE_PLATFORM="rockchip"
    BASE_ASSET_BOARD="$BOARD_ID"
    BASE_CODENAME="unknown"
    BASE_KERNEL="unknown"
    BASE_EDITION="server"
    BASE_DATE="$(date -u +%Y.%m.%d)"

    local re='^Armbian_([^_]+)_([^_]+)_(.+)_([a-z]+)_([^_]+)_([a-z]+)_([0-9.]+)\.img\.(gz|xz|zst)$'
    if [[ "$BASE_NAME" =~ $re ]]; then
        BASE_ARMBIAN_VERSION="${BASH_REMATCH[1]}"
        BASE_PLATFORM="${BASH_REMATCH[2]}"
        BASE_ASSET_BOARD="${BASH_REMATCH[3]}"
        BASE_CODENAME="${BASH_REMATCH[4]}"
        BASE_KERNEL="${BASH_REMATCH[5]}"
        BASE_EDITION="${BASH_REMATCH[6]}"
        BASE_DATE="${BASH_REMATCH[7]}"
    else
        warn "Cannot parse Armbian metadata from ${BASE_NAME}"
    fi
}

decompress_base_image() {
    group_start "Decompress base image"
    local src="$BASE_FILE"
    local -a decomp
    case "$src" in
        *.gz)
            if command -v pigz >/dev/null 2>&1; then decomp=(pigz -dc); else decomp=(gzip -dc); fi
            ;;
        *.xz) decomp=(xz -dc -T0) ;;
        *.zst) decomp=(zstd -dc) ;;
        *) decomp=(cat) ;;
    esac
    rm -f "$IMG"
    "${decomp[@]}" "$src" | dd of="$IMG" bs=4M conv=sparse status=none \
        || die "Failed to decompress ${src}"
    sfdisk -J "$IMG" >/dev/null || die "Decompressed image has no valid partition table"
    info "Image: $(human_bytes "$(stat -c %s "$IMG")")"
    group_end
}

# ---------------------------------------------------------------------------
# Kernel bundle
# ---------------------------------------------------------------------------

load_kernel_bundle() {
    if [ -n "$ARG_KERNEL_BUNDLE" ]; then
        KERNEL_BUNDLE="$(cd "$ARG_KERNEL_BUNDLE" && pwd)"
    else
        KERNEL_BUNDLE="${WORK}/kernel-bundle"
        local extra=()
        [ "$KERNEL_MODULES_FALLBACK" = "true" ] || extra+=(--no-fallback-modules)
        bash "${SCRIPT_DIR}/kernel/prepare-kernel.sh" \
            --repo "$KERNEL_REPO" \
            --release "$ARG_KERNEL_RELEASE" \
            --tag-pattern "$KERNEL_TAG_PATTERN" \
            --image-pattern "$KERNEL_IMAGE_PATTERN" \
            --config-pattern "$KERNEL_CONFIG_PATTERN" \
            --systemmap-pattern "$KERNEL_SYSTEMMAP_PATTERN" \
            --dtb-pattern "$KERNEL_DTB_PATTERN" \
            --modules-pattern "$KERNEL_MODULES_PATTERN" \
            --git-url "$KERNEL_GIT_URL" \
            --arch "$KERNEL_ARCH" \
            --cross-compile "$KERNEL_CROSS_COMPILE" \
            --output-dir "$KERNEL_BUNDLE" \
            "${extra[@]}"
    fi
    [ -f "${KERNEL_BUNDLE}/kernel.env" ] || die "Missing ${KERNEL_BUNDLE}/kernel.env"
    # shellcheck disable=SC1090
    source "${KERNEL_BUNDLE}/kernel.env"
    [ -n "${KERNEL_VERSION:-}" ] || die "KERNEL_VERSION is empty"
    [ -n "${KERNEL_DTB:-}" ] || die "KERNEL_DTB is not set in ${BOARD_FILE}"
    [ -f "${KERNEL_BUNDLE}/${KERNEL_DTB}" ] \
        || die "Kernel bundle does not contain ${KERNEL_DTB}"
    info "Kernel ${KERNEL_RELEASE_TAG} / ${KERNEL_VERSION} (modules: ${KERNEL_MODULES_SOURCE})"
}

# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------

apply_components() {
    local phase="$1"
    [ "${APPLY_COMPONENTS:-true}" = "true" ] || return 0
    local dir
    for dir in "${REPO_ROOT}/${COMPONENTS_DIR}/common" "${REPO_ROOT}/${COMPONENTS_DIR}/${BOARD_ID}"; do
        [ -d "$dir" ] || continue
        if [ "$phase" = "pre" ]; then
            if [ -d "${dir}/rootfs" ]; then
                cp -a "${dir}/rootfs/." "${ROOT_MNT}/"
            fi
            if [ -d "${dir}/boot" ]; then
                cp -a "${dir}/boot/." "${BOOT_MNT}/"
            fi
        fi
        [ -d "${dir}/${phase}-install.d" ] || continue
        local hook
        shopt -s nullglob
        for hook in "${dir}/${phase}-install.d/"*.sh; do
            shopt -u nullglob
            info "Component hook (${phase}): ${hook}"
            ROOT="$ROOT_MNT" BOOT="$BOOT_MNT" KVER="$KERNEL_VERSION" \
                BOARD_ID="$BOARD_ID" BUILD_VERSION="$BUILD_VERSION" WORK="$WORK" \
                bash "$hook" || die "Component hook failed: ${hook}"
            shopt -s nullglob
        done
        shopt -u nullglob
    done
}

# ---------------------------------------------------------------------------
# One-KVM
# ---------------------------------------------------------------------------

install_one_kvm() {
    if [ "${ONE_KVM_ENABLED:-true}" != "true" ]; then
        info "One-KVM installation disabled"
        return 0
    fi

    local url="${ARG_ONE_KVM_URL:-}"
    local version="${ARG_ONE_KVM_VERSION:-}"
    local sha="${ARG_ONE_KVM_SHA:-}"
    local tag="${ARG_ONE_KVM_TAG:-$ONE_KVM_RELEASE}"

    if [ -z "$url" ]; then
        group_start "Resolve One-KVM release"
        local json
        json="$(bash "${SCRIPT_DIR}/one-kvm/resolve-one-kvm.sh" \
            --repo "$ONE_KVM_REPO" \
            --release "$tag" \
            --asset-pattern "$ONE_KVM_ASSET_PATTERN" \
            --min-version "${ONE_KVM_MIN_VERSION:-}" \
            --wait-seconds "$ONE_KVM_WAIT_SECONDS")"
        url="$(printf '%s' "$json" | jq -r '.url')"
        version="$(printf '%s' "$json" | jq -r '.version')"
        sha="$(printf '%s' "$json" | jq -r '.sha256')"
        group_end
    fi

    ONE_KVM_VERSION="$version"
    ONE_KVM_SHA256="$sha"
    info "Installing One-KVM ${version:-unknown}"
    bash "${SCRIPT_DIR}/one-kvm/install-one-kvm.sh" \
        --root "$ROOT_MNT" \
        --url "$url" \
        --version "$version" \
        --sha256 "$sha" \
        --kernel-version "$KERNEL_VERSION"
}

# ---------------------------------------------------------------------------
# Extra apt packages / Wi-Fi AP
# ---------------------------------------------------------------------------

install_extra_packages() {
    local packages="${APT_PACKAGES:-} ${ARG_APT_PACKAGES:-}"
    if [ "${WIFI_AP_ENABLED:-true}" = "true" ]; then
        packages+=" ${WIFI_AP_PACKAGES:-hostapd dnsmasq lighttpd iw}"
    fi
    bash "${SCRIPT_DIR}/features/apt-install.sh" \
        --root "$ROOT_MNT" \
        --packages "$packages" \
        --recommends "${APT_INSTALL_RECOMMENDS:-false}"
}

configure_wifi_ap() {
    if [ "${WIFI_AP_ENABLED:-true}" != "true" ]; then
        info "Wi-Fi AP configuration disabled"
        return 0
    fi
    bash "${SCRIPT_DIR}/features/wifi-ap.sh" \
        --root "$ROOT_MNT" \
        --ssid-prefix "${WIFI_AP_SSID_PREFIX:-OneKVM-}" \
        --hash-length "${WIFI_AP_HASH_LENGTH:-6}" \
        --security "${WIFI_AP_SECURITY:-open}" \
        --password "${WIFI_AP_PASSWORD:-}" \
        --country "${WIFI_AP_COUNTRY:-CN}" \
        --channel "${WIFI_AP_CHANNEL:-6}" \
        --ip "${WIFI_AP_IP:-192.168.4.1}" \
        --dhcp-start "${WIFI_AP_DHCP_START:-192.168.4.10}" \
        --dhcp-end "${WIFI_AP_DHCP_END:-192.168.4.100}" \
        --portal-port "${WIFI_AP_PORTAL_PORT:-8080}" \
        --interface "${WIFI_AP_INTERFACE:-}"
}

# ---------------------------------------------------------------------------
# Metadata / output
# ---------------------------------------------------------------------------

write_image_manifest() {
    mkdir -p "${ROOT_MNT}/etc/one-kvm-build"
    jq -n \
        --arg board "$BOARD_ID" \
        --arg board_name "${BOARD_NAME:-}" \
        --arg version "$BUILD_VERSION" \
        --arg built_at "$(utc_now)" \
        --arg base_image "$BASE_NAME" \
        --arg base_sha "$BASE_SHA" \
        --arg base_release "$BASE_RELEASE_TAG" \
        --arg kernel_tag "$KERNEL_RELEASE_TAG" \
        --arg kernel_version "$KERNEL_VERSION" \
        --arg kernel_dtb "$KERNEL_DTB" \
        --arg modules_source "$KERNEL_MODULES_SOURCE" \
        --arg one_kvm_version "${ONE_KVM_VERSION:-}" \
        --arg one_kvm_sha "${ONE_KVM_SHA256:-}" \
        --arg apt_packages "$(printf '%s %s' "${APT_PACKAGES:-}" "${ARG_APT_PACKAGES:-}" | xargs)" \
        --arg wifi_ap_enabled "${WIFI_AP_ENABLED:-true}" \
        --arg wifi_ap_prefix "${WIFI_AP_SSID_PREFIX:-OneKVM-}" \
        --arg wifi_ap_security "${WIFI_AP_SECURITY:-open}" \
        --arg wifi_ap_ip "${WIFI_AP_IP:-192.168.4.1}" \
        --arg wifi_ap_portal_port "${WIFI_AP_PORTAL_PORT:-8080}" \
        --arg commit "${GITHUB_SHA:-local}" \
        --arg run "${GITHUB_RUN_ID:-local}" \
        '{board: $board, board_name: $board_name, build_version: $version,
          built_at: $built_at, commit: $commit, run: $run,
          base_image: {name: $base_image, sha256: $base_sha, release: $base_release},
          kernel: {release: $kernel_tag, version: $kernel_version, dtb: $kernel_dtb,
                   modules_source: $modules_source},
          one_kvm: {version: $one_kvm_version, sha256: $one_kvm_sha},
          apt_packages: $apt_packages,
          wifi_ap: {enabled: $wifi_ap_enabled, ssid_prefix: $wifi_ap_prefix,
                    security: $wifi_ap_security, ip: $wifi_ap_ip,
                    portal_port: $wifi_ap_portal_port}}' \
        >"${ROOT_MNT}/etc/one-kvm-build/build.json"
}

render_output_name() {
    local template="$OUTPUT_NAME_TEMPLATE"
    local -A tokens=(
        [armbian_version]="$BASE_ARMBIAN_VERSION"
        [platform]="$BASE_PLATFORM"
        [board]="$BOARD_ID"
        [base_board]="$BASE_ASSET_BOARD"
        [codename]="$BASE_CODENAME"
        [kernel]="$KERNEL_VERSION"
        [onekvm_version]="${ONE_KVM_VERSION:-none}"
        [base_date]="$BASE_DATE"
        [timestamp]="${BUILD_VERSION#V}"
        [ext]="$ARG_COMPRESS"
    )
    local key
    for key in "${!tokens[@]}"; do
        template="${template//\{${key}\}/${tokens[$key]}}"
    done
    template="${template// /_}"
    template="${template//\//_}"
    printf '%s' "$template"
}

compress_and_publish() {
    local name
    name="$(render_output_name)"
    [ -n "$name" ] || die "Rendered output name is empty"
    local dest="${OUT}/${name}"
    group_start "Compress image -> ${name}"

    case "$ARG_COMPRESS" in
        gz)
            if command -v pigz >/dev/null 2>&1; then
                pigz -9 -p "$(nproc)" -c "$IMG" >"$dest"
            else
                gzip -9 -c "$IMG" >"$dest"
            fi
            ;;
        xz) xz -9 -T0 -c "$IMG" >"$dest" ;;
        zst) zstd -19 -T0 -c "$IMG" >"$dest" ;;
    esac
    [ -s "$dest" ] || die "Compression produced an empty file"
    group_end

    (cd "$OUT" && sha256sum "$name" >"${name}.sha256")
    IMAGE_NAME="$name"
    IMAGE_SHA256="$(sha256_of "$dest")"

    jq --arg name "$IMAGE_NAME" --arg sha "$IMAGE_SHA256" --arg file "$dest" \
        '.output = {name: $name, sha256: $sha}' \
        "${OUT}/manifest-${BOARD_ID}.json" >"${OUT}/manifest-${BOARD_ID}.json.tmp"
    mv -f "${OUT}/manifest-${BOARD_ID}.json.tmp" "${OUT}/manifest-${BOARD_ID}.json"

    if [ "$KEEP_UNCOMPRESSED" != "true" ]; then
        rm -f "$IMG"
    fi
    info "Output: ${dest} ($(human_bytes "$(stat -c %s "$dest")"))"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

resolve_base_image
download_base_image
parse_base_metadata
decompress_base_image
load_kernel_bundle

# shellcheck source=families/rockchip.sh
source "$FAMILY_FILE"

group_start "Prepare image"
family_inspect_image "$IMG"
family_grow_image
family_mount_image
trap 'family_cleanup' EXIT
check_target_arch "$ROOT_MNT"
group_end

group_start "Install kernel and boot configuration"
family_install_kernel
family_configure_boot
family_configure_system
group_end

group_start "Install extra packages and Wi-Fi AP"
install_extra_packages
configure_wifi_ap
group_end

group_start "Regenerate initramfs"
family_create_initrd
group_end

apply_components pre
install_one_kvm
apply_components post

write_image_manifest

# Persist a copy of the manifest outside the image.
jq -n \
    --arg board "$BOARD_ID" \
    --arg version "$BUILD_VERSION" \
    --arg base_image "$BASE_NAME" \
    --arg base_sha "$BASE_SHA" \
    --arg base_release "$BASE_RELEASE_TAG" \
    --arg base_kernel "$BASE_KERNEL" \
    --arg base_edition "$BASE_EDITION" \
    --arg kernel_tag "$KERNEL_RELEASE_TAG" \
    --arg kernel_version "$KERNEL_VERSION" \
    --arg kernel_dtb "$KERNEL_DTB" \
    --arg modules_source "$KERNEL_MODULES_SOURCE" \
    --arg one_kvm_version "${ONE_KVM_VERSION:-}" \
    --arg apt_packages "$(printf '%s %s' "${APT_PACKAGES:-}" "${ARG_APT_PACKAGES:-}" | xargs)" \
    --arg wifi_ap_enabled "${WIFI_AP_ENABLED:-true}" \
    --arg wifi_ap_prefix "${WIFI_AP_SSID_PREFIX:-OneKVM-}" \
    --arg wifi_ap_security "${WIFI_AP_SECURITY:-open}" \
    --arg wifi_ap_ip "${WIFI_AP_IP:-192.168.4.1}" \
    --arg wifi_ap_portal_port "${WIFI_AP_PORTAL_PORT:-8080}" \
    --arg built_at "$(utc_now)" \
    '{board: $board, build_version: $version, built_at: $built_at,
      base_image: {name: $base_image, sha256: $base_sha, release: $base_release,
                   kernel: $base_kernel, edition: $base_edition},
      kernel: {release: $kernel_tag, version: $kernel_version, dtb: $kernel_dtb,
               modules_source: $modules_source},
      one_kvm: {version: $one_kvm_version},
      apt_packages: $apt_packages,
      wifi_ap: {enabled: $wifi_ap_enabled, ssid_prefix: $wifi_ap_prefix,
                security: $wifi_ap_security, ip: $wifi_ap_ip,
                portal_port: $wifi_ap_portal_port}}' \
    >"${OUT}/manifest-${BOARD_ID}.json"

family_cleanup
trap - EXIT

compress_and_publish

{
    write_env_var "${OUT}/result-${BOARD_ID}.env" IMAGE_NAME "$IMAGE_NAME"
    write_env_var "${OUT}/result-${BOARD_ID}.env" IMAGE_SHA256 "$IMAGE_SHA256"
    write_env_var "${OUT}/result-${BOARD_ID}.env" MANIFEST "${OUT}/manifest-${BOARD_ID}.json"
}

set_output image_name "$IMAGE_NAME"
set_output image_sha256 "$IMAGE_SHA256"
set_output manifest "${OUT}/manifest-${BOARD_ID}.json"

{
    echo "### ${BOARD_ID}"
    echo
    echo "- Image: \`${IMAGE_NAME}\`"
    echo "- SHA256: \`${IMAGE_SHA256}\`"
    echo "- Kernel: \`${KERNEL_VERSION}\` (${KERNEL_RELEASE_TAG})"
    echo "- DTB: \`${KERNEL_DTB}\`"
    echo "- One-KVM: ${ONE_KVM_VERSION:-skipped}"
    echo "- Wi-Fi AP: ${WIFI_AP_ENABLED:-true} (SSID ${WIFI_AP_SSID_PREFIX:-OneKVM-}<hash>, portal :${WIFI_AP_PORTAL_PORT:-8080})"
    echo "- Extra apt: ${APT_PACKAGES:-} ${ARG_APT_PACKAGES:-}"
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$KEEP_WORK" != "true" ]; then
    rm -rf "$WORK"
fi
info "Done: ${OUT}/${IMAGE_NAME}"
