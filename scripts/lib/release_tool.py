#!/usr/bin/env python3
"""Select GitHub releases/assets from JSON produced by the GitHub API.

The shell helpers pipe API JSON into this tool.  Keeping the matching logic
here avoids fragile parsing in bash.

Subcommands
-----------
select-latest   input: JSON array of releases; output: first matching release
select-release  input: JSON object of one release; output: validated release
select-asset    input: JSON object of one release; output: first matching asset

Matching uses shell-style globs (fnmatch), not regular expressions.
Run with `python3 -I` so the interpreter ignores modules from the CWD.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from typing import Any


def _asset_names(release: dict[str, Any]) -> list[str]:
    return [asset.get("name", "") for asset in release.get("assets", [])]


def _validate_release(release: dict[str, Any], requires: list[str]) -> bool:
    names = _asset_names(release)
    return all(
        any(fnmatch.fnmatchcase(name, pattern) for name in names)
        for pattern in requires
    )


def _require_exact_asset(release: dict[str, Any], pattern: str) -> dict[str, Any]:
    matches = [
        asset
        for asset in release.get("assets", [])
        if fnmatch.fnmatchcase(asset.get("name", ""), pattern)
    ]
    if not matches:
        raise LookupError(f"no asset matching {pattern!r} in release {release.get('tag_name')!r}")
    if len(matches) > 1:
        names = ", ".join(asset.get("name", "") for asset in matches)
        raise LookupError(
            f"asset pattern {pattern!r} is ambiguous in release "
            f"{release.get('tag_name')!r}: {names}"
        )
    return matches[0]


def select_latest(releases: list[dict[str, Any]], tag_pattern: str, requires: list[str]) -> dict[str, Any]:
    for release in releases:
        if release.get("draft") or release.get("prerelease"):
            continue
        if tag_pattern and not fnmatch.fnmatchcase(release.get("tag_name", ""), tag_pattern):
            continue
        if _validate_release(release, requires):
            return release
    raise LookupError(
        "no release matches tag pattern "
        f"{tag_pattern!r} with all required assets {requires!r}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    latest = sub.add_parser("select-latest")
    latest.add_argument("--tag-pattern", default="")
    latest.add_argument("--require", action="append", default=[])

    release = sub.add_parser("select-release")
    release.add_argument("--require", action="append", default=[])

    asset = sub.add_parser("select-asset")
    asset.add_argument("--pattern", required=True)

    args = parser.parse_args()

    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"invalid JSON on stdin: {exc}", file=sys.stderr)
        return 2

    try:
        if args.command == "select-latest":
            if not isinstance(payload, list):
                raise LookupError("select-latest expects a JSON array")
            result = select_latest(payload, args.tag_pattern, args.require)
        elif args.command == "select-release":
            if not isinstance(payload, dict):
                raise LookupError("select-release expects a JSON object")
            if not _validate_release(payload, args.require):
                raise LookupError(
                    f"release {payload.get('tag_name')!r} is missing required assets {args.require!r}"
                )
            result = payload
        else:
            if not isinstance(payload, dict):
                raise LookupError("select-asset expects a JSON object")
            result = _require_exact_asset(payload, args.pattern)
    except LookupError as exc:
        print(str(exc), file=sys.stderr)
        return 3

    json.dump(result, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
