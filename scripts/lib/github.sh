#!/usr/bin/env bash
# GitHub API helpers.
#
# Prefers the `gh` CLI when it is installed and authenticated; falls back to
# curl (with GH_TOKEN/GITHUB_TOKEN when available) for local use.

gh_available() {
    command -v gh >/dev/null 2>&1 || return 1
    if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
        return 0
    fi
    gh auth status >/dev/null 2>&1
}

# api_get <endpoint>   e.g. repos/owner/repo/releases?per_page=100
api_get() {
    local endpoint="${1#/}"
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if gh_available; then
        GH_TOKEN="$token" gh api "$endpoint"
        return
    fi
    local -a args=(
        -fsSL --retry 3 --retry-delay 5 --connect-timeout 30
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28"
    )
    if [ -n "$token" ]; then
        args+=(-H "Authorization: Bearer ${token}")
    fi
    curl "${args[@]}" "https://api.github.com/${endpoint}"
}

# resolve_release <repo> <tag|latest> <tag_pattern> [required_asset_glob...]
# Prints a normalized JSON object with tag_name and assets.
resolve_release() {
    local repo="$1" release="$2" tag_pattern="$3"
    shift 3
    local -a requires=("$@")
    local raw
    local -a cargs
    local pattern

    if [ "$release" = "latest" ]; then
        raw="$(api_get "repos/${repo}/releases?per_page=100")" \
            || die "Cannot list releases for ${repo}"
        cargs=(select-latest --tag-pattern "$tag_pattern")
    else
        raw="$(api_get "repos/${repo}/releases/tags/${release}")" \
            || die "Cannot read release ${release} of ${repo}"
        cargs=(select-release)
    fi

    for pattern in "${requires[@]}"; do
        cargs+=(--require "$pattern")
    done

    printf '%s' "$raw" | python3 -I "${LIB_DIR}/release_tool.py" "${cargs[@]}"
}

# select_asset <release_json> <glob>
select_asset() {
    local release_json="$1" pattern="$2"
    printf '%s' "$release_json" \
        | python3 -I "${LIB_DIR}/release_tool.py" select-asset --pattern "$pattern"
}

# asset_field <asset_json> <field>
asset_field() {
    local asset_json="$1" field="$2"
    printf '%s' "$asset_json" | jq -r --arg f "$field" '.[$f] // empty'
}

urlencode() {
    jq -rn --arg s "$1" '$s | @uri'
}

# download_url <url> <dest> [expected_sha256]
download_url() {
    local url="$1" dest="$2" expected_sha="${3:-}"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ] && [ -n "$expected_sha" ] \
        && [ "$(sha256_of "$dest")" = "$expected_sha" ]; then
        info "Using cached $(basename "$dest")"
        return 0
    fi
    rm -f "$dest"
    local -a args=(-fL --retry 5 --retry-delay 5 --connect-timeout 30)
    retry 5 curl "${args[@]}" -o "$dest" "$url" \
        || die "Failed to download ${url}"
    verify_sha256 "$dest" "$expected_sha"
}

# download_asset <repo> <tag> <asset_name> <dest_dir> [expected_sha256]
# Returns the downloaded path in DOWNLOADED_ASSET.
download_asset() {
    local repo="$1" tag="$2" name="$3" dest_dir="$4" expected_sha="${5:-}"
    local dest="${dest_dir}/${name}"
    mkdir -p "$dest_dir"

    if [ -f "$dest" ] && [ -n "$expected_sha" ] \
        && [ "$(sha256_of "$dest")" = "$expected_sha" ]; then
        info "Using cached asset: ${name}"
        return 0
    fi

    rm -f "$dest"

    if gh_available; then
        info "Downloading ${repo}@${tag}/${name} via gh"
        GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" \
            gh release download "$tag" \
                --repo "$repo" \
                --pattern "$name" \
                --dir "$dest_dir" \
                --clobber \
            || die "Failed to download ${name} from ${repo}@${tag}"
    else
        local encoded_name url
        encoded_name="$(urlencode "$name")"
        url="https://github.com/${repo}/releases/download/${tag}/${encoded_name}"
        info "Downloading ${name}"
        local -a cargs=(-fL --retry 5 --retry-delay 5 --connect-timeout 30)
        if [ -s "$dest" ]; then
            cargs+=(-C -)
        fi
        retry 5 curl "${cargs[@]}" -o "$dest" "$url" \
            || die "Failed to download ${url}"
    fi

    [ -f "$dest" ] || die "Download did not produce ${dest}"
    verify_sha256 "$dest" "$expected_sha"
}
