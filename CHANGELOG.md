# Changelog

All notable changes to Argus.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)

## [Unreleased]

### Added
- `.truthsayer.toml` config and pre-commit hook for agent instruction enforcement (7a79735)
- Shell test coverage for `argus.sh` main loop functions (`call_llm`, `process_llm_response`, `rotate_log`) and `collectors.sh` functions (`collect_services`, `collect_system`, `collect_processes`, `collect_agents`, `collect_cgroup_memory_context`)

### Fixed
- Shellcheck lint failures: quoting fixes in `collectors.sh` and `install.sh`, suppression directives in `argus.sh`, SC2015 fix in `actions.sh`

### Changed
- README: further mythology-forward rewrite — spicy, standalone voice (f042a84, e5f62eb)
- Improved `claude -p` failure diagnostics in `argus.sh` by capturing and logging stderr output on non-zero exits.
- Wrapped watchdog breadcrumb load errors with context (`load breadcrumb: ...`) in `internal/watchdog/watchdog.go`.

### Fixed
- 2026-02-20: Extended `actions.sh` integer env validation to additional runtime controls (`ARGUS_RELAY_TIMEOUT`, `ARGUS_BEAD_PRIORITY`, `ARGUS_DEDUP_RETENTION_SECONDS`, `ARGUS_RESTART_BACKOFF_THIRD_DELAY`, `ARGUS_RESTART_COOLDOWN_SECONDS`) so invalid values fail fast before action execution.
- 2026-02-20: Added `validate_int_env` guards for arithmetic-backed env configs in `actions.sh` (`ARGUS_BEAD_REPEAT_THRESHOLD`, `ARGUS_BEAD_REPEAT_WINDOW_SECONDS`, `ARGUS_DEDUP_WINDOW`, `ARGUS_DISK_CLEAN_MAX_AGE_DAYS`, `ARGUS_RESTART_BACKOFF_SECOND_DELAY`) to fail fast on non-integer or out-of-range values.
- 2026-02-20: Resolved truthsayer-reported swallowed error paths in `cmd/argus/main.go` by returning wrapped runtime/shutdown errors through `run()` and exiting non-zero in `main`, so failures are no longer silently logged during shutdown.
- 2026-02-20: Resolved watchdog error-handling gaps in `internal/watchdog/watchdog.go` by propagating cycle errors from `RunCycle`/`Run`, preserving failure state when breadcrumb persistence fails, and handling temp-file cleanup errors instead of discarding them.

### Removed
- `.truthsayer.toml` reverted — rule suppression removed, judge handles context directly (eed4559)

## [0.2.1] - 2026-02-19

### Added
- "For Agents" section in README: install instructions, runtime usage, and what-this-is for agent consumers (f286e6d)
- Changelog ground rule added to `AGENTS.md`: every user-facing change requires a CHANGELOG entry (4faa9d2)

## [0.2.0] - 2026-02-19

### Added
- `IMPROVEMENTS.md`: five prioritised engineering improvements with implementation plans (5c09fc9)
- Banner image added to `README.md` (a7c316c)

### Changed
- README rewritten in Athena's Agora mythology voice (0acf2bc, bd4496d)
- Gateway health check switched from systemd unit to port 18500 TCP probe — supports non-systemd deployments (4d8a572)
- `prompt.md` updated to reflect reduced service scope and new gateway check method (4d8a572, 5c09fc9)
- Allowed services list in `actions.sh` and `prompt.md` updated (4d8a572)
- `argus.service` and `install.sh` path fixes (815be6a)

### Fixed
- Arithmetic errors in process and tmux session counting in `collectors.sh` (807e435)
- README title typo (e72d3f5)

### Removed
- `athena-web` dropped from monitoring: service checks, port 9000 probe, and restart action removed (5c09fc9)
- `mcp-agent-mail` removed from monitoring scope, collectors, and documentation (815be6a)

## [0.1.1] - 2026-02-16

### Added
- Go watchdog runtime: `cmd/argus/main.go` and `internal/watchdog/` package with breadcrumb crash recovery, `/health` HTTP endpoint, panic isolation per check, and dry-run mode (c9e0ecf)
- Unit tests for watchdog: cycle continuation after errors and panics, interrupted breadcrumb recovery, health handler JSON contract (c9e0ecf)
- Log rotation: `argus.log` rotates at 10 MB (3 backups kept); `observations.md` rotates at 500 KB (8733266)
- Disk space guard: skips LLM call and sends emergency Telegram alert when less than 100 MB free (8733266)
- JSON safety: all state files (`cycle_state.json`, `argus-orphans.json`) written via `jq` — eliminates injection risk from error message content (8733266)
- Telegram retry: failed alerts retried once before giving up; alert failure no longer fails the monitoring cycle (8733266)
- Hostname prepended in all Telegram alerts for multi-server clarity (8733266)
- Self-monitor rate limiting: operator alerted every 3rd consecutive failure rather than every cycle (8733266)
- Orphan `node --test` auto-kill: after 3 consecutive detections, processes are SIGTERM'd (SIGKILL after 5 s if stubborn); state tracked in `argus-orphans.json` (0fa190a)

### Fixed
- LLM call timeout (120 s) added to prevent infinite hangs on unresponsive `claude -p` (8c7306b)
- Self-monitoring across cycles: operator alerted after 3 consecutive cycle failures (8c7306b)
- `((action_count++))` failure under `set -e` when count starts at zero (8c7306b)
- `sed` code fence stripping: switched to line-delete to correctly remove ` ``` ` and ` ```json ` wrappers from LLM output (8c7306b)
- `pgrep` self-matching in `collectors.sh`: switched to `-cf` flag for count-only matching (8c7306b)
- Each collector wrapped in independent error handler — one failing collector no longer aborts the entire cycle (8c7306b)

### Changed
- Dependency check at startup: `claude`, `jq`, `curl` verified before entering the monitoring loop (8c7306b)
- `<YOUR_HOSTNAME>` placeholder in `prompt.md` auto-substituted at runtime (8c7306b)
- Self-monitor status fed into metrics payload so the LLM can reason about Argus's own health (8c7306b)
- Observations logged to file and repeated problem detection triggers `problem-detected.sh` bead creation (0fa190a)

## [0.1.0] - 2026-02-13

### Added
- Standalone systemd ops watchdog service (`argus.service`, `install.sh`)
- AI-powered monitoring loop using Claude Haiku for decision-making, running every 5 minutes
- System metric collection: memory, disk, load average, uptime (`collectors.sh`)
- Service monitoring: `openclaw-gateway`, `athena-web`
- Process monitoring: orphan `node --test` detection, tmux session inventory
- Athena memory file modification tracking
- Five allowlisted corrective actions: `restart_service`, `kill_pid`, `kill_tmux`, `alert`, `log` (`actions.sh`)
- Independent Telegram bot alerting with credential-based configuration (`argus.env`)
- Integration with `problem-detected.sh` for automatic bead creation on repeated issues
- Core scripts: `argus.sh`, `collectors.sh`, `actions.sh`, `prompt.md`
- `argus.env.example` for credential configuration reference

### Changed
- Hardcoded host and home paths removed from service file, scripts, and documentation (816ae74)
