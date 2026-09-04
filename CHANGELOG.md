# Changelog

## [0.4.2] - 2026-09-04

### Changed
- Show reset-card expirations directly in the main panel, removing the extra click and nested popover.
- Bound inline card details to a scrollable area while retaining unavailable/partial-data notices.

## [0.4.1] - 2026-09-04

### Added
- Read-only earned reset count and per-card expiration details from the existing App Server quota response.
- Explicit unknown/partial-detail states, bounded detail lists, local timezone dates, and no redemption action.
- Parser regression coverage for older responses, malformed details, and service-authoritative counts.

## [0.4.0] - 2026-08-31

### Added
- A dedicated minimal macOS application icon with generated ICNS resources.
- `account/read` preflight checks before live quota requests.
- Explicit states for missing ChatGPT login and API-key-only Codex setups.
- “Open Codex to sign in” action when ChatGPT authentication is required.
- Quota recovery notifications for scheduled resets and unexpected server-side recovery.
- Detection for both early window replacement and large remaining-quota increases within the same window.
- Eight-second confirmation query plus persistent event fingerprints to suppress transient and duplicate notifications.
- Official Codex App Server quota provider using `account/rateLimits/read`.
- Multi-bucket `rateLimitsByLimitId` support with aggregate Codex selection.
- Automatic JSONL and cached-data fallback when the live provider is unavailable.
- Visible refresh progress and explicit live/fallback source labels.
- Flexible quota-window parser with explicit diagnostics and freshness states.
- File-change monitoring with polling fallback.
- Optional low-quota notifications and launch-at-login controls.
- Privacy-safe diagnostic copy action with version and running path.
- Parser fixtures and Swift Testing coverage.
- Signed ZIP packaging, checksum, and notarization helper scripts.

### Changed
- Renamed the user-facing application from Codex Meter to Codex 额度 while preserving the existing bundle identifier and internal executable name for compatibility.
- Version advanced to 0.4.0 (build 14).
- Account responses retain only the account mode and plan type; email is neither cached nor displayed.
- Shared builds always use the recipient’s local Codex login and never contain distributor account data.
- App Server request timeouts now identify the exact protocol method and allow 20 seconds, covering slow authentication refreshes.
- Timed-out App Server child processes are synchronously reaped before retrying, preventing overlapping retries.
- Running copies now detect when the app bundle executable is replaced and relaunch automatically, preventing stale in-memory builds after manual updates.
- Live queries now exclusively use the CLI bundled in ChatGPT.app.
- Removed discovery and execution of Codex.app, standalone `codex`, `PATH`, Homebrew, MacPorts, and `CODEX_CLI_PATH`.
- Session-log fallback now bounds each file tail to 512 KiB, scans at most 40 recent files, and prefers primary sessions over subagent logs.
- Notification control now covers both low-quota and quota-recovery alerts.
- Low-quota notification thresholds reset after a confirmed quota recovery.
- Manual refresh now performs a live App Server query instead of only rescanning JSONL files.
- Split quota parsing into `CodexMeterCore` and removed the external `sqlite3` subprocess.
- Replaced deprecated custom status item view with the standard status-bar button API.
- Data generation time is now distinct from refresh/check time.
- Single-window weekly records no longer masquerade as 5-hour quota.
- Notifications are requested only after the user enables them.

### Fixed
- Transient `account/rateLimits/read` transport failures now receive one immediate retry with a longer per-request timeout.
- Rebuilt the App Server parser for current camelCase responses and aggregate `codex` bucket selection.
- App Server early exits now include bounded stderr diagnostics instead of only reporting a generic closed connection.
- Generic timeout fallback labels no longer assert that the failure was necessarily caused by network instability.
- Repeated transient failures are labeled as network instability and trigger a bounded automatic refresh after ten seconds.
- Permanent login, installation, and protocol errors are not retried.
- Shared builds now discover ChatGPT/Codex desktop apps through their macOS Bundle ID, including renamed apps and custom install locations.
- Added compatibility for the current `ChatGPT.app` name and more common standalone CLI locations.
- Missing-app fallback is now visible in the panel source label, and copied diagnostics include the resolved CLI path.
- Notification control now reflects the real macOS authorization state instead of appearing unresponsive after permission was denied.
- Clicking a denied notification control opens System Settings, and authorization is synchronized again when the app becomes active.
- Swift 6 notification callback crash during launch.
- Duplicate running copies now prefer the newer build.
- Transient zero-percent records no longer override higher usage in the same reset window.

## [0.1.0] - 2026-07-09

- Initial release scaffold with 5-hour and weekly quota meter, menu bar status text, and popover panel.
- Local-only inference from `.codex/sessions` logs.
- Optional periodic voice broadcast and low-quota notifications.
- DMG packaging script.
