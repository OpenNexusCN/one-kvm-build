#!/usr/bin/env bash
# Offline checks for the build tooling.  No network, no root required.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0

check() {
    local name="$1"
    shift
    if "$@"; then
        printf 'ok   %s\n' "$name"
        pass=$((pass + 1))
    else
        printf 'FAIL %s\n' "$name"
        fail=$((fail + 1))
    fi
}

check "shell syntax" bash -c '
    set -e
    for f in $(find scripts -type f -name "*.sh"); do bash -n "$f"; done
    bash -n files/wifi-ap/onekvm-ap-init.sh
'
check "wifi-ap templates" bash -c '
    test -f files/wifi-ap/onekvm-wifi-ap.service
    test -f files/wifi-ap/unit-after.conf
    test -f files/wifi-ap/networkmanager-unmanaged.conf
'
check "python syntax" python3 -m py_compile scripts/lib/release_tool.py scripts/lib/extlinux_patch.py
check "board validation" bash scripts/validate-boards.sh
check "matrix selection" bash -c '
    out="$(bash scripts/prepare-matrix.sh --boards fmx1-pro)"
    printf "%s" "$out" | jq -e "length == 1 and .[0].board == \"fmx1-pro\" and .[0].config == \"boards/fmx1-pro.conf\"" >/dev/null
'
check "matrix all" bash -c '
    out="$(bash scripts/prepare-matrix.sh --boards all)"
    printf "%s" "$out" | jq -e "length >= 2" >/dev/null
'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"${tmp}/releases.json" <<'JSON'
[
  {
    "tag_name": "V20260101000000",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "Image-6.18.60-otgfix+", "browser_download_url": "https://example.invalid/Image", "digest": "sha256:aa"},
      {"name": "config-6.18.60-otgfix+", "browser_download_url": "https://example.invalid/config", "digest": "sha256:bb"},
      {"name": "rk3399-fmx1-pro-otg.dtb", "browser_download_url": "https://example.invalid/dtb", "digest": "sha256:cc"},
      {"name": "SHA256SUMS", "browser_download_url": "https://example.invalid/sums", "digest": null}
    ]
  },
  {
    "tag_name": "V20251201000000",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"name": "Image-6.18.59", "browser_download_url": "https://example.invalid/old", "digest": null}
    ]
  }
]
JSON

check "release selection" bash -c "
    python3 -I scripts/lib/release_tool.py select-latest \
        --tag-pattern 'V*' --require 'Image-*' --require '*.dtb' \
        < '${tmp}/releases.json' \
    | jq -e '.tag_name == \"V20260101000000\"' >/dev/null
"

check "asset selection" bash -c "
    jq '.[0]' '${tmp}/releases.json' \
    | python3 -I scripts/lib/release_tool.py select-asset --pattern '*.dtb' \
    | jq -e '.name == \"rk3399-fmx1-pro-otg.dtb\"' >/dev/null
"

check "ambiguous asset rejected" bash -c "
    ! jq '.[0]' '${tmp}/releases.json' \
    | python3 -I scripts/lib/release_tool.py select-asset --pattern '*' >/dev/null 2>&1
"

cat >"${tmp}/extlinux.conf" <<'EOF'
LABEL Armbian
  LINUX /Image
  INITRD /uInitrd
  FDT /dtb/rockchip/rk3399-old.dtb
  APPEND root=UUID=test rootwait
EOF
python3 -I scripts/lib/extlinux_patch.py \
    --file "${tmp}/extlinux.conf" \
    --kernel /Image \
    --fdt /dtb/rockchip/rk3399-new.dtb \
    --initrd /uInitrd
check "extlinux patch" grep -q 'FDT /dtb/rockchip/rk3399-new.dtb' "${tmp}/extlinux.conf"
check "extlinux backup" test -f "${tmp}/extlinux.conf.orig"

mkdir -p "${tmp}/ap-root"
check "wifi-ap build install" bash -c "
    bash scripts/features/wifi-ap.sh \
        --root '${tmp}/ap-root' \
        --ssid-prefix OneKVM- \
        --hash-length 6 \
        --security open \
        --country CN \
        --channel 6 \
        --ip 192.168.4.1 \
        --portal-port 8080
    test -f '${tmp}/ap-root/etc/one-kvm-wifi/ap.env'
    test -x '${tmp}/ap-root/usr/local/sbin/onekvm-ap-init'
    grep -q 'OneKVM-' '${tmp}/ap-root/etc/one-kvm-wifi/ap.env'
"
check "wifi-ap rejects bad security" bash -c "
    ! bash scripts/features/wifi-ap.sh --root '${tmp}/ap-root' --security nope >/dev/null 2>&1
"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
