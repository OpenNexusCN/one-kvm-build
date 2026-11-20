# Boards

Every board is a shell fragment sourced after `config/defaults.conf`.  The
minimum board adds an Armbian base image and the DTB that the kernel release
provides.  `KERNEL_DTB_FROM_BASE_IMAGE="true"` is available for boards whose
base image already ships a usable DTB, but board DTS changes belong in the
kernel repository.

| Board | SoC | Base image | Kernel DTB | Status |
|---|---|---|---|---|
| `fmx1-pro` | RK3399 | `Armbian_26.11.0_rockchip_fmx1-pro_noble_6.18.59_server_2026.11.02.img.gz` | `rk3399-fmx1-pro-otg.dtb` | active |
| `fmx1-pro-b` | RK3399 | `Armbian_26.11.0_rockchip_fmx1-pro-b_noble_6.18.59_server_2026.11.02.img.gz` | `rk3399-fmx1-pro-otg.dtb` | active (experimental on B hardware) |
| `nanopc-t4` | RK3399 | `Armbian_26.11.0_rockchip_nanopc-t4_trixie_6.18.63_server_2026.11.14.img.gz` | `rk3399-nanopc-t4-otg.dtb` | active |
| `sw799` | RK3399 | `Armbian_26.11.0_rockchip_sw799_trixie_6.18.59_server_2026.11.02.img.gz` | `rk3399-bozz-sw799-otg.dtb` | active |

## sw799 note

The kernel repository provides
`arch/arm64/boot/dts/rockchip/rk3399-bozz-sw799-otg.dts`.  The board's J23
micro-USB connector is the TYPEC0/DWC3_0 OTG port; the stock DTS disables
it.  The -otg variant enables `u2phy0_otg` and DWC3_0, keeps
`dr_mode = "otg"` so the PHY uses the real `TYPEC0_ID` pin, defaults the
dwc3 role switch to `peripheral`, and limits the port to high-speed
because J23 only exposes USB2 D+/D-.  DWC3_1 remains the stock host port.

The board has AP6236/AP6181-class SDIO Wi-Fi (`wifi@1` on `sdio0`); the
trixie image ships the matching brcmfmac firmware, so the default Wi-Fi AP
feature works.  Like nanopc-t4, this board uses
`ANDROID_SCRCPY_MODE="distro"` with `trixie-backports` for scrcpy 3.3.4;
the image build writes a `one-kvm.service` drop-in setting
`ONE_KVM_SCRCPY_SERVER_VERSION=3.3.4` so One-KVM's default 3.3 does not
cause a server/client version mismatch.

## Batch RK3399 boards

`boards/*.conf` also contains the full RK3399 set from the ophub model
database (42 boards).  For each board that has a kernel DTS, the kernel
repository publishes an `-otg` DTB; the variant includes the stock DTS and
enables the maskrom/flashing USB OTG port with the same role-switch setup as
the boards above.  The variants also include `rk3399-vpu.dtsi` (BSP MPP:
`mpp_srv`/`vepu`/`vdpu`, mainline hantro `vpu` disabled) and
`rk3399-iep.dtsi` (IEP image enhancement, `/dev/iep`); without them
`/dev/mpp_service` and `/dev/iep` are absent.

Currently enabled for `--boards all` (19):

```text
aio-3399c  aio-3399c-ai  dlfr100  eaidk-610  firefly-jd4  firefly-rk3399
fmx1-pro  fmx1-pro-b  kylin3399  leez  lzk4  nanopc-t4  nanopi-som
sw799  taram  tps781  tvi3315a  xiaobao  zk-r39a
```

Added but `ENABLED="false"` until the USB OTG port is verified on hardware
(23):

```text
ai3399-c  aio-3399b  crrc  dg3399  emb3531  fine3399  gea-6319  h339pc
hd9901  hs530r  hugsun-x99  king3399  lx-r3s  smart-am40  sv-33a6x
sv-33a6x-vpu  sz3390  tb-ls3399  tn3399  tpm312  yskj  zcube1-max  zysj
```

HD9901 has no DTS in the kernel source yet, so it keeps the base image DTB
(`KERNEL_DTB_FROM_BASE_IMAGE=true`).  To test a disabled board, set
`ENABLED="true"` in its config (and adjust the chosen OTG controller if the
maskrom port is wired to DWC3_1).

## nanopc-t4 note

The kernel repository provides
`arch/arm64/boot/dts/rockchip/rk3399-nanopc-t4-otg.dts`.  It includes the
upstream `rk3399-nanopc-t4.dts`, keeps `usbdrd_dwc3_0` in
`dr_mode = "otg"`, defaults the dwc3 role switch to `peripheral`, and
describes the FUSB302 USB-C port as a sink-only device so TCPM presents Rd
on CC.  This exposes a UDC for One-KVM's HID (virtual keyboard/mouse),
mass-storage (virtual CD-ROM) and UVC gadgets.  The kernel CI builds and
publishes `rk3399-nanopc-t4-otg.dtb`; one-kvm-build only consumes it.

Debian trixie uses FFmpeg 7, while the prebuilt `3rd/scrcpy-3.3-aarch64`
client was linked against noble's FFmpeg 6.  This board therefore sets
`ANDROID_SCRCPY_MODE="distro"` and `ANDROID_SCRCPY_APT_SUITE="trixie-backports"`,
installing scrcpy 3.3.4 from the backports suite that is already enabled in
the Armbian image.

## fmx1-pro-b note

The kernel provides `rk3399-fmx1-pro-b.dtb` for the B revision, but no
B-specific OTG variant yet.  The build process currently uses the generic
`rk3399-fmx1-pro-otg.dtb` on both boards.  If a B unit does not boot or its
Type-C port does not enumerate as a peripheral, change `KERNEL_DTB` in
`boards/fmx1-pro-b.conf` to `rk3399-fmx1-pro-b.dtb` (One-KVM then has no USB
gadget on that port) or add a B OTG DTS to the kernel repository.

## Adding a board

See `docs/adding-a-board.md`.
