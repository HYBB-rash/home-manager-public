#!/usr/bin/env python3

import importlib.util
import os
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = pathlib.Path(os.environ.get(
    "WECHAT_RELEASE_STATUS_MODULE",
    ROOT / "system" / "wechat-release-status.py",
))
SPEC = importlib.util.spec_from_file_location(
    "wechat_release_status", MODULE_PATH
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class Second UserReleaseStatusTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        (self.root / "project-releases").mkdir()
        (self.root / "bundle-releases").mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def install_project(self, release="a" * 40):
        destination = self.root / "project-releases" / release
        destination.mkdir()
        (destination / "RELEASE").write_text(release + "\n", encoding="ascii")
        (self.root / "project-current").symlink_to(
            f"project-releases/{release}"
        )
        return release

    def test_reports_valid_selectors_and_absent_previous(self):
        release = self.install_project()
        bundle = "zt-2026.08.04-r42"
        (self.root / "bundle-releases" / bundle).mkdir()
        (self.root / "bundle-current").symlink_to(f"bundle-releases/{bundle}")

        self.assertEqual(MODULE.status(self.root), [
            f"user2-project-current: project-releases/{release}",
            "user2-project-previous: absent",
            f"user2-bundle-current: bundle-releases/{bundle}",
            "user2-bundle-previous: absent",
        ])

    def test_verify_project_requires_matching_physical_marker(self):
        release = self.install_project()
        self.assertEqual(
            MODULE.verify_project(self.root, release),
            f"verified Second User project release {release}",
        )
        marker = self.root / "project-releases" / release / "RELEASE"
        marker.unlink()
        marker.symlink_to(self.root / "outside")
        with self.assertRaisesRegex(MODULE.StatusError, "physical regular file"):
            MODULE.verify_project(self.root, release)

    def test_refuses_selector_escape_missing_target_and_non_symlink(self):
        current = self.root / "project-current"
        current.symlink_to("../outside")
        with self.assertRaisesRegex(MODULE.StatusError, "invalid Second User release target"):
            MODULE.status(self.root)
        current.unlink()
        current.symlink_to("project-releases/" + "b" * 40)
        with self.assertRaisesRegex(MODULE.StatusError, "missing Second User release target"):
            MODULE.status(self.root)
        current.unlink()
        current.write_text("not-a-link", encoding="ascii")
        with self.assertRaisesRegex(MODULE.StatusError, "not a symlink"):
            MODULE.status(self.root)

    def test_refuses_marker_mismatch(self):
        release = self.install_project()
        marker = self.root / "project-releases" / release / "RELEASE"
        marker.write_text("b" * 40 + "\n", encoding="ascii")
        with self.assertRaisesRegex(MODULE.StatusError, "does not match"):
            MODULE.verify_project(self.root, release)


if __name__ == "__main__":
    unittest.main()
