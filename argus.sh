#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: argus.sh failed at line $LINENO" >&2' ERR

# argus.sh — main monitoring loop for Argus ops watchdog
# Runs as a systemd service, collecting metrics every cycle and using
# Claude Haiku to reason about system health and take corrective action.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/argus.log"
PROMPT_FILE="${SCRIPT_DIR}/prompt.md"
SLEEP_INTERVAL="${ARGUS_INTERVAL:-300}"  # 5 minutes default, configurable
LLM_TIMEOUT=120     # max seconds for claude -p call
CYCLE_STATE_FILE="${LOG_DIR}/cycle_state.json"
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10 MB
MAX_LOG_FILES=3
HOSTNAME_CACHED=""

# Source helper scripts
source "${SCRIPT_DIR}/collectors.sh"
source "${SCRIPT_DIR}/actions.sh"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Cache hostname once at startup
HOSTNAME_CACHED=$(hostname -f 2>/dev/null || hostname) # REASON: FQDN may be unavailable; fallback to short hostname.

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Rotate log file when it exceeds MAX_LOG_SIZE
rotate_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        return 0
    fi
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) # REASON: file may not exist yet; 0 means no rotation needed.
    if (( size > MAX_LOG_SIZE )); then
        local i
        # Remove oldest, shift others down
        for (( i = MAX_LOG_FILES; i >= 1; i-- )); do
            local prev=$((i - 1))
            local src="${LOG_FILE}.${prev}"
            [[ $prev -eq 0 ]] && src="$LOG_FILE"
            if [[ -f "$src" ]]; then
                mv "$src" "${LOG_FILE}.${i}"
            fi
        done
        # Truncate current log — the mv above moved it to .1
        : > "$LOG_FILE"
        log INFO "Log rotated (previous log exceeded $((MAX_LOG_SIZE / 1024 / 1024))MB)"
    fi
}

call_llm() {
    local system_prompt="$1"
    local user_message="$2"

    local full_prompt
    full_prompt=$(printf '%s\n\n---\n\n%s\n\nRespond with ONLY valid JSON. No markdown, no explanation.' "$system_prompt" "$user_message")

    local response exit_code stderr_file
    stderr_file=$(mktemp)
    # shellcheck disable=SC2016 # Single quotes intentional: script is passed to bash -c
    response=$(timeout "$LLM_TIMEOUT" bash -c 'echo "$1" | claude -p --model haiku --output-format text 2>"$2"' _ "$full_prompt" "$stderr_file") && exit_code=0 || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        local stderr_output
        stderr_output=$(cat "$stderr_file" 2>/dev/null; rm -f "$stderr_file") # REASON: temp file may already be cleaned up
        if [[ $exit_code -eq 124 ]]; then
            log ERROR "claude -p timed out after ${LLM_TIMEOUT}s"
        else
            log ERROR "claude -p call failed (exit code: $exit_code)"
        fi
        [[ -n "$stderr_output" ]] && log ERROR "claude -p stderr: $stderr_output"
        return 1
    fi

    rm -f "$stderr_file"

    if [[ -z "$response" ]]; then
        log ERROR "Empty response from claude -p"
        return 1
    fi

    echo "$response"
}

