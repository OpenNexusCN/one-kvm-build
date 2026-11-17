#!/usr/bin/env bash
# onekvm-iso-fix.sh —— 把"UDF-only / 缺 Joliet"的 ISO 重制成 Windows 能读的
#                      ISO9660 + Joliet + El Torito 镜像（One-KVM 虚拟光驱用）
#
# 背景：有些重打包的 Windows 镜像把 ISO9660 层做成空壳（只有一个 README.TXT），
#       真实内容全在 UDF 分区里；而 Windows 通过 USB 虚拟光驱不挂 UDF，
#       于是只看到 README，或 Setup 报"缺少计算机所需的介质驱动程序"。
#       本脚本把 UDF 里的内容重新打成标准 ISO9660+Joliet，并原样保留 El Torito
#       引导（BIOS + UEFI），这样 Windows / Linux / BIOS 都能正常读和引导。
#
# 用法：
#   onekvm-iso-fix.sh 镜像.iso [更多.iso ...]
#   onekvm-iso-fix.sh -o /path/out -s _fixed 镜像.iso
#
# 选项：
#   -o DIR        输出目录（默认与源文件同目录）
#   -s SUFFIX     输出文件名后缀（默认 _joliet）
#   -V LABEL      强制指定卷标（默认沿用源 ISO 的 Volume id）
#   -f            覆盖已存在的输出文件
#   -n            只检测，不转换（dry-run，会打印将要执行的动作）
#   --replace     转换成功后把源文件改名为 <name>.orig-udfonly（不删除）
#   --no-install  缺少依赖时不自动 apt 安装，直接报错
#   --min-files N ISO9660 文件数低于该值即视为"空壳"（默认 100）
#   -q            安静模式（只输出错误）
#   -h            帮助
#
# 依赖（脚本会自动安装）：
#   xorriso      —— 重制镜像
#   genisoimage  —— 提供 isoinfo（检测 ISO9660/Joliet/文件树）
#   udftools     —— 提供 udfinfo（检测 UDF 与文件数）
#   内核 udf 模块 —— 挂载源镜像内容（modprobe udf）
#
# 退出码：0 成功（含"本来就好，跳过"）；1 失败
set -u

OUTDIR=""
SUFFIX="_joliet"
FORCE_LABEL=""
FORCE=0
DRYRUN=0
REPLACE=0
NOINSTALL=0
QUIET=0
MIN_FILES=100

quiet_now() { [ "$QUIET" = 1 ] && [ "$DRYRUN" = 0 ]; }
die()  { echo "错误: $*" >&2; exit 1; }
info() { quiet_now || echo "$@"; }
step() { quiet_now || { echo; echo "=== $* ==="; }; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
	case "$1" in
	-o) OUTDIR=${2:?}; shift 2 ;;
	-s) SUFFIX=${2:?}; shift 2 ;;
	-V) FORCE_LABEL=${2:?}; shift 2 ;;
	-f) FORCE=1; shift ;;
	-n) DRYRUN=1; shift ;;
	--replace) REPLACE=1; shift ;;
	--no-install) NOINSTALL=1; shift ;;
	--min-files) MIN_FILES=${2:?}; shift 2 ;;
	-q) QUIET=1; shift ;;
	-h|--help) usage ;;
	--) shift; break ;;
	-*) die "未知选项: $1" ;;
	*) break ;;
	esac
done

