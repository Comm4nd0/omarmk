# Changelog

## 0.1.0 (2026-10-18)

- Initial release: bar icon with problem count, popup listing down hosts and
  WARN/CRIT/UNKNOWN services worst first with deep links into Checkmk,
  desktop notifications for new or worsening problems (one summary at
  start-up, deduplicated across monitors), read-only automation user with
  the secret kept in a file and passed to curl on stdin.
- "Ask the AI agent" buttons (header, per row, `a` key) that open Omarchy's
  default coding agent with a prompt describing the problems; read-only
  diagnosis by default, optional safe fixes and extra context settings.
