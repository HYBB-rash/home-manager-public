"""Tests for the Second User-only cron feed helper."""

import importlib.util
import os
import pathlib
import sqlite3
import tempfile
import unittest


MODULE_PATH = (
    pathlib.Path(__file__).parents[1]
    / "system/user2-cron/scripts/wechat_snapshot_feed.py"
)
SPEC = importlib.util.spec_from_file_location("user2_cron_feed", MODULE_PATH)
feed = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(feed)


class CronFeedTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="user2-cron-test-")
        self.root = pathlib.Path(self.temporary.name)
        self.database = self.root / "snapshot.db"
        with sqlite3.connect(self.database) as connection:
            connection.execute("CREATE TABLE meta (key TEXT, value TEXT)")
            connection.execute(
                "CREATE TABLE chats (peer_username TEXT, peer_display TEXT)"
            )
            connection.execute(
                """CREATE TABLE messages (
                    chat_username TEXT, sender_label TEXT, sender_wxid TEXT,
                    create_time INTEGER, text TEXT, type_name TEXT,
                    link_url TEXT, link_title TEXT
                )"""
            )
            connection.execute(
                "INSERT INTO chats VALUES ('friend', 'Friend')"
            )
            connection.execute(
                "INSERT INTO chats VALUES ('gh_source', 'Source')"
            )
            connection.execute(
                "INSERT INTO messages VALUES (?, ?, ?, strftime('%s', 'now'), ?, ?, ?, ?)",
                ("friend", "Friend", "friend", "private test", "[文本]", "", ""),
            )
            connection.execute(
                "INSERT INTO messages VALUES (?, ?, ?, strftime('%s', 'now'), ?, ?, ?, ?)",
                ("gh_source", "", "", "article test", "[链接]", "https://example.test", "Article test"),
            )

    def tearDown(self):
        self.temporary.cleanup()

    def test_validation_accepts_expected_snapshot_shape(self):
        feed.validate_snapshot(self.database)

    def test_daily_feed_exposes_items_without_writing_source_snapshot(self):
        with feed.open_snapshot(self.database) as connection:
            output, items = feed.render_daily(
                feed.rows_since(connection, 0), feed.display_map(connection), 0
            )
        self.assertIn("private test", output)
        self.assertEqual(items[0]["url"], "https://example.test")

    def test_quarterly_feed_has_no_events_marker(self):
        self.assertIn("无新消息", feed.render_quarterly([], {}, 0))


if __name__ == "__main__":
    unittest.main()