process_llm_response() {
    local response="$1"

    # Strip markdown code fences if present (```json ... ``` wrapper)
    response=$(echo "$response" | sed '/^```\(json\)\{0,1\}$/d')

    # Validate JSON
    if ! echo "$response" | jq empty 2>/dev/null; then # REASON: jq parse errors are less useful than our raw response log below.
        log ERROR "LLM response is not valid JSON"
        log ERROR "Raw response (first 500 chars): ${response:0:500}"
        return 1
    fi

    # Extract assessment
    local assessment
    assessment=$(echo "$response" | jq -r '.assessment // "No assessment provided"')
    log INFO "Assessment: $assessment"

    # Extract and log observations
    local obs_output
    obs_output=$(echo "$response" | jq -r 'if .observations then .observations[] else empty end' 2>/dev/null) || true # REASON: response already validated; empty/missing observations is normal.
    if [[ -n "$obs_output" ]]; then
        log INFO "Observations:"
        while IFS= read -r obs; do
            [[ -n "$obs" ]] && log INFO "  - $obs"
        done <<< "$obs_output"
    fi

    # Execute actions
    local actions_output
    actions_output=$(echo "$response" | jq -c 'if .actions then .actions[] else empty end' 2>/dev/null) || true # REASON: response already validated; empty/missing actions is normal.

    if [[ -z "$actions_output" ]]; then
        log INFO "No actions to execute"
        return 0
    fi

    log INFO "Executing actions:"
    local action_count=0
    while IFS= read -r action; do
        [[ -z "$action" ]] && continue
        action_count=$((action_count + 1))
        local action_type
        action_type=$(echo "$action" | jq -r '.type // "unknown"')
        log INFO "  Action $action_count: $action_type"

        if execute_action "$action"; then
            log INFO "  Action $action_count ($action_type) completed"
        else
            log ERROR "  Action $action_count ($action_type) failed"
        fi
    done <<< "$actions_output"

    log INFO "Executed $action_count action(s)"
}

# Record cycle outcome for self-monitoring
# Uses jq for safe JSON construction (no injection risk from error messages)
record_cycle_state() {
    local status="$1"  # ok | failed
    local detail="${2:-}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local prev_failures=0
    if [[ -f "$CYCLE_STATE_FILE" ]]; then
        prev_failures=$(jq -r '.consecutive_failures // 0' "$CYCLE_STATE_FILE" 2>/dev/null || echo 0) # REASON: state file may be corrupted or from older version; 0 is safe default.
    fi

    local consecutive_failures=0
    if [[ "$status" == "failed" ]]; then
        consecutive_failures=$((prev_failures + 1))
    fi

    # Use jq for safe JSON construction — detail may contain quotes/special chars
    jq -n \
        --arg status "$status" \
        --arg timestamp "$now" \
        --arg detail "$detail" \
        --argjson failures "$consecutive_failures" \
        '{status: $status, timestamp: $timestamp, detail: $detail, consecutive_failures: $failures}' \
        > "$CYCLE_STATE_FILE"
}

# Check if previous cycle failed and include that in metrics
check_previous_cycle() {
    if [[ ! -f "$CYCLE_STATE_FILE" ]]; then
        echo "Previous cycle: no state (first run or state cleared)"
        return 0
    fi

    local prev_status prev_detail prev_ts prev_failures
    prev_status=$(jq -r '.status // "unknown"' "$CYCLE_STATE_FILE" 2>/dev/null || echo "unknown") # REASON: state file may be corrupted or from older format; safe defaults prevent crash.
    prev_detail=$(jq -r '.detail // ""' "$CYCLE_STATE_FILE" 2>/dev/null || echo "") # REASON: state file may be corrupted or from older format; safe defaults prevent crash.
    prev_ts=$(jq -r '.timestamp // ""' "$CYCLE_STATE_FILE" 2>/dev/null || echo "") # REASON: state file may be corrupted or from older format; safe defaults prevent crash.
    prev_failures=$(jq -r '.consecutive_failures // 0' "$CYCLE_STATE_FILE" 2>/dev/null || echo 0) # REASON: state file may be corrupted or from older format; safe defaults prevent crash.

    if [[ "$prev_status" == "failed" ]]; then
        echo "WARNING: Previous cycle FAILED at ${prev_ts}: ${prev_detail}"
        echo "Consecutive failures: ${prev_failures}"

        # Alert if 3+ consecutive failures (but don't spam — only alert once)
        if (( prev_failures >= 3 )) && (( prev_failures % 3 == 0 )); then
            log ERROR "SELF-MONITOR: ${prev_failures} consecutive cycle failures"
            if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
                action_alert "[${HOSTNAME_CACHED}] Argus self-monitor: ${prev_failures} consecutive cycle failures. Last error: ${prev_detail}" || true # REASON: alert delivery is best-effort; must not crash monitor loop.
            fi
        fi
    else
        echo "Previous cycle: ${prev_status} at ${prev_ts}"
    fi
}

