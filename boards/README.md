# Boards

Every board is a shell fragment sourced after `config/defaults.conf`.  The
minimum board adds an Armbian base image and the DTB the kernel release
provides; boards whose DTB exists only in the base image set
`KERNEL_DTB_FROM_BASE_IMAGE="true"` (see `nanopc-t4`).

| Board | SoC | Base image | Kernel DTB | Status |
|---|---|---|---|---|
| `fmx1-pro` | RK3399 | `Armbian_26.11.0_rockchip_fmx1-pro_noble_6.18.59_server_2026.11.02.img.gz` | `rk3399-fmx1-pro-otg.dtb` | active |
| `fmx1-pro-b` | RK3399 | `Armbian_26.11.0_rockchip_fmx1-pro-b_noble_6.18.59_server_2026.11.02.img.gz` | `rk3399-fmx1-pro-otg.dtb` | active (experimental on B hardware) |
| `nanopc-t4` | RK3399 | `Armbian_26.11.0_rockchip_nanopc-t4_trixie_6.18.63_server_2026.11.14.img.gz` | `rk3399-nanopc-t4.dtb` (base image) | active |

## nanopc-t4 note

The OpenNexusCN kernel release currently publishes only the FMX1 DTBs, so
`boards/nanopc-t4.conf` sets `KERNEL_DTB_FROM_BASE_IMAGE=true`.  The build
keeps the upstream Armbian `rk3399-nanopc-t4.dtb`, which already puts
`usbdrd_dwc3_0` (the USB-C port) in `dr_mode = "otg"`.  If a later kernel
release includes `rk3399-nanopc-t4.dtb`, that DTB is used instead
automatically.

The stock `dr_mode = "otg"` does not register a UDC on 6.18, so
`components/nanopc-t4/pre-install.d/10-usb-otg-dts.sh` decompiles the DTB
to DTS, appends `components/nanopc-t4/dts/otg-fragment.dtsi`, recompiles it,
and verifies the result.  The fragment keeps `dr_mode = "otg"`, defaults the
dwc3 role switch to `peripheral`, and adds a sink-only `usb-c-connector`
under the FUSB302 so TCPM presents Rd on CC.  The hook also fails the build
unless the kernel config and module tree provide HID, mass storage and UVC
gadgets (virtual keyboard/mouse, virtual CD-ROM and video).  The build job
installs `device-tree-compiler` for `dtc`.

## fmx1-pro-b note

The kernel provides `rk3399-fmx1-pro-b.dtb` for the B revision, but no
B-specific OTG variant yet.  The build process currently uses the generic
`rk3399-fmx1-pro-otg.dtb` on both boards.  If a B unit does not boot or its
Type-C port does not enumerate as a peripheral, change `KERNEL_DTB` in
`boards/fmx1-pro-b.conf` to `rk3399-fmx1-pro-b.dtb` (One-KVM then has no USB
gadget on that port) or add a B OTG DTS to the kernel repository.

## Adding a board

See `docs/adding-a-board.md`.
