#!/usr/bin/env python3
"""Fail-closed host reconciler for the managed WeChat release."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
from typing import Any


RELEASE_RE = re.compile(r"^zt-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-r[1-9][0-9]*$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
EVIDENCE_RE = re.compile(r"^evidence/sha256-([0-9a-f]{64})\.(json|txt|log|evidence)$")
ARTIFACTS = {
    "vm": ("wechat-vm-export.tar.gz", "vm.pkg"),
    "user2": ("wechat-consumer-zt.tar.gz", "user2.bundle"),
}


class ReconcileError(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def load_object(path: pathlib.Path, code: str, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReconcileError(code, f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise ReconcileError(code, f"{label} must be a JSON object")
    return value


def regular_owned(path: pathlib.Path, uid: int) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReconcileError("R-105", f"missing release file: {path.name}") from error
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != uid:
        raise ReconcileError("R-106", f"release file is not an operator-owned regular file: {path.name}")


def _safe_member(member: tarfile.TarInfo) -> pathlib.PurePosixPath:
    path = pathlib.PurePosixPath(member.name)
    if not member.name or path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ReconcileError("R-105", f"unsafe artifact member: {member.name!r}")
    if not member.isfile():
        raise ReconcileError("R-105", f"unsupported artifact member: {member.name}")
    return path


def validate_artifact(path: pathlib.Path, unit: dict[str, Any], owner_uid: int) -> str:
    plane = unit.get("plane")
    if plane not in ARTIFACTS:
        raise ReconcileError("R-100", "unknown release plane")
    archive_name, destination = ARTIFACTS[plane]
    regular_owned(path, owner_uid)
    artifacts = unit.get("artifacts")
    if not isinstance(artifacts, list):
        raise ReconcileError("R-100", f"{plane} artifacts are invalid")
    rows = {row.get("name"): row for row in artifacts if isinstance(row, dict)}
    archive = rows.get(archive_name)
    if not archive or archive.get("dest") != destination or not DIGEST_RE.fullmatch(str(archive.get("sha256", ""))):
        raise ReconcileError("R-100", f"{plane} archive declaration is invalid")
    actual_digest = sha256(path)
    if actual_digest != archive["sha256"]:
        raise ReconcileError("R-105", f"{plane} archive digest mismatch")

    expected_members = {name: row for name, row in rows.items() if name != archive_name}
    observed: set[str] = set()
    try:
        with tarfile.open(path, "r:gz") as bundle:
            for member in bundle.getmembers():
                name = _safe_member(member).as_posix()
                if name in observed or name not in expected_members:
                    raise ReconcileError("R-105", f"unexpected or duplicate {plane} member: {name}")
                stream = bundle.extractfile(member)
                if stream is None:
                    raise ReconcileError("R-105", f"cannot read {plane} member: {name}")
                digest = "sha256:" + hashlib.sha256(stream.read()).hexdigest()
                row = expected_members[name]
                if digest != row.get("sha256") or row.get("dest") != destination:
                    raise ReconcileError("R-105", f"{plane} member metadata mismatch: {name}")
                if row.get("mode") != f"0{member.mode & 0o777:03o}":
                    raise ReconcileError("R-105", f"{plane} member mode mismatch: {name}")
                observed.add(name)
    except (OSError, tarfile.TarError) as error:
        raise ReconcileError("R-105", f"cannot inspect {plane} archive: {error}") from error
    if observed != set(expected_members):
        raise ReconcileError("R-105", f"{plane} archive member set is incomplete")
    return actual_digest


def validate_release(release_dir: pathlib.Path, binding_digest: str, owner_uid: int) -> dict[str, Any]:
    try:
        root = release_dir.resolve(strict=True)
    except OSError as error:
        raise ReconcileError("R-105", f"release directory is unavailable: {error}") from error
    if not root.is_dir() or release_dir.is_symlink():
        raise ReconcileError("R-106", "release directory must be physical")
    descriptor_path = root / "descriptor.json"
    regular_owned(descriptor_path, owner_uid)
    descriptor = load_object(descriptor_path, "R-100", "release descriptor")
    release = descriptor.get("release") if isinstance(descriptor.get("release"), dict) else {}
    release_id = release.get("id")
    source = str(release.get("source", ""))
    if (
        descriptor.get("descriptor_version") != 1
        or descriptor.get("maturity") not in ("deployable", "verified")
        or descriptor.get("zero_touch_ready") is not True
        or descriptor.get("capability_grants") != []
        or not isinstance(release_id, str)
        or not RELEASE_RE.fullmatch(release_id)
        or not source.startswith("git:")
        or not SHA_RE.fullmatch(source[4:])
    ):
        raise ReconcileError("R-110", "release is not zero-touch ready")
    if root.name != release_id:
        raise ReconcileError("R-100", "release directory and descriptor id differ")

    evidence_refs = descriptor.get("evidence_refs")
    if not isinstance(evidence_refs, list) or not evidence_refs:
        raise ReconcileError("R-110", "readiness evidence is missing")
    for reference in evidence_refs:
        match = EVIDENCE_RE.fullmatch(str(reference))
        if match is None:
            raise ReconcileError("R-110", "readiness evidence reference is not portable")
        evidence_path = root.joinpath(*pathlib.PurePosixPath(reference).parts)
        regular_owned(evidence_path, owner_uid)
        if sha256(evidence_path) != "sha256:" + match.group(1):
            raise ReconcileError("R-110", "readiness evidence digest mismatch")
        evidence = load_object(evidence_path, "R-110", "readiness evidence")
        if evidence != {
            "binding_sha256": binding_digest,
            "checks": ["fixed-root-entry", "vm-control", "host-pull", "user2-runtime", "cron-runtime"],
            "ok": True,
            "schema": "wechat-zt-preflight-v1",
        }:
            raise ReconcileError("R-110", "readiness evidence does not match this platform")

    units = descriptor.get("units")
    if not isinstance(units, list) or len(units) != 2:
        raise ReconcileError("R-100", "release must contain exactly VM and Second User units")
    by_plane = {unit.get("plane"): unit for unit in units if isinstance(unit, dict)}
    if set(by_plane) != {"vm", "user2"} or by_plane["vm"].get("name") != "sync-daemon" or by_plane["user2"].get("name") != "daily-digest":
        raise ReconcileError("R-100", "release units do not match the platform contract")
    paths = {}
    digests = {}
    for plane, (name, _) in ARTIFACTS.items():
        path = root / "artifacts" / plane / name
        paths[plane] = path
        digests[plane] = validate_artifact(path, by_plane[plane], owner_uid)
    return {
        "descriptor": descriptor,
        "descriptor_digest": sha256(descriptor_path),
        "release_id": release_id,
        "source_sha": source[4:],
        "units": by_plane,
        "paths": paths,
        "digests": digests,
    }


class Runner:
    def run(self, command: list[str], *, env: dict[str, str] | None = None) -> str:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=env,
            timeout=1800,
            check=False,
        )
        if result.returncode != 0:
            name = pathlib.Path(command[0]).name
            raise ReconcileError(
                "R-111", f"{name} failed noninteractively with exit {result.returncode}"
            )
        return result.stdout


def atomic_json(path: pathlib.Path, value: dict[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(canonical_json(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)


def read_owned_regular(path: pathlib.Path, uid: int) -> bytes | None:
    if not path.exists() and not path.is_symlink():
        return None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise ReconcileError("R-109", f"managed state is not a physical file: {path.name}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != uid or metadata.st_size > 1024 * 1024:
            raise ReconcileError("R-109", f"managed state ownership or size is invalid: {path.name}")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            return stream.read()
    finally:
        os.close(descriptor)


def freeze_artifacts(release: dict[str, Any], state_root: pathlib.Path) -> None:
    identity = release["descriptor_digest"].removeprefix("sha256:")
    frozen_root = state_root / "artifacts" / identity
    frozen_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(frozen_root, 0o700)
    for plane in ("vm", "user2"):
        source = release["paths"][plane]
        destination = frozen_root / ARTIFACTS[plane][0]
        expected = release["digests"][plane]
        if destination.exists():
            if destination.is_symlink() or not destination.is_file() or sha256(destination) != expected:
                raise ReconcileError("R-105", f"frozen {plane} artifact drifted")
        else:
            descriptor, temporary = tempfile.mkstemp(prefix=f".{plane}.", dir=frozen_root)
            try:
                os.fchmod(descriptor, 0o600)
                with source.open("rb") as incoming, os.fdopen(descriptor, "wb") as output:
                    shutil.copyfileobj(incoming, output)
                    output.flush()
                    os.fsync(output.fileno())
                if sha256(pathlib.Path(temporary)) != expected:
                    raise ReconcileError("R-105", f"{plane} artifact changed while freezing")
                os.replace(temporary, destination)
            finally:
                pathlib.Path(temporary).unlink(missing_ok=True)
        release["paths"][plane] = destination


def preflight(args: argparse.Namespace, runner: Runner) -> dict[str, Any]:
    if os.geteuid() != 0:
        raise ReconcileError("R-111", "fixed root entry is not active")
    binding_path = pathlib.Path(args.binding)
    binding = load_object(binding_path, "R-100", "platform binding")
    if binding.get("binding_version") != 1 or binding.get("consumer_mode") != "bundle":
        raise ReconcileError("R-100", "unsupported platform binding")
    for executable in (args.vmctl, args.installer, args.cron_reconciler, args.hermes_cli, args.runuser):
        if not os.path.isfile(executable) or not os.access(executable, os.X_OK):
            raise ReconcileError("R-102", f"required executable is unavailable: {executable}")
    runner.run([args.systemctl, "is-active", "wechat-exporter-vm.service"])
    runner.run([args.systemctl, "is-enabled", "wechat-snapshot-pull.timer"])
    runner.run([args.systemctl, "is-active", "hermes-user2.service"])
    runner.run([args.runuser, "-u", args.operator, "--", args.vmctl, "release-status"])
    scripts = pathlib.Path(args.user2_home) / "scripts"
    wrapper = scripts / "wechat-zt-daily-digest"
    if wrapper.is_symlink() or not wrapper.is_file() or not os.access(wrapper, os.X_OK):
        raise ReconcileError("R-106", "Second User managed cron wrapper is not a physical executable")
    return {
        "binding_sha256": sha256(binding_path),
        "checks": ["fixed-root-entry", "vm-control", "host-pull", "user2-runtime", "cron-runtime"],
        "ok": True,
        "schema": "wechat-zt-preflight-v1",
    }


def desired_cron(release: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    schedule = release["units"]["user2"].get("schedule", {})
    if schedule.get("kind") != "hermes-cron" or schedule.get("tz") != "Asia/Shanghai":
        raise ReconcileError("R-104", "unsupported Second User schedule")
    cron = schedule.get("cron")
    if not isinstance(cron, str) or not cron.strip():
        raise ReconcileError("R-104", "Second User cron expression is missing")
    return {
        "version": 1,
        "jobs": [{
            "logical_name": "daily-digest",
            "name": "wechat-zt:daily-digest",
            "schedule": cron,
            "deliver": "origin",
            "script": str(pathlib.Path(args.user2_home) / "scripts" / "wechat-zt-daily-digest"),
            "workdir": args.user2_workspace,
            "no_agent": True,
        }],
    }


def cron_command(args: argparse.Namespace, desired_path: pathlib.Path) -> list[str]:
    return [
        args.runuser, "-u", args.user2_user, "--", args.cron_reconciler,
        "--desired", str(desired_path),
        "--inventory", str(pathlib.Path(args.user2_home) / "runtime" / "wechat-zt-owned-jobs.json"),
        "--jobs-file", str(pathlib.Path(args.user2_home) / "cron" / "jobs.json"),
        "--hermes-cli", args.hermes_cli,
        "--script-root", str(pathlib.Path(args.user2_home) / "scripts"),
    ]


def restore_release_link(root: pathlib.Path, current_name: str, old_target: str | None, prefix: str) -> None:
    current = root / current_name
    if old_target is None:
        if current.is_symlink():
            current.unlink()
        return
    if not old_target.startswith(prefix + "/") or not (root / old_target).is_dir():
        raise ReconcileError("R-109", "previous release target is invalid")
    temporary = root / f".{current_name}.rollback"
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(old_target)
    os.replace(temporary, current)


def reconcile(args: argparse.Namespace, runner: Runner) -> str:
    evidence = preflight(args, runner)
    owner_uid = int(runner.run([args.id, "-u", args.operator]).strip())
    user2_uid = int(runner.run([args.id, "-u", args.user2_user]).strip())
    release = validate_release(pathlib.Path(args.release_dir), evidence["binding_sha256"], owner_uid)
    state_root = pathlib.Path(args.state_root)
    current_state_path = state_root / "current.json"
    previous_state_path = state_root / "previous.json"
    current_state = load_object(current_state_path, "R-109", "current release state") if current_state_path.exists() else None
    desired = desired_cron(release, args)
    desired_path = pathlib.Path(args.user2_home) / "runtime" / "wechat-zt-desired.json"
    old_desired = read_owned_regular(desired_path, user2_uid)

    if current_state and current_state.get("descriptor_digest") == release["descriptor_digest"]:
        if old_desired != canonical_json(desired):
            raise ReconcileError("R-109", "managed cron desired state drifted from current release")
        runner.run(cron_command(args, desired_path))
        runner.run([
            args.runuser, "-u", args.user2_user, "--", args.user2_wrapper, "--check-only"
        ])
        return f"no-op release={release['release_id']}"

    runtime_root = pathlib.Path(args.user2_home) / "runtime"
    probe_descriptor, probe_name = tempfile.mkstemp(prefix=".wechat-zt-preflight.", dir=runtime_root)
    probe_path = pathlib.Path(probe_name)
    try:
        with os.fdopen(probe_descriptor, "wb") as stream:
            stream.write(canonical_json(desired))
        os.chmod(probe_path, 0o640)
        shutil.chown(probe_path, user=args.user2_user, group=args.user2_group)
        runner.run([*cron_command(args, probe_path), "--dry-run"])
    finally:
        probe_path.unlink(missing_ok=True)

    freeze_artifacts(release, state_root)
    atomic_json(desired_path, desired, 0o640)
    shutil.chown(desired_path, user=args.user2_user, group=args.user2_group)
    user2_root = pathlib.Path(args.user2_release_root)
    old_user2_target = os.readlink(user2_root / "bundle-current") if (user2_root / "bundle-current").is_symlink() else None
    vm_changed = user2_changed = cron_changed = False
    try:
        runner.run([
            args.runuser, "-u", args.operator, "--", args.vmctl, "deploy", "--artifact",
            release["source_sha"], str(release["paths"]["vm"]), release["digests"]["vm"],
        ])
        vm_changed = True
        runner.run([args.systemctl, "start", "wechat-snapshot-pull.service"])
        runner.run([
            args.installer,
            "--archive", str(release["paths"]["user2"]),
            "--root", args.user2_release_root,
            "--release", release["release_id"],
            "--owner", "root", "--group", args.user2_group,
            "--expected-archive-owner", "root",
            "--release-directory", "bundle-releases",
            "--current-link", "bundle-current",
            "--previous-link", "bundle-previous",
            "--expected-sha256", release["digests"]["user2"],
        ])
        user2_changed = True
        runner.run(cron_command(args, desired_path))
        cron_changed = True
        runner.run([
            args.runuser, "-u", args.user2_user, "--", args.user2_wrapper, "--check-only"
        ])
    except Exception as error:
        rollback_errors = []
        if cron_changed:
            try:
                desired_path.write_bytes(old_desired or canonical_json({"version": 1, "jobs": []}))
                shutil.chown(desired_path, user=args.user2_user, group=args.user2_group)
                runner.run(cron_command(args, desired_path))
                if old_desired is None:
                    desired_path.unlink()
            except Exception as rollback_error:
                rollback_errors.append(f"cron: {rollback_error}")
        elif old_desired is None:
            desired_path.unlink(missing_ok=True)
        else:
            desired_path.write_bytes(old_desired)
            shutil.chown(desired_path, user=args.user2_user, group=args.user2_group)
        if user2_changed:
            try:
                restore_release_link(user2_root, "bundle-current", old_user2_target, "bundle-releases")
            except Exception as rollback_error:
                rollback_errors.append(f"user2: {rollback_error}")
        if vm_changed:
            try:
                runner.run([args.runuser, "-u", args.operator, "--", args.vmctl, "rollback"])
            except Exception as rollback_error:
                rollback_errors.append(f"vm: {rollback_error}")
        suffix = f"; rollback incomplete: {rollback_errors[0]}" if rollback_errors else "; code and schedule restored"
        raise ReconcileError("R-103", f"release transaction failed: {error}{suffix}") from error

    next_state = {
        "descriptor_digest": release["descriptor_digest"],
        "release_id": release["release_id"],
        "source_sha": release["source_sha"],
    }
    if current_state:
        atomic_json(previous_state_path, current_state)
    atomic_json(current_state_path, next_state)
    return f"reconciled release={release['release_id']} vm+snapshot+user2+cron"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--binding", required=True)
    result.add_argument("--state-root", required=True)
    result.add_argument("--vmctl", required=True)
    result.add_argument("--installer", required=True)
    result.add_argument("--cron-reconciler", required=True)
    result.add_argument("--hermes-cli", required=True)
    result.add_argument("--user2-wrapper", required=True)
    result.add_argument("--user2-home", required=True)
    result.add_argument("--user2-workspace", required=True)
    result.add_argument("--user2-release-root", required=True)
    result.add_argument("--snapshot-db", required=True)
    result.add_argument("--systemctl", default="systemctl")
    result.add_argument("--runuser", default="runuser")
    result.add_argument("--id", default="id")
    result.add_argument("--operator", default="user")
    result.add_argument("--user2-user", default="user2")
    result.add_argument("--user2-group", default="hermes-user2")
    commands = result.add_subparsers(dest="command", required=True)
    commands.add_parser("preflight")
    apply = commands.add_parser("reconcile")
    apply.add_argument("--release-dir", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "preflight":
            output = canonical_json(preflight(args, Runner())).decode("ascii").rstrip()
        else:
            output = reconcile(args, Runner())
    except ReconcileError as error:
        print(f"REFUSED {error.code}: {error}", file=os.sys.stderr)
        return 1
    print(f"OK: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
