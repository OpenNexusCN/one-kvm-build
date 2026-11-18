# 故障排查

## `prepare` 找不到 One-KVM release

现象：

```text
No mofeng-git/One-KVM release (latest) with asset matching one-kvm_*_arm64.deb
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
No mofeng-git/One-KVM release (latest) with one-kvm_*_arm64.deb >= 0.2.9
```

构建默认使用 `zoneBen/One-KVM`，要求 `ONE_KVM_MIN_VERSION=0.2.9`。该 fork
的 CI 会先上传 tar.gz，再上传 deb；构建计划会轮询等待
`one-kvm_*_arm64.deb` 出现（`one_kvm_wait_minutes`，默认 60 分钟）。
如果该 release 暂时只有 tar.gz，可以：

- 等 deb 上传完成后重跑；
- 或者把 workflow 的 `one_kvm_repo` 设为 `mofeng-git/One-KVM`，使用上游
  0.2.9 deb。

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

## Windows 镜像只看到 README.TXT / 缺少介质驱动程序

现象：通过 One-KVM 虚拟光驱挂载某些重打包的 Windows ISO，客户机里只看到
`README.TXT`，或者 Windows Setup 报“缺少计算机所需的介质驱动程序”。

原因：这些镜像的 ISO9660 层是空壳，真实文件都在 UDF 分区里，而虚拟光驱
不向 Windows 暴露 UDF。镜像已内置修复工具：

```bash
onekvm-iso-fix -n /etc/one-kvm/msd/images/xxx.iso     # 先检测
onekvm-iso-fix --replace /etc/one-kvm/msd/images/xxx.iso
```

转换后会在同目录生成 `*_joliet.iso`（`--replace` 会把原文件改名为
`.orig-udfonly`）。随后在 One-KVM 网页里重新选择新镜像并“连接”，
再重启被控机（WinPE 缓存了“没有安装介质”，返回再点是没用的）。
完整说明见镜像内的 `/usr/share/doc/onekvm-iso-fix/README.md`。

如果命令不存在，检查构建时是否设置了 `ISO_FIX_ENABLED=false`；
如果提示缺少 `xorriso` / `isoinfo` / `udfinfo`，确认镜像里有
`xorriso`、`genisoimage`、`udftools` 三个包。

## 构建失败：内核缺少 UDF 支持

现象：

```text
Kernel cannot mount UDF; onekvm-iso-fix would not be able to fix UDF-only ISOs
```

原因：内核 release 的 `config-*` 里没有 `CONFIG_UDF_FS=y`，或者它是
`=m` 但模块包里面没有 `udf.ko`。修复工具需要 UDF 才能读取空壳镜像的
真实内容。

处理：

- 在内核仓库打开 `CONFIG_UDF_FS`（`=y` 或 `=m`）并重新发布内核；
- 或临时设置 `ISO_FIX_REQUIRE_UDF=false` 让构建继续（工具只能处理
  ISO9660 树完整的镜像）。

## B 板无法启动 / Type-C 不识别

`fmx1-pro-b` 目前使用 `rk3399-fmx1-pro-otg.dtb`。如果某块 B 板启动异常，
把 `boards/fmx1-pro-b.conf` 的 `KERNEL_DTB` 改成
`rk3399-fmx1-pro-b.dtb` 验证。注意该 DTB 没有开启 OTG peripheral，
One-KVM 的 USB gadget 可能不可用；长期方案是在内核仓库新增 B 板的
OTG DTS。

## Wi-Fi AP 没有启动

检查：

```bash
systemctl status onekvm-wifi-ap hostapd dnsmasq lighttpd
journalctl -u onekvm-wifi-ap -b --no-pager
dmesg | grep -i brcmfmac
iw dev
cat /etc/one-kvm-wifi/runtime.env
ls /etc/one-kvm-wifi/no-wifi
```

常见原因：

- 板子没有无线网卡：初始化服务会创建 `/etc/one-kvm-wifi/no-wifi`，
  hostapd/dnsmasq/lighttpd 的 drop-in 会跳过；这是预期行为。
- 驱动/firmware 缺失：确认新内核模块里有 `brcmfmac.ko`，且
  `/lib/firmware/brcm` 下有对应芯片的 firmware。可以通过 `apt_packages`
  额外安装 `firmware-brcm80211`。
- 接口被其他工具占用：镜像已经通过 NetworkManager/systemd-networkd 的
  unmanaged 配置和 wpa_supplicant drop-in 避免冲突；如果手动改过网络配置，
  检查 `nmcli device status` 和 `systemctl status wpa_supplicant`。
- hostapd 驱动错误：查看 `journalctl -u hostapd`，确认芯片/驱动支持 AP
  模式；可以尝试把 `WIFI_AP_INTERFACE` 指定为实际接口。

## 强制门户没有跳转

