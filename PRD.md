# Argus — Product Requirements Document

**Mode: Prescriptive** — This document defines what Argus ought to do.

**Version:** 1.0
**Date:** 2026-03-12

---

## Purpose

Argus is a self-contained server watchdog with LLM-assisted decision-making. It collects system metrics on a fixed interval, sends them to an LLM for assessment, and executes a small set of allowlisted remediation actions. The LLM decides *what* to do; the code decides *what is allowed*.

Argus is designed for Linux servers running autonomous agents where unattended operation is the norm. It must be boring, correct, and safe.

---

## Core Loop

Every cycle (default 300 seconds):

1. **Collect metrics** — CPU, memory, disk, swap, process table, service health
2. **Call LLM** — Send metrics to Claude Haiku with a decision-making prompt
3. **Parse response** — Extract assessment, observations, and action list from JSON
4. **Dispatch actions** — Execute each action through validated handlers
5. **Record state** — Log outcome, update cycle state, write to problem registry

---

## Action Contract

Argus permits exactly 6 actions. No arbitrary shell execution exists.

| Action | Purpose | Key Guardrail |
|--------|---------|---------------|
| `restart_service` | Restart a systemd service | Explicit `ALLOWED_SERVICES` allowlist (empty by default) |
| `kill_pid` | Kill a runaway process by PID | PID must be numeric and match `node\|claude\|codex` |
| `kill_tmux` | Kill a tmux session by name | Name sanitized to `[a-zA-Z0-9._-]` |
| `clean_disk` | Remove old files from safe paths | Hardcoded safelist (`/tmp`, `/var/tmp`, selected cache dirs) |
| `alert` | Send a Telegram notification | Retry on failure, hostname prepended |
| `log` | Record an observation | Auto-escalates after 3 consecutive repeats |

Additionally, orphan `node --test` processes are killed deterministically after 3 consecutive detections. This path does not involve the LLM.

---

## Problem Registry

Every detected problem is appended to `state/problems.jsonl` with fields: timestamp, severity, type, description, action taken, action result, bead ID, and host. This file is the source of truth for all downstream analytics, pattern detection, and reporting.

---

## Bead Integration

Argus creates beads (via `br`) when an issue needs human attention:

- An action failed (`action_result: failure`)
- The same problem recurred at least N times (default 3) within a time window (default 24h)
- No automatic remediation path exists

Open beads are deduplicated by a key derived from problem type and description hash. On successful remediation (e.g., a restart succeeds), matching open beads are auto-closed. If `br` is unavailable, bead creation is silently skipped.

---

## Relay Integration

When Relay (Hermes) is available, Argus publishes structured `argus.problem` events. If Relay is unavailable, events append to a fallback JSONL file. Two companion scripts handle periodic publishing:

- `relay-observations.sh` — sends recent observation snapshots
- `relay-summary.sh` — sends daily summaries (falls back to Telegram)

---

## Alert Deduplication

Repeat alerts for the same problem key are suppressed within a configurable window (default 3600s). Suppression state is persisted in `state/dedup.json` and compacted automatically. Suppressed repeats are still recorded in the problem registry with `action_result: suppressed`.

---

## Restart Backoff

`restart_service` uses persistent per-service backoff state:

- Attempt 1: immediate
- Attempt 2: wait 60s (configurable)
- Attempt 3: wait 300s (configurable)
- Attempt 4+: enter cooldown (default 3600s), mark restart loop

Successful restarts reset counters and auto-close matching beads.

---

## Metric Collection

Collectors gather: service health (systemd + gateway liveness probe), system stats (CPU, memory, disk, swap, load), process table (top consumers), agent status, and memory hog details when memory is critical. Previous cycle state is appended to metrics for self-monitoring context.

---

## Reliability Requirements

- **Log rotation**: at 10MB with 3 backups
- **Disk space guard**: skip LLM call if root filesystem < 100MB free; send emergency alert
- **Self-monitoring**: escalate after 3 consecutive cycle failures
- **Boot grace period**: suppress service restart failure beads during startup (default 120s)
- **Clean shutdown**: handle SIGTERM/SIGINT gracefully
- **JSON safety**: all state files constructed via `jq` to prevent injection

---

## Security Requirements

- No arbitrary command execution path
- PID inputs must be numeric and match an allowed process name pattern
- Service names checked against an explicit allowlist
- Tmux session names sanitized against injection
- Telegram payloads built with `jq`, not string concatenation
- systemd unit runs with `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `MemoryMax=1G`

---

## Dependencies

**Required:** `bash`, `claude` CLI (with valid API key), `jq`, `curl`, `timeout`

**Optional:** `relay` (Hermes), `br` (beads), `systemctl`, `tmux`

---

## Go Binary (Reserved)

A Go-based watchdog binary exists at `cmd/argus/` with breadcrumb crash recovery, health endpoints (`/health`), and a check framework. Its production checks are currently placeholders. The Go binary is reserved for future unification of both runtimes into a single entry point, as described in the improvements roadmap.

---

## Out of Scope

- Arbitrary shell execution
- Multi-host coordination
- Mythology and narrative (see README.md)
- LLM fallback when API is unreachable (planned improvement)
- Cross-cycle context window (planned improvement)
