# one-kvm-build

把 **ophub 的 Armbian 盒子镜像**、**OpenNexusCN/rk-linux-6.18.y 内核** 和
**One-KVM 的 arm64 deb** 组合成可直接烧录的板子镜像，全部构建过程运行在
GitHub Actions，并把结果发布到 GitHub Releases。

当前适配 **FMX1 Pro（RK3399）A/B 两个硬件版本**；后续新增板子只需要增加
`boards/<id>.conf`，镜像内部结构不同的平台再增加一个 family 脚本。

## 产物

每次构建创建一个 release，tag 与标题为：

```text
V<年月日时分秒>          例如 V20261108181345
```

镜像命名遵循 Armbian/ophub 的风格，并在发行版代号后插入 `-onekvm`，
内核版本替换为新内核，例如：

```text
Armbian_26.11.0_rockchip_fmx1-pro_noble-onekvm_6.18.60-otgfix+_server_2026.11.02.img.gz
Armbian_26.11.0_rockchip_fmx1-pro-b_noble-onekvm_6.18.60-otgfix+_server_2026.11.02.img.gz
```

每个 release 包含：

- `<镜像>.img.gz`（可通过输入改成 `.xz` / `.zst`）
- `<镜像>.img.gz.sha256`
- `manifest-<board>.json`：板子、内核、基础镜像、One-KVM 版本与构建信息
- `SHA256SUMS`：所有镜像的汇总校验

## 构建流程

```text
prepare ──> kernel ──> build (matrix: 每个板子一个 job) ──> release
```

1. **prepare**：校验板子配置；解析基础镜像、内核 release、One-KVM release；
   生成 board matrix 和统一的版本号。
2. **kernel**：下载内核 release 的 `Image-*`、DTB、config、System.map；
   如果 release 没有 `modules-*.tar.gz`，按同一源码 tag 和 config 重编译
   模块（One-KVM 的 USB gadget 依赖模块）。
3. **build**：解压基础镜像 → 扩容 rootfs → 挂载 → 替换内核/DTB/modules →
   重建 initramfs → 安装 One-KVM deb → 应用 components → 压缩校验。
4. **release**：汇总所有镜像，生成 release notes 与 SHA256SUMS，
   创建 `V<年月日时分秒>` release。

更完整的说明见：

- [docs/architecture.md](docs/architecture.md)
- [docs/adding-a-board.md](docs/adding-a-board.md)
- [docs/troubleshooting.md](docs/troubleshooting.md)
- 仓库根目录的 `流程.txt`（最初的手工流程记录）

## 在 GitHub Actions 里构建

推送仓库后：

```text
Actions -> Build One-KVM images -> Run workflow
```

可填参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `boards` | `all` | `all` 或逗号分隔的板子 id |
| `kernel_release` | `latest` | 内核 release tag（`V...`）或 `latest` |
| `one_kvm_repo` | 空 | 覆盖 One-KVM 仓库，默认取 `config/defaults.conf` 的 `ONE_KVM_REPO` |
| `one_kvm_release` | `latest` | One-KVM release tag 或 `latest` |
| `one_kvm_wait_minutes` | `30` | 等待 One-KVM release 出现 arm64 deb 的分钟数 |
| `compress` | `gz` | `gz` / `xz` / `zst` |
| `create_release` | `true` | 是否创建 GitHub Releases |

工作流也支持 `push`（仅 workflow 自身变更时触发）和
`repository_dispatch`（`kernel-release`、`one-kvm-release`），方便以后由
内核/One-KVM 仓库自动触发。

## 本地构建

需要 Linux、root（loop device 和 mount）、`qemu-user-static`、
`u-boot-tools`、`kmod`、`e2fsprogs`、`jq`、`python3`：

```bash
# 校验配置
make validate
make list

# 只生成构建计划（需要 GitHub API；建议 export GH_TOKEN）
make plan BOARDS=fmx1-pro

# 构建单个板子
sudo -E make build BOARD=fmx1-pro

# 构建所有启用的板子
sudo -E make build-all
```

本地构建会自行解析基础镜像、内核 release 和 One-KVM release；如果只是
调试镜像替换流程，可以复用已经下载的内核 bundle：

```bash
sudo -E bash scripts/build-image.sh \
  --board fmx1-pro \
  --kernel-bundle /path/to/kernel-bundle \
  --skip-one-kvm \
  --keep-work
```

## 板子

| id | SoC | 基础镜像 | DTB | 说明 |
|---|---|---|---|---|
| `fmx1-pro` | RK3399 | ophub Armbian noble `fmx1-pro` | `rk3399-fmx1-pro-otg.dtb` | A 板，USB-C 作为 OTG peripheral |
| `fmx1-pro-b` | RK3399 | ophub Armbian noble `fmx1-pro-b` | `rk3399-fmx1-pro-otg.dtb` | B 板，暂无 B 专用 OTG DTS |

板子配置在 `boards/*.conf`，全局默认在 `config/defaults.conf`。

## 关键设计

### 1. 内核模块必须匹配