- 确认 AP 客户端拿到了 10.42.0.x 地址：`ip addr` / DHCP 租约。
- 在客户端访问 `http://10.42.0.1/`，应返回 302 到
  `http://10.42.0.1:8080/`；如果失败，检查 lighttpd 是否绑定在
  `10.42.0.1:80`。
- `dnsmasq` 必须监听 10.42.0.1:53，且配置了
  `address=/#/10.42.0.1`；用 `dig @10.42.0.1 example.com` 验证。
- 强制门户依赖 HTTP/DNS，不拦截 HTTPS；用浏览器打开任意 HTTP 页面，
  或直接访问 `http://10.42.0.1:8080/`。
- 如果 One-KVM 改了端口，同步修改 `WIFI_AP_PORTAL_PORT` 并重新构建。

## 忘记 Wi-Fi 密码

WPA2 模式首次启动会生成密码，写入：

```text
/boot/one-kvm-wifi.txt
/etc/one-kvm-wifi/password
```

也可以在串口/SSH 登录后查看。默认是开放网络时没有密码。

## APT 安装失败

- 检查 workflow 的 `apt_packages` 输入和板子 `APT_PACKAGES`：只支持普通
  包名，不支持 `pkg=version`；空格分隔。
- 构建日志里的 `apt-get update` 需要 chroot 内可用的 DNS。基础镜像的
  `/etc/resolv.conf` 是 systemd-resolved 的符号链接，脚本会在安装期间
  临时替换并在结束后恢复。
- 如果某个包不存在或源不可用，构建会失败；先在本地/容器里确认
  `apt-get install -y <包名>` 可用。
- 安装过程使用 `policy-rc.d` 阻止服务在 chroot 内启动；如果看到
  “policy-rc.d denied execution”，这是预期行为。

## 构建计划失败：基础镜像资产有歧义

现象：

```text
Cannot select base image asset Armbian_*_rockchip_fmx1-pro_noble_*_server_*.img.gz
asset pattern 'Armbian_*_rockchip_fmx1-pro_noble_*_server_*.img.gz' is ambiguous
in release 'Armbian_noble_arm64_server_2026.11': ...6.18.59..., ...6.18.63...
```

原因：上游在同一个基础镜像 release 里追加了刷新后的镜像（例如 2026-11-14
增加的 6.18.63 版本），板子配置的 asset 通配符同时命中多个文件。

处理：板子配置里的 `BASE_IMAGE_SHA256` 就是目标镜像的摘要，解析器会用它
在匹配项中按 asset `digest` 精确选择。如果仍然失败，检查该 SHA256 是否
等于 release 中某个 asset 的 `digest`，或者把
`BASE_IMAGE_ASSET_PATTERN` 收窄到具体文件名。

## adb 看不到手机

检查：

```bash
adb devices
lsusb
command -v scrcpy
scrcpy --version
```

- 手机需要开启“开发者选项 → USB 调试”，并在弹窗中允许本机调试。
- 使用数据线而不是纯充电线，必要时更换 USB 口/线。
- `android-sdk-platform-tools-common` 提供 USB udev 规则，确认已安装：
  `dpkg -l android-sdk-platform-tools-common`。
- One-KVM 服务以 root 运行 adb，不需要额外的用户组配置。

## scrcpy 崩溃 / 录出 0 字节

Ubuntu 仓库的 scrcpy 1.25 在 Android 14+ 上会因服务端反射调用失败而
崩溃，因此镜像**不安装**该包，只提供预编译的 3.3。确认：

```bash
command -v scrcpy          # 应为 /usr/local/bin/scrcpy
scrcpy --version           # 3.3
ls -l /usr/local/share/scrcpy/scrcpy-server
```

如果 `command -v scrcpy` 指向 `/usr/bin/scrcpy`，说明有人手动装了发行版
包（或者用了旧镜像），移除它：
`apt-get remove --purge scrcpy`。如果命令不存在，检查构建时是否设置了
`ANDROID_TOOLS_ENABLED=false`。板子没有桌面环境时使用
`--no-playback --record=...`。

## 构建失败：scrcpy 校验或架构不符

现象：

```text
scrcpy checksums do not match ...
scrcpy is not an aarch64 binary: ...
```

处理：

- 确认 `3rd/scrcpy-3.3-aarch64/` 下的 `scrcpy`、`scrcpy-server` 未被改动；
  如果替换了版本，同步更新同目录的 `SHA256SUMS`。
- 客户端必须是 aarch64 ELF；镜像不能运行 x86 版本。

## GitHub API rate limit

`prepare` 作业使用 `GITHUB_TOKEN`，限额足够。本地运行 `make plan` 或
`make build` 时如果出现 `API rate limit exceeded`，设置一个 token：

```bash
export GH_TOKEN="$(gh auth token)"   # 或手动创建 PAT
```

## Release tag 已存在

版本号精确到秒。如果同一秒内重复发布（极少见），重新运行 workflow 即可
得到新的 `V<年月日时分秒>`。
