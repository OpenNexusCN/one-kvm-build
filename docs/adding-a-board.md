# 新增板子

以新增一块 RK3399/RK3568/RK3588 板子为例。整个流程只需要改配置；
只有镜像内部结构完全不同（例如 Amlogic 的 `boot.scr`/`uEnv.txt` 布局）
时才需要新增 family 脚本。

## 1. 内核仓库准备 DTB

在 `OpenNexusCN/rk-linux-6.18.y` 里添加板子的 DTS，确认
`arch/arm64/boot/dts/rockchip/<board>.dtb` 会被 CI 构建并发布到 release。
当前内核 workflow 显式列出了 FMX1 的三个 DTB；新增板子时记得把它加到
`build-fmx1.yml` 的 dtb 列表里（或改成按 defconfig 构建所有 DTB）。

## 2. 找到基础镜像

从 `ophub/amlogic-s9xxx-armbian` 的 release 里找到板子对应的 Armbian 镜像，
记下：

- release tag，例如 `Armbian_noble_arm64_server_2026.11`
- 资产文件名 pattern，例如
  `Armbian_*_rockchip_<board>_noble_*_server_*.img.gz`
- SHA256（release 列表里可见；也可下载后计算）

如果希望固定到某个具体 URL，也可以直接设置 `BASE_IMAGE_URL` 和
`BASE_IMAGE_SHA256`，此时不做 GitHub release 查询。

## 3. 新建 `boards/<board-id>.conf`

```bash
BOARD_ID="<board-id>"                 # 必须与文件名一致
BOARD_NAME="<human readable name>"
BOARD_DESCRIPTION="..."
SOC_FAMILY="rockchip"                 # scripts/families/rockchip.sh
SOC="rk3399"

BASE_IMAGE_REPO="ophub/amlogic-s9xxx-armbian"
BASE_IMAGE_RELEASE="Armbian_noble_arm64_server_2026.11"
BASE_IMAGE_ASSET_PATTERN="Armbian_*_rockchip_<board>_noble_*_server_*.img.gz"
BASE_IMAGE_SHA256="<sha256>"

KERNEL_DTB="rk3399-<board>-otg.dtb"   # 内核 release 里必须存在
ONE_KVM_ENABLED="true"
```

常用可覆盖项：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `BASE_IMAGE_URL` | 空 | 直接指定镜像 URL，优先于 repo/pattern |
| `BASE_IMAGE_SHA256` | 空 | 基础镜像校验值，强烈建议填写 |
| `KERNEL_REPO` | `OpenNexusCN/rk-linux-6.18.y` | 内核 release 仓库 |
| `KERNEL_RELEASE` | `latest` | 固定内核 release tag 可写成 `V...` |
| `KERNEL_DTB` | 无 | 必须填写，脚本会校验 kernel bundle 中存在 |
| `KERNEL_MODULES_FALLBACK` | `true` | release 没有 modules 时从源码重编译 |
| `IMAGE_EXTRA_MB` | `1024` | 构建时给 rootfs 扩容的 MiB 数 |
| `PRUNE_OLD_KERNEL` | `false` | 是否删除基础镜像自带内核 |
| `ONE_KVM_ENABLED` | `true` | 是否安装 One-KVM |
| `ONE_KVM_REPO` | `zoneBen/One-KVM` | One-KVM release 仓库 |
| `ONE_KVM_ASSET_PATTERN` | `one-kvm_*_arm64.deb` | deb 资产匹配 |
| `OUTPUT_NAME_TEMPLATE` | 见 defaults | 输出文件名模板 |
| `ENABLED` | `true` | `false` 时不出现在 `--boards all` |

## 4. 如有特殊组件，添加 `components/<board-id>/`

```text
components/<board-id>/
├── rootfs/etc/...        # 覆盖到 rootfs
├── boot/...              # 覆盖到 boot 分区
├── pre-install.d/*.sh    # One-KVM 安装前执行
└── post-install.d/*.sh   # One-KVM 安装后执行
```

参考 `components/README.md`。

## 5. 校验并构建

```bash
make validate
make list
sudo -E make build BOARD=<board-id>
```

或者推送后在 Actions 里手动选择板子：

```text
Actions -> Build One-KVM images -> Run workflow
boards = <board-id>（或 all）
```

## 6. 更新文档

把新板子加到 `boards/README.md` 的表格里，并注明：

- 使用的 DTB（尤其是 OTG/peripheral 模式）；
- 基础镜像版本；
- 已知限制（例如 B 板暂无 OTG DTS）。

## 7. 非 Rockchip 平台

如果板子不是 Rockchip/ophub 布局：

1. 新增 `scripts/families/<family>.sh`，实现 `build-image.sh` 调用的函数：
   `family_inspect_image`、`family_grow_image`、`family_mount_image`、
   `family_install_kernel`、`family_configure_boot`、`family_create_initrd`、
   `family_configure_system`、`family_cleanup`。
2. 在板子配置里设置 `SOC_FAMILY="<family>"`。
3. 如果开机配置是 `uEnv.txt`/`boot.scr`，在 family 里按相应格式更新 FDT
   和 initrd。
