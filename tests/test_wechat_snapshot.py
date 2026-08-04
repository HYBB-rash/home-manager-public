"""Synthetic tests for complete SQLite snapshot publication."""

import importlib.util
import json
import os
import pathlib
import sqlite3
import tarfile
import tempfile
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).parents[1] / "system" / "wechat-snapshot.py"
SPEC = importlib.util.spec_from_file_location("wechat_snapshot", MODULE_PATH)
snapshot = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(snapshot)


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wechat-snapshot-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.source = self.root / "source.db"
        self.destination = self.root / "published"
        self.owner = __import__("pwd").getpwuid(os.getuid()).pw_name
        self.group = __import__("grp").getgrgid(os.getgid()).gr_name

    def tearDown(self):
        self.temporary.cleanup()

    def create_complete_database(self, marker: int) -> None:
        self.source.unlink(missing_ok=True)
        with sqlite3.connect(self.source) as connection:
            for table in sorted(snapshot.REQUIRED_TABLES):
                connection.execute(f'CREATE TABLE "{table}" (value INTEGER)')
            connection.execute("INSERT INTO meta VALUES (?)", (marker,))

    def test_publish_is_complete_and_read_only(self):
        self.create_complete_database(1)
        generation = snapshot.publish_source(
            self.source, self.destination, self.owner, self.group
        )
        current_database = self.destination / "current" / "snapshot.db"
        manifest_path = self.destination / "current" / "manifest.json"

        manifest = snapshot.load_and_validate_manifest(current_database, manifest_path)
        self.assertEqual(generation.name, manifest["generation_id"])
        self.assertEqual(
            sqlite3.connect(
                f"file:{current_database}?mode=ro&immutable=1", uri=True
            ).execute("SELECT value FROM meta").fetchone()[0],
            1,
        )
        with self.assertRaises(sqlite3.OperationalError):
            sqlite3.connect(
                f"file:{current_database}?mode=ro&immutable=1", uri=True
            ).execute("INSERT INTO meta VALUES (2)")

    def test_retention_prunes_only_old_generations(self):
        observed = []
        for marker in range(5):
            self.create_complete_database(marker)
            generation = snapshot.publish_source(
                self.source,
                self.destination,
                self.owner,
                self.group,
                retain=3,
            )
            observed.append(generation.name)

        generations = {
            path.name
            for path in (self.destination / "generations").iterdir()
            if path.is_dir()
        }
        self.assertEqual(len(generations), 3)
        self.assertEqual(
            (self.destination / "current").resolve().name,
            observed[-1],
        )
        self.assertIn(observed[-1], generations)
        self.assertNotIn(observed[0], generations)

    def test_incomplete_schema_is_rejected_without_switch(self):
        self.create_complete_database(1)
        first = snapshot.publish_source(
            self.source, self.destination, self.owner, self.group
        )
        with sqlite3.connect(self.source) as connection:
            connection.execute("DROP TABLE messages")

        with self.assertRaises(snapshot.SnapshotError):
            snapshot.publish_source(
                self.source, self.destination, self.owner, self.group
            )
        self.assertEqual((self.destination / "current").resolve(), first.resolve())

    def test_manifest_tampering_is_rejected(self):
        self.create_complete_database(1)
        snapshot.publish_source(
            self.source, self.destination, self.owner, self.group
        )
        database = self.destination / "current" / "snapshot.db"
        manifest_path = self.destination / "current" / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["sha256"] = "0" * 64
        tampered = self.root / "tampered.json"
        tampered.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaises(snapshot.SnapshotError):
            snapshot.load_and_validate_manifest(database, tampered)

    def test_source_glob_requires_exactly_one_snapshot(self):
        with self.assertRaises(snapshot.SnapshotError):
            snapshot.publish_glob(
                str(self.root / "published_*.db"),
                self.destination,
                self.owner,
                self.group,
            )

    def test_restricted_tar_fetch_accepts_only_canonical_database(self):
        self.create_complete_database(1)
        identity = self.root / "id_ed25519"
        known_hosts = self.root / "known_hosts"
        identity.touch()
        known_hosts.touch()

        def write_archive(command, *, stdout, check):
            self.assertTrue(check)
            self.assertEqual(command[-1], "wechat-snapshot-read-v1")
            with tarfile.open(fileobj=stdout, mode="w") as archive:
                archive.add(self.source, arcname="snapshot.db")

        with mock.patch.object(snapshot.subprocess, "run", side_effect=write_archive):
            database = snapshot._fetch_restricted_tar(
                self.root / "incoming",
                "127.0.0.1",
                22222,
                "wechat-exporter",
                identity,
                known_hosts,
            )
        self.assertTrue(database.is_file())
        self.assertEqual(snapshot.inspect_database(database)["integrity_check"], "ok")

    def test_restricted_tar_fetch_rejects_extra_members(self):
        self.create_complete_database(1)
        identity = self.root / "id_ed25519"
        known_hosts = self.root / "known_hosts"
        extra = self.root / "extra"
        identity.touch()
        known_hosts.touch()
        extra.write_text("unexpected", encoding="utf-8")

        def write_archive(command, *, stdout, check):
            with tarfile.open(fileobj=stdout, mode="w") as archive:
                archive.add(self.source, arcname="snapshot.db")
                archive.add(extra, arcname="extra")

        with mock.patch.object(snapshot.subprocess, "run", side_effect=write_archive):
            with self.assertRaises(snapshot.SnapshotError):
                snapshot._fetch_restricted_tar(
                    self.root / "incoming",
                    "127.0.0.1",
                    22222,
                    "wechat-exporter",
                    identity,
                    known_hosts,
                )


if __name__ == "__main__":
    unittest.main()
