# Argus

![Argus Banner](banner.png)

*One red eye. Spiked collar. Zero chill.*

---

Argus is a server watchdog. Every five minutes it collects system metrics — CPU, memory, disk, swap, processes, service health — sends them to Claude Haiku, and lets the model pick from a short list of safe actions. It can restart a service, kill a runaway process, clean stale temp files, or send you a Telegram alert. That's it. No arbitrary shell execution, no creative freedom, no surprises. The LLM decides *what* to do; the code decides *what's allowed*. If you run autonomous agents on a Linux box and want something watching the host while you sleep, this is that something.

---

In the Odyssey, Argus was the dog who waited twenty years for his master to come home. He was old, covered in fleas, lying on a pile of dung, and he was the only living thing in Ithaca that recognized Odysseus. Then he died. Loyalty like that doesn't come with commands. It comes with scars.

Our Argus has the same energy, except instead of waiting on a porch he patrols a Linux server every five minutes and kills anything that shouldn't be there. Spiked bronze collar with tally marks — one for every orphan process that thought it could hide. One eye is normal. The other glows red. A broken chain drags behind him because nobody put Argus on a leash. Nobody could.

You don't want your ops watchdog to be creative. You want it to be correct, boring, and slightly terrifying. Argus is all three.

---

## How It Works

```
Every ARGUS_INTERVAL seconds (default 300):
  collect metrics → ask Claude Haiku what to do → do it → log it → go back to sleep
```

Argus collects system metrics (CPU, memory, disk, swap, processes, service health), sends them to an LLM with a decision-making prompt, and acts on the response. The LLM can only execute **6 allowlisted actions**. That's it. There's no `exec("arbitrary shell command")` hiding in here.

| Action | What It Does | Guardrail |
|--------|-------------|-----------|
| `restart_service` | Restarts a service | Must be in explicit `ALLOWED_SERVICES` allowlist |
| `kill_pid` | Kills a process | Must be numeric PID; must match `node\|claude\|codex` |
| `kill_tmux` | Kills a tmux session | Name sanitized against injection |
| `clean_disk` | Cleans old files from safe temp/cache/archive paths | Hardcoded safelist only (`/tmp`, `/var/tmp`, selected `~/.cache`, log archives) |
| `alert` | Sends a Telegram notification | Retry on failure, hostname prepended |
| `log` | Records an observation | Auto-escalates after 3 consecutive repeats |

Orphan `node --test` processes are auto-killed **deterministically** after 3 consecutive detections. No LLM involved. Some things don't need AI.

---

## Two Runtimes

This repo contains two independent runtimes:

### 1. Bash production loop (`argus.sh`)

The main monitoring system. Runs every `ARGUS_INTERVAL` seconds, collects metrics, calls Claude Haiku, and executes allowlisted actions.

```bash
./argus.sh           # loop forever
./argus.sh --once    # single cycle then exit
```

### 2. Go watchdog binary (`cmd/argus`)

A separate Go-based watchdog with its own CLI, breadcrumb state persistence, and HTTP health endpoint. The default checks in the current build are placeholders — no production actions are wired in the Go binary by default.

```
argus [flags]

Flags:
  --breadcrumb-file <path>   Breadcrumb state file (default: logs/watchdog.breadcrumb.json)
  --health-addr <addr>       Health server bind address; empty disables it (default: :8080 or ARGUS_HEALTH_ADDR)
  --interval <duration>      Watchdog cycle interval (default: 5m)
  --once                     Run one cycle and exit
  --dry-run                  Log intended actions, skip execution
```

HTTP endpoint (Go binary only):

| Endpoint | Method | Response |
|----------|--------|----------|
| `GET /health` | Returns `{"status":"ok"\|"degraded","watchdog":{...}}` |

Status is `degraded` when `PreviousCycleInterrupted=true` or `ConsecutiveFailures>0`.

---

## Components

| File | What it does |
|------|-------------|
| `argus.sh` | Main loop: metrics → LLM → actions → logs |
| `collectors.sh` | Gathers services, system stats, processes, agents, memory hog context |
| `actions.sh` | 6 allowlisted actions with validation, backoff, dedup, bead integration |
| `prompt.md` | LLM decision contract and action schema. Edit this to change what Argus cares about. |
| `argus.service` | Systemd unit with resource limits and security hardening |
| `install.sh` | Idempotent installer. Run it twice, nothing breaks. |
| `notify-telegram.sh <message>` | One-shot Telegram ops message sender |

### Operational Scripts

| Script | Description |
|--------|-------------|
| `scripts/argus-stats.sh [output_file]` | Export dashboard JSON from `problems.jsonl` |
| `scripts/pattern-analysis.sh` | Build `state/pattern-analysis.json` from problem history |
| `scripts/pattern-detect.sh` | Create one daily pattern bead per new signature |
| `scripts/relay-observations.sh` | Send recent observation snapshot to Relay (fallback to JSONL) |
| `scripts/relay-summary.sh` | Send daily summary to Relay (fallback to Telegram or JSONL) |

---

## Install

