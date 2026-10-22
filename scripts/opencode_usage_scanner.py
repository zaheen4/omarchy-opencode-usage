#!/usr/bin/env python3
"""Report OpenCode usage from the local OpenCode database.

Two scan modes keep the widget cheap:

  quick  all-time (session aggregates) + today (message rows for today only)
  full   quick + the last seven days + exact active dates when needed

Message rows carry full transcripts, so SQLite's JSON parser is the expensive
part. Each row is extracted once for its token subtree (not once per token
field), then the small subtree is parsed in Python. Results are mirrored to a
cache file so the shell renders instantly at startup.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sqlite3
import sys
import time


SCHEMA_VERSION = 2
SEC_MS_THRESHOLD = 10_000_000_000
TOKEN_COLUMNS = (
  "id, model, tokens_input, tokens_output, tokens_reasoning,"
  " tokens_cache_read, tokens_cache_write, time_created"
)
SESSION_TOKEN_SUM = (
  "(COALESCE(tokens_input,0)+COALESCE(tokens_output,0)+COALESCE(tokens_reasoning,0)"
  "+COALESCE(tokens_cache_read,0)+COALESCE(tokens_cache_write,0))"
)
USAGE = "usage: opencode_usage_scanner.py [--mode quick|full] [--rebuild] [db_path]"


def number(value: object) -> int:
  try:
    return max(0, int(float(value or 0)))
  except (TypeError, ValueError):
    return 0


def date_string(day: dt.date) -> str:
  return day.strftime("%Y-%m-%d")


def recent_dates(today: dt.date) -> list[str]:
  return [date_string(today - dt.timedelta(days=offset)) for offset in range(6, -1, -1)]


def local_midnight_epoch(day: dt.date) -> int:
  return int(dt.datetime.combine(day, dt.time.min).astimezone().timestamp())


def token_bucket() -> dict:
  return {
    "inputTokens": 0,
    "outputTokens": 0,
    "cacheReadInputTokens": 0,
    "cacheCreationInputTokens": 0,
  }


def token_total(raw: object) -> int:
  """Sum a message's token JSON without making SQLite parse it five times."""
  if not raw:
    return 0
  try:
    tokens = json.loads(raw)
  except (TypeError, ValueError):
    return 0
  if not isinstance(tokens, dict):
    return 0
  cache = tokens.get("cache")
  if not isinstance(cache, dict):
    cache = {}
  return (
    number(tokens.get("input"))
    + number(tokens.get("output"))
    + number(tokens.get("reasoning"))
    + number(cache.get("read"))
    + number(cache.get("write"))
  )


def cache_path() -> str:
  configured = os.environ.get("XDG_CACHE_HOME")
  base = os.path.expanduser(configured) if configured else os.path.join(os.path.expanduser("~"), ".cache")
  return os.path.join(base, "omarchy", "opencode-usage.json")


def read_cache() -> dict | None:
  try:
    with open(cache_path(), encoding="utf-8") as stream:
      payload = json.load(stream)
  except (OSError, ValueError):
    return None
  if not isinstance(payload, dict) or payload.get("schemaVersion") != SCHEMA_VERSION:
    return None
  return payload


def write_cache(payload: dict) -> None:
  path = cache_path()
  text = json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n"
  try:
    with open(path, encoding="utf-8") as stream:
      if stream.read() == text:
        return
  except OSError:
    pass
  try:
    import tempfile

    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".opencode-usage-", suffix=".json")
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
      stream.write(text)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
  except OSError as exc:
    print(f"opencode-usage: cache write failed: {exc}", file=sys.stderr)


def expanded_path(value: str, relative_to: str) -> str:
  path = os.path.expandvars(os.path.expanduser(value))
  if not os.path.isabs(path):
    path = os.path.join(relative_to, path)
  return os.path.realpath(path)


def data_home() -> str:
  configured = os.environ.get("XDG_DATA_HOME")
  home = os.path.expanduser("~")
  return expanded_path(configured, home) if configured else os.path.join(home, ".local", "share")


