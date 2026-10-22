# Changelog

## 1.1.0 — 2026-10-22

- Read OpenCode v2 databases (`session_v2` / `session_message`) as well as the
  legacy `session` / `message` layout.
- Made refreshes event-driven: inotify on the OpenCode database with a
  configurable throttle and an hourly safety fallback.
- Sped up the scanner with one token-subtree extraction per message, a cached
  result file, and separate quick/full passes.
- Added a manual **Check for updates** action to the panel, with a one-click
  fast-forward through Omarchy's validated plugin updater. Nothing polls for
  updates in the background.

## 1.0.0

- Initial release.
