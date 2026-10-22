#!/usr/bin/env bash
# Scanner regression tests: v2 schema, legacy schema, quick/full, cache recovery.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-/usr/bin/python3}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export XDG_CACHE_HOME="$TMP/cache"
unset OPENCODE_DB OPENCODE_DATABASE

scanner() {
  "$PYTHON" -S "$ROOT/scripts/opencode_usage_scanner.py" "$@"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------- v2 schema
DB="$TMP/v2.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE session_v2 (
  id TEXT PRIMARY KEY, model TEXT,
  tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
  tokens_cache_read INTEGER, tokens_cache_write INTEGER,
  time_created INTEGER, time_updated INTEGER
);
CREATE TABLE session_message (
  id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
  seq INTEGER NOT NULL, time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL, data TEXT NOT NULL
);

INSERT INTO session_v2 VALUES
  ('s1', '{"id":"model-a","providerID":"opencode"}', 100, 50, 10, 40, 0,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   CAST(strftime('%s','now') AS INTEGER) * 1000),
  ('s2', '{"id":"model-b","providerID":"opencode"}', 200, 20, 0, 0, 0,
   (CAST(strftime('%s','now') AS INTEGER) - 3 * 86400) * 1000,
   (CAST(strftime('%s','now') AS INTEGER) - 3 * 86400) * 1000);

INSERT INTO session_message VALUES
  ('m1', 's1', 'assistant', 1,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   '{"model":{"id":"model-a","providerID":"opencode"},"tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":40,"write":0}}}'),
  ('m2', 's1', 'user', 2,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   CAST(strftime('%s','now') AS INTEGER) * 1000,
   '{"text":"ignored"}'),
  ('m3', 's2', 'assistant', 1,
   (CAST(strftime('%s','now') AS INTEGER) - 3 * 86400) * 1000,
   (CAST(strftime('%s','now') AS INTEGER) - 3 * 86400) * 1000,
   '{"model":{"id":"model-b","providerID":"opencode"},"tokens":{"input":200,"output":20,"reasoning":0,"cache":{"read":0,"write":0}}}');
SQL

time_full=$("$PYTHON" -S - <<PY
import subprocess, time
start = time.perf_counter()
subprocess.run(["$PYTHON", "-S", "$ROOT/scripts/opencode_usage_scanner.py", "--mode", "full", "$DB"], check=True, capture_output=True)
print(int((time.perf_counter() - start) * 1000))
PY
)

FULL="$(scanner --mode full "$DB")"
jq -e '
  .hasLocalStats == true and
  .todayTotalTokens == 200 and
  .todayPrompts == 1 and
  .todaySessions == 1 and
  .recentDays[-1].messageCount == 200 and
  .recentDays[-4].messageCount == 220 and
  .modelUsage["model-a"].inputTokens == 110 and
  .modelUsage["model-a"].outputTokens == 50 and
  .modelUsage["model-a"].cacheReadInputTokens == 40 and
  .modelUsage["model-b"].inputTokens == 200 and
  .modelUsage["model-b"].outputTokens == 20 and
  .totalSessions == 2 and
  .totalPrompts == 2 and
  .activeDays == 2
' >/dev/null <<<"$FULL" || fail "v2 full scan produced unexpected values: $FULL"

QUICK="$(scanner --mode quick "$DB")"
jq -e '
  .todayTotalTokens == 200 and
  .recentDays[-1].messageCount == 200 and
  .recentDays[-4].messageCount == 220 and
  .activeDays == 2 and
  .scanMs >= 0
' >/dev/null <<<"$QUICK" || fail "v2 quick scan did not carry the week: $QUICK"

# A corrupt cache must not break a quick scan.
printf '{not json' > "$TMP/cache/omarchy/opencode-usage.json"
RECOVERED="$(scanner --mode quick "$DB")"
jq -e '.todayTotalTokens == 200 and .recentDays[-4].messageCount == 220' \
  >/dev/null <<<"$RECOVERED" || fail "corrupt cache was not recovered: $RECOVERED"

# ------------------------------------------------------------ legacy schema
LEGACY="$TMP/v1.db"
sqlite3 "$LEGACY" <<'SQL'
CREATE TABLE session (
  id TEXT PRIMARY KEY, model TEXT,
  tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER,
  tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_created INTEGER
);
CREATE TABLE message (
  id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT
);
INSERT INTO session VALUES
  ('old', '{"id":"legacy-model"}', 10, 5, 0, 2, 0,
   CAST(strftime('%s','now') AS INTEGER) * 1000);
INSERT INTO message VALUES
  ('old-m', 'old', CAST(strftime('%s','now') AS INTEGER) * 1000,
   '{"role":"assistant","modelID":"legacy-model","tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":2,"write":0}}}');
SQL

LEGACY_OUT="$(scanner --mode full "$LEGACY")"
jq -e '
  .todayTotalTokens == 17 and
  .todayPrompts == 1 and
  .todaySessions == 1 and
  .modelUsage["legacy-model"].inputTokens == 10 and
  .modelUsage["legacy-model"].outputTokens == 5 and
  .totalSessions == 1 and
  .activeDays == 1
' >/dev/null <<<"$LEGACY_OUT" || fail "legacy scan failed: $LEGACY_OUT"

# ------------------------------------------------------------- no database
MISSING="$(scanner --mode full "$TMP/missing.db")"
jq -e '.hasLocalStats == false and .usageStatusText == "OpenCode data not found"' \
  >/dev/null <<<"$MISSING" || fail "missing database was not reported: $MISSING"

echo "scanner tests passed (full ${time_full}ms, quick reported above)"
