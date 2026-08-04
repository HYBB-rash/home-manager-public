#!/usr/bin/env python3

import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = pathlib.Path(
    os.environ.get(
        "WECHAT_CRON_RECONCILE_MODULE",
        ROOT / "system" / "wechat-cron-reconcile.py",
    )
)
SPEC = importlib.util.spec_from_file_location("wechat_cron_reconcile", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def desired(logical_name="daily-digest", schedule="0 8 * * *", script="/tmp/job.py"):
    return MODULE.DesiredJob(
        logical_name=logical_name,
        name=f"wechat-zt:{logical_name}",
        schedule=schedule,
        deliver="origin",
        script=script,
        workdir="/var/lib/hermes-user2/workspace",
    )


def actual(job_id, wanted):
    return {
        "id": job_id,
        **wanted.config(),
        "schedule_display": wanted.schedule,
        "schedule": {"kind": "cron", "value": wanted.schedule},
    }


def write_jobs(path, jobs):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": 1, "jobs": jobs}), encoding="utf-8")


class FakeHermes:
    def __init__(self, jobs_path, fail_action=None):
        self.jobs_path = jobs_path
        self.fail_action = fail_action
        self.calls = []
        self.counter = 0

    def _jobs(self):
        return MODULE.load_jobs(self.jobs_path)

    def _save(self, jobs):
        write_jobs(self.jobs_path, jobs)

    def _fail(self, action):
        self.calls.append(action)
        if self.fail_action == action:
            self.fail_action = None
            raise MODULE.CronReconcileError(f"synthetic {action} failure")

    def create(self, wanted):
        self._fail("create")
        self.counter += 1
        job_id = f"created{self.counter}"
        jobs = self._jobs()
        jobs.append(actual(job_id, wanted))
        self._save(jobs)
        return job_id

    def edit(self, job_id, wanted):
        self._fail("edit")
        jobs = self._jobs()
        for index, job in enumerate(jobs):
            if job["id"] == job_id:
                jobs[index] = actual(job_id, wanted)
                self._save(jobs)
                return
        raise MODULE.CronReconcileError("synthetic missing edit target")

    def remove(self, job_id):
        self._fail("remove")
        jobs = self._jobs()
        next_jobs = [job for job in jobs if job["id"] != job_id]
        if len(next_jobs) == len(jobs):
            raise MODULE.CronReconcileError("synthetic missing remove target")
        self._save(next_jobs)


class CronReconcileTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.jobs_path = self.base / "home" / "cron" / "jobs.json"
        self.inventory_path = self.base / "runtime" / "owned-jobs.json"

    def tearDown(self):
        self.temp.cleanup()

    def inventory(self, logical_name, job_id, wanted):
        return {
            logical_name: {
                "job_id": job_id,
                "fingerprint": MODULE.fingerprint(wanted.config()),
            }
        }

    def test_noop_requires_both_inventory_and_actual_fingerprint(self):
        wanted = desired()
        job = actual("job1", wanted)
        plan = MODULE.build_plan(
            {wanted.logical_name: wanted},
            self.inventory(wanted.logical_name, "job1", wanted),
            [job],
            "wechat-zt:",
        )
        self.assertEqual(plan, [])

    def test_unowned_name_collision_is_refused(self):
        wanted = desired()
        with self.assertRaisesRegex(MODULE.CronReconcileError, "unowned cron name"):
            MODULE.build_plan(
                {wanted.logical_name: wanted},
                {},
                [actual("foreign", wanted)],
                "wechat-zt:",
            )

    def test_actual_fingerprint_drift_is_refused_before_mutation(self):
        wanted = desired()
        changed = actual("job1", wanted)
        changed["deliver"] = "local"
        with self.assertRaisesRegex(MODULE.CronReconcileError, "fingerprint drift"):
            MODULE.build_plan(
                {wanted.logical_name: wanted},
                self.inventory(wanted.logical_name, "job1", wanted),
                [changed],
                "wechat-zt:",
            )

    def test_missing_owned_job_is_not_silently_recreated(self):
        wanted = desired()
        with self.assertRaisesRegex(MODULE.CronReconcileError, "is missing"):
            MODULE.build_plan(
                {wanted.logical_name: wanted},
                self.inventory(wanted.logical_name, "job1", wanted),
                [],
                "wechat-zt:",
            )

    def test_load_inventory_rejects_corrupt_or_wrong_prefix(self):
        self.inventory_path.parent.mkdir(parents=True)
        self.inventory_path.write_text("not-json", encoding="utf-8")
        with self.assertRaises(MODULE.CronReconcileError):
            MODULE.load_inventory(self.inventory_path, "wechat-zt:")
        self.inventory_path.write_text(
            json.dumps({"version": 1, "managed_name_prefix": "other:", "jobs": {}}),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(MODULE.CronReconcileError, "prefix mismatch"):
            MODULE.load_inventory(self.inventory_path, "wechat-zt:")

    def test_load_desired_requires_physical_script_inside_scripts_root(self):
        scripts = self.base / "scripts"
        scripts.mkdir()
        outside = self.base / "outside.py"
        outside.write_text("pass\n", encoding="utf-8")
        link = scripts / "job.py"
        link.symlink_to(outside)
        wanted = {
            "version": 1,
            "jobs": [
                {
                    "logical_name": "daily-digest",
                    "name": "wechat-zt:daily-digest",
                    "schedule": "0 8 * * *",
                    "deliver": "origin",
                    "script": str(link),
                    "no_agent": True,
                }
            ],
        }
        path = self.base / "desired.json"
        path.write_text(json.dumps(wanted), encoding="utf-8")
        with self.assertRaisesRegex(MODULE.CronReconcileError, "escapes"):
            MODULE.load_desired(path, "wechat-zt:", scripts)

    def test_create_and_inventory_are_idempotent(self):
        write_jobs(self.jobs_path, [])
        wanted = desired(script=str(self.base / "job.py"))
        client = FakeHermes(self.jobs_path)
        plan = MODULE.reconcile(
            {wanted.logical_name: wanted},
            {},
            self.jobs_path,
            self.inventory_path,
            "wechat-zt:",
            client,
        )
        self.assertEqual([operation.action for operation in plan], ["create"])
        inventory = MODULE.load_inventory(self.inventory_path, "wechat-zt:")
        self.assertEqual(inventory["daily-digest"]["job_id"], "created1")
        second = MODULE.reconcile(
            {wanted.logical_name: wanted},
            inventory,
            self.jobs_path,
            self.inventory_path,
            "wechat-zt:",
            client,
        )
        self.assertEqual(second, [])
        self.assertEqual(client.calls, ["create"])

    def test_edit_failure_preserves_old_job_and_inventory(self):
        old = desired(schedule="0 7 * * *", script=str(self.base / "job.py"))
        new = desired(schedule="0 8 * * *", script=str(self.base / "job.py"))
        write_jobs(self.jobs_path, [actual("job1", old)])
        inventory = self.inventory(old.logical_name, "job1", old)
        MODULE._write_inventory(self.inventory_path, "wechat-zt:", inventory)
        client = FakeHermes(self.jobs_path, fail_action="edit")
        with self.assertRaisesRegex(MODULE.CronReconcileError, "rolled back"):
            MODULE.reconcile(
                {new.logical_name: new},
                inventory,
                self.jobs_path,
                self.inventory_path,
                "wechat-zt:",
                client,
            )
        self.assertEqual(
            MODULE.fingerprint(MODULE.normalize_actual(MODULE.load_jobs(self.jobs_path)[0])),
            MODULE.fingerprint(old.config()),
        )
        self.assertEqual(
            MODULE.load_inventory(self.inventory_path, "wechat-zt:"), inventory
        )

    def test_later_failure_rolls_back_created_job(self):
        first = desired("daily-digest", script=str(self.base / "daily.py"))
        second = desired("quarterly-digest", script=str(self.base / "quarter.py"))
        write_jobs(self.jobs_path, [])

        class FailSecondCreate(FakeHermes):
            def create(self, wanted):
                if self.counter == 1:
                    raise MODULE.CronReconcileError("synthetic second create failure")
                return super().create(wanted)

        client = FailSecondCreate(self.jobs_path)
        with self.assertRaisesRegex(MODULE.CronReconcileError, "rolled back"):
            MODULE.reconcile(
                {first.logical_name: first, second.logical_name: second},
                {},
                self.jobs_path,
                self.inventory_path,
                "wechat-zt:",
                client,
            )
        self.assertEqual(MODULE.load_jobs(self.jobs_path), [])
        self.assertEqual(
            MODULE.load_inventory(self.inventory_path, "wechat-zt:"), {}
        )


if __name__ == "__main__":
    unittest.main()
