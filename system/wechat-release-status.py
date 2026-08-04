#!/usr/bin/env python3
"""Read-only verification for the root-owned WeChat consumer releases."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import stat


PROJECT_RELEASE_RE = re.compile(r"^[0-9a-f]{40}$")
BUNDLE_RELEASE_RE = re.compile(
    r"^zt-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-r[1-9][0-9]*$"
)


class StatusError(RuntimeError):
    """The root-owned release state is missing or structurally invalid."""


def _selector(root: pathlib.Path, family: str, selector: str) -> str | None:
    name = f"{family}-{selector}"
    path = root / name
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise StatusError(f"cannot inspect Second User release selector: {name}") from error
    if not stat.S_ISLNK(metadata.st_mode):
        raise StatusError(f"Second User release selector is not a symlink: {name}")

    target = os.readlink(path)
    pattern = PROJECT_RELEASE_RE if family == "project" else BUNDLE_RELEASE_RE
    prefix = f"{family}-releases/"
    release = target.removeprefix(prefix)
    if not target.startswith(prefix) or "/" in release or not pattern.fullmatch(release):
        raise StatusError(f"invalid Second User release target: {name}")

    destination = root / target
    try:
        target_metadata = destination.lstat()
    except OSError as error:
        raise StatusError(f"missing Second User release target: {name}") from error
    if not stat.S_ISDIR(target_metadata.st_mode):
        raise StatusError(f"Second User release target is not a physical directory: {name}")
    return target


def status(root: pathlib.Path) -> list[str]:
    lines = []
    for family in ("project", "bundle"):
        for selector in ("current", "previous"):
            target = _selector(root, family, selector)
            lines.append(
                f"user2-{family}-{selector}: {target if target is not None else 'absent'}"
            )
    return lines


def verify_project(root: pathlib.Path, release: str) -> str:
    if not PROJECT_RELEASE_RE.fullmatch(release):
        raise StatusError("invalid project release id")
    target = _selector(root, "project", "current")
    expected = f"project-releases/{release}"
    if target != expected:
        raise StatusError("Second User project-current does not select the requested release")

    marker = root / expected / "RELEASE"
    try:
        metadata = marker.lstat()
    except OSError as error:
        raise StatusError("Second User project release marker is unavailable") from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 128:
        raise StatusError("Second User project release marker is not a physical regular file")
    try:
        recorded = marker.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as error:
        raise StatusError("Second User project release marker cannot be read") from error
    if recorded != release:
        raise StatusError("Second User project release marker does not match")
    return f"verified Second User project release {release}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    verify = commands.add_parser("verify-project")
    verify.add_argument("release")
    args = parser.parse_args()

    try:
        if args.command == "status":
            for line in status(args.root):
                print(line)
        else:
            print(verify_project(args.root, args.release))
    except StatusError as error:
        print(f"wechat-user2-release-status: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
