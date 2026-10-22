# OpenCode Usage

One bar icon and one panel that shows the tokens you have spent in
[OpenCode](https://opencode.ai), read from OpenCode's local database.

`Panel.qml` owns the bar button and the popup; `Main.qml` owns the scanner
fan-out and the optional cross-device aggregation; `providers/` holds the
provider adapter; `scripts/opencode_usage_scanner.py` reads the SQLite
database with nothing but the Python standard library.

## What you see

- **Hero** — the OpenCode mark and the source of the numbers ("Local stats").
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
omarchy plugin add https://github.com/zaheen4/omarchy-opencode-usage.git --enable --yes
```

The widget joins the bar's default layout at the next shell reload
(`omarchy-restart-shell`). `omarchy plugin update markbusai.opencode-usage`
pulls future changes from this fork. Remove it with:

```bash
omarchy plugin remove markbusai.opencode-usage
```

## Data source

The scanner reads assistant metadata from OpenCode's SQLite database. The
default location follows the same resolution OpenCode itself uses:

1. `OPENCODE_DB` when set, otherwise
2. `$XDG_DATA_HOME/opencode/opencode.db` (usually `~/.local/share/opencode/opencode.db`)

Set an explicit override in the widget settings with:

```bash
omarchy bar set markbusai.opencode-usage providers '{"opencode": {"enabled": true, "dbPath": "/custom/path/opencode.db"}}' --json
```

OpenCode v2 stores sessions in `session_v2` and messages in `session_message`;
older installs use `session` and `message`. The scanner uses the v2 tables when
present and falls back to the legacy tables, so both layouts work. All-time
totals come from the session aggregates (which already include compaction),
while today and the last seven days come from per-message timestamps so a long
session is attributed to the days it was actually used. It reads no message
text beyond the token and model fields.

## Refresh model

Scanning is event-driven, not polled. The widget watches OpenCode's data
directory with `inotifywait` and runs a **quick** scan (today + all-time) after
the database changes, at most once per `scanThrottleSec`. Opening the panel
runs one **full** scan (adds the seven-day breakdown). A safety timer covers
machines without `inotifywait` or a watcher that dies.

Scans run as `nice -n 19 ionice -c 3`, use only indexed SQLite queries, and
write their result to `~/.cache/omarchy/opencode-usage.json`; the shell renders
that cache instantly at startup. Typical cost: under 0.1 s per quick scan and
about 0.1 s per full scan; while OpenCode is idle only the sleeping watcher
remains, plus one cheap safety scan per interval.

The cache keeps the historical active-day list so a routine scan does not have
to walk every message. A day counts as active when OpenCode produced an
assistant response that day. If you delete or import sessions and want that list
recomputed exactly, run the scanner once with `--rebuild` (about 0.2 s):

```bash
python3 ~/.config/omarchy/plugins/markbusai.opencode-usage/scripts/opencode_usage_scanner.py --rebuild
```

## Settings

Settings live in the widget's entry in `~/.config/omarchy/shell.json`. Set
them with `omarchy bar set markbusai.opencode-usage <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `3600` | Safety poll, used only as a fallback when the watcher is unavailable |
| `watchDatabase` | `true` | Watch the OpenCode database with `inotifywait`; idle costs nothing |
| `scanThrottleSec` | `60` | Minimum seconds between background scans while OpenCode is writing |
| `syncMode` | `"Off"` | `"On"` writes this machine's snapshot and merges the others |
| `syncDir` | `""` | A folder synced by Syncthing, Dropbox, rsync, … |
| `syncFileName` | `<hostname>.json` | This machine's snapshot file |
| `syncDeviceId` | hostname | Stable device name inside the snapshot |

Numbers need `--json`, or they land in `shell.json` as strings:

```bash
omarchy bar set markbusai.opencode-usage refreshIntervalSec 3600 --json
omarchy bar set markbusai.opencode-usage syncDir '~/Sync/opencode-usage'
```

With `syncMode` on, every `*.json` snapshot in `syncDir` is merged, so today,
the last 7 days, and the all-time totals cover every machine you code on —
active days are unioned by date rather than summed. The snapshot contains
counts only, never conversation content.

## Interactions

- Bar icon: left = panel, right = launch `omarchy-agent --pick`, middle = refresh.
- Panel: `j`/`k` scroll, `r` or Enter refresh, Tab moves to the neighboring
  bar panel, Esc closes.
- IPC: `omarchy-shell markbusai.opencode-usage <open|close|toggle|refresh|next>`.

## License

MIT. The OpenCode mark is a trademark of its respective owner and is used
here to identify the tool this widget reports on.
