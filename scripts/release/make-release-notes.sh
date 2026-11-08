#!/usr/bin/env bash
# Generate Markdown release notes from the per-board manifests.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

DIR=""
VERSION=""
REPO="${GITHUB_REPOSITORY:-OpenNexusCN/one-kvm-build}"
RUN_ID="${GITHUB_RUN_ID:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="${2:?}"; shift 2 ;;
        --version) VERSION="${2:?}"; shift 2 ;;
        --repo) REPO="${2:?}"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ -n "$DIR" ] || die "--dir is required"
[ -d "$DIR" ] || die "Directory not found: $DIR"
require_cmd jq

shopt -s nullglob
manifests=("${DIR}"/manifest-*.json)
shopt -u nullglob
[ "${#manifests[@]}" -gt 0 ] || die "No manifest-*.json files in ${DIR}"

echo "## One-KVM 镜像 ${VERSION}"
echo
echo "基于 ophub Armbian 镜像，替换为 OpenNexusCN/rk-linux-6.18.y 内核，并预装 One-KVM。"
echo
echo "| 板子 | 镜像 | 内核 | One-KVM | 基础镜像 |"
echo "|---|---|---|---|---|"

for manifest in "${manifests[@]}"; do
    printf '| `%s` | `%s` | `%s` | `%s` | `%s` |\n' \
        "$(jq -r '.board' "$manifest")" \
        "$(jq -r '.output.name // "unknown"' "$manifest")" \
        "$(jq -r '.kernel.version' "$manifest")" \
        "$(jq -r '.one_kvm.version // "未安装"' "$manifest")" \
        "$(jq -r '.base_image.name' "$manifest")"
done

echo
echo "### 烧录说明"
echo
echo "1. 解压镜像：\`gzip -d <镜像>.img.gz\`（或使用 balenaEtcher / Rufus 直接写入）。"
echo "2. 写入 TF 卡或 eMMC。FMX1 可按住刷机键上电进入 MASKROM，使用 RKDevTool 写入。"
echo "3. 首次启动后通过串口或路由器查看设备 IP。Armbian 默认账号为 \`root\`，默认密码 \`1234\`（首次登录会要求修改）。"
echo "4. One-KVM Web 控制台：\`http://<设备IP>:8080\`。"
echo
echo "### 校验"
echo
echo '```'
if [ -f "${DIR}/SHA256SUMS" ]; then
    cat "${DIR}/SHA256SUMS"
else
    for manifest in "${manifests[@]}"; do
        name="$(jq -r '.output.name // empty' "$manifest")"
        sha="$(jq -r '.output.sha256 // empty' "$manifest")"
        if [ -n "$name" ]; then
            printf '%s  %s\n' "$sha" "$name"
        fi
    done
fi
echo '```'
echo
if [ -n "$RUN_ID" ]; then
    echo "构建运行：https://github.com/${REPO}/actions/runs/${RUN_ID}"
    echo
fi
echo "_由 one-kvm-build 自动生成_"