def db_activity(path: str) -> int:
  activity = 0
  for candidate in (path, path + "-wal"):
    try:
      activity = max(activity, os.stat(candidate).st_mtime_ns)
    except OSError:
      pass
  return activity


def resolve_db_path(explicit: str | None) -> str:
  home = os.path.expanduser("~")
  if explicit:
    return expanded_path(explicit, home)

  opencode_dir = os.path.join(data_home(), "opencode")
  configured = os.environ.get("OPENCODE_DB") or os.environ.get("OPENCODE_DATABASE")
  if configured:
    return expanded_path(configured, opencode_dir)

  stable = os.path.join(opencode_dir, "opencode.db")
  databases = [stable]
  try:
    for name in os.listdir(opencode_dir):
      if name.startswith("opencode-") and name.endswith(".db"):
        databases.append(os.path.join(opencode_dir, name))
  except OSError:
    pass
  existing = [path for path in databases if os.path.isfile(path)]
  return max(existing, key=db_activity) if existing else stable


def table_names(conn: sqlite3.Connection) -> set[str]:
  return {
    str(row[0])
    for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
  }


def result(
  *,
  db_path: str,
  has_local_stats: bool,
  status: str = "",
  help_text: str = "",
  today: dt.date | None = None,
) -> dict:
  today = today or dt.datetime.now().date()
  return {
    "schemaVersion": SCHEMA_VERSION,
    "ready": True,
    "hasLocalStats": has_local_stats,
    "todayDate": date_string(today),
    "todayPrompts": 0,
    "todaySessions": 0,
    "todayTotalTokens": 0,
    "todayTokensByModel": {},
    "recentDays": [{"date": day, "messageCount": 0} for day in recent_dates(today)],
    "totalPrompts": 0,
    "totalSessions": 0,
    "activeDays": 0,
    "activeDates": [],
    "modelUsage": {},
    "tierLabel": "Local stats" if has_local_stats else "",
    "usageStatusText": status,
    "authHelpText": help_text,
    "dbPath": db_path,
    "generatedAt": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
    "scanMs": 0,
  }


def model_label(raw: object) -> str:
  value = str(raw or "").strip()
  if value.startswith("{"):
    try:
      parsed = json.loads(value)
      return str(parsed.get("id") or value)
    except ValueError:
      return value
  return value or "unknown"


def session_source(conn: sqlite3.Connection, tables: set[str]) -> str | None:
  """Sessions from V2 and legacy V1, each session counted once."""
  if "session_v2" in tables and "session" in tables:
    return (
      f"SELECT {TOKEN_COLUMNS} FROM session_v2 UNION ALL "
      f"SELECT {TOKEN_COLUMNS} FROM session WHERE id NOT IN (SELECT id FROM session_v2)"
    )
  if "session_v2" in tables:
    return f"SELECT {TOKEN_COLUMNS} FROM session_v2"
  if "session" in tables:
    return f"SELECT {TOKEN_COLUMNS} FROM session"
  return None


def scan_all_time(conn: sqlite3.Connection, tables: set[str], output: dict) -> None:
  source = session_source(conn, tables)
  if source is None:
    return

  rows = conn.execute(f"""
    SELECT model,
           SUM(COALESCE(tokens_input,0)+COALESCE(tokens_reasoning,0)) AS input_tokens,
           SUM(COALESCE(tokens_output,0)) AS output_tokens,
           SUM(COALESCE(tokens_cache_read,0)) AS cache_read,
           SUM(COALESCE(tokens_cache_write,0)) AS cache_write
    FROM ({source})
    WHERE time_created > 0 AND {SESSION_TOKEN_SUM} > 0
    GROUP BY model
  """)
  for row in rows:
    bucket = output["modelUsage"].setdefault(model_label(row["model"]), token_bucket())
    bucket["inputTokens"] += number(row["input_tokens"])
    bucket["outputTokens"] += number(row["output_tokens"])
    bucket["cacheReadInputTokens"] += number(row["cache_read"])
    bucket["cacheCreationInputTokens"] += number(row["cache_write"])

  row = conn.execute(
    f"SELECT COUNT(DISTINCT id) AS sessions FROM ({source}) "
    f"WHERE time_created > 0 AND {SESSION_TOKEN_SUM} > 0"
  ).fetchone()
  output["totalSessions"] = number(row["sessions"] if row else 0)