```bash
git clone https://github.com/Perttulands/argus-watcher.git
cd argus-watcher
cp argus.env.example argus.env
# Edit argus.env: set ANTHROPIC_API_KEY (required), TELEGRAM_BOT_TOKEN + CHAT_ID (optional)
chmod +x install.sh
./install.sh
```

No compiler. No runtime. No package manager existential crisis. It's bash scripts and an API key.

---

## Usage

```bash
# Single cycle — see what he sees
source argus.env && ./argus.sh --once

# Let him loose
sudo systemctl start argus

# Watch him work
tail -f logs/argus.log

# See his last decision
cat logs/last_response.json | jq

# Service management
sudo systemctl start|stop|restart|status argus
```

---

## Current Status

What works, what doesn't.

- ✅ Bash production loop — stable, running in production since February 2026
- ✅ All 6 allowlisted actions — validated, sanitized, tested
- ✅ Problem registry and alert deduplication
- ✅ Restart backoff with persistent per-service state
- ✅ Orphan process deterministic kill (no LLM needed)
- ✅ Bead lifecycle automation (create, dedup, auto-close)
- ✅ Relay integration with graceful fallback to JSONL
- ✅ Pattern analysis and daily bead summaries
- ✅ Telegram alerting with retry
- ✅ systemd deployment with security hardening
- ✅ Shell and Go test suites
- ⚠️ Go watchdog binary — builds and runs, but default checks are placeholders. No production actions wired yet.
- ⚠️ `ALLOWED_SERVICES` is empty by default — you must populate it to permit `restart_service`
- ⚠️ Requires `claude` CLI with valid API key — no fallback LLM path

---

## Security

No arbitrary command execution. Every input is validated like it's trying to escape.

- PIDs: must be numeric, must exist, must match allowed process names (`node|claude|codex`)
- Services: explicit `ALLOWED_SERVICES` allowlist only (empty by default — must be populated to permit restarts)
- Tmux names: sanitized against injection (`[a-zA-Z0-9._-]` only)
- Telegram payloads: built with `jq`, not string concatenation
- systemd: `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `MemoryMax=1G`

---

## Reliability

- Log rotation at 10MB (3 backups)
- Disk space guard — skips LLM call if root filesystem `< 100MB` free; sends emergency alert
- Self-monitoring — escalates after 3 consecutive cycle failures
- Boot grace period — suppresses service restart failure beads during `ARGUS_BOOT_GRACE_SECONDS` (default 120s)
- Clean shutdown on `SIGTERM`/`SIGINT`
- JSON state via `jq` (no injection from error messages)

---

## Problem Registry

Argus records detected problems to `state/problems.jsonl` (override with `ARGUS_PROBLEMS_FILE`).

Each line is a JSON object:

```json
{
  "ts": "2026-02-20T00:00:00Z",
  "severity": "critical|warning|info",
  "type": "disk|memory|service|process|swap",
  "description": "human-readable problem summary",
  "action_taken": "restart_service:openclaw-gateway",
  "action_result": "success|failure|skipped",
  "bead_id": null,
  "host": "hostname"
}
```

Quick validation:

```bash
jq -c . state/problems.jsonl >/dev/null
```

---

## Auto Bead Creation

Argus creates or reuses beads when an issue needs human attention:

- Action failed (`action_result: failure`)
- Same problem recurs at least `ARGUS_BEAD_REPEAT_THRESHOLD` times (default 3) within `ARGUS_BEAD_REPEAT_WINDOW_SECONDS` (default 86400)
- Problem has no automatic remediation path (for example, `alert`/`log`)

Behavior:

- Command used: `br create "[argus] <type>: <description>" ...`
- Open-bead dedup key: `Problem key: <type>:<description_sha256_16>`
- If `br` is unavailable, Argus skips bead creation and continues monitoring

---

## Alert Deduplication

Argus suppresses repeat alerts for the same problem key (`<type>:<description_sha256_16>`) within `ARGUS_DEDUP_WINDOW` seconds (default `3600`).

Suppression state is kept in `state/dedup.json` and old keys are compacted automatically. Suppressed repeats are still written to `state/problems.jsonl` with `action_result: suppressed`.

---

## Memory Hog Identification

When memory is critical, Argus enriches alerts and problem records with:

- process name, PID, RSS (KB), `%MEM`, runtime (`etime`)
- kill-candidate hint (`yes` when process matches `node|claude|codex`)

---

## Restart Backoff

`restart_service` actions use persistent per-service backoff state (`state/restart-backoff.json`):

- attempt 1: immediate
- attempt 2: wait `ARGUS_RESTART_BACKOFF_SECOND_DELAY` (default 60s)
- attempt 3: wait `ARGUS_RESTART_BACKOFF_THIRD_DELAY` (default 300s)
- attempt 4+: mark restart loop, enter cooldown for `ARGUS_RESTART_COOLDOWN_SECONDS` (default 3600s)

On successful restart, attempt counters reset and any matching open service bead is auto-closed.

---

## Pattern Analysis

Argus includes offline pattern tooling over `state/problems.jsonl`:

- `scripts/pattern-analysis.sh`: generates `state/pattern-analysis.json`. Detects: `service_restart_spike` (≥3 restarts same day), `disk_pressure_trend` (≥3 disk events across ≥2 days), `memory_hog_recurring` (≥3 memory events for same process), `time_correlation` (≥3 problems in same UTC hour).
- `scripts/pattern-detect.sh`: turns analysis output into one daily summary bead per signature and records emissions in `state/patterns.jsonl`.

---

## Historical Metrics Export

```bash
# Print stats JSON to stdout
scripts/argus-stats.sh

