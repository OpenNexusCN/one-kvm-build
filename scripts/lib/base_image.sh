#!/usr/bin/env bash
# Resolve an Armbian base image asset.
#
# Reads from the environment/config:
#   BASE_IMAGE_REPO, BASE_IMAGE_RELEASE, BASE_IMAGE_TAG_PATTERN,
#   BASE_IMAGE_ASSET_PATTERN, BASE_IMAGE_URL, BASE_IMAGE_SHA256
#
# Sets:
#   BASE_URL, BASE_NAME, BASE_SHA, BASE_RELEASE_TAG

# shellcheck disable=SC2034  # BASE_* are consumed by the sourcing scripts
resolve_base_image_asset() {
    if [ -n "${BASE_IMAGE_URL:-}" ]; then
        BASE_URL="$BASE_IMAGE_URL"
        BASE_NAME="$(basename "${BASE_IMAGE_URL%%\?*}")"
        BASE_SHA="${BASE_IMAGE_SHA256:-}"
        BASE_RELEASE_TAG="${BASE_IMAGE_RELEASE:-pinned-url}"
        return 0
    fi

    [ -n "${BASE_IMAGE_REPO:-}" ] || die "BASE_IMAGE_REPO is not set"
    [ -n "${BASE_IMAGE_ASSET_PATTERN:-}" ] || die "BASE_IMAGE_ASSET_PATTERN is not set"

    local release_json asset_json digest
    release_json="$(resolve_release "$BASE_IMAGE_REPO" "$BASE_IMAGE_RELEASE" \
        "$BASE_IMAGE_TAG_PATTERN" "$BASE_IMAGE_ASSET_PATTERN")" \
        || die "Cannot resolve a base image release for ${BASE_IMAGE_ASSET_PATTERN}"
    BASE_RELEASE_TAG="$(printf '%s' "$release_json" | jq -r '.tag_name')"

    asset_json="$(select_asset "$release_json" "$BASE_IMAGE_ASSET_PATTERN")" \
        || die "Cannot select base image asset ${BASE_IMAGE_ASSET_PATTERN}"
    BASE_NAME="$(asset_field "$asset_json" name)"
    BASE_URL="$(asset_field "$asset_json" browser_download_url)"
    digest="$(asset_field "$asset_json" digest)"
    digest="${digest#sha256:}"
    BASE_SHA="${BASE_IMAGE_SHA256:-$digest}"

    [ -n "$BASE_NAME" ] || die "Resolved base image has an empty name"
    [ -n "$BASE_URL" ] || die "Resolved base image has no download URL"
}