def message_scale(conn: sqlite3.Connection, table: str) -> int:
  """OpenCode stores milliseconds; tolerate seconds in ancient databases."""
  row = conn.execute(f"SELECT MAX(time_created) FROM {table}").fetchone()
  newest = number(row[0] if row else 0)
  return 1 if newest and newest < SEC_MS_THRESHOLD else 1000


def scan_messages(
  conn: sqlite3.Connection,
  table: str,
  *,
  since_epoch_s: int,
  scale: int,
  output: dict,
  today: dt.date,
) -> tuple[dict[str, int], set[str]]:
  """Fill today/week buckets from one indexed pass over message rows."""
  day_expr = f"date(time_created/{scale},'unixepoch','localtime')"
  since_raw = since_epoch_s * scale
  today_s = date_string(today)
  recent = {day: 0 for day in recent_dates(today)}
  active_days: set[str] = set()
  today_prompts = 0
  today_sessions: set[str] = set()

  rows = conn.execute(f"""
    SELECT {day_expr} AS day,
           session_id,
           COALESCE(json_extract(data,'$.model.id'),json_extract(data,'$.modelID'),'unknown') AS model,
           json_extract(data,'$.tokens') AS tokens
    FROM {table}
    WHERE type = 'assistant' AND time_created >= ? AND json_valid(data)
  """, (since_raw,))

  for row in rows:
    day = str(row["day"] or "")
    if not day:
      continue
    active_days.add(day)
    tokens = token_total(row["tokens"])
    if tokens <= 0:
      continue
    if day in recent:
      recent[day] += tokens
    if day == today_s:
      model = str(row["model"] or "unknown")
      output["todayTokensByModel"][model] = output["todayTokensByModel"].get(model, 0) + tokens
      output["todayTotalTokens"] += tokens
      today_prompts += 1
      session_id = row["session_id"]
      if session_id:
        today_sessions.add(str(session_id))

  output["todayPrompts"] = today_prompts
  output["todaySessions"] = len(today_sessions)
  return recent, active_days


def count_prompts(conn: sqlite3.Connection, tables: set[str]) -> int:
  if "session_message" in tables:
    row = conn.execute("SELECT COUNT(*) AS prompts FROM session_message WHERE type = 'assistant'").fetchone()
    return number(row["prompts"] if row else 0)
  return 0


def exact_active_dates(conn: sqlite3.Connection, tables: set[str], scale: int) -> set[str]:
  """A day is active when OpenCode produced an assistant message.

  Deliberately avoids JSON: checking the token subtree across every historical
  row costs a second, while this indexed date scan costs a fraction of that.
  """
  if "session_message" not in tables:
    return set()
  day_expr = f"date(time_created/{scale},'unixepoch','localtime')"
  rows = conn.execute(
    f"SELECT DISTINCT {day_expr} AS day FROM session_message WHERE type = 'assistant'"
  )
  return {str(row["day"]) for row in rows if row["day"]}


def merge_active_dates(
  cached: dict | None,
  week_rows: set[str],
  today_s: str,
  today_active: bool,
) -> set[str]:
  dates: set[str] = set()
  cached_date = ""
  if cached:
    dates = {str(day) for day in cached.get("activeDates", []) if isinstance(day, str)}
    cached_date = str(cached.get("todayDate") or "")
  dates |= week_rows
  if today_active:
    dates.add(today_s)
  elif cached_date == today_s:
    dates.discard(today_s)
  return dates


