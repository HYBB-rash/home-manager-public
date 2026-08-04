#!/usr/bin/env python3
"""Validate and atomically publish complete WeChat SQLite snapshots."""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import grp
import hashlib
import json
import os
import pathlib
import pwd
import re
import shutil
import sqlite3
import subprocess
import tempfile
import tarfile
import uuid


FORMAT_VERSION = 1
REQUIRED_TABLES = frozenset(
    {
        "meta",
        "contacts",
        "groups",
        "group_members",
        "chats",
        "messages",
        "media",
        "contact_labels",
        "biz_info",
        "voices",
        "sessions",
    }
)


class SnapshotError(RuntimeError):
    pass


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _open_read_only(path: pathlib.Path) -> sqlite3.Connection:
    uri = f"file:{path.resolve()}?mode=ro&immutable=1"
    return sqlite3.connect(uri, uri=True)


def inspect_database(path: pathlib.Path) -> dict[str, object]:
    if not path.is_file():
        raise SnapshotError(f"snapshot is not a regular file: {path}")

    try:
        with _open_read_only(path) as connection:
            connection.execute("PRAGMA query_only = ON")
            integrity_rows = connection.execute("PRAGMA integrity_check").fetchall()
            integrity = [str(row[0]) for row in integrity_rows]
            if integrity != ["ok"]:
                raise SnapshotError(f"SQLite integrity_check failed: {integrity[:3]}")
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_schema WHERE type = 'table'"
                )
            }
    except sqlite3.Error as error:
        raise SnapshotError(f"cannot validate SQLite snapshot: {error}") from error

    missing = sorted(REQUIRED_TABLES - tables)
    if missing:
        raise SnapshotError(f"snapshot is missing required tables: {', '.join(missing)}")

    return {
        "size": path.stat().st_size,
        "sha256": _sha256(path),
        "integrity_check": "ok",
        "required_tables": sorted(REQUIRED_TABLES),
    }


def load_and_validate_manifest(
    database: pathlib.Path, manifest_path: pathlib.Path
) -> dict[str, object]:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SnapshotError(f"cannot read snapshot manifest: {error}") from error

    if manifest.get("format_version") != FORMAT_VERSION:
        raise SnapshotError("unsupported snapshot manifest format")
    if manifest.get("database") != "snapshot.db":
        raise SnapshotError("manifest database name is not canonical")

    observed = inspect_database(database)
    for field in ("size", "sha256", "integrity_check", "required_tables"):
        if manifest.get(field) != observed[field]:
            raise SnapshotError(f"manifest {field} does not match snapshot")
    if manifest.get("generation_id") != observed["sha256"]:
        raise SnapshotError("manifest generation_id does not match snapshot hash")
    return manifest


def _resolve_ids(owner: str, group: str) -> tuple[int, int]:
    try:
        return pwd.getpwnam(owner).pw_uid, grp.getgrnam(group).gr_gid
    except KeyError as error:
        raise SnapshotError(f"unknown owner or group: {error}") from error