[ $# -gt 0 ] || usage
INPUTS=("$@")

# ---------------------------------------------------------------- 依赖
missing_deps() {
	command -v xorriso >/dev/null 2>&1 || return 0
	command -v isoinfo >/dev/null 2>&1 || return 0
	command -v udfinfo >/dev/null 2>&1 || return 0
	return 1
}

ensure_deps() {
	modprobe udf 2>/dev/null || true

	if missing_deps; then
		[ "$NOINSTALL" = 1 ] && die "缺少依赖（xorriso / genisoimage / udftools），且指定了 --no-install"
		command -v apt-get >/dev/null 2>&1 \
			|| die "缺少依赖，且没有 apt-get，请手动安装：xorriso genisoimage udftools"
		info "安装依赖: xorriso genisoimage udftools ..."
		DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
		DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xorriso genisoimage udftools >/dev/null 2>&1 \
			|| die "依赖安装失败，请手动安装：xorriso genisoimage udftools"
	fi

	for c in xorriso isoinfo udfinfo; do
		command -v "$c" >/dev/null 2>&1 || die "依赖缺失: $c"
	done
	info "依赖检查通过: xorriso / isoinfo / udfinfo"
}

# ---------------------------------------------------------------- 检测
# 注意：isoinfo 在"没有 Joliet"时也会打印 "NO Joliet present"，
#       所以必须只匹配以 Joliet 开头的行（"Joliet with UCS level 3 found"）。
has_joliet() {
	isoinfo -d -i "$1" 2>/dev/null | grep -q '^Joliet'
}

# 输出: "树文件数|有Joliet(1/0)|有UDF(1/0)|UDF文件数|UDF目录数"
probe() {
	local iso=$1 n jol udf nf nd
	n=$(isoinfo -f -i "$iso" 2>/dev/null | wc -l | tr -d ' ')
	if has_joliet "$iso"; then jol=1; else jol=0; fi
	if command -v udfinfo >/dev/null 2>&1 && udfinfo "$iso" >/dev/null 2>&1; then
		udf=1
		nf=$(udfinfo "$iso" 2>/dev/null | awk -F= '/^numfiles=/{print $2+0; exit}')
		nd=$(udfinfo "$iso" 2>/dev/null | awk -F= '/^numdirs=/{print $2+0; exit}')
	else
		udf=0; nf=0; nd=0
	fi
	echo "${n:-0}|$jol|$udf|${nf:-0}|${nd:-0}"
}

needs_fix() {
	local iso=$1 p n jol
	p=$(probe "$iso")
	n=$(echo "$p" | cut -d'|' -f1)
	jol=$(echo "$p" | cut -d'|' -f2)
	[ "$n" -lt "$MIN_FILES" ] && return 0
	[ "$jol" = "0" ] && return 0
	return 1
}

# ---------------------------------------------------------------- 引导参数
# 兜底探测（最可靠）：直接看已挂载的内容里有没有常见引导文件
boot_opts_fallback() {
	local root=$1 opts=""
	if [ -f "$root/boot/etfsboot.com" ]; then
		opts="-b boot/etfsboot.com -no-emul-boot -boot-load-size 8"
	elif [ -f "$root/BOOT/ETFSBOOT.COM" ]; then
		opts="-b BOOT/ETFSBOOT.COM -no-emul-boot -boot-load-size 8"
	elif [ -f "$root/boot/bcd" ]; then
		opts="-b boot/etfsboot.com -no-emul-boot -boot-load-size 8"
	fi
	if [ -f "$root/efi/microsoft/boot/efisys.bin" ]; then
		opts="$opts -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot"
	elif [ -f "$root/efi/microsoft/boot/efisys_noprompt.bin" ]; then
		opts="$opts -eltorito-alt-boot -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot"
	elif [ -f "$root/efi/boot/efiboot.img" ]; then
		opts="$opts -eltorito-alt-boot -e efi/boot/efiboot.img -no-emul-boot"
	fi
	if [ -z "$opts" ] && [ -f "$root/isolinux/isolinux.bin" ]; then
		opts="-b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table"
	fi
	if [ -n "$opts" ] && [ -f "$root/boot/grub/efi.img" ]; then
		opts="$opts -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot"
	fi
	printf '%s' "$opts"
}

# 从 El Torito 目录还原（适用于 ISO9660 树完整、引导文件可见的镜像）
boot_opts_from_catalog() {
	local iso=$1
	xorriso -indev "$iso" -report_el_torito as_mkisofs 2>/dev/null \
		| grep -E '^-' \
		| grep -vE '^--' \
		| grep -vE "^-V |^-volid " \
		| tr '\n' ' ' \
		| sed "s#-b '/#-b '#g; s#-e '/#-e '#g; s#-b \"/#-b \"#g; s#-e \"/#-e \"#g"
}

volume_label() {
	local iso=$1 lbl
	lbl=$(isoinfo -d -i "$iso" 2>/dev/null | awk -F': ' '/^Volume id:/{print $2; exit}')
	[ -n "${lbl:-}" ] || lbl=$(basename "$iso" .iso)
	printf '%s' "$lbl"
}

has_bios_boot() { case "$1" in *"-b "*) return 0 ;; esac; return 1; }
has_efi_boot()  { case "$1" in *"-e "*) return 0 ;; esac; return 1; }

