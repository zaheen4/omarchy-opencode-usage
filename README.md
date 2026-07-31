# OpenCode Usage

One bar icon and one panel that shows the tokens you have spent in
[OpenCode](https://opencode.ai), read from OpenCode's local database.

`Panel.qml` owns the bar button and the popup; `Main.qml` owns the scanner
fan-out and the optional cross-device aggregation; `providers/` holds the
provider adapter; `scripts/opencode_usage_scanner.py` reads the SQLite
database with nothing but the Python standard library.

## What you see

- **Hero** — the OpenCode mark and the source of the numbers ("Local usage").
- **Tokens by day** — one row per day for the last week: day, bar, tokens,
  with today bolded at the bottom. Hover today for its prompt and session
  count.
- **Tokens by model** — tokens per model with the bar behind each row scaled
  to the heaviest model. Hover for the input / output / cache split.

OpenCode keeps no rate-limit state in its local store, so there are no
percentage meters — the widget reads token totals only. It appears in the bar
once a scan finds usage, and leaves the bar entirely on a machine that has
never run OpenCode.

## Install

```bash
omarchy plugin add https://github.com/markbus-ai/omarchy-opencode-usage --enable
```

The widget joins the bar's default layout at the next shell reload
(`omarchy-restart-shell`). Remove it with:

```bash
omarchy plugin remove markbusai.opencode-usage
```

## Data source

The scanner reads assistant-message metadata from OpenCode's SQLite database.
The default location follows the same resolution OpenCode itself uses:

1. `OPENCODE_DB` when set, otherwise
2. `$XDG_DATA_HOME/opencode/opencode.db` (usually `~/.local/share/opencode/opencode.db`)

Set an explicit override in the widget settings with:

```bash
omarchy bar set markbusai.opencode-usage providers '{"opencode": {"enabled": true, "dbPath": "/custom/path/opencode.db"}}' --json
```

The scan aggregates session totals (prompts, sessions, tokens, per-model
buckets) from the database's `session` table, so it is fast and reads no
message content.

## Settings

Settings live in the widget's entry in `~/.config/omarchy/shell.json`. Set
them with `omarchy bar set markbusai.opencode-usage <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often local scans and snapshots refresh |
| `syncMode` | `"Off"` | `"On"` writes this machine's snapshot and merges the others |
| `syncDir` | `""` | A folder synced by Syncthing, Dropbox, rsync, … |
| `syncFileName` | `<hostname>.json` | This machine's snapshot file |
| `syncDeviceId` | hostname | Stable device name inside the snapshot |

Numbers need `--json`, or they land in `shell.json` as strings:

```bash
omarchy bar set markbusai.opencode-usage refreshIntervalSec 300 --json
omarchy bar set markbusai.opencode-usage syncDir '~/Sync/opencode-usage'
```

With `syncMode` on, every `*.json` snapshot in `syncDir` is merged, so today,
the last 7 days, and the all-time totals cover every machine you code on —
active days are unioned by date rather than summed. The snapshot contains
counts only, never conversation content.

## Interactions

- Bar icon: left = panel, right = refresh, middle = next provider.
- Panel: `j`/`k` scroll, `r` or Enter refresh, Tab moves to the neighboring
  bar panel, Esc closes.
- IPC: `omarchy-shell markbusai.opencode-usage <open|close|toggle|refresh|next>`.

## License

MIT. The OpenCode mark is a trademark of its respective owner and is used
here to identify the tool this widget reports on.
