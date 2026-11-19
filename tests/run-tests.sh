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
    for f in $(find scripts components -type f -name "*.sh" 2>/dev/null); do bash -n "$f"; done
    bash -n files/wifi-ap/onekvm-ap-init.sh
    bash -n files/iso-fix/onekvm-iso-fix.sh
'
check "iso-fix script sync" cmp -s docs/iso-fix/onekvm-iso-fix.sh files/iso-fix/onekvm-iso-fix.sh
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
check "matrix nanopc-t4" bash -c '
    out="$(bash scripts/prepare-matrix.sh --boards nanopc-t4)"
    printf "%s" "$out" | jq -e "length == 1 and .[0].board == \"nanopc-t4\" and .[0].config == \"boards/nanopc-t4.conf\"" >/dev/null
'
check "nanopc-t4 kernel dtb config" bash -c '
    source config/defaults.conf
    source boards/nanopc-t4.conf
    [ "$KERNEL_DTB" = "rk3399-nanopc-t4-otg.dtb" ]
    [ "$KERNEL_DTB_FROM_BASE_IMAGE" = "false" ]
    [ "$BASE_IMAGE_SHA256" = "8857b0ad5a3df28d0bda10bc13b2c71b9543b735d408fa09da9d86b8f23f1bb0" ]
'
check "dtb fallback helper" bash -c '
    source scripts/families/rockchip.sh
    d="$(mktemp -d)"
    touch "$d/bundle.dtb" "$d/boot.dtb"
    _dtb_available "$d/bundle.dtb" "$d/missing.dtb" false
    _dtb_available "$d/bundle.dtb" "$d/boot.dtb" true
    _dtb_available "$d/missing.dtb" "$d/boot.dtb" true
    ! _dtb_available "$d/missing.dtb" "$d/boot.dtb" false
    ! _dtb_available "$d/missing.dtb" "$d/missing.dtb" true
    rm -rf "$d"
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
      {"name": "Armbian_26.11.0_rockchip_test_noble_6.18.59_server_2026.11.02.img.gz", "browser_download_url": "https://example.invalid/base-old", "digest": "sha256:aaaa"},
      {"name": "Armbian_26.11.0_rockchip_test_noble_6.18.63_server_2026.11.14.img.gz", "browser_download_url": "https://example.invalid/base-new", "digest": "sha256:bbbb"},
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
check "asset selection by digest" bash -c "
    jq '.[0]' '${tmp}/releases.json' \
    | python3 -I scripts/lib/release_tool.py select-asset \
        --pattern 'Armbian_*' --sha256 'sha256:bbbb' \
    | jq -e '.name == \"Armbian_26.11.0_rockchip_test_noble_6.18.63_server_2026.11.14.img.gz\"' >/dev/null
"
check "unknown digest rejected" bash -c "
    ! jq '.[0]' '${tmp}/releases.json' \
    | python3 -I scripts/lib/release_tool.py select-asset \
        --pattern 'Armbian_*' --sha256 'sha256:deadbeef' >/dev/null 2>&1
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
        --ip 10.42.0.1 \
        --portal-port 8080
    test -f '${tmp}/ap-root/etc/one-kvm-wifi/ap.env'
    test -x '${tmp}/ap-root/usr/local/sbin/onekvm-ap-init'
    grep -q 'OneKVM-' '${tmp}/ap-root/etc/one-kvm-wifi/ap.env'
"
check "wifi-ap rejects bad security" bash -c "
    ! bash scripts/features/wifi-ap.sh --root '${tmp}/ap-root' --security nope >/dev/null 2>&1
"

mkdir -p "${tmp}/iso-fix-root/usr/lib/modules/6.18.60-test/kernel/fs/udf" \
         "${tmp}/iso-fix-root/usr/lib/modules/6.18.60-test/kernel/fs/isofs"
: >"${tmp}/iso-fix-root/usr/lib/modules/6.18.60-test/kernel/fs/udf/udf.ko"
: >"${tmp}/iso-fix-root/usr/lib/modules/6.18.60-test/kernel/fs/isofs/isofs.ko"
cat >"${tmp}/kconfig-udf" <<'EOF'
CONFIG_ISO9660_FS=m
CONFIG_UDF_FS=m
EOF
cat >"${tmp}/kconfig-noudf" <<'EOF'
# CONFIG_UDF_FS is not set
CONFIG_ISO9660_FS=y
EOF
check "iso-fix build install" bash -c "
    bash scripts/features/iso-fix.sh \
        --root '${tmp}/iso-fix-root' \
        --skip-deps-check \
        --kernel-config '${tmp}/kconfig-udf'
    test -x '${tmp}/iso-fix-root/usr/local/sbin/onekvm-iso-fix'
    test -L '${tmp}/iso-fix-root/usr/local/sbin/onekvm-iso-fix.sh'
    test -f '${tmp}/iso-fix-root/usr/share/doc/onekvm-iso-fix/README.md'
"
check "iso-fix rejects kernel without udf" bash -c "
    ! bash scripts/features/iso-fix.sh \
        --root '${tmp}/iso-fix-root' \
        --skip-deps-check \
        --kernel-config '${tmp}/kconfig-noudf' >/dev/null 2>&1
"
check "iso-fix allows kernel without udf when optional" bash -c "
    bash scripts/features/iso-fix.sh \
        --root '${tmp}/iso-fix-root' \
        --skip-deps-check \
        --require-udf false \
        --kernel-config '${tmp}/kconfig-noudf'
"

mkdir -p "${tmp}/android-root"
check "android tools install" bash -c "
    bash scripts/features/android-tools.sh \
        --root '${tmp}/android-root' \
        --skip-deps-check
    test -x '${tmp}/android-root/usr/local/bin/scrcpy'
    test -f '${tmp}/android-root/usr/local/share/scrcpy/scrcpy-server'
    test \"\$(sha256sum '${tmp}/android-root/usr/local/bin/scrcpy' | cut -d' ' -f1)\" = \
        '4fd97fd1134fd74b01c300e5b5c7f79121f278b719fef1e7fe179dc8692728c9'
"
check "android tools reject tampered client" bash -c "
    cp -a 3rd/scrcpy-3.3-aarch64 '${tmp}/tampered-scrcpy'
    printf 'x' >> '${tmp}/tampered-scrcpy/scrcpy'
    ! bash scripts/features/android-tools.sh \
        --root '${tmp}/android-root2' \
        --source '${tmp}/tampered-scrcpy' \
        --skip-deps-check >/dev/null 2>&1
"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