# ---------------------------------------------------------------- 主流程
ensure_deps

TMPMNT=$(mktemp -d /tmp/isofix.XXXXXX) || die "无法创建临时目录"
cleanup() {
	if mountpoint -q "$TMPMNT" 2>/dev/null; then umount "$TMPMNT" 2>/dev/null; fi
	rmdir "$TMPMNT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

FAILED=0
for src in "${INPUTS[@]}"; do
	if [ ! -f "$src" ]; then
		echo "跳过（不存在）: $src" >&2
		FAILED=1
		continue
	fi

	step "$(basename "$src")"

	p=$(probe "$src")
	tree=$(echo "$p" | cut -d'|' -f1)
	jol=$(echo "$p" | cut -d'|' -f2)
	udf=$(echo "$p" | cut -d'|' -f3)
	ufiles=$(echo "$p" | cut -d'|' -f4)
	udirs=$(echo "$p" | cut -d'|' -f5)
	info "  ISO9660 文件数 : $tree"
	if [ "$jol" = 1 ]; then info "  Joliet         : 有"; else info "  Joliet         : 无"; fi
	if [ "$udf" = 1 ]; then
		info "  UDF            : 有（$ufiles 文件 / $udirs 目录）"
	else
		info "  UDF            : 无"
	fi

	if ! needs_fix "$src"; then
		info "  → 结论: 无需转换（ISO9660 树完整且带 Joliet）"
		continue
	fi

	if [ "$udf" = 1 ] && [ "$ufiles" -gt 0 ]; then
		MNT_TYPE=udf
		info "  → 结论: 需要转换（ISO9660 是空壳，内容在 UDF 里），挂载类型=udf"
	elif [ "$tree" -ge "$MIN_FILES" ]; then
		MNT_TYPE=iso9660
		info "  → 结论: 需要转换（缺 Joliet），挂载类型=iso9660"
	else
		echo "  → 结论: 无法转换（ISO9660 空且没有 UDF 内容）" >&2
		FAILED=1
		continue
	fi

	base=$(basename "$src")
	base=${base%.iso}
	outdir=${OUTDIR:-$(dirname "$src")}
	out="$outdir/${base}${SUFFIX}.iso"

	if [ -f "$out" ] && [ "$FORCE" = 0 ]; then
		echo "  → 输出已存在（用 -f 覆盖）: $out" >&2
		FAILED=1
		continue
	fi

	label=${FORCE_LABEL:-$(volume_label "$src")}

	# 空间预检：输出目录必须能放下约 1.1 倍源文件大小的新镜像
	avail=$(df -Pk "$outdir" 2>/dev/null | awk 'NR==2{print $4*1024}')
	need=$(stat -c %s "$src" 2>/dev/null || echo 0)
	if [ -n "${avail:-}" ] && [ "$avail" -lt $(( need + need / 10 )) ]; then
		echo "  → 空间不足: 需要约 $(( need / 1024 / 1024 )) MB, $outdir 仅剩 $(( avail / 1024 / 1024 )) MB（/tmp 若是 tmpfs，请用 -o 换目录）" >&2
		FAILED=1
		continue
	fi

	# 挂载（dry-run 也挂一下，只读，用于探测引导文件）
	if ! mount -t "$MNT_TYPE" -o loop,ro "$src" "$TMPMNT" 2>/dev/null; then
		if ! mount -o loop,ro "$src" "$TMPMNT" 2>/dev/null; then
			echo "  → 挂载失败: $src" >&2
			FAILED=1
			continue
		fi
	fi

	# 引导参数：优先按挂载内容兜底探测（空壳镜像的 ISO9660 里没有引导文件，
	# 此时 El Torito 目录回推出来的参数不完整），否则用 El Torito 目录
	opts=$(boot_opts_fallback "$TMPMNT")
	opts_src="兜底探测"
	if ! has_bios_boot "$opts" && ! has_efi_boot "$opts"; then
		opts=$(boot_opts_from_catalog "$src")
		opts_src="El Torito 目录"
	fi

	info "  卷标           : $label"
	info "  引导参数($opts_src): ${opts:-（无）}"

	if [ "$DRYRUN" = 1 ]; then
		mountpoint -q "$TMPMNT" && umount "$TMPMNT" 2>/dev/null
		info "  [dry-run] 将输出: $out"
		continue
	fi

	tmpout="$out.part.$$"
	rm -f "$tmpout"
	info "  → 重制中..."

	xorriso -as mkisofs -iso-level 3 -J -joliet-long -r \
		-V "$label" \
		$opts \
		-hide boot.catalog -hide-joliet boot.catalog \
		-o "$tmpout" "$TMPMNT" >/tmp/isofix.log 2>&1
	rc=$?

	umount "$TMPMNT" 2>/dev/null || true

	if [ $rc -ne 0 ] || [ ! -s "$tmpout" ]; then
		echo "  → 重制失败（xorriso rc=$rc），日志: /tmp/isofix.log" >&2
		tail -5 /tmp/isofix.log >&2
		rm -f "$tmpout"
		FAILED=1
		continue
	fi

	# ---------------- 校验 ----------------
	ver_ok=1
	ntree=$(isoinfo -f -i "$tmpout" 2>/dev/null | wc -l | tr -d ' ')
	src_bios=$(xorriso -indev "$src"   -report_el_torito plain 2>/dev/null | grep -c 'BIOS' || true)
	new_bios=$(xorriso -indev "$tmpout" -report_el_torito plain 2>/dev/null | grep -c 'BIOS' || true)
	src_efi=$(xorriso -indev "$src"   -report_el_torito plain 2>/dev/null | grep -c 'UEFI' || true)
	new_efi=$(xorriso -indev "$tmpout" -report_el_torito plain 2>/dev/null | grep -c 'UEFI' || true)

	info "  新 ISO9660 文件数: $ntree"
	if has_joliet "$tmpout"; then info "  Joliet        : 有"; else info "  Joliet        : 无"; ver_ok=0; fi
	info "  El Torito BIOS: 源 $src_bios → 新 $new_bios"
	info "  El Torito UEFI: 源 $src_efi  → 新 $new_efi"

	[ "$ntree" -ge "$MIN_FILES" ] || ver_ok=0
	[ "$new_bios" -ge "$src_bios" ] || ver_ok=0
	[ "$new_efi" -ge "$src_efi" ] || ver_ok=0

	if [ "$ver_ok" != 1 ]; then
		echo "  → 校验未通过，保留 .part 供排查: $tmpout" >&2
		FAILED=1
		continue
	fi

	mv -f "$tmpout" "$out"
	if [ "$REPLACE" = 1 ]; then mv -f "$src" "$src.orig-udfonly"; fi
	info "  ✅ 完成: $out ($(stat -c %s "$out") 字节)"
done

[ "$FAILED" = 0 ] || exit 1
exit 0
