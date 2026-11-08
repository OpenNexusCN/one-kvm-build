# Boards

Every board is a shell fragment sourced after `config/defaults.conf`.  The
minimum board adds an Armbian base image and the DTB that the kernel release
must provide.

| Board | SoC | Base image | Kernel DTB | Status |
|---|---|---|---|---|
| `fmx1-pro` | RK3399 | `Armbian_26.11.0_rockchip_fmx1-pro_noble_6.18.59_server_2026.11.02.img.gz` | `rk3399-fmx1-pro-otg.dtb` | active |
| `fmx1-pro-b` | RK3399 | `Armbian_26.11.0_rockchip_fmx1-pro-b_noble_6.18.59_server_2026.11.02.img.gz` | `rk3399-fmx1-pro-otg.dtb` | active (experimental on B hardware) |

## fmx1-pro-b note

The kernel provides `rk3399-fmx1-pro-b.dtb` for the B revision, but no
B-specific OTG variant yet.  The build process currently uses the generic
`rk3399-fmx1-pro-otg.dtb` on both boards.  If a B unit does not boot or its
Type-C port does not enumerate as a peripheral, change `KERNEL_DTB` in
`boards/fmx1-pro-b.conf` to `rk3399-fmx1-pro-b.dtb` (One-KVM then has no USB
gadget on that port) or add a B OTG DTS to the kernel repository.

## Adding a board

See `docs/adding-a-board.md`.