# Write stats JSON to a file
scripts/argus-stats.sh state/argus-stats.json
```

Output includes totals, counts by type/severity/action result, success rate, and hourly/daily buckets.

---

## Relay Integration (Optional)

When Relay is available, Argus publishes structured problem events:
- Event type: `argus.problem`
- Route: `ARGUS_RELAY_TO` (default: `athena`)
- Sender: `ARGUS_RELAY_FROM` (default: `argus`)

If Relay is unavailable, events append to `ARGUS_RELAY_FALLBACK_FILE` (default: `state/relay-fallback.jsonl`).

Observations logged via the `log` action are written to `ARGUS_OBSERVATIONS_FILE` (default: `state/observations.md`).

```bash
scripts/relay-observations.sh    # send observation snapshot to Relay
scripts/relay-summary.sh         # send daily summary to Relay
```

Both scripts fall back to JSONL queues when Relay is unavailable. `relay-summary.sh` optionally falls back to direct Telegram if bot credentials are configured.

---

## Configuration

Copy `argus.env.example` to `argus.env` and edit. Key variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ARGUS_INTERVAL` | `300` | Loop sleep interval (seconds) |
| `ARGUS_GATEWAY_PORT` | `18505` | Gateway liveness probe port |
| `ARGUS_RELAY_ENABLED` | `true` | Enable Relay publishing |
| `ARGUS_RELAY_BIN` | `$HOME/go/bin/relay` | Relay CLI path |
| `ARGUS_DEDUP_WINDOW` | `3600` | Alert suppression window (seconds) |
| `ARGUS_BEAD_REPEAT_THRESHOLD` | `3` | Recurrence count for bead creation |
| `ARGUS_RESTART_BACKOFF_SECOND_DELAY` | `60` | Delay before 2nd restart attempt |
| `ARGUS_RESTART_COOLDOWN_SECONDS` | `3600` | Cooldown after restart loop detection |
| `ARGUS_DISK_CLEAN_MAX_AGE_DAYS` | `7` | Cleanup age threshold |
| `TELEGRAM_BOT_TOKEN` | unset | Telegram API token |
| `TELEGRAM_CHAT_ID` | unset | Telegram chat target |

See `argus.env.example` for the full list.

---

## Dependencies

**Required:** `bash`, `claude` CLI, `jq`, `curl`, `timeout`

**Optional:** `relay`, `br`, `systemctl`, `tmux`

**Go runtime:** Go 1.22+ (stdlib only, no third-party modules)

---

## For Agents

This repo includes `AGENTS.md` with operational instructions.

---

## Part of Polis

Argus is the infrastructure watchdog in a larger ecosystem of tools that work together.

| Tool | What it does | Repo |
|------|-------------|------|
| **Ergon** | Work orchestration | [ergon-work-orchestration](https://github.com/Perttulands/ergon-work-orchestration) |
| **Hermes** | Message relay between agents | [hermes-relay](https://github.com/Perttulands/hermes-relay) |
| **Cerberus** | Access gate | [cerberus-gate](https://github.com/Perttulands/cerberus-gate) |
| **Chiron** | Agent training framework | [chiron-trainer](https://github.com/Perttulands/chiron-trainer) |
| **Learning Loop** | Feedback and learning pipeline | [learning-loop](https://github.com/Perttulands/learning-loop) |
| **Senate** | Governance and decisions | [senate](https://github.com/Perttulands/senate) |
| **Beads** | Work tracking units | [beads-polis](https://github.com/Perttulands/beads-polis) |
| **Truthsayer** | Code analysis and review | [truthsayer](https://github.com/Perttulands/truthsayer) |
| **UBS** | Bug scanning | [ultimate_bug_scanner](https://github.com/Perttulands/ultimate_bug_scanner) |
| **Oathkeeper** | Promise and contract enforcement | [horkos-oathkeeper](https://github.com/Perttulands/horkos-oathkeeper) |
| **Argus** | Server watchdog (you are here) | [argus-watcher](https://github.com/Perttulands/argus-watcher) |
| **Utils** | Shared utilities | [polis-utils](https://github.com/Perttulands/polis-utils) |

---

Argus was forged as part of Polis, where AI agents build software and a hound with one red eye makes sure the server doesn't burn down while they do it.

[Truthsayer](https://github.com/Perttulands/truthsayer) watches the code. [Oathkeeper](https://github.com/Perttulands/horkos-oathkeeper) watches the promises. [Relay](https://github.com/Perttulands/hermes-relay) carries the messages. Argus watches everything else. Between the four of them, the 3am page is someone else's problem.

The [mythology](https://github.com/Perttulands/athena-workspace/blob/main/mythology.md) has the full story.

## License

MIT
