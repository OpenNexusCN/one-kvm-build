# 架构说明

## 目标

把 ophub 的 Armbian 盒子镜像、OpenNexusCN 的内核和 One-KVM 的 deb
组合成可直接烧录的板子镜像，并把“板子差异”限制在配置文件和少量脚本里，
方便后续增加新板子。

流程参考仓库根目录的 `流程.txt`：

1. 从 `ophub/amlogic-s9xxx-armbian` release 下载 FMX1 的 Armbian 镜像。
2. 用 `OpenNexusCN/rk-linux-6.18.y` release 里的 `Image-*` 和
   `rk3399-fmx1-pro-otg.dtb` 替换镜像里的内核与设备树。
3. 安装 `zoneBen/One-KVM` release 里的 `one-kvm_*_arm64.deb`。
4. 输出形如
   `Armbian_26.11.0_rockchip_fmx1-pro_noble-onekvm_6.18.60-otgfix+_server_2026.11.02.img.gz`
   的镜像。

## GitHub Actions 作业图

```
prepare ──> kernel ──> build (matrix: 每个板子一个 job) ──> release
```

| 作业 | 作用 | 主要脚本 |
|---|---|---|
| `prepare` | 校验板子配置；解析基础镜像、内核 release、One-KVM release；生成 matrix、版本号和发布参数 | `scripts/plan-build.sh` |
| `kernel` | 下载内核 release 产物；缺少 modules 时从同一源码 tag 和 config 重编译模块；上传 `kernel-bundle` | `scripts/kernel/prepare-kernel.sh`、`scripts/kernel/build-modules.sh` |
| `build` | 每个板子独立运行：解压基础镜像、挂载、替换内核/DTB/modules、重建 initramfs、安装 One-KVM、应用 components、压缩并校验 | `scripts/build-image.sh`、`scripts/families/rockchip.sh`、`scripts/one-kvm/install-one-kvm.sh` |
| `release` | 汇总所有镜像，生成 SHA256SUMS 和 release notes，创建 `V<年月日时分秒>` release | `scripts/release/make-release-notes.sh` |

所有作业共享 `prepare` 解析出的版本号，因此一次构建里的所有板子产物
属于同一个 release tag。

## 为什么需要重编译内核模块

当前内核 workflow 默认只构建 `Image`、DTB、config 和 System.map，
release 里没有 `modules-*.tar.gz`。而 One-KVM 依赖的 USB gadget
选项（例如 `CONFIG_USB_CONFIGFS=m`）是模块，旧镜像里的
`/lib/modules/6.18.59-ophub` 也无法在新内核上加载。

因此 `kernel` 作业在找不到 modules 资产时会：

1. 按 release tag 浅克隆内核源码（tag 指向构建该 Image 的 commit）；
2. 复制 release 的 `config-*`；
3. 把 release 字符串后缀写入 `localversion` 文件，清空
   `CONFIG_LOCALVERSION`，并设置 `LOCALVERSION=""`，让内核版本精确等于
   `Image-*` 文件名里的版本（例如 `6.18.60-otgfix+`）；
4. `make modules_prepare && make modules && make modules_install`；
5. 用 `modinfo -F vermagic` 验证模块 vermagic 与 Image 完全一致；
6. 打包成与内核 release 相同布局的 `modules-<ver>.tar.gz`。

如果以后内核 workflow 直接发布 modules 资产，这个 fallback 会自动跳过。

## 镜像启动流程（Rockchip / ophub）

ophub 的 FMX1 镜像有两个 ext4 分区：

- 分区 1：`BOOT`，包含 `Image`、`uInitrd`、`dtb/rockchip/*.dtb`、
  `armbianEnv.txt`、`boot.scr`、`extlinux/extlinux.conf`；
- 分区 2：`ROOTFS`，包含 `/usr/lib/modules/<ver>` 等。

U-Boot 的 `boot.scr` 会读取 `armbianEnv.txt` 的 `fdtfile`，加载
`/Image`、`/uInitrd`、`/dtb/<fdtfile>`；同时镜像也提供
`extlinux/extlinux.conf` 作为 distro-boot 路径。构建脚本会同时更新：

