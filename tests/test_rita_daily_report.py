"""Tests for Second User's snapshot-only daily report helper."""

import importlib.util
import os
import pathlib
import sqlite3
import tempfile
import unittest


MODULE_PATH = (
    pathlib.Path(__file__).parents[1]
    / "system/user2-skills/wechat-daily/scripts/daily_report.py"
)
SPEC = importlib.util.spec_from_file_location("user2_daily_report", MODULE_PATH)
report = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(report)


class DailyReportTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="user2-daily-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.database = self.root / "snapshot.db"
        with sqlite3.connect(self.database) as connection:
            connection.execute("CREATE TABLE meta (key TEXT, value TEXT)")
            connection.execute("CREATE TABLE chats (peer_username TEXT, peer_display TEXT)")
            connection.execute(
                "CREATE TABLE messages (chat_username TEXT, create_time INTEGER, text TEXT)"
            )
            connection.execute(
                "INSERT INTO messages VALUES ('room@chatroom', strftime('%s', 'now'), 'test')"
            )
        self.previous = os.environ.get("WECHAT_SNAPSHOT_DB")
        os.environ["WECHAT_SNAPSHOT_DB"] = str(self.database)

    def tearDown(self):
        if self.previous is None:
            os.environ.pop("WECHAT_SNAPSHOT_DB", None)
        else:
            os.environ["WECHAT_SNAPSHOT_DB"] = self.previous
        self.temporary.cleanup()

    def test_smoke_validation_never_queries_message_text(self):
        report.validate_snapshot(self.database)

    def test_report_stays_in_workspace_and_defaults_to_aggregates(self):
        workspace = self.root / "workspace"
        workspace.mkdir()
        previous_cwd = pathlib.Path.cwd()
        os.chdir(workspace)
        try:
            target = report.output_path("reports/daily.md")
            target.parent.mkdir(parents=True)
            target.write_text(report.render_report(self.database, 24, False), encoding="utf-8")
        finally:
            os.chdir(previous_cwd)
        text = target.read_text(encoding="utf-8")
        self.assertIn("Messages: 1", text)
        self.assertNotIn("test", text)


if __name__ == "__main__":
    unittest.main()
