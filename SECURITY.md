# Security Policy

## Reporting a vulnerability

If you discover a security issue, please report it directly and privately.

Before disclosure, please include:

- A short description of the issue
- Steps to reproduce (if applicable)
- Version/build you tested on
- Potential impact

Please avoid posting sensitive security details in public issues until we can review it.

## Scope

Codex 额度 starts the `codex app-server` executable bundled in ChatGPT.app and communicates with that local child process over standard input/output. It does not call provider HTTP endpoints directly.

When the live App Server lookup is unavailable, it reads only quota fields from local session logs in:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

It does not collect or upload prompt content, replies, attachments, or auth credentials.
