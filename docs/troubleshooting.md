# 故障排查

## `prepare` 找不到 One-KVM release

现象：

```text
No zoneBen/One-KVM release (latest) with asset matching one-kvm_*_arm64.deb
```

原因：One-KVM 的 release 还在构建，或者最新 release 没有 arm64 deb。

处理：

- 等待 One-KVM 构建完成，然后重新运行 workflow；
- 或者把 `one_kvm_wait_minutes` 调大（workflow_dispatch 输入）；
- 或者指定一个已有 arm64 deb 的 release tag。

## One-KVM release 版本过旧

现象：

```text
Release v260125 provides 0.1.x, older than 0.2.9; waiting
No zoneBen/One-KVM release (latest) with one-kvm_*_arm64.deb >= 0.2.9
```

`zoneBen/One-KVM` 上仍有旧的 Python 版本 release。构建默认要求
`ONE_KVM_MIN_VERSION=0.2.9`，会跳过这些旧版本。等新的 Rust 0.2.9
release 构建完成后重跑，或者在 workflow 里把 `one_kvm_repo` 设为
`mofeng-git/One-KVM`（上游已有 v261101 / 0.2.9）。

## 内核 release 没有 modules

现象：

```text
Release V... has no modules asset; rebuilding modules from V...
```

这是预期行为。`kernel` 作业会按 release tag 克隆内核源码、使用 release
的 config 重编译模块，并验证 vermagic。需要跨编译工具链
（`gcc-aarch64-linux-gnu`），workflow 已经安装。

如果想加快构建，可以在内核仓库的 workflow 里把 `build_modules` 设为
`true` 并重新发布 release；之后这里会自动使用 release 里的 modules。

## 模块 vermagic 不匹配

现象：

```text
Module vermagic '6.18.60-otgfix' does not match expected '6.18.60-otgfix+'
```

原因：release 的 `Image-*` 文件名里的版本后缀（例如 `-otgfix+`）没有
被精确复现。`build-modules.sh` 通过 `localversion` 文件、清空
`CONFIG_LOCALVERSION` 和 `LOCALVERSION=""` 来固定版本；如果内核源码的
版本计算方式变化，检查：

```bash
cd <ksrc>
make -s kernelrelease
```

并确认 `localversion` 文件内容等于 `Image-<ver>` 去掉基础版本后的后缀。

## `update-initramfs` 失败 / qemu 报 `Exec format error`

现象：

```text
Failed to regenerate initramfs for 6.18.60-otgfix+
```

检查：

```bash
ls /proc/sys/fs/binfmt_misc/qemu-aarch64
```

CI 的依赖安装步骤会安装 `qemu-user-static` 和 `binfmt-support`，并执行
`update-binfmts --enable qemu-aarch64` 和
`systemctl restart systemd-binfmt`。本地构建需要同样安装并启用。

如果确实无法重建 initramfs，可以临时设置 `REQUIRE_INITRD_REGEN=false`
让构建保留基础镜像的 initrd；这可能导致新内核无法挂载 rootfs，不建议
用于发布。

## rootfs 空间不足

现象：

```text
Not enough space in root filesystem
```

处理：

- 增大板子配置里的 `IMAGE_EXTRA_MB`（默认 1024），构建脚本会扩容 root
  分区并 `resize2fs`；
- 或者设置 `PRUNE_OLD_KERNEL=true` 删除基础镜像自带内核，释放空间；
- 或减少不需要的组件。

## B 板无法启动 / Type-C 不识别

`fmx1-pro-b` 目前使用 `rk3399-fmx1-pro-otg.dtb`。如果某块 B 板启动异常，
把 `boards/fmx1-pro-b.conf` 的 `KERNEL_DTB` 改成
`rk3399-fmx1-pro-b.dtb` 验证。注意该 DTB 没有开启 OTG peripheral，
One-KVM 的 USB gadget 可能不可用；长期方案是在内核仓库新增 B 板的
OTG DTS。

## GitHub API rate limit

`prepare` 作业使用 `GITHUB_TOKEN`，限额足够。本地运行 `make plan` 或
`make build` 时如果出现 `API rate limit exceeded`，设置一个 token：

```bash
export GH_TOKEN="$(gh auth token)"   # 或手动创建 PAT
```

## Release tag 已存在

版本号精确到秒。如果同一秒内重复发布（极少见），重新运行 workflow 即可
得到新的 `V<年月日时分秒>`。