# Check available disk space — if critically low, skip LLM call to avoid making it worse
check_disk_space() {
    local avail_kb
    avail_kb=$(df --output=avail / 2>/dev/null | tail -1 | tr -d ' ') || return 0 # REASON: df may emit stderr in containers; inability to check disk should not halt monitor.
    if (( avail_kb < 102400 )); then  # < 100MB available
        log ERROR "CRITICAL: Disk space critically low (${avail_kb}KB available). Sending emergency alert."
        if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
            action_alert "[${HOSTNAME_CACHED}] CRITICAL: Disk space < 100MB (${avail_kb}KB). Argus skipping LLM call to conserve space." || true # REASON: alert delivery is best-effort; must not crash monitor loop.
        fi
        return 1
    fi
    return 0
}

run_monitoring_cycle() {
    log INFO "===== Monitoring cycle ====="

    # Rotate logs if needed
    rotate_log

    # Self-monitoring: check previous cycle state
    local self_check
    self_check=$(check_previous_cycle)
    log INFO "$self_check"

    # Pre-flight: check disk space before doing anything expensive
    if ! check_disk_space; then
        record_cycle_state "failed" "Disk space critically low — skipped LLM call"
        return 1
    fi

    # Deterministic orphan auto-kill (no LLM needed)
    action_check_and_kill_orphan_tests "false" || log ERROR "Orphan check failed"

    # Collect metrics
    log INFO "Collecting metrics..."
    local metrics
    metrics=$(collect_all_metrics 2>&1)

    # Append self-monitoring info to metrics
    metrics=$(printf '%s\n\n=== Argus Self-Monitor ===\n%s' "$metrics" "$self_check")

    # Load system prompt
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log ERROR "Prompt file not found: $PROMPT_FILE"
        record_cycle_state "failed" "Prompt file missing"
        return 1
    fi
    local system_prompt
    system_prompt=$(cat "$PROMPT_FILE")

    # Substitute hostname placeholder
    system_prompt="${system_prompt//<YOUR_HOSTNAME>/$HOSTNAME_CACHED}"

    # Call LLM
    log INFO "Calling LLM..."
    local llm_response
    if ! llm_response=$(call_llm "$system_prompt" "$metrics"); then
        log ERROR "LLM call failed"
        record_cycle_state "failed" "LLM call failed"
        return 1
    fi

    # Save raw response for debugging
    state_atomic_write_string "${LOG_DIR}/last_response.json" "$llm_response"

    # Process response and execute actions
    if ! process_llm_response "$llm_response"; then
        log ERROR "Failed to process LLM response"
        record_cycle_state "failed" "LLM response processing failed"
        return 1
    fi

    record_cycle_state "ok"
    log INFO "===== Cycle complete ====="
}

main() {
    log INFO "Argus ops watchdog starting (host: ${HOSTNAME_CACHED}, interval: ${SLEEP_INTERVAL}s)"

    # Check for --once flag
    local run_once=false
    if [[ "${1:-}" == "--once" ]]; then
        run_once=true
        log INFO "Running in single-shot mode (--once)"
    fi

    # Verify dependencies
    local missing=()
    for cmd in claude jq curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Missing required commands: ${missing[*]}"
        exit 1
    fi

    log INFO "Dependencies OK: claude, jq, curl"

    # Run monitoring loop
    if [[ "$run_once" == "true" ]]; then
        run_monitoring_cycle || log ERROR "Monitoring cycle failed"
    else
        log INFO "Entering continuous monitoring loop"
        while true; do
            if ! run_monitoring_cycle; then
                log ERROR "Cycle failed, will retry in ${SLEEP_INTERVAL}s"
            fi
            sleep "$SLEEP_INTERVAL" &
            wait $! 2>/dev/null || break  # REASON: wait on backgrounded sleep emits stderr when interrupted by signal; this is the standard interruptible-sleep pattern.
        done
    fi
}

# Handle signals gracefully — wait for current work to finish
# shellcheck disable=SC2034 # Read by trap handler
SHUTTING_DOWN=false
trap 'SHUTTING_DOWN=true; log INFO "Received signal, shutting down..."; exit 0' SIGTERM SIGINT

main "$@"
