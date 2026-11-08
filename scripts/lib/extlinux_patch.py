#!/usr/bin/env python3
"""Patch kernel/FDT/initrd entries in an extlinux.conf file.

Keywords are matched case-insensitively.  Existing entries are replaced in
place; missing FDT or INITRD entries are inserted after the first LINUX line.
A one-time `.orig` backup is written next to the original file.
"""
from __future__ import annotations

import argparse
import re
from pathlib import Path

KEY_RE = re.compile(r"^(?P<indent>\s*)(?P<key>[A-Za-z_]+)(?P<sep>\s+)(?P<value>.*?)(?P<eol>\r?\n)?$")


def patch_line(line: str, kernel: str, fdt: str, initrd: str) -> str | None:
    """Return a replacement line, or None to keep the original."""
    match = KEY_RE.match(line)
    if not match:
        return None
    key = match.group("key").upper()
    indent = match.group("indent")
    if key in {"LINUX", "KERNEL"}:
        return f"{indent}LINUX {kernel}\n"
    if key in {"FDT", "FDTDIR", "FDTPATH"}:
        return f"{indent}FDT {fdt}\n"
    if key == "INITRD":
        return f"{indent}INITRD {initrd}\n"
    return None


def ensure_entry(lines: list[str], key: str, value: str) -> list[str]:
    pattern = re.compile(rf"^\s*{key}\s+", re.IGNORECASE)
    if any(pattern.match(line) for line in lines):
        return lines
    for index, line in enumerate(lines):
        if re.match(r"^\s*(LINUX|KERNEL)\s+", line, re.IGNORECASE):
            lines.insert(index + 1, f"  {key} {value}\n")
            return lines
    lines.append(f"  {key} {value}\n")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--fdt", required=True)
    parser.add_argument("--initrd", required=True)
    args = parser.parse_args()

    path = Path(args.file)
    if not path.is_file():
        raise SystemExit(f"not a file: {path}")

    original = path.read_text(encoding="utf-8", errors="surrogateescape").splitlines(keepends=True)
    patched: list[str] = []
    for line in original:
        replacement = patch_line(line, args.kernel, args.fdt, args.initrd)
        patched.append(replacement if replacement is not None else line)

    patched = ensure_entry(patched, "FDT", args.fdt)
    patched = ensure_entry(patched, "INITRD", args.initrd)

    backup = path.with_suffix(path.suffix + ".orig")
    if not backup.exists():
        backup.write_text("".join(original), encoding="utf-8", errors="surrogateescape")
    path.write_text("".join(patched), encoding="utf-8", errors="surrogateescape")

    text = "".join(patched)
    for needle in (args.kernel, args.fdt, args.initrd):
        if needle not in text:
            raise SystemExit(f"patch verification failed: {needle} missing from {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
