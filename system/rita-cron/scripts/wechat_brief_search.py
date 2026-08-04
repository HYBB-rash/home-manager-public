#!/usr/bin/env python3
"""Search the current Second User-local daily article index without opening the snapshot."""

from __future__ import annotations

import json
import os
import re
import sys


def normalize(value: str) -> str:
    return "".join(character for character in value.lower() if character.isalnum())


def main() -> int:
    query = " ".join(sys.argv[1:]).strip()
    if not query:
        print("请回复主题词，例如「AI」「招聘」或「健康」。")
        return 0
    home = os.environ.get("HERMES_HOME")
    if not home:
        print("微信晨报索引不可用：HERMES_HOME 未设置。")
        return 1
    path = os.path.join(home, "runtime", "wechat_daily_brief_items.json")
    try:
        with open(path, encoding="utf-8") as handle:
            items = json.load(handle)
    except (OSError, json.JSONDecodeError):
        print("公众号编号清单尚未生成，请等待下一次晨报。")
        return 0

    tokens = [normalize(token) for token in re.split(r"[\s,，、;；/]+", query) if token]
    hits = [
        item
        for item in items
        if all(token in normalize(str(item.get("title", ""))) for token in tokens)
    ]
    if not hits:
        print(f"没有找到「{query}」相关的公众号文章。")
        return 0
    print(f"「{query}」相关 {len(hits)} 篇：")
    for item in hits:
        link = item.get("url") or "（无可用链接）"
        print(f"- #{item.get('number')} {item.get('title')}（{item.get('source')} {item.get('time')}） {link}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
