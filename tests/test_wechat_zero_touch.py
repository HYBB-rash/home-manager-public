#!/usr/bin/env python3

import argparse
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tarfile
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = pathlib.Path(os.environ.get(
    "WECHAT_ZERO_TOUCH_MODULE", ROOT / "system" / "wechat-zero-touch.py"
))
SPEC = importlib.util.spec_from_file_location("wechat_zero_touch", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def digest(payload):
    return "sha256:" + hashlib.sha256(payload).hexdigest()


class ZeroTouchValidationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.release_id = "zt-2026.08.04-r42"
        self.release = self.base / self.release_id
        self.release.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, plane, members):
        name, destination = MODULE.ARTIFACTS[plane]
        path = self.release / "artifacts" / plane / name
        path.parent.mkdir(parents=True)
        rows = []
        with tarfile.open(path, "w:gz") as bundle:
            for member_name, payload, mode in members:
                info = tarfile.TarInfo(member_name)
                info.size = len(payload)
                info.mode = mode
                bundle.addfile(info, io.BytesIO(payload))
                rows.append({
                    "name": member_name,
                    "sha256": digest(payload),
                    "mode": f"0{mode:03o}",
                    "dest": destination,
                })
        rows.insert(0, {
            "name": name,
            "sha256": MODULE.sha256(path),
            "mode": "0550",
            "dest": destination,
        })
        return rows

    def make_release(self, binding_digest="sha256:" + "a" * 64):
        evidence = {
            "binding_sha256": binding_digest,
            "checks": ["fixed-root-entry", "vm-control", "host-pull", "user2-runtime", "cron-runtime"],
            "ok": True,
            "schema": "wechat-zt-preflight-v1",
        }
        payload = MODULE.canonical_json(evidence)
        reference = f"evidence/sha256-{hashlib.sha256(payload).hexdigest()}.json"
        evidence_path = self.release / reference
        evidence_path.parent.mkdir()
        evidence_path.write_bytes(payload)
        descriptor = {
            "descriptor_version": 1,
            "maturity": "deployable",
            "zero_touch_ready": True,
            "capability_grants": [],
            "evidence_refs": [reference],
            "release": {
                "id": self.release_id,
                "source": "git:" + "b" * 40,
                "created_at": "2026-08-04T00:00:00+08:00",
            },
            "units": [
                {
                    "name": "sync-daemon", "plane": "vm",
                    "artifacts": self.archive("vm", [("sync.py", b"pass\n", 0o440)]),
                },
                {
                    "name": "daily-digest", "plane": "user2",
                    "artifacts": self.archive("user2", [("bin/wx-check", b"pass\n", 0o550)]),
                    "schedule": {"kind": "hermes-cron", "cron": "0 8 * * *", "tz": "Asia/Shanghai"},
                },
            ],
        }
        (self.release / "descriptor.json").write_text(json.dumps(descriptor), encoding="utf-8")
        return descriptor

    def test_validates_portable_evidence_and_both_artifacts(self):
        binding = "sha256:" + "a" * 64
        self.make_release(binding)
        result = MODULE.validate_release(self.release, binding, os.getuid())
        self.assertEqual(result["release_id"], self.release_id)
        self.assertEqual(result["source_sha"], "b" * 40)

    def test_tampered_archive_is_refused(self):
        binding = "sha256:" + "a" * 64
        self.make_release(binding)
        path = self.release / "artifacts" / "vm" / MODULE.ARTIFACTS["vm"][0]
        path.write_bytes(path.read_bytes() + b"tamper")
        with self.assertRaisesRegex(MODULE.ReconcileError, "digest mismatch"):
            MODULE.validate_release(self.release, binding, os.getuid())

    def test_foreign_or_absolute_evidence_reference_is_refused(self):
        binding = "sha256:" + "a" * 64
        descriptor = self.make_release(binding)
        descriptor["evidence_refs"] = ["/tmp/preflight.json"]
        (self.release / "descriptor.json").write_text(json.dumps(descriptor), encoding="utf-8")
        with self.assertRaisesRegex(MODULE.ReconcileError, "not portable"):
            MODULE.validate_release(self.release, binding, os.getuid())

    def test_freezes_validated_artifacts_before_deployment(self):
        vm = self.base / "vm.tar.gz"
        user2 = self.base / "user2.tar.gz"
        vm.write_bytes(b"vm-payload")
        user2.write_bytes(b"user2-payload")
        release = {
            "descriptor_digest": "sha256:" + "f" * 64,
            "paths": {"vm": vm, "user2": user2},
            "digests": {"vm": MODULE.sha256(vm), "user2": MODULE.sha256(user2)},
        }
        MODULE.freeze_artifacts(release, self.base / "state")
        frozen_vm = release["paths"]["vm"]
        vm.write_bytes(b"changed-after-validation")
        self.assertEqual(frozen_vm.read_bytes(), b"vm-payload")
        self.assertEqual(frozen_vm.stat().st_mode & 0o777, 0o600)

    def test_managed_state_symlink_is_refused_without_reading_target(self):
        target = self.base / "private"
        target.write_text("do-not-copy", encoding="utf-8")
        link = self.base / "desired.json"
        link.symlink_to(target)
        with self.assertRaisesRegex(MODULE.ReconcileError, "not a physical file"):
            MODULE.read_owned_regular(link, os.getuid())


