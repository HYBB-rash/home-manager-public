#!/usr/bin/env python3
"""Create a workspace-local WeChat daily report from an immutable snapshot."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import pathlib
import sqlite3
import sys


REQUIRED_TABLES = frozenset({"chats", "messages", "meta"})


def open_snapshot(path: pathlib.Path) -> sqlite3.Connection:
    resolved = path.resolve(strict=True)
    return sqlite3.connect(f"file:{resolved}?mode=ro&immutable=1", uri=True)


def validate_snapshot(path: pathlib.Path) -> None:
    with open_snapshot(path) as connection:
        integrity = [row[0] for row in connection.execute("PRAGMA integrity_check")]
        if integrity != ["ok"]:
            raise RuntimeError("snapshot integrity check failed")
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_schema WHERE type = 'table'"
            )
        }
    missing = sorted(REQUIRED_TABLES - tables)
    if missing:
        raise RuntimeError(f"snapshot missing required tables: {', '.join(missing)}")


def output_path(value: str) -> pathlib.Path:
    workspace = pathlib.Path.cwd().resolve()
    target = pathlib.Path(value).resolve()
    if workspace not in (target, *target.parents):
        raise ValueError("report output must stay inside the current workspace")
    return target


def category_rows(connection: sqlite3.Connection, since: int) -> list[tuple[str, int]]:
    return connection.execute(
        """
        SELECT CASE
          WHEN chat_username LIKE '%@chatroom' THEN '群聊'
          WHEN chat_username LIKE 'gh_%' THEN '公众号'
          ELSE '其他会话'
        END AS category, COUNT(*)
        FROM messages
        WHERE create_time >= ?
        GROUP BY category
        ORDER BY COUNT(*) DESC, category
        """,
        (since,),
    ).fetchall()


def render_report(path: pathlib.Path, hours: int, include_snippets: bool) -> str:
    now = dt.datetime.now(dt.timezone.utc)
    since = int((now - dt.timedelta(hours=hours)).timestamp())
    with open_snapshot(path) as connection:
        message_count = connection.execute(
            "SELECT COUNT(*) FROM messages WHERE create_time >= ?", (since,)
        ).fetchone()[0]
        conversation_count = connection.execute(
            "SELECT COUNT(DISTINCT chat_username) FROM messages WHERE create_time >= ?",
            (since,),
        ).fetchone()[0]
        categories = category_rows(connection, since)
        snippets: list[tuple[str, str]] = []
        if include_snippets:
            snippets = connection.execute(
                """
                SELECT chat_username, substr(text, 1, 120)
                FROM messages
                WHERE create_time >= ? AND trim(COALESCE(text, '')) != ''
                ORDER BY create_time DESC
                LIMIT 5
                """,
                (since,),
            ).fetchall()

    start = dt.datetime.fromtimestamp(since, tz=dt.timezone.utc).isoformat()
    lines = [
        "# WeChat Daily Activity",
        "",
        f"Window: {start} to {now.isoformat()}",
        f"Messages: {message_count}",
        f"Active conversations: {conversation_count}",
        "",
        "## Categories",
    ]
    lines.extend(f"- {category}: {count}" for category, count in categories)
    if include_snippets:
        lines.extend(["", "## Recent Snippets"])
        lines.extend(f"- {chat}: {text}" for chat, text in snippets)
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hours", type=int, default=24)
    parser.add_argument("--output")
    parser.add_argument("--include-snippets", action="store_true")
    parser.add_argument("--smoke-test", action="store_true")
    args = parser.parse_args()
    if args.hours < 1:
        parser.error("--hours must be at least one")
    snapshot_value = os.environ.get("WECHAT_SNAPSHOT_DB")
    if not snapshot_value:
        parser.error("WECHAT_SNAPSHOT_DB is required")
    snapshot = pathlib.Path(snapshot_value)
    try:
        validate_snapshot(snapshot)
        if args.smoke_test:
            if args.output or args.include_snippets:
                parser.error("--smoke-test cannot generate a report")
            print("wechat daily snapshot: ready")
            return 0
        if not args.output:
            parser.error("--output is required unless --smoke-test is used")
        target = output_path(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            render_report(snapshot, args.hours, args.include_snippets), encoding="utf-8"
        )
    except (OSError, RuntimeError, sqlite3.Error, ValueError) as error:
        print(f"wechat-daily: {error}", file=sys.stderr)
        return 1
    print(target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
