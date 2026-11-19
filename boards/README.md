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
`ANDROID_SCRCPY_MODE="distro"` with `trixie-backports` for scrcpy 3.3.4.

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
