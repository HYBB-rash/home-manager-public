#!/usr/bin/env python3
"""Reconcile only the Second User Hermes cron jobs owned by WeChat zero-touch."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
from dataclasses import dataclass
from typing import Any, Callable


LOGICAL_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
JOB_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
FINGERPRINT_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
CREATED_RE = re.compile(r"Created job:\s*([A-Za-z0-9_-]{1,128})(?:\s|$)")


class CronReconcileError(RuntimeError):
    """The requested cron state cannot be reconciled safely."""


@dataclass(frozen=True)
class DesiredJob:
    logical_name: str
    name: str
    schedule: str
    deliver: str
    script: str
    workdir: str | None
    no_agent: bool = True

    def config(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "schedule": self.schedule,
            "deliver": self.deliver,
            "script": self.script,
            "workdir": self.workdir,
            "no_agent": self.no_agent,
            "prompt": "",
            "skills": [],
            "model": None,
            "provider": None,
        }


@dataclass(frozen=True)
class Operation:
    action: str
    logical_name: str
    desired: DesiredJob | None = None
    actual: dict[str, Any] | None = None


def _schedule(job: dict[str, Any]) -> str:
    display = job.get("schedule_display")
    if isinstance(display, str) and display.strip():
        return display.strip()
    value = job.get("schedule")
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, dict):
        for key in ("display", "value", "expr", "run_at"):
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate.strip():
                return candidate.strip()
    return ""


def normalize_actual(job: dict[str, Any]) -> dict[str, Any]:
    deliver = job.get("deliver")
    if isinstance(deliver, list):
        if len(deliver) != 1:
            deliver = json.dumps(deliver, sort_keys=True, separators=(",", ":"))
        else:
            deliver = deliver[0]
    skills = job.get("skills")
    if not isinstance(skills, list):
        skills = [job["skill"]] if job.get("skill") else []
    return {
        "name": str(job.get("name") or ""),
        "schedule": _schedule(job),
        "deliver": str(deliver or "local"),
        "script": str(job.get("script") or ""),
        "workdir": job.get("workdir") or None,
        "no_agent": bool(job.get("no_agent", False)),
        "prompt": str(job.get("prompt") or ""),
        "skills": [str(value) for value in skills],
        "model": job.get("model") or None,
        "provider": job.get("provider") or None,
    }


def fingerprint(config: dict[str, Any]) -> str:
    payload = json.dumps(
        config, sort_keys=True, ensure_ascii=True, separators=(",", ":")
    ).encode("ascii")
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def _load_object(path: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CronReconcileError(f"cannot read {label}: {error}") from error
    if not isinstance(value, dict):
        raise CronReconcileError(f"{label} must be a JSON object")
    return value


def load_jobs(path: pathlib.Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    value = _load_object(path, "Hermes cron jobs")
    jobs = value.get("jobs", [])
    if not isinstance(jobs, list) or not all(isinstance(job, dict) for job in jobs):
        raise CronReconcileError("Hermes cron jobs has an invalid jobs array")
    return jobs


def load_inventory(path: pathlib.Path, prefix: str) -> dict[str, dict[str, str]]:
    if not path.exists():
        return {}
    value = _load_object(path, "owned-job inventory")
    if value.get("version") != 1 or value.get("managed_name_prefix") != prefix:
        raise CronReconcileError("owned-job inventory version or prefix mismatch")
    jobs = value.get("jobs")
    if not isinstance(jobs, dict):
        raise CronReconcileError("owned-job inventory has an invalid jobs object")
    result: dict[str, dict[str, str]] = {}
    for logical_name, entry in jobs.items():
        if not LOGICAL_NAME_RE.fullmatch(logical_name) or not isinstance(entry, dict):
            raise CronReconcileError("owned-job inventory contains an invalid entry")
        job_id = entry.get("job_id")
        expected = entry.get("fingerprint")
        if not isinstance(job_id, str) or not JOB_ID_RE.fullmatch(job_id):
            raise CronReconcileError("owned-job inventory contains an invalid job id")
        if not isinstance(expected, str) or not FINGERPRINT_RE.fullmatch(expected):
            raise CronReconcileError("owned-job inventory contains an invalid fingerprint")
        result[logical_name] = {"job_id": job_id, "fingerprint": expected}
    return result


def load_desired(
    path: pathlib.Path, prefix: str, script_root: pathlib.Path
) -> dict[str, DesiredJob]:
    value = _load_object(path, "desired cron state")
    rows = value.get("jobs")
    if value.get("version") != 1 or not isinstance(rows, list):
        raise CronReconcileError("desired cron state has an invalid version or jobs array")
    result: dict[str, DesiredJob] = {}
    root = script_root.resolve()
    for row in rows:
        if not isinstance(row, dict):
            raise CronReconcileError("desired cron state contains a non-object job")
        logical_name = row.get("logical_name")
        if not isinstance(logical_name, str) or not LOGICAL_NAME_RE.fullmatch(logical_name):
            raise CronReconcileError("desired cron state contains an invalid logical name")
        if logical_name in result:
            raise CronReconcileError(f"duplicate desired cron job: {logical_name}")
        name = row.get("name")
        if name != prefix + logical_name:
            raise CronReconcileError(f"managed job name mismatch: {logical_name}")
        schedule = row.get("schedule")
        deliver = row.get("deliver")
        script = row.get("script")
        workdir = row.get("workdir") or None
        if not all(isinstance(value, str) and value for value in (schedule, deliver, script)):
            raise CronReconcileError(f"managed job fields are incomplete: {logical_name}")
        script_path = pathlib.Path(script)
        if not script_path.is_absolute():
            raise CronReconcileError(
                f"managed script path must be absolute: {logical_name}"
            )
        try:
            resolved = script_path.resolve(strict=True)
            resolved.relative_to(root)
        except (OSError, ValueError) as error:
            raise CronReconcileError(
                f"managed script escapes the Second User scripts directory: {logical_name}"
            ) from error
        if script_path.is_symlink() or not script_path.is_file():
            raise CronReconcileError(
                f"managed script must be a physical regular file: {logical_name}"
            )
        if workdir is not None and (not isinstance(workdir, str) or not os.path.isabs(workdir)):
            raise CronReconcileError(f"managed workdir must be absolute: {logical_name}")
        if row.get("no_agent", True) is not True:
            raise CronReconcileError(f"managed jobs must use no-agent mode: {logical_name}")
        result[logical_name] = DesiredJob(
            logical_name=logical_name,
            name=name,
            schedule=schedule,
            deliver=deliver,
            script=str(script_path),
            workdir=workdir,
        )
    return result


def build_plan(
    desired: dict[str, DesiredJob],
    inventory: dict[str, dict[str, str]],
    actual_jobs: list[dict[str, Any]],
    prefix: str,
    recover_exact_collisions: bool = False,
) -> list[Operation]:
    by_id: dict[str, dict[str, Any]] = {}
    by_name: dict[str, list[dict[str, Any]]] = {}
    for job in actual_jobs:
        job_id = job.get("id")
        name = str(job.get("name") or "")
        if isinstance(job_id, str):
            by_id[job_id] = job
        by_name.setdefault(name, []).append(job)

    owned_actual: dict[str, dict[str, Any]] = {}
    for logical_name, entry in inventory.items():
        actual = by_id.get(entry["job_id"])
        expected_name = prefix + logical_name
        if actual is None:
            raise CronReconcileError(f"owned cron job is missing: {logical_name}")
        if actual.get("name") != expected_name or not expected_name.startswith(prefix):
            raise CronReconcileError(f"owned cron job name mismatch: {logical_name}")
        actual_fingerprint = fingerprint(normalize_actual(actual))
        if actual_fingerprint != entry["fingerprint"]:
            raise CronReconcileError(f"owned cron job fingerprint drift: {logical_name}")
        owned_actual[logical_name] = actual

    operations: list[Operation] = []
    for logical_name, wanted in desired.items():
        actual = owned_actual.get(logical_name)
        if actual is None:
            collisions = by_name.get(wanted.name, [])
            if collisions:
                if (
                    recover_exact_collisions
                    and len(collisions) == 1
                    and isinstance(collisions[0].get("id"), str)
                    and JOB_ID_RE.fullmatch(collisions[0]["id"])
                    and normalize_actual(collisions[0]) == wanted.config()
                ):
                    operations.append(
                        Operation("adopt", logical_name, desired=wanted, actual=collisions[0])
                    )
                    continue
                raise CronReconcileError(f"unowned cron name collision: {wanted.name}")
            operations.append(Operation("create", logical_name, desired=wanted))
        elif fingerprint(normalize_actual(actual)) != fingerprint(wanted.config()):
            operations.append(
                Operation("edit", logical_name, desired=wanted, actual=actual)
            )

    for logical_name, actual in owned_actual.items():
        if logical_name not in desired:
            operations.append(Operation("remove", logical_name, actual=actual))
    return operations


class HermesCron:
    def __init__(self, executable: pathlib.Path, jobs_path: pathlib.Path):
        self.executable = executable
        self.jobs_path = jobs_path

    def run(self, *args: str) -> str:
        environment = os.environ.copy()
        environment["NO_COLOR"] = "1"
        try:
            result = subprocess.run(
                [str(self.executable), "cron", *args],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env=environment,
                timeout=45,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise CronReconcileError(f"Hermes cron command failed: {error}") from error
        if result.returncode != 0:
            summary = " ".join(result.stdout.split())[:200]
            raise CronReconcileError(f"Hermes cron command refused: {summary}")
        return result.stdout

    def create(self, job: DesiredJob) -> str:
        before_ids = {
            row.get("id") for row in load_jobs(self.jobs_path)
            if isinstance(row.get("id"), str)
        }
        args = [
            "create",
            job.schedule,
            "",
            "--name",
            job.name,
            "--deliver",
            job.deliver,
            "--script",
            job.script,
            "--no-agent",
        ]
        if job.workdir:
            args.extend(["--workdir", job.workdir])
        output = self.run(*args)
        match = CREATED_RE.search(output)
        reported_id = match.group(1) if match is not None else None
        candidates = [
            row for row in load_jobs(self.jobs_path)
            if row.get("id") not in before_ids
            and isinstance(row.get("id"), str)
            and JOB_ID_RE.fullmatch(row["id"])
            and normalize_actual(row) == job.config()
        ]
        if reported_id is not None:
            reported = [row for row in candidates if row["id"] == reported_id]
            if len(reported) == 1:
                return reported_id
        if len(candidates) == 1:
            return candidates[0]["id"]
        raise CronReconcileError(
            "Hermes cron create did not produce exactly one matching job"
        )

    def edit(self, job_id: str, job: DesiredJob) -> None:
        args = [
            "edit",
            job_id,
            "--schedule",
            job.schedule,
            "--prompt",
            "",
            "--name",
            job.name,
            "--deliver",
            job.deliver,
            "--clear-skills",
            "--script",
            job.script,
            "--no-agent",
            "--model",
            "",
            "--provider",
            "",
            "--workdir",
            job.workdir or "",
        ]
        self.run(*args)

    def remove(self, job_id: str) -> None:
        self.run("remove", job_id)


def _desired_from_actual(logical_name: str, job: dict[str, Any]) -> DesiredJob:
    config = normalize_actual(job)
    if not config["no_agent"] or config["prompt"] or config["skills"]:
        raise CronReconcileError(f"owned job is not a managed no-agent job: {logical_name}")
    return DesiredJob(
        logical_name=logical_name,
        name=config["name"],
        schedule=config["schedule"],
        deliver=config["deliver"],
        script=config["script"],
        workdir=config["workdir"],
    )


def _write_inventory(
    path: pathlib.Path, prefix: str, jobs: dict[str, dict[str, str]]
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = json.dumps(
        {"version": 1, "managed_name_prefix": prefix, "jobs": jobs},
        sort_keys=True,
        indent=2,
    ) + "\n"
    descriptor, temporary = tempfile.mkstemp(prefix=".owned-jobs.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def reconcile(
    desired: dict[str, DesiredJob],
    inventory: dict[str, dict[str, str]],
    jobs_path: pathlib.Path,
    inventory_path: pathlib.Path,
    prefix: str,
    client: HermesCron,
    recover_exact_collisions: bool = False,
) -> list[Operation]:
    actual_jobs = load_jobs(jobs_path)
    plan = build_plan(
        desired, inventory, actual_jobs, prefix, recover_exact_collisions
    )
    if not plan:
        return plan

    next_inventory = {key: dict(value) for key, value in inventory.items()}
    applied: list[tuple[str, str, DesiredJob | None]] = []
    try:
        for operation in plan:
            if operation.action == "adopt":
                assert operation.actual is not None and operation.desired is not None
                job_id = str(operation.actual["id"])
                next_inventory[operation.logical_name] = {
                    "job_id": job_id,
                    "fingerprint": fingerprint(operation.desired.config()),
                }
            elif operation.action == "create":
                assert operation.desired is not None
                job_id = client.create(operation.desired)
                next_inventory[operation.logical_name] = {
                    "job_id": job_id,
                    "fingerprint": fingerprint(operation.desired.config()),
                }
                applied.append(("create", job_id, None))
            elif operation.action == "edit":
                assert operation.actual is not None and operation.desired is not None
                job_id = str(operation.actual["id"])
                old = _desired_from_actual(operation.logical_name, operation.actual)
                client.edit(job_id, operation.desired)
                next_inventory[operation.logical_name] = {
                    "job_id": job_id,
                    "fingerprint": fingerprint(operation.desired.config()),
                }
                applied.append(("edit", job_id, old))
            else:
                assert operation.actual is not None
                job_id = str(operation.actual["id"])
                old = _desired_from_actual(operation.logical_name, operation.actual)
                client.remove(job_id)
                next_inventory.pop(operation.logical_name, None)
                applied.append(("remove", job_id, old))
        verification = build_plan(
            desired, next_inventory, load_jobs(jobs_path), prefix
        )
        if verification:
            raise CronReconcileError("Hermes cron state did not converge after apply")
        _write_inventory(inventory_path, prefix, next_inventory)
        return plan
    except Exception as original:
        restored = {key: dict(value) for key, value in inventory.items()}
        rollback_errors: list[str] = []
        for action, job_id, old in reversed(applied):
            try:
                if action == "create":
                    client.remove(job_id)
                elif action == "edit":
                    assert old is not None
                    client.edit(job_id, old)
                else:
                    assert old is not None
                    replacement_id = client.create(old)
                    restored[old.logical_name] = {
                        "job_id": replacement_id,
                        "fingerprint": fingerprint(old.config()),
                    }
            except Exception as rollback_error:  # pragma: no cover - reported below
                rollback_errors.append(str(rollback_error))
        _write_inventory(inventory_path, prefix, restored)
        if rollback_errors:
            raise CronReconcileError(
                f"cron reconcile failed and rollback was incomplete: {rollback_errors[0]}"
            ) from original
        raise CronReconcileError(f"cron reconcile failed and was rolled back: {original}") from original


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--desired", type=pathlib.Path, required=True)
    parser.add_argument("--inventory", type=pathlib.Path, required=True)
    parser.add_argument("--jobs-file", type=pathlib.Path, required=True)
    parser.add_argument("--hermes-cli", type=pathlib.Path, required=True)
    parser.add_argument("--script-root", type=pathlib.Path, required=True)
    parser.add_argument("--managed-prefix", default="wechat-zt:")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--recover-exact-collisions", action="store_true")
    args = parser.parse_args()
    try:
        desired = load_desired(args.desired, args.managed_prefix, args.script_root)
        inventory = load_inventory(args.inventory, args.managed_prefix)
        plan = build_plan(
            desired,
            inventory,
            load_jobs(args.jobs_file),
            args.managed_prefix,
            args.recover_exact_collisions,
        )
        if args.dry_run:
            print(json.dumps([operation.action for operation in plan]))
            return 0
        applied = reconcile(
            desired,
            inventory,
            args.jobs_file,
            args.inventory,
            args.managed_prefix,
            HermesCron(args.hermes_cli, args.jobs_file),
            args.recover_exact_collisions,
        )
    except CronReconcileError as error:
        print(f"REFUSED R-104: {error}", file=os.sys.stderr)
        return 1
    summary = "no changes" if not applied else ",".join(
        operation.action for operation in applied
    )
    print(f"OK: cron {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