def scan_v2(
  conn: sqlite3.Connection,
  tables: set[str],
  *,
  mode: str,
  cache: dict | None,
  rebuild: bool,
  output: dict,
  today: dt.date,
) -> None:
  scale = message_scale(conn, "session_message")
  today_s = date_string(today)
  week_start = local_midnight_epoch(today - dt.timedelta(days=6))

  if mode == "quick":
    # Today only: the bar chip is the only consumer between panel opens.
    recent, active_days = scan_messages(
      conn,
      "session_message",
      since_epoch_s=local_midnight_epoch(today),
      scale=scale,
      output=output,
      today=today,
    )
    recent[today_s] = output["todayTotalTokens"]
    if cache:
      for entry in cache.get("recentDays", []):
        day = str(entry.get("date") or "")
        if day in recent and day != today_s:
          recent[day] = number(entry.get("messageCount"))
    output["recentDays"] = [{"date": day, "messageCount": recent[day]} for day in recent_dates(today)]
  else:
    # One indexed pass over the last seven days covers today as well.
    recent, active_days = scan_messages(
      conn,
      "session_message",
      since_epoch_s=week_start,
      scale=scale,
      output=output,
      today=today,
    )
    output["recentDays"] = [{"date": day, "messageCount": recent[day]} for day in recent_dates(today)]

  scan_all_time(conn, tables, output)
  output["totalPrompts"] = count_prompts(conn, tables)

  cached_date = ""
  if cache:
    cached_date = str(cache.get("todayDate") or "")
  gap_days = 999
  if cached_date:
    try:
      gap_days = (today - dt.date.fromisoformat(cached_date)).days
    except ValueError:
      gap_days = 999

  if rebuild or cache is None or gap_days > 7:
    active = exact_active_dates(conn, tables, scale)
  else:
    active = merge_active_dates(cache, active_days, today_s, today_s in active_days)

  output["activeDates"] = sorted(active)
  output["activeDays"] = len(active)
  output["tierLabel"] = "Local stats"


def scan_legacy(
  conn: sqlite3.Connection,
  *,
  output: dict,
  today: dt.date,
) -> None:
  """Pre-v2 fallback: walk assistant messages and aggregate in Python."""
  today_s = date_string(today)
  dates = recent_dates(today)
  recent = {day: 0 for day in dates}
  sessions: set[str] = set()
  today_sessions: set[str] = set()
  active: set[str] = set()

  rows = conn.execute("SELECT id, session_id, time_created, data FROM message")
  for row in rows:
    try:
      data = json.loads(row["data"])
    except (TypeError, ValueError):
      continue
    usage = legacy_message_usage(data)
    if usage is None:
      continue

    model, input_tokens, output_tokens, cache_read, cache_write = usage
    tokens = input_tokens + output_tokens + cache_read + cache_write
    session_id = str(row["session_id"] or row["id"])
    try:
      day = date_string(dt.datetime.fromtimestamp(float(row["time_created"]) / 1000).date())
    except (OSError, TypeError, ValueError):
      day = today_s

    output["totalPrompts"] += 1
    sessions.add(session_id)
    active.add(day)

    bucket = output["modelUsage"].setdefault(model, token_bucket())
    bucket["inputTokens"] += input_tokens
    bucket["outputTokens"] += output_tokens
    bucket["cacheReadInputTokens"] += cache_read
    bucket["cacheCreationInputTokens"] += cache_write

    if day in recent:
      recent[day] += tokens
    if day == today_s:
      output["todayPrompts"] += 1
      output["todayTotalTokens"] += tokens
      output["todayTokensByModel"][model] = output["todayTokensByModel"].get(model, 0) + tokens
      today_sessions.add(session_id)

  output["recentDays"] = [{"date": day, "messageCount": recent[day]} for day in dates]
  output["todaySessions"] = len(today_sessions)
  output["totalSessions"] = len(sessions)
  output["activeDates"] = sorted(active)
  output["activeDays"] = len(active)
  output["tierLabel"] = "Local stats"


def legacy_message_usage(data: object) -> tuple[str, int, int, int, int] | None:
  if not isinstance(data, dict) or data.get("role") != "assistant":
    return None
  tokens = data.get("tokens")
  if not isinstance(tokens, dict):
    return None
  cache = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
  input_tokens = number(tokens.get("input"))
  output_tokens = number(tokens.get("output")) + number(tokens.get("reasoning"))
  cache_read = number(cache.get("read"))
  cache_write = number(cache.get("write"))
  if input_tokens + output_tokens + cache_read + cache_write == 0:
    return None
  model = str(data.get("modelID") or data.get("modelId") or "opencode")
  return model, input_tokens, output_tokens, cache_read, cache_write


