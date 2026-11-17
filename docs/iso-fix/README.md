# onekvm-iso-fix.sh —— 把"UDF-only"的 ISO 转成 Windows 能读的镜像

## 解决什么问题

有些重打包的 Windows 安装镜像（常见于国内二次打包/搬运）把 **ISO9660 层做成了空壳**：
里面只有一个 `README.TXT`，真正的文件全在 **UDF 1.02 分区**里。

而 Windows 通过 One-KVM 的 **USB 虚拟光驱** 不挂 UDF（实测：纯 UDF 盘直接报
"The volume does not contain a recognized file system"），于是：

- 资源管理器里只看到 `README.TXT`
- 或报 **"This disc contains a UDF file system..."**
- Windows Setup 能启动（El Torito 在 ISO9660 层里，是有的），但到一半报
  **"缺少计算机所需的介质驱动程序"** —— 因为找不到 `\sources\install.wim`

**脚本做的事**：把 UDF 里的真实内容重新打包成标准 **ISO9660 + Joliet** 镜像，
并**原样保留 El Torito 引导**（BIOS `boot/etfsboot.com` + UEFI
`efi/microsoft/boot/efisys.bin`），这样 Windows / Linux / BIOS 都能正常读和引导。

> **已内置到 one-kvm-build 镜像**：构建时会把本目录的脚本安装为
> `/usr/local/sbin/onekvm-iso-fix`（另有 `.sh` 符号链接），并预装
> `xorriso` / `genisoimage` / `udftools`，说明文档在
> `/usr/share/doc/onekvm-iso-fix/README.md`。设备上直接运行
> `onekvm-iso-fix <镜像.iso>` 即可，无需手动拷贝脚本或联网安装依赖。
> 部署副本位于 `files/iso-fix/onekvm-iso-fix.sh`，改动脚本时两处需保持
> 一致（`tests/run-tests.sh` 会校验）。

## 快速用法

```bash
# 检测（不转换）
onekvm-iso-fix.sh -n 某个.iso

# 转换（输出同目录，文件名加 _joliet 后缀）
onekvm-iso-fix.sh 某个.iso

# 批量 + 转换后把原件改名（防止在 UI 里选错）
onekvm-iso-fix.sh --replace /etc/one-kvm/msd/images/*.iso

# 指定输出目录 / 后缀 / 卷标
onekvm-iso-fix.sh -o /root -s _fixed -V MYLABEL 某个.iso
```

### 选项

| 选项 | 说明 |
|---|---|
| `-o DIR` | 输出目录（默认与源文件同目录） |
| `-s SUFFIX` | 输出文件名后缀（默认 `_joliet`） |
| `-V LABEL` | 强制卷标（默认沿用源 ISO 的 Volume id） |
| `-f` | 覆盖已存在的输出 |
| `-n` | 只检测（dry-run，会打印将执行的挂载/卷标/引导参数/输出路径） |
| `--replace` | 成功后把源文件改名 `<name>.orig-udfonly`（不删除） |
| `--no-install` | 缺依赖时不自动 apt 安装 |
| `--min-files N` | ISO9660 文件数低于 N 视为"空壳"（默认 100） |
| `-q` | 安静模式 |
| `-h` | 帮助 |

## 依赖（脚本会自动安装）

| 依赖 | 提供什么 | 用途 |
|---|---|---|
| `xorriso` | `xorriso` | 重制镜像 |
| `genisoimage` | `isoinfo` | 检测 ISO9660 / Joliet / 文件树 |
| `udftools` | `udfinfo` | 检测 UDF 与文件数 |
| 内核 `udf` 模块 | — | 挂载源镜像内容（脚本会 `modprobe udf`） |

Debian/Ubuntu/Armbian 上缺什么装什么：脚本调用
`apt-get install -y xorriso genisoimage udftools`；没有 apt 的系统请手动装。

## 判定逻辑

```
ISO9660 文件数 < 100  或  没有 Joliet   → 需要转换
  ├─ 有 UDF 且 numfiles > 0  → 挂 UDF 取内容（空壳镜像走这条）
  └─ 否则 ISO9660 本身够大   → 挂 ISO9660（仅缺 Joliet 的镜像走这条）
否则 → 跳过（已经可用）
```

引导参数优先级：

1. **按挂载内容兜底探测**（最可靠）：`boot/etfsboot.com`、`BOOT/ETFSBOOT.COM`、
   `efi/microsoft/boot/efisys.bin`、`efi/boot/efiboot.img`、`isolinux/isolinux.bin`
   —— 空壳镜像的 ISO9660 里没有引导文件，靠 El Torito 目录回推会不完整，必须走这条；
2. 兜底探测不到时，才用 `xorriso -report_el_torito as_mkisofs` 回推。

转换后自动校验：**ISO9660 文件数 ≥ 100、Joliet 存在、BIOS 与 UEFI 引导入口数量不少于源镜像**。

## 本机实测（2026-11-14，192.168.0.192）

| 镜像 | 源 | 转换后 |
|---|---|---|
| Win10 LTSC 2019 x64 | ISO9660 1 个文件 / 无 Joliet / UDF 943 文件 85 目录 | 1027 个文件、Joliet ✓、`/sources` 931 条、BIOS+UEFI 各 1 |
| Win7 Ultimate SP1 x64 | ISO9660 1 个文件 / 无 Joliet / UDF 877 文件 200 目录 | 1076 个文件、Joliet ✓、`/sources` 930 条、BIOS+UEFI 各 1 |

```
✅ 完成: cn_windows_7_..._joliet.iso (3416733696 字节)
   El Torito BIOS: 源 1 → 新 1
   El Torito UEFI: 源 1 → 新 1
```

## 注意事项

1. **别把输出写到 `/tmp`**：多数系统 `/tmp` 是 tmpfs（本机约 1.9 GB），装不下 3–4 GB 的镜像。
   脚本会预检空间并明确报错（"空间不足: 需要约 X MB, /tmp 仅剩 Y MB"）。
2. **One-KVM 会用它自己的数据库覆盖挂载状态**（`/etc/one-kvm/one-kvm.db`）：
   转换完要在**网页里**选中新镜像点"连接"，只在 configfs 里改会被写回去。
   列表里若同时有原文件，建议 `--replace` 改名或手动 `mv` 成 `.orig-udfonly`。
3. **换介质后必须重启被控机**：WinPE 已经缓存了"没有安装介质"，返回再点是没用的。
4. **卷标会被 Joliet 截断**：Joliet 卷标上限 16 字符，例如
   `CES_X64FREV_ZH-CN_DV5` → Windows 里显示 `CES_X64FREV_ZH-C`，只是显示问题。
5. **输出比源略大**（ISO9660 + Joliet 两套目录），一般大几 MB 到十几 MB。
6. 转换**不改动源文件**（除非用 `--replace`）。
7. 转换后镜像**不再依赖 UDF**，但内容与原 UDF 视图一致；如果原 ISO 是 UDF 2.50+
   （蓝光），本脚本同样适用（读的是挂载后的文件树，与 UDF 版本无关）。
