# Components

This directory holds board- or platform-specific files that must be copied
into an image or run at build time.  It exists so that future boards can carry
special blobs, services, udev rules, firmware, or init scripts without touching
the generic build pipeline.

## Layout

```
components/
├── common/                  # applied to every board
│   ├── rootfs/              # copied over the target root filesystem
│   ├── boot/                # copied over the boot partition
│   ├── pre-install.d/*.sh   # run before the One-KVM package is installed
│   └── post-install.d/*.sh  # run after the One-KVM package is installed
└── <board-id>/              # applied only to boards/<board-id>.conf
    ├── rootfs/
    ├── boot/
    ├── pre-install.d/
    └── post-install.d/
```

Order: `common` first, then `<board-id>` (board files win).  All `rootfs/`
and `boot/` trees are copied before the One-KVM package is installed, then
the `pre-install.d` hooks run in filename order, then One-KVM is installed,
then the `post-install.d` hooks run.

## Hook environment

Hooks run with `bash` and `set -e` semantics from the repository root.  The
following variables are exported:

| Variable | Meaning |
|---|---|
| `ROOT` | Mounted target root filesystem |
| `BOOT` | Mounted boot filesystem (inside `ROOT/boot`) |
| `KVER` | Kernel release, e.g. `6.18.60-otgfix+` |
| `BOARD_ID` | Board id from `boards/<id>.conf` |
| `BUILD_VERSION` | Release version, e.g. `V20261108181345` |
| `WORK` | Per-board work directory |

Example `post-install.d/10-enable-uart.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
sed -i 's/^console=.*/console=ttyS2,1500000/' "$BOOT/armbianEnv.txt"
```

## Notes

- Keep large binaries out of git history when possible; document their
  provenance and verify checksums in a hook or in the board config.
- Hooks run on the CI runner as root (inside the mounted image).  Treat them
  as trusted code: review changes before merging.
- Files copied into the image are not automatically removed by the build; the
  hooks are responsible for cleaning temporary files.