def scan(
  db_path: str,
  *,
  mode: str,
  rebuild: bool = False,
  now: dt.datetime | None = None,
) -> tuple[dict, dict | None]:
  started = time.perf_counter()
  now = now or dt.datetime.now()
  today = now.date()
  cache = read_cache()
  today_s = date_string(today)

  # A quick scan relies on the cached week. Fall back to a full pass when the
  # cache is missing or was written on a different day.
  if mode == "quick":
    if cache is None or str(cache.get("todayDate") or "") != today_s:
      mode = "full"

  output = result(db_path=db_path, has_local_stats=True, today=today)
  uri = (
    "file:"
    + db_path.replace("%", "%25").replace(" ", "%20").replace("?", "%3f").replace("#", "%23")
    + "?mode=ro"
  )
  try:
    conn = sqlite3.connect(uri, uri=True, timeout=2)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA cache_size = -2000")
  except sqlite3.Error as exc:
    return result(
      db_path=db_path,
      has_local_stats=False,
      status="OpenCode database unreadable",
      help_text=str(exc),
      today=today,
    ), None

  try:
    tables = table_names(conn)
    if "session_message" in tables:
      scan_v2(conn, tables, mode=mode, cache=cache, rebuild=rebuild, output=output, today=today)
    elif "message" in tables:
      scan_legacy(conn, output=output, today=today)
    else:
      return result(
        db_path=db_path,
        has_local_stats=False,
        status="OpenCode database schema unsupported",
        help_text="no message or session_message table",
        today=today,
      ), None
  except sqlite3.Error as exc:
    return result(
      db_path=db_path,
      has_local_stats=False,
      status="OpenCode scan failed",
      help_text=str(exc),
      today=today,
    ), None
  finally:
    try:
      conn.close()
    except sqlite3.Error:
      pass

  output["scanMs"] = int((time.perf_counter() - started) * 1000)
  output["generatedAt"] = dt.datetime.now().astimezone().isoformat(timespec="seconds")
  return output, cache


def parse_args(argv: list[str]) -> tuple[str | None, str, bool]:
  mode = "full"
  rebuild = False
  db_path = None
  index = 1
  while index < len(argv):
    arg = argv[index]
    if arg in ("-h", "--help"):
      print(USAGE)
      raise SystemExit(0)
    if arg == "--rebuild":
      rebuild = True
    elif arg == "--mode":
      index += 1
      if index >= len(argv) or argv[index] not in ("quick", "full"):
        raise ValueError("--mode requires quick or full")
      mode = argv[index]
    elif arg.startswith("--mode="):
      value = arg.split("=", 1)[1]
      if value not in ("quick", "full"):
        raise ValueError("--mode requires quick or full")
      mode = value
    elif arg.startswith("-"):
      raise ValueError(f"unknown option: {arg}")
    else:
      if db_path is not None:
        raise ValueError("unexpected extra argument")
      db_path = arg
    index += 1
  return db_path, mode, rebuild


def main(argv: list[str] | None = None) -> int:
  argv = sys.argv if argv is None else argv
  try:
    db_arg, mode, rebuild = parse_args(argv)
  except ValueError as exc:
    print(f"opencode-usage: {exc}\n{USAGE}", file=sys.stderr)
    return 2

  db_path = resolve_db_path(db_arg)
  if not os.path.isfile(db_path):
    output = result(
      db_path=db_path,
      has_local_stats=False,
      status="OpenCode data not found",
      help_text="Run `opencode` once to create its usage database.",
    )
    write_cache(output)
  else:
    output, _ = scan(db_path, mode=mode, rebuild=rebuild)
    if output.get("hasLocalStats"):
      write_cache(output)

  print(json.dumps(output, separators=(",", ":")))
  return 0


if __name__ == "__main__":
  sys.exit(main())