- `/boot/Image`（真实文件）和 `/boot/Image-<ver>`、`vmlinuz-<ver>`；
- `/boot/dtb/rockchip/<new dtb>`；
- `/boot/armbianEnv.txt` 的 `fdtfile=rockchip/<new dtb>`；
- `/boot/extlinux/extlinux.conf` 的 `LINUX /Image`、`FDT ...`、`INITRD /uInitrd`；
- `/boot/uInitrd` 和 `/boot/uInitrd-<ver>`（`mkimage -T ramdisk`）。

initramfs 在 chroot 里用目标 rootfs 的 `update-initramfs -c -k <ver>`
重建（qemu-user-static + binfmt_misc），保证它和新内核模块匹配。

## 多板子兼容设计

### 板子配置

每个板子一个 `boards/<id>.conf`，只描述差异：

```bash
BOARD_ID="fmx1-pro"
BOARD_NAME="FMX1 Pro (A board)"
SOC_FAMILY="rockchip"
SOC="rk3399"
BASE_IMAGE_REPO="ophub/amlogic-s9xxx-armbian"
BASE_IMAGE_RELEASE="Armbian_noble_arm64_server_2026.11"
BASE_IMAGE_ASSET_PATTERN="Armbian_*_rockchip_fmx1-pro_noble_*_server_*.img.gz"
BASE_IMAGE_SHA256="..."
KERNEL_DTB="rk3399-fmx1-pro-otg.dtb"
ONE_KVM_ENABLED="true"
```

`config/defaults.conf` 放全局默认值（内核仓库、One-KVM 仓库、输出命名、
压缩格式、是否扩容等），板子文件覆盖它。

### 平台 family

镜像内部结构因 SoC 平台而异。`SOC_FAMILY` 决定加载
`scripts/families/<family>.sh`。当前实现 `rockchip`，负责：

- 通过 GPT 和文件系统探测 boot/root 分区；
- 可选扩容 root 分区（`IMAGE_EXTRA_MB`）；
- 安装内核/DTB/modules；
- 更新 extlinux 和 armbianEnv；
- 重建 initramfs。

未来增加 Amlogic/Allwinner 板子时，新增一个 family 文件，实现同名函数即可，
主流程 `scripts/build-image.sh` 不需要修改。

### components

`components/common/` 和 `components/<board-id>/` 用于放置特殊组件：
rootfs/boot overlay、安装前后 hook。适合放 u-boot blob、固件、udev 规则、
板子专属 systemd 服务等。详见 `components/README.md`。

### 新增板子的完整流程

见 `docs/adding-a-board.md`。

## 版本与发布

- 版本号：`V$(TZ=Asia/Shanghai date +%Y%m%d%H%M%S)`，由 `prepare` 作业
  生成一次，所有板子共用。
- 每次构建创建一个 GitHub release，tag/title 都是 `V<年月日时分秒>`。
- 资产：每个板子的 `.img.gz`（或 xz/zst）、对应 `.sha256`、
  `manifest-<board>.json`、汇总的 `SHA256SUMS`。
- 输出文件名模板在 `config/defaults.conf` 的 `OUTPUT_NAME_TEMPLATE`，
  支持 `{armbian_version}`、`{platform}`、`{board}`、`{codename}`、
  `{kernel}`、`{onekvm_version}`、`{base_date}` 等占位符。

## 安全与可重复性

- 基础镜像按板子配置里的 SHA256 校验；内核 release 用 release 的
  `SHA256SUMS` 和 GitHub asset digest 双重校验；One-KVM deb 使用
  release asset digest 校验。
- 内核/基础镜像/One-KVM 的版本在 `prepare` 阶段固定，写进构建计划，
  所有板子使用同一组输入。
- 构建脚本要求 root（loop device 和 mount），CI 通过 `sudo -E` 调用；
  chroot 使用清空后的环境，不向目标系统泄露 GitHub token。
- 产物内写入 `/etc/one-kvm-build/build.json`，记录板子、内核、基础镜像、
  One-KVM 版本和构建时间，便于追溯。
