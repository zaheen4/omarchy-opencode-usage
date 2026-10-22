#!/usr/bin/env bash
# Update-check regression tests: current, available, ahead, diverged, dirty, error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check_update.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=Test
export GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test
export GIT_COMMITTER_EMAIL=test@example.com

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_check() {
  local dir=$1 expected_state=$2 expected_dirty=$3 expected_detail=${4:-}
  local out state dirty detail
  out="$("$CHECK" "$dir")"
  state="$(printf '%s\n' "$out" | cut -f1)"
  detail="$(printf '%s\n' "$out" | cut -f2)"
  dirty="$(printf '%s\n' "$out" | cut -f3)"
  [[ $state == "$expected_state" && $dirty == "$expected_dirty" ]] \
    || fail "expected $expected_state/$expected_dirty, got $out"
  if [[ -n $expected_detail && $detail != "$expected_detail" ]]; then
    fail "expected detail '$expected_detail', got '$detail'"
  fi
}

# Local bare remote, so the test never touches the network.
git init -q -b main "$TMP/seed"
printf 'one\n' > "$TMP/seed/file.txt"
git -C "$TMP/seed" add file.txt
git -C "$TMP/seed" commit -qm "initial"
git clone -q --bare "$TMP/seed" "$TMP/remote.git"
git -C "$TMP/seed" remote add origin "$TMP/remote.git"

git clone -q "$TMP/remote.git" "$TMP/current"
assert_check "$TMP/current" current 0

printf 'two\n' >> "$TMP/seed/file.txt"
git -C "$TMP/seed" add file.txt
git -C "$TMP/seed" commit -qm "remote feature"
git -C "$TMP/seed" push -q origin main
assert_check "$TMP/current" available 0 "remote feature"

printf 'local\n' > "$TMP/current/local.txt"
git -C "$TMP/current" add local.txt
git -C "$TMP/current" commit -qm "local commit"
assert_check "$TMP/current" diverged 0

git clone -q "$TMP/remote.git" "$TMP/ahead"
printf 'ahead\n' > "$TMP/ahead/local.txt"
git -C "$TMP/ahead" add local.txt
git -C "$TMP/ahead" commit -qm "local ahead"
assert_check "$TMP/ahead" ahead 0

git clone -q "$TMP/remote.git" "$TMP/dirty"
touch "$TMP/dirty/untracked.txt"
assert_check "$TMP/dirty" current 1

mkdir "$TMP/plain"
assert_check "$TMP/plain" error 0 "Not a git checkout"
assert_check "$TMP/missing" error 0 "Plugin folder not found"

echo "update check tests passed"
