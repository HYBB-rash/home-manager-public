---
name: wechat-daily
description: Generate a local daily activity report from Second User's read-only WeChat snapshot.
---

# WeChat Daily

The only data source is `$WECHAT_SNAPSHOT_DB`. Open it exclusively through a
read-only immutable SQLite URI. Never copy it into the workspace or attempt any
write, pragma mutation, attach, vacuum, or export operation against the source.

The complete, versioned exporter project is available read-only at
`$WX_PROJECT_DIR`. Read its `README.md`, `AGENTS.md`, deployment contract, source,
and tests when schema or behavior needs clarification. `WX_PROJECT_DIR` is code
and documentation only; it must never replace `$WECHAT_SNAPSHOT_DB` as the data
source.

Run the readiness check before relying on a newly deployed snapshot:

```bash
python3 "$HERMES_HOME/skills/wechat-daily/scripts/daily_report.py" --smoke-test
```

Create the default aggregate report in the workspace:

```bash
mkdir -p reports
python3 "$HERMES_HOME/skills/wechat-daily/scripts/daily_report.py" \
  --hours 24 --output reports/wechat-daily.md
```

The default report contains only counts and conversation categories. Use
`--include-snippets` only when the user explicitly asks for message-level detail.
Keep generated reports in the workspace and treat them as private user data.
