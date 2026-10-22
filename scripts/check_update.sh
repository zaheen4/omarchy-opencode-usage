#!/usr/bin/env bash
# Report whether this git-managed plugin can fast-forward from origin.
#
# Output is one tab-separated line:
#   state<TAB>detail<TAB>dirty
# state: current | available | ahead | diverged | error
set -u

export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}"

root=${1:-}
if [[ -z $root || ! -d $root ]]; then
  printf 'error\tPlugin folder not found\t0\n'
  exit 0
fi

if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'error\tNot a git checkout\t0\n'
  exit 0
fi

if ! timeout 15 git -C "$root" fetch --quiet origin HEAD 2>/dev/null; then
  printf 'error\tCould not reach origin\t0\n'
  exit 0
fi

local_head=$(git -C "$root" rev-parse HEAD 2>/dev/null) \
  || { printf 'error\tNo local commit\t0\n'; exit 0; }
remote_head=$(git -C "$root" rev-parse FETCH_HEAD 2>/dev/null) \
  || { printf 'error\tNo remote commit\t0\n'; exit 0; }

dirty=0
if [[ -n $(git -C "$root" status --porcelain 2>/dev/null) ]]; then
  dirty=1
fi

if [[ $local_head == "$remote_head" ]]; then
  printf 'current\t\t%s\n' "$dirty"
elif git -C "$root" merge-base --is-ancestor "$local_head" "$remote_head" 2>/dev/null; then
  subject=$(git -C "$root" --no-pager log -1 --format=%s "$remote_head" 2>/dev/null)
  printf 'available\t%s\t%s\n' "$subject" "$dirty"
elif git -C "$root" merge-base --is-ancestor "$remote_head" "$local_head" 2>/dev/null; then
  printf 'ahead\t\t%s\n' "$dirty"
else
  printf 'diverged\t\t%s\n' "$dirty"
fi
