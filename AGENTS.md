# AGENTS.md

Guidance for AI agents working on Codex 额度.

## Project

Codex 额度 is a macOS menu bar utility written with SwiftUI and AppKit. It reads live quota through the local Codex App Server, falls back to local `~/.codex` session logs, and displays a compact menu bar status item plus a small popover panel.

## Principles

- Keep the app lightweight, local-first, and menu-bar focused.
- Keep upstream communication behind the local Codex App Server; do not add direct provider HTTP calls.
- Do not collect, upload, or expose user prompts, model replies, attachments, auth files, or other private session content.
- Label App Server values as live and JSONL/cache values as fallback data.
- Preserve compact menu bar width.
- Prefer native macOS APIs and SwiftUI/AppKit over third-party dependencies.
- Keep UI changes glanceable and minimal; avoid full settings pages unless the feature genuinely needs one.

## Build

```sh
scripts/build-app.sh
```

## Run

```sh
scripts/restart.sh
```

## Package

Use `scripts/package-release.sh`; set `CODEX_METER_UNIVERSAL=1` for a universal Apple Silicon and Intel archive.

## UI Notes

- Menu bar text should remain short, currently `percent | reset`.
- The popover should prioritize 5-hour quota, reset countdown, and weekly quota.
- Buttons in the popover should stay compact and icon-based.
- Voice broadcast settings should stay in the More popover.

## Quota Parsing Notes

- Prefer `account/rateLimits/read` and `account/rateLimits/updated` from Codex App Server.
- Prefer `rateLimitsByLimitId.codex` when the multi-bucket view is present.
- Fall back to JSONL without replacing valid cached data with an unavailable state.
- Real quota records are read from `payload.rate_limits`.
- Prefer aggregate Codex limits where `limit_id == "codex"`.
- Ignore model-specific limits such as `codex_bengalfox`.
- For the current 5-hour window, prefer the highest observed `used_percent` among recent valid records to avoid transient `0%` records.
- Read file tails instead of entire JSONL files when possible; local session logs can be large.