class FakeRunner:
    def __init__(self, fail_health=False, release_root=None):
        self.commands = []
        self.fail_health = fail_health
        self.release_root = release_root

    def run(self, command, *, env=None):
        self.commands.append(command)
        if "-u" in command and command[-2:] == ["id", "placeholder"]:
            return str(os.getuid())
        if len(command) >= 3 and command[-3:-1] == ["id", "-u"]:
            return str(os.getuid())
        if command and command[0] == "id-bin":
            return str(os.getuid())
        if "installer" in command:
            root = pathlib.Path(self.release_root)
            releases = root / "bundle-releases"
            releases.mkdir(parents=True, exist_ok=True)
            (releases / "new").mkdir(exist_ok=True)
            if not (root / "bundle-current").exists():
                (root / "bundle-current").symlink_to("bundle-releases/old")
                (root / "bundle-previous").symlink_to("bundle-releases/older")
            current = os.readlink(root / "bundle-current")
            (root / "bundle-previous").unlink()
            (root / "bundle-previous").symlink_to(current)
            (root / "bundle-current").unlink()
            (root / "bundle-current").symlink_to("bundle-releases/new")
        if self.fail_health and command[-1:] == ["--check-only"]:
            raise MODULE.ReconcileError("R-111", "synthetic health failure")
        return ""


def fake_args(base):
    home = base / "home"
    (home / "runtime").mkdir(parents=True)
    return argparse.Namespace(
        binding="binding", state_root=str(base / "state"), vmctl="vmctl",
        installer="installer", cron_reconciler="cron-reconciler",
        hermes_cli="hermes-cli", user2_wrapper="user2-wrapper",
        user2_home=str(home), user2_workspace=str(base / "workspace"),
        user2_release_root=str(base / "releases"), snapshot_db=str(base / "snapshot.db"),
        systemctl="systemctl", runuser="runuser", id="id-bin",
        operator="operator", user2_user="user2", user2_group="hermes-user2",
        release_dir=str(base / "input"),
    )


def fake_release(base, digest_value="sha256:" + "c" * 64):
    return {
        "descriptor_digest": digest_value,
        "release_id": "zt-2026.08.04-r42",
        "source_sha": "b" * 40,
        "units": {
            "user2": {"schedule": {"kind": "hermes-cron", "cron": "0 8 * * *", "tz": "Asia/Shanghai"}}
        },
        "paths": {"vm": base / "vm.tar.gz", "user2": base / "user2.tar.gz"},
        "digests": {"vm": "sha256:" + "d" * 64, "user2": "sha256:" + "e" * 64},
    }


class ZeroTouchTransactionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.args = fake_args(self.base)

    def tearDown(self):
        self.temp.cleanup()

    @mock.patch.object(MODULE.shutil, "chown", autospec=True)
    @mock.patch.object(MODULE, "freeze_artifacts")
    @mock.patch.object(MODULE, "validate_release")
    @mock.patch.object(MODULE, "preflight")
    def test_same_descriptor_is_read_only_noop(self, preflight, validate, _freeze, _chown):
        preflight.return_value = {"binding_sha256": "sha256:" + "a" * 64}
        validate.return_value = fake_release(self.base)
        state = pathlib.Path(self.args.state_root)
        MODULE.atomic_json(state / "current.json", {
            "descriptor_digest": validate.return_value["descriptor_digest"],
            "release_id": validate.return_value["release_id"],
            "source_sha": validate.return_value["source_sha"],
        })
        desired = MODULE.desired_cron(validate.return_value, self.args)
        desired_path = pathlib.Path(self.args.user2_home) / "runtime" / "wechat-zt-desired.json"
        desired_path.write_bytes(MODULE.canonical_json(desired))
        before = desired_path.stat().st_mtime_ns
        runner = FakeRunner()
        result = MODULE.reconcile(self.args, runner)
        self.assertIn("no-op", result)
        self.assertEqual(desired_path.stat().st_mtime_ns, before)
        flattened = [" ".join(command) for command in runner.commands]
        self.assertFalse(any("deploy" in command for command in flattened))
        self.assertFalse(any("snapshot-pull" in command for command in flattened))

    @mock.patch.object(MODULE.shutil, "chown", autospec=True)
    @mock.patch.object(MODULE, "freeze_artifacts")
    @mock.patch.object(MODULE, "validate_release")
    @mock.patch.object(MODULE, "preflight")
    def test_late_health_failure_rolls_back_cron_user2_and_vm(self, preflight, validate, _freeze, _chown):
        preflight.return_value = {"binding_sha256": "sha256:" + "a" * 64}
        validate.return_value = fake_release(self.base)
        root = pathlib.Path(self.args.user2_release_root)
        (root / "bundle-releases" / "old").mkdir(parents=True)
        (root / "bundle-releases" / "older").mkdir()
        (root / "bundle-current").symlink_to("bundle-releases/old")
        (root / "bundle-previous").symlink_to("bundle-releases/older")
        runner = FakeRunner(fail_health=True, release_root=root)
        with self.assertRaisesRegex(MODULE.ReconcileError, "code and schedule restored"):
            MODULE.reconcile(self.args, runner)
        self.assertEqual(os.readlink(root / "bundle-current"), "bundle-releases/old")
        flattened = [" ".join(command) for command in runner.commands]
        self.assertTrue(any("vmctl rollback" in command for command in flattened))
        self.assertGreaterEqual(sum("cron-reconciler" in command for command in flattened), 2)

    def test_runner_closes_stdin(self):
        source = pathlib.Path(MODULE_PATH).read_text(encoding="utf-8")
        self.assertIn("stdin=subprocess.DEVNULL", source)


if __name__ == "__main__":
    unittest.main()
