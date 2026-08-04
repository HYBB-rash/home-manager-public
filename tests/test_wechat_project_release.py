#!/usr/bin/env python3

import importlib.util
import io
import os
import pathlib
import pwd
import grp
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = pathlib.Path(os.environ.get(
    "WECHAT_PROJECT_RELEASE_MODULE",
    ROOT / "system" / "wechat-project-release.py",
))
SPEC = importlib.util.spec_from_file_location(
    "wechat_project_release", MODULE_PATH
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ProjectReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.temp.name)
        self.root = self.base / "store"
        self.user = pwd.getpwuid(os.getuid()).pw_name
        self.group = grp.getgrgid(os.getgid()).gr_name

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, entries):
        path = self.base / f"release-{len(list(self.base.glob('release-*')))}.tar"
        with tarfile.open(path, "w") as archive:
            for name, kind, content in entries:
                info = tarfile.TarInfo(name)
                if kind == "file":
                    payload = content.encode()
                    info.size = len(payload)
                    info.mode = 0o755 if name.endswith(".py") else 0o644
                    archive.addfile(info, io.BytesIO(payload))
                elif kind == "dir":
                    info.type = tarfile.DIRTYPE
                    archive.addfile(info)
                elif kind == "symlink":
                    info.type = tarfile.SYMTYPE
                    info.linkname = content
                    archive.addfile(info)
        return path

    def install(self, archive, release):
        return MODULE.install_release(
            archive, self.root, release, self.user, self.group, self.user
        )

    def test_installs_complete_release_and_switches_atomically(self):
        first = "1" * 40
        archive = self.archive([
            ("README.md", "file", "schema docs"),
            ("tests", "dir", ""),
            ("tests/test_query.py", "file", "pass"),
        ])
        destination = self.install(archive, first)
        self.assertEqual((destination / "README.md").read_text(), "schema docs")
        self.assertEqual(os.readlink(self.root / "project-current"),
                         f"project-releases/{first}")
        self.assertEqual((destination / "RELEASE").read_text().strip(), first)
        self.assertEqual((destination / "README.md").stat().st_mode & 0o777, 0o640)

        second = "2" * 40
        second_archive = self.archive([("README.md", "file", "new")])
        self.install(second_archive, second)
        self.assertEqual(os.readlink(self.root / "project-current"),
                         f"project-releases/{second}")
        self.assertEqual(os.readlink(self.root / "project-previous"),
                         f"project-releases/{first}")

    def test_rejects_path_escape_without_changing_current(self):
        release = "3" * 40
        good = self.archive([("README.md", "file", "good")])
        self.install(good, release)
        bad = self.archive([("../escape", "file", "bad")])
        with self.assertRaises(MODULE.ReleaseError):
            self.install(bad, "4" * 40)
        self.assertEqual(os.readlink(self.root / "project-current"),
                         f"project-releases/{release}")
        self.assertFalse((self.base / "escape").exists())

    def test_rejects_links_and_cleans_stage(self):
        archive = self.archive([("outside", "symlink", "/etc")])
        with self.assertRaises(MODULE.ReleaseError):
            self.install(archive, "5" * 40)
        releases = self.root / "project-releases"
        self.assertEqual(list(releases.glob(".stage.*")), [])

    def test_rejects_archive_root_member(self):
        archive = self.archive([(".", "dir", "")])
        with self.assertRaises(MODULE.ReleaseError):
            self.install(archive, "7" * 40)

    def test_same_release_requires_identical_archive(self):
        release = "6" * 40
        first = self.archive([("README.md", "file", "one")])
        self.install(first, release)
        altered = self.archive([("README.md", "file", "two")])
        with self.assertRaises(MODULE.ReleaseError):
            self.install(altered, release)


if __name__ == "__main__":
    unittest.main()