def _fsync_directory(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _install_generation(
    database: pathlib.Path,
    manifest: dict[str, object],
    destination: pathlib.Path,
    owner: str,
    group: str,
    retain: int,
) -> pathlib.Path:
    if retain < 1:
        raise SnapshotError("snapshot retention must be at least one generation")
    uid, gid = _resolve_ids(owner, group)
    destination.mkdir(parents=True, exist_ok=True)
    generations = destination / "generations"
    generations.mkdir(mode=0o750, exist_ok=True)
    os.chown(destination, uid, gid)
    os.chmod(destination, 0o750)
    os.chown(generations, uid, gid)
    os.chmod(generations, 0o750)

    generation_id = str(manifest["generation_id"])
    final_generation = generations / generation_id
    if not final_generation.exists():
        stage = pathlib.Path(
            tempfile.mkdtemp(prefix=".staging-", dir=str(generations))
        )
        try:
            staged_database = stage / "snapshot.db"
            staged_manifest = stage / "manifest.json"
            shutil.copyfile(database, staged_database)
            staged_manifest.write_text(
                json.dumps(manifest, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            load_and_validate_manifest(staged_database, staged_manifest)

            for path in (staged_database, staged_manifest):
                os.chown(path, uid, gid)
                os.chmod(path, 0o440)
                with path.open("rb") as handle:
                    os.fsync(handle.fileno())
            os.rename(stage, final_generation)
            os.chown(final_generation, uid, gid)
            os.chmod(final_generation, 0o550)
            _fsync_directory(generations)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    else:
        load_and_validate_manifest(
            final_generation / "snapshot.db", final_generation / "manifest.json"
        )

    temporary_link = destination / f".current-{uuid.uuid4().hex}"
    temporary_link.symlink_to(pathlib.Path("generations") / generation_id)
    os.replace(temporary_link, destination / "current")
    _fsync_directory(destination)
    _prune_generations(destination, retain)
    return final_generation


def _prune_generations(destination: pathlib.Path, retain: int) -> None:
    generations = destination / "generations"
    current = (destination / "current").resolve(strict=True)
    candidates = [
        path
        for path in generations.iterdir()
        if path.is_dir()
        and not path.is_symlink()
        and re.fullmatch(r"[0-9a-f]{64}", path.name)
    ]
    candidates.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
    keep = {current}
    for candidate in candidates:
        if len(keep) >= retain:
            break
        keep.add(candidate.resolve())
    for candidate in candidates:
        if candidate.resolve() not in keep:
            os.chmod(candidate, 0o750)
            shutil.rmtree(candidate)
    _fsync_directory(generations)


def publish_source(
    source: pathlib.Path,
    destination: pathlib.Path,
    owner: str,
    group: str,
    retain: int = 3,
) -> pathlib.Path:
    destination.mkdir(parents=True, exist_ok=True)
    temporary = destination / f".backup-{uuid.uuid4().hex}.db"
    try:
        with _open_read_only(source) as source_connection:
            source_connection.execute("PRAGMA query_only = ON")
            with sqlite3.connect(temporary) as destination_connection:
                source_connection.backup(destination_connection)
        observed = inspect_database(temporary)
        manifest: dict[str, object] = {
            "format_version": FORMAT_VERSION,
            "database": "snapshot.db",
            "generation_id": observed["sha256"],
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            **observed,
        }
        return _install_generation(
            temporary, manifest, destination, owner, group, retain
        )
    finally:
        temporary.unlink(missing_ok=True)


def publish_glob(
    pattern: str,
    destination: pathlib.Path,
    owner: str,
    group: str,
    retain: int = 3,
) -> pathlib.Path:
    matches = [pathlib.Path(path) for path in glob.glob(pattern)]
    if len(matches) != 1:
        raise SnapshotError(
            f"expected exactly one completed exporter snapshot, found {len(matches)}"
        )
    return publish_source(matches[0], destination, owner, group, retain)


def _fetch_sftp(
    incoming: pathlib.Path,
    host: str,
    port: int,
    user: str,
    identity: pathlib.Path,
    known_hosts: pathlib.Path,
) -> tuple[pathlib.Path, pathlib.Path]:
    if not identity.is_file():
        raise SnapshotError(f"missing host-managed SSH identity: {identity}")
    if not known_hosts.is_file():
        raise SnapshotError(f"missing pinned SSH known_hosts file: {known_hosts}")

    incoming.mkdir(parents=True, exist_ok=True)
    database = incoming / "snapshot.db"
    manifest = incoming / "manifest.json"
    batch = incoming / "sftp.batch"
    batch.write_text(
        f"get /current/snapshot.db {database}\n"
        f"get /current/manifest.json {manifest}\n",
        encoding="utf-8",
    )
    command = [
        "sftp",
        "-q",
        "-b",
        str(batch),
        "-P",
        str(port),
        "-i",
        str(identity),
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        "HostKeyAlias=wechat-exporter-vm",
        f"{user}@{host}",
    ]
    try:
        subprocess.run(command, check=True)
    except subprocess.CalledProcessError as error:
        raise SnapshotError(
            f"SFTP snapshot fetch failed with status {error.returncode}"
        ) from error
    finally:
        batch.unlink(missing_ok=True)
    return database, manifest


def _fetch_restricted_tar(
    incoming: pathlib.Path,
    host: str,
    port: int,
    user: str,
    identity: pathlib.Path,
    known_hosts: pathlib.Path,
) -> pathlib.Path:
    """Fetch one fixed database stream from a forced-command SSH key."""
    if not identity.is_file():
        raise SnapshotError(f"missing host-managed SSH identity: {identity}")
    if not known_hosts.is_file():
        raise SnapshotError(f"missing pinned SSH known_hosts file: {known_hosts}")

    incoming.mkdir(parents=True, exist_ok=True)
    archive = incoming / "snapshot.tar"
    database = incoming / "snapshot.db"
    command = [
        "ssh",
        "-p",
        str(port),
        "-i",
        str(identity),
        "-o",
        "BatchMode=yes",
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        "HostKeyAlias=wechat-exporter-vm",
        f"{user}@{host}",
        "wechat-snapshot-read-v1",
    ]
    try:
        with archive.open("wb") as output:
            subprocess.run(command, stdout=output, check=True)
        with tarfile.open(archive, "r:") as stream:
            members = stream.getmembers()
            if (
                len(members) != 1
                or members[0].name != "snapshot.db"
                or not members[0].isreg()
            ):
                raise SnapshotError("restricted snapshot stream has unexpected members")
            source = stream.extractfile(members[0])
            if source is None:
                raise SnapshotError("restricted snapshot stream has no database payload")
            with source, database.open("wb") as output:
                shutil.copyfileobj(source, output)
    except (OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        raise SnapshotError(f"restricted snapshot fetch failed: {error}") from error
    finally:
        archive.unlink(missing_ok=True)
    return database


def pull_snapshot(args: argparse.Namespace) -> pathlib.Path:
    with tempfile.TemporaryDirectory(prefix="wechat-pull-", dir=args.incoming) as temp:
        incoming = pathlib.Path(temp)
        if args.transport == "sftp":
            database, manifest_path = _fetch_sftp(
                incoming,
                args.host,
                args.port,
                args.user,
                pathlib.Path(args.identity),
                pathlib.Path(args.known_hosts),
            )
            manifest = load_and_validate_manifest(database, manifest_path)
            return _install_generation(
                database,
                manifest,
                pathlib.Path(args.destination),
                args.owner,
                args.group,
                args.retain,
            )
        database = _fetch_restricted_tar(
            incoming,
            args.host,
            args.port,
            args.user,
            pathlib.Path(args.identity),
            pathlib.Path(args.known_hosts),
        )
        # The guest cannot create a root-owned manifest in the rootless mode.
        # Rebuild and validate the host generation from the fixed database stream.
        return publish_source(
            database,
            pathlib.Path(args.destination),
            args.owner,
            args.group,
            args.retain,
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    publish = subparsers.add_parser("publish")
    source = publish.add_mutually_exclusive_group(required=True)
    source.add_argument("--source", type=pathlib.Path)
    source.add_argument("--source-glob")
    publish.add_argument("--destination", required=True, type=pathlib.Path)
    publish.add_argument("--owner", default="root")
    publish.add_argument("--group", required=True)
    publish.add_argument("--retain", type=int, default=3)

    verify = subparsers.add_parser("verify")
    verify.add_argument("--database", required=True, type=pathlib.Path)
    verify.add_argument("--manifest", required=True, type=pathlib.Path)

    pull = subparsers.add_parser("pull")
    pull.add_argument("--host", required=True)
    pull.add_argument("--port", type=int, default=22)
    pull.add_argument("--user", required=True)
    pull.add_argument("--transport", choices=["sftp", "restricted-tar"], default="sftp")
    pull.add_argument("--identity", required=True)
    pull.add_argument("--known-hosts", required=True)
    pull.add_argument("--incoming", required=True)
    pull.add_argument("--destination", required=True)
    pull.add_argument("--owner", default="root")
    pull.add_argument("--group", required=True)
    pull.add_argument("--retain", type=int, default=3)
    return parser


def main() -> None:
    args = _parser().parse_args()
    try:
        if args.command == "publish":
            if args.source is not None:
                result = publish_source(
                    args.source,
                    args.destination,
                    args.owner,
                    args.group,
                    args.retain,
                )
            else:
                result = publish_glob(
                    args.source_glob,
                    args.destination,
                    args.owner,
                    args.group,
                    args.retain,
                )
            print(result)
        elif args.command == "verify":
            manifest = load_and_validate_manifest(args.database, args.manifest)
            print(manifest["generation_id"])
        else:
            print(pull_snapshot(args))
    except SnapshotError as error:
        raise SystemExit(f"wechat-snapshot: {error}") from error


if __name__ == "__main__":
    main()
