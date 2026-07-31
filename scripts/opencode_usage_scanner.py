#!/usr/bin/env python3
"""Report OpenCode usage from assistant-message metadata."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sqlite3
import sys
from pathlib import Path
from typing import Any


def number(value: Any) -> int:
  try:
    return max(0, int(float(value or 0)))
  except (TypeError, ValueError):
    return 0


def date_string(day: dt.date) -> str:
  return day.strftime("%Y-%m-%d")


def day_from_ms(value: Any, fallback: str) -> str:
  try:
    return date_string(dt.datetime.fromtimestamp(float(value) / 1000).date())
  except (OSError, TypeError, ValueError):
    return fallback


def recent_dates(today: dt.date) -> list[str]:
  return [date_string(today - dt.timedelta(days=offset)) for offset in range(6, -1, -1)]


def token_bucket() -> dict[str, int]:
  return {
    "inputTokens": 0,
    "outputTokens": 0,
    "cacheReadInputTokens": 0,
    "cacheCreationInputTokens": 0,
  }


def result(
  *,
  db_path: Path,
  has_local_stats: bool,
  status: str = "",
  help_text: str = "",
) -> dict[str, Any]:
  today = dt.datetime.now().date()
  return {
    "ready": True,
    "hasLocalStats": has_local_stats,
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
    "dbPath": str(db_path),
  }


def expanded_path(value: str, relative_to: Path) -> Path:
  path = Path(os.path.expandvars(os.path.expanduser(value)))
  if not path.is_absolute():
    path = relative_to / path
  return path.resolve()


def data_home() -> Path:
  configured = os.environ.get("XDG_DATA_HOME")
  return expanded_path(configured, Path.home()) if configured else Path.home() / ".local" / "share"


def resolve_db_path(explicit: str | None) -> Path:
  if explicit:
    return expanded_path(explicit, Path.home())

  opencode_dir = data_home() / "opencode"
  configured = os.environ.get("OPENCODE_DB") or os.environ.get("OPENCODE_DATABASE")
  if configured:
    return expanded_path(configured, opencode_dir)

  stable = opencode_dir / "opencode.db"
  databases = [stable, *opencode_dir.glob("opencode-*.db")]
  databases = [path for path in databases if path.is_file()]
  if databases:
    return max(databases, key=db_activity)
  return stable


def db_activity(path: Path) -> int:
  activity = 0
  for candidate in (path, Path(str(path) + "-wal")):
    try:
      activity = max(activity, candidate.stat().st_mtime_ns)
    except OSError:
      pass
  return activity


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
  return {str(row[1]) for row in conn.execute(f"PRAGMA table_info({table})")}


def message_usage(data: Any) -> tuple[str, int, int, int, int] | None:
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


def scan(db_path: Path) -> dict[str, Any]:
  output = result(db_path=db_path, has_local_stats=True)
  today = dt.datetime.now().date()
  today_s = date_string(today)
  dates = recent_dates(today)
  recent = {day: 0 for day in dates}
  today_sessions: set[str] = set()
  sessions: set[str] = set()
  active_dates: set[str] = set()

  try:
    conn = sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True, timeout=2)
    conn.row_factory = sqlite3.Row
  except sqlite3.Error as exc:
    return result(
      db_path=db_path,
      has_local_stats=False,
      status="OpenCode database unreadable",
      help_text=str(exc),
    )

  try:
    required = {"id", "session_id", "time_created", "data"}
    if not required.issubset(table_columns(conn, "message")):
      return result(
        db_path=db_path,
        has_local_stats=False,
        status="OpenCode database schema unsupported",
        help_text="message table is missing usage metadata",
      )

    rows = conn.execute("SELECT id, session_id, time_created, data FROM message")
    for row in rows:
      try:
        data = json.loads(row["data"])
      except (TypeError, json.JSONDecodeError):
        continue

      usage = message_usage(data)
      if usage is None:
        continue

      model, input_tokens, output_tokens, cache_read, cache_write = usage
      total = input_tokens + output_tokens + cache_read + cache_write
      session_id = str(row["session_id"] or row["id"])
      day = day_from_ms(row["time_created"], today_s)

      output["totalPrompts"] += 1
      sessions.add(session_id)
      active_dates.add(day)

      bucket = output["modelUsage"].setdefault(model, token_bucket())
      bucket["inputTokens"] += input_tokens
      bucket["outputTokens"] += output_tokens
      bucket["cacheReadInputTokens"] += cache_read
      bucket["cacheCreationInputTokens"] += cache_write

      if day in recent:
        recent[day] += total

      if day == today_s:
        output["todayPrompts"] += 1
        output["todayTotalTokens"] += total
        output["todayTokensByModel"][model] = output["todayTokensByModel"].get(model, 0) + total
        today_sessions.add(session_id)
  except sqlite3.Error as exc:
    return result(
      db_path=db_path,
      has_local_stats=False,
      status="OpenCode scan failed",
      help_text=str(exc),
    )
  finally:
    conn.close()

  output["recentDays"] = [{"date": day, "messageCount": recent[day]} for day in dates]
  output["todaySessions"] = len(today_sessions)
  output["totalSessions"] = len(sessions)
  output["activeDays"] = len(active_dates)
  output["activeDates"] = sorted(active_dates)
  return output


def main() -> int:
  parser = argparse.ArgumentParser(description="Scan OpenCode local usage")
  parser.add_argument("db_path", nargs="?", help="Optional database path override")
  args = parser.parse_args()
  db_path = resolve_db_path(args.db_path)

  if not db_path.is_file():
    output = result(
      db_path=db_path,
      has_local_stats=False,
      status="OpenCode data not found",
      help_text="Run `opencode` once to create its usage database.",
    )
  else:
    output = scan(db_path)

  print(json.dumps(output, separators=(",", ":")))
  return 0


if __name__ == "__main__":
  sys.exit(main())