当前内核 release 只有 `Image-*`、DTB、config、System.map。One-KVM 依赖
`CONFIG_USB_CONFIGFS=m` 等模块，而基础镜像自带的
`/lib/modules/6.18.59-ophub` 无法加载到新内核上。

`kernel` 作业会在需要时按 release tag 浅克隆内核源码，使用 release 的
`config-*`，并通过 `localversion` 文件精确复现 `Image-*` 文件名里的版本
（例如 `6.18.60-otgfix+`），然后编译模块、校验 `vermagic`、打包。
如果以后内核 workflow 直接发布 modules 资产，这一步自动跳过。

### 2. 同时更新 boot.scr 与 extlinux

ophub 的 Rockchip 镜像同时提供：

- `boot.scr`：读取 `armbianEnv.txt` 的 `fdtfile`，加载 `/Image`、`/uInitrd`；
- `extlinux/extlinux.conf`：distro-boot 的备用路径。

构建脚本会同时更新两者的 FDT、kernel、initrd，避免某条启动路径仍指向
旧设备树。

### 3. initramfs 在目标 rootfs 内重建

使用 `qemu-user-static` + binfmt_misc，在 chroot 里运行
`update-initramfs -c -k <ver>`，保证 initramfs 里的模块与新内核一致；
再用 `mkimage -T ramdisk` 生成 U-Boot 需要的 `uInitrd`。

### 4. 多板子与特殊组件

- `SOC_FAMILY` 选择 `scripts/families/<family>.sh`，平台差异集中在这里；
- `components/common/` 和 `components/<board-id>/` 可以放 rootfs/boot
  overlay 以及安装前后 hook，适合后续加入 u-boot blob、固件、udev 规则、
  板子专属服务等；
- 详见 `components/README.md`。

### 5. 版本与可追溯性

- release tag 为 `V$(TZ=Asia/Shanghai date +%Y%m%d%H%M%S)`；
- 一次构建内所有板子共用同一个版本号和同一组内核/One-KVM 输入；
- 镜像内 `/etc/one-kvm-build/build.json` 记录板子、内核、基础镜像、
  One-KVM 版本和构建时间；
- 基础镜像、内核 release 资产、One-KVM deb 都做 SHA256 校验。

## 目录结构

```text
.
├── .github/workflows/build-images.yml   # GitHub Actions 工作流
├── boards/                              # 板子配置
├── components/                          # 板子/平台特殊组件
├── config/defaults.conf                 # 全局默认配置
├── scripts/
│   ├── build-image.sh                   # 单板镜像构建入口
│   ├── plan-build.sh                    # 解析输入 + 生成 matrix
│   ├── prepare-matrix.sh
│   ├── validate-boards.sh
│   ├── list-boards.sh
│   ├── families/rockchip.sh             # Rockchip 镜像内部操作
│   ├── kernel/                          # 内核 bundle 与模块重编译
│   ├── one-kvm/                         # One-KVM release 解析与安装
│   ├── release/                         # release notes
│   └── lib/                             # 公共 shell/python 工具
├── docs/
├── Makefile
└── 流程.txt
```

## One-KVM

镜像会安装 `mofeng-git/One-KVM` release 里的 `one-kvm_*_arm64.deb`
（默认要求 >= `ONE_KVM_MIN_VERSION`，即 0.2.9），并启用
`one-kvm.service`。`流程.txt` 里引用的 `zoneBen/One-KVM` fork 当前 release
只提供二进制 tar.gz、没有 deb；如果该 fork 以后提供 deb，可以通过
workflow 的 `one_kvm_repo` 输入切换。首次启动后访问：

```text
http://<设备IP>:8080
```

Armbian 默认账号 `root`，默认密码 `1234`（首次登录要求修改）。

## 烧录

1. 解压 `.img.gz`（或直接用 balenaEtcher/Rufus 写入）。
2. 写入 TF 卡或 eMMC。FMX1 可按住刷机键上电进入 MASKROM，用 RKDevTool
   写入；已有 U-Boot 时也可直接写 eMMC。
3. 首次启动 Armbian 会自动扩展分区到整块存储。

## 已知限制

- `fmx1-pro-b` 暂用 A 板的 OTG DTB；如果 B 板无法启动，可切到
  `rk3399-fmx1-pro-b.dtb`（但会失去 OTG gadget）。
- 基础镜像固定为 ophub `Armbian_noble_arm64_server_2026.11`；升级基础镜像
  需要更新板子配置里的 SHA256 和 pattern。
- GitHub release 资产体积较大（每个镜像约 1 GB 级），构建和发布耗时较长。
- `push` 触发只针对构建脚本/配置的变更；日常构建建议手动
  `workflow_dispatch`，避免无关提交触发大镜像构建。

## 参考

- [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian)
- [OpenNexusCN/rk-linux-6.18.y](https://github.com/OpenNexusCN/rk-linux-6.18.y)
- [zoneBen/One-KVM](https://github.com/zoneBen/One-KVM)
- [mofeng-git/One-KVM](https://github.com/mofeng-git/One-KVM)
