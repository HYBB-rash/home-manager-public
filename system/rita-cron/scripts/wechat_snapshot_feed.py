#!/usr/bin/env python3
"""Generate Second User-local WeChat cron feeds from the immutable host snapshot."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import time


REQUIRED_TABLES = frozenset({"chats", "messages", "meta"})
MAX_DIRECT_MESSAGES = 12
MAX_GROUPS = 6
MAX_GROUP_MESSAGES = 3
MAX_OFFICIAL_MESSAGES = 8


def snapshot_path() -> pathlib.Path:
    value = os.environ.get("WECHAT_SNAPSHOT_DB")
    if not value:
        raise RuntimeError("WECHAT_SNAPSHOT_DB is required")
    return pathlib.Path(value).resolve(strict=True)


def open_snapshot(path: pathlib.Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro&immutable=1", uri=True)


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


def timestamp(value: int) -> str:
    return dt.datetime.fromtimestamp(value).strftime("%H:%M")


def display_map(connection: sqlite3.Connection) -> dict[str, str]:
    return {
        username: display or username
        for username, display in connection.execute(
            "SELECT peer_username, peer_display FROM chats"
        )
    }


def classify(username: str) -> str:
    if username.endswith("@chatroom"):
        return "group"
    if username.startswith("gh_"):
        return "official"
    return "direct"


def compact(value: object, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def rows_since(connection: sqlite3.Connection, since: int) -> list[tuple]:
    return connection.execute(
        """
        SELECT chat_username, sender_label, sender_wxid, create_time, text,
               type_name, link_url, link_title
        FROM messages
        WHERE create_time >= ?
        ORDER BY create_time ASC
        """,
        (since,),
    ).fetchall()


def render_quarterly(rows: list[tuple], display: dict[str, str], since: int) -> str:
    grouped: dict[str, list[tuple]] = {}
    for row in rows:
        grouped.setdefault(row[0], []).append(row)

    lines = [f"【窗口】过去 15 分钟（{timestamp(since)} 起）", "【事件】"]
    if not grouped:
        lines.append("  （无新消息）")
        return "\n".join(lines) + "\n"

    for username, messages in sorted(grouped.items(), key=lambda item: -len(item[1]))[:8]:
        kind = classify(username)
        name = compact(display.get(username, username), 18)
        if kind == "group":
            last = messages[-1]
            content = compact(last[4] or last[5], 60)
            lines.append(f"  群[{name}] {len(messages)}条 最新({timestamp(last[3])}) {content}")
        elif kind == "official":
            for message in messages[:2]:
                title = compact(message[7] or message[4] or message[5], 60)
                link = compact(message[6], 240)
                suffix = f" | {link}" if link else ""
                lines.append(f"  公众号[{name}] {timestamp(message[3])} {title}{suffix}")
        else:
            for message in messages[:3]:
                content = compact(message[4] or message[5], 60)
                lines.append(f"  单聊[{name}] {timestamp(message[3])} {content}")
    return "\n".join(lines) + "\n"


def render_daily(rows: list[tuple], display: dict[str, str], since: int) -> tuple[str, list[dict[str, str]]]:
    direct = [row for row in rows if classify(row[0]) == "direct"]
    official = [row for row in rows if classify(row[0]) == "official"]
    groups: dict[str, list[tuple]] = {}
    for row in rows:
        if classify(row[0]) == "group":
            groups.setdefault(row[0], []).append(row)

    lines = [f"【窗口】过去 24 小时（{timestamp(since)} 起）", "【重要的人】"]
    if direct:
        for row in direct[-MAX_DIRECT_MESSAGES:]:
            name = compact(display.get(row[0], row[0]), 18)
            lines.append(f"  {timestamp(row[3])} {name}: {compact(row[4] or row[5], 80)}")
    else:
        lines.append("  （无新消息）")

    lines.append("【群聊】")
    if groups:
        for username, messages in sorted(groups.items(), key=lambda item: -len(item[1]))[:MAX_GROUPS]:
            name = compact(display.get(username, username), 18)
            lines.append(f"  群[{name}] {len(messages)}条")
            for row in messages[-MAX_GROUP_MESSAGES:]:
                sender = compact(row[1] or row[2] or "成员", 14)
                lines.append(f"    {timestamp(row[3])} {sender}: {compact(row[4] or row[5], 80)}")
    else:
        lines.append("  （无新消息）")

    items: list[dict[str, str]] = []
    lines.append("【公众号】")
    if official:
        for number, row in enumerate(official[-MAX_OFFICIAL_MESSAGES:], start=1):
            name = compact(display.get(row[0], row[0]), 18)
            title = compact(row[7] or row[4] or row[5], 80)
            link = compact(row[6], 300)
            lines.append(f"  #{number} {title}（{name} {timestamp(row[3])}）" + (f" | {link}" if link else ""))
            items.append(
                {
                    "number": str(number),
                    "title": title,
                    "source": name,
                    "time": timestamp(row[3]),
                    "url": link,
                }
            )
    else:
        lines.append("  （无更新）")
    return "\n".join(lines) + "\n", items


def write_items(items: list[dict[str, str]]) -> None:
    hermes_home = pathlib.Path(os.environ.get("HERMES_HOME", "")).resolve()
    if not str(hermes_home) or not hermes_home.is_dir():
        raise RuntimeError("HERMES_HOME must identify the managed Second User home")
    target = hermes_home / "runtime" / "wechat_daily_brief_items.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=target.parent, delete=False
    ) as handle:
        json.dump(items, handle, ensure_ascii=False)
        handle.write("\n")
        temporary = pathlib.Path(handle.name)
    os.chmod(temporary, 0o600)
    temporary.replace(target)


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--quarterly", action="store_true")
    mode.add_argument("--daily", action="store_true")
    mode.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--minutes", type=int, default=15)
    args = parser.parse_args()
    if args.minutes < 1:
        parser.error("--minutes must be at least one")

    try:
        path = snapshot_path()
        validate_snapshot(path)
        if args.smoke_test:
            print("wechat cron snapshot: ready")
            return 0
        now = int(time.time())
        since = now - (24 * 60 * 60 if args.daily else args.minutes * 60)
        with open_snapshot(path) as connection:
            display = display_map(connection)
            rows = rows_since(connection, since)
        if args.daily:
            output, items = render_daily(rows, display, since)
            write_items(items)
        else:
            output = render_quarterly(rows, display, since)
        print(output, end="")
        return 0
    except (OSError, RuntimeError, sqlite3.Error) as error:
        print(f"wechat-cron: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
