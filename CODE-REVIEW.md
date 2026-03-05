# Code Review — Argus

_Quick pass: dead code, bugs, missing error handling, doc/code inconsistencies, flagged comments._

---

## Critical

- **`argus.env` is gitignored but present on disk with real credentials** (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`). The `.gitignore` correctly excludes it, so it won't be committed — but it lives in the working tree next to tracked files. Any accidental `git add -f` or a misconfigured ignore rule would expose secrets. Consider storing credentials outside the repo root.

---

## Architectural

- **Dual control planes, neither complete** (`cmd/argus/main.go`, `internal/watchdog/`): The Go watchdog framework is solid and well-tested (breadcrumb crash recovery, `/health` endpoint, panic isolation) but its two registered checks are empty stubs — one logs "dry-run: would collect metrics" and the other does nothing. Production logic lives entirely in `argus.sh`. The Go binary is not referenced in `argus.service`. `IMPROVEMENTS.md` #2 calls this out explicitly. The two layers don't share state or signal each other.

- **`SHUTTING_DOWN` variable is set but never read** (`argus.sh:319–320`): The trap sets `SHUTTING_DOWN=true` then exits immediately. The variable is never checked anywhere. Dead code.

---

## Bugs

- **`TELEGRAM_MAX_RETRIES=2` is misnamed** (`actions.sh:11`, `actions.sh:136`): The variable is described as "max retries" but controls the total number of attempts. With `TELEGRAM_MAX_RETRIES=2`, the loop runs attempts 1 and 2 — no retries, just two tries. For actual retries you'd want 3 attempts. Either rename to `TELEGRAM_MAX_ATTEMPTS` or set to 3.

- **Hostname prepend skips messages that contain any `[`** (`actions.sh:115`): The condition `[[ "$message" != *"["* ]]` blocks prepending the hostname whenever the message contains any opening bracket — e.g., `[WARNING] disk full` won't get a hostname tag even though it lacks the host identifier. The intent is to avoid double-tagging, but the heuristic is too broad. Should check for the actual hostname string only.

- **`action_log` default path hardcodes `$HOME/athena/`** (`actions.sh:164`): `ARGUS_OBSERVATIONS_FILE` defaults to `$HOME/athena/state/argus/observations.md`. Same for `problem_script` (`$HOME/athena/scripts/problem-detected.sh`) and `wake_script` (`$HOME/athena/scripts/wake-gateway.sh`). These paths silently no-op when the Athena tree doesn't exist. Fine for the current deployment but fragile for others.

- **`collect_athena` uses GNU `find -printf`** (`collectors.sh:126`): `-printf "%T+ %p\n"` is a GNU extension. Will silently fail or error on BSD/macOS. Low impact given the deployment target is Linux, but worth noting.

---

## Missing Error Handling

- **`action_restart_service` returns success when `ALLOWED_SERVICES` is empty** (`actions.sh:9, 18–29`): `ALLOWED_SERVICES=()` is the current default (all services were removed). The loop over an empty array skips without setting `allowed=true`, so every restart attempt is correctly blocked — but the error message says "not in allowlist ()" which is confusing. There's no guard against calling `action_restart_service` when the allowlist is intentionally empty.

- **`run_monitoring_cycle` ignores orphan check failure silently** (`argus.sh:234`): `action_check_and_kill_orphan_tests "false" || log ERROR "Orphan check failed"` swallows the error and continues. The cycle isn't marked failed. If orphan state is corrupt the function will silently no-op.

- **Go `main.go` doesn't handle health server bind errors** (`cmd/argus/main.go:76`): The goroutine logs the error but the process continues running without a health endpoint. There's no way to detect from outside that `/health` is silently unavailable.

---

## Doc / Code Inconsistencies

- **`README.md` and `prompt.md` still reference Athena's Agora mythology framing** but `collectors.sh:24` and `collectors.sh:130` have inline comments ("athena-web removed from monitoring (2026-02-19)") showing those services were removed. The monitoring scope shown in docs should clarify what's actually active vs. what's been retired.

- **`install.sh` likely still references paths or services removed in `815be6a`** — not re-verified post-cleanup, but the commit touched `install.sh` for path fixes; worth checking if any `mcp-agent-mail` references survived.

- **Go module path updated to `github.com/Perttulands/argus-watcher`** (`go.mod`) — matches the published GitHub repo name.

- **`IMPROVEMENTS.md` is written as future work** but is committed as a tracked file with no indication of which items have been actioned. Items 1–5 are all open. The Go watchdog (Improvement #2) was partially implemented but not wired up.

---

## TODO / FIXME

No `TODO`, `FIXME`, or `HACK` comments found in tracked source files. The open work is documented in `IMPROVEMENTS.md` instead.

---

## Minor

- **`collect_all_metrics` does not time-bound individual collectors** (`collectors.sh:162–168`): A hanging `curl` or `tmux` call in a collector would block the entire cycle despite the per-collector error isolation. The LLM timeout (120 s) provides a ceiling but no per-collector timeout exists.

- **`action_log` appends to a file with `>>` without locking** (`actions.sh:185`): Safe in single-process use but fragile if multiple Argus instances ran against the same observations file.

- **`argus.sh:70` spawns a subshell for every LLM call** via `bash -c 'echo "$1" | claude -p ...' _ "$full_prompt"` — the extra shell layer is unnecessary; `echo "$full_prompt" | timeout ... claude -p ...` would work directly and is cleaner.
