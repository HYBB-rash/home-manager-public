#!/usr/bin/env python3
"""Install a validated archive as a read-only Second User WeChat code release."""

from __future__ import annotations

import argparse
import grp
import hashlib
import os
import pathlib
import pwd
import re
import shutil
import stat
import tarfile
import tempfile


MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_EXPANDED_BYTES = 128 * 1024 * 1024
MAX_MEMBERS = 10_000
RELEASE_RE = re.compile(r"^(?:[0-9a-f]{40}|zt-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-r[1-9][0-9]*)$")


class ReleaseError(RuntimeError):
    """The supplied release cannot be installed safely."""


def _identity(name: str, *, group: bool) -> int:
    try:
        return grp.getgrnam(name).gr_gid if group else pwd.getpwnam(name).pw_uid
    except KeyError as error:
        kind = "group" if group else "user"
        raise ReleaseError(f"unknown {kind}: {name}") from error


def _validated_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]:
    members = archive.getmembers()
    if not members or len(members) > MAX_MEMBERS:
        raise ReleaseError("archive has an invalid member count")

    seen: set[str] = set()
    expanded = 0
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        if (
            not member.name
            or not path.parts
            or path.is_absolute()
            or any(part in {"", ".", ".."} for part in path.parts)
        ):
            raise ReleaseError(f"unsafe archive path: {member.name!r}")
        normalized = path.as_posix()
        if normalized in seen:
            raise ReleaseError(f"duplicate archive path: {normalized}")
        seen.add(normalized)
        if not (member.isdir() or member.isfile()):
            raise ReleaseError(f"unsupported archive member: {normalized}")
        if member.isfile():
            expanded += member.size
            if expanded > MAX_EXPANDED_BYTES:
                raise ReleaseError("archive expands beyond the configured limit")
    return members


def _chown_mode(path: pathlib.Path, mode: int, uid: int, gid: int) -> None:
    os.chmod(path, mode, follow_symlinks=False)
    os.chown(path, uid, gid, follow_symlinks=False)


def _extract(
    archive_path: pathlib.Path,
    stage: pathlib.Path,
    uid: int,
    gid: int,
) -> None:
    with tarfile.open(archive_path, mode="r:*") as archive:
        members = _validated_members(archive)
        for member in members:
            target = stage.joinpath(*pathlib.PurePosixPath(member.name).parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise ReleaseError(f"cannot read archive member: {member.name}")
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with source, os.fdopen(fd, "wb") as destination:
                shutil.copyfileobj(source, destination)
            mode = 0o750 if member.mode & 0o111 else 0o640
            _chown_mode(target, mode, uid, gid)

    directories = [stage, *(path for path in stage.rglob("*") if path.is_dir())]
    for directory in sorted(directories, key=lambda value: len(value.parts), reverse=True):
        _chown_mode(directory, 0o750, uid, gid)


def _replace_link(link: pathlib.Path, target: str) -> None:
    temporary = link.with_name(f".{link.name}.{os.getpid()}")
    try:
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(target)
        os.replace(temporary, link)
    finally:
        temporary.unlink(missing_ok=True)


def install_release(
    archive_path: pathlib.Path,
    root: pathlib.Path,
    release: str,
    owner: str,
    group: str,
    expected_archive_owner: str,
    *,
    release_directory: str = "project-releases",
    current_link: str = "project-current",
    previous_link: str = "project-previous",
    expected_sha256: str | None = None,
) -> pathlib.Path:
    if not RELEASE_RE.fullmatch(release):
        raise ReleaseError("release has an invalid identifier")
    for name in (release_directory, current_link, previous_link):
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
            raise ReleaseError("release layout name is invalid")

    archive_stat = archive_path.lstat()
    expected_uid = _identity(expected_archive_owner, group=False)
    if not stat.S_ISREG(archive_stat.st_mode) or archive_stat.st_uid != expected_uid:
        raise ReleaseError("archive must be a regular file owned by the operator")
    if archive_stat.st_size <= 0 or archive_stat.st_size > MAX_ARCHIVE_BYTES:
        raise ReleaseError("archive size is outside the configured limit")

    uid = _identity(owner, group=False)
    gid = _identity(group, group=True)
    root.mkdir(parents=True, exist_ok=True)
    releases = root / release_directory
    releases.mkdir(mode=0o750, exist_ok=True)
    _chown_mode(root, 0o750, uid, gid)
    _chown_mode(releases, 0o750, uid, gid)

    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    if expected_sha256 is not None and expected_sha256 != f"sha256:{digest}":
        raise ReleaseError("archive digest does not match the descriptor")
    destination = releases / release
    if destination.exists():
        recorded = destination / ".archive-sha256"
        if not recorded.is_file() or recorded.read_text(encoding="ascii").strip() != digest:
            raise ReleaseError("existing release does not match the supplied archive")
    else:
        stage = pathlib.Path(tempfile.mkdtemp(prefix=f".stage.{release}.", dir=releases))
        try:
            _extract(archive_path, stage, uid, gid)
            for name, value in (("RELEASE", release), (".archive-sha256", digest)):
                target = stage / name
                target.write_text(value + "\n", encoding="ascii")
                _chown_mode(target, 0o640, uid, gid)
            os.replace(stage, destination)
        finally:
            if stage.exists():
                shutil.rmtree(stage)

    current = root / current_link
    old_target = os.readlink(current) if current.is_symlink() else ""
    _replace_link(current, f"{release_directory}/{release}")
    if old_target and old_target != f"{release_directory}/{release}":
        _replace_link(root / previous_link, old_target)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--group", required=True)
    parser.add_argument("--expected-archive-owner", required=True)
    parser.add_argument("--release-directory", default="project-releases")
    parser.add_argument("--current-link", default="project-current")
    parser.add_argument("--previous-link", default="project-previous")
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()
    try:
        installed = install_release(
            args.archive,
            args.root,
            args.release,
            args.owner,
            args.group,
            args.expected_archive_owner,
            release_directory=args.release_directory,
            current_link=args.current_link,
            previous_link=args.previous_link,
            expected_sha256=args.expected_sha256,
        )
    except (OSError, tarfile.TarError, ReleaseError) as error:
        raise SystemExit(f"wechat-project-release: {error}") from error
    print(installed)


if __name__ == "__main__":
    main()
