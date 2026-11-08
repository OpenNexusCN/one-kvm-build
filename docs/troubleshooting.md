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

- 确认 AP 客户端拿到了 192.168.4.x 地址：`ip addr` / DHCP 租约。
- 在客户端访问 `http://192.168.4.1/`，应返回 302 到
  `http://192.168.4.1:8080/`；如果失败，检查 lighttpd 是否绑定在
  `192.168.4.1:80`。
- `dnsmasq` 必须监听 192.168.4.1:53，且配置了
  `address=/#/192.168.4.1`；用 `dig @192.168.4.1 example.com` 验证。
- 强制门户依赖 HTTP/DNS，不拦截 HTTPS；用浏览器打开任意 HTTP 页面，
  或直接访问 `http://192.168.4.1:8080/`。
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

## GitHub API rate limit

`prepare` 作业使用 `GITHUB_TOKEN`，限额足够。本地运行 `make plan` 或
`make build` 时如果出现 `API rate limit exceeded`，设置一个 token：

```bash
export GH_TOKEN="$(gh auth token)"   # 或手动创建 PAT
```

## Release tag 已存在

版本号精确到秒。如果同一秒内重复发布（极少见），重新运行 workflow 即可
得到新的 `V<年月日时分秒>`。
