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
LLM_FAILURE_DETAIL=""
LLM_FAILURE_KIND=""
LLM_RESPONSE_CONTENT=""

# Source helper scripts
source "${SCRIPT_DIR}/collectors.sh"
source "${SCRIPT_DIR}/actions.sh"

STATE_DIR="${ARGUS_STATE_DIR:-${SCRIPT_DIR}/state}"
LLM_BACKOFF_STATE_FILE="${ARGUS_LLM_BACKOFF_STATE_FILE:-${STATE_DIR}/llm-backoff.json}"
LLM_BACKOFF_BASE_SECONDS="${ARGUS_LLM_BACKOFF_BASE_SECONDS:-${SLEEP_INTERVAL}}"
LLM_BACKOFF_MAX_SECONDS="${ARGUS_LLM_BACKOFF_MAX_SECONDS:-7200}"
LLM_RATE_LIMIT_MIN_SECONDS="${ARGUS_LLM_RATE_LIMIT_MIN_SECONDS:-1800}"

validate_int_env "SLEEP_INTERVAL" 1 86400
validate_int_env "LLM_TIMEOUT" 1 3600
validate_int_env "LLM_BACKOFF_BASE_SECONDS" 1 86400
validate_int_env "LLM_BACKOFF_MAX_SECONDS" 1 86400
validate_int_env "LLM_RATE_LIMIT_MIN_SECONDS" 1 86400

# Ensure log directory exists
mkdir -p "$LOG_DIR"
mkdir -p "$STATE_DIR"

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

single_line() {
    tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

state_atomic_write_string() {
    local target_file="$1"
    local content="${2:-}"
    local target_dir tmp_file

    target_dir=$(dirname "$target_file")
    mkdir -p "$target_dir"
    tmp_file=$(mktemp "${target_dir}/.$(basename "$target_file").tmp.XXXXXX")
    printf '%s' "$content" > "$tmp_file"
    mv "$tmp_file" "$target_file"
}

classify_llm_failure() {
    local detail="${1:-}"
    local lower
    lower=$(printf '%s' "$detail" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        *rate*limit*|*too\ many\ requests*|*429*|*quota*|*cooldown*)
            echo "rate_limit"
            ;;
        *timed*out*|*timeout*)
            echo "timeout"
            ;;
        *empty*response*)
            echo "empty_response"
            ;;
        *invalid*json*|*not*valid*json*)
            echo "invalid_response"
            ;;
        *)
            echo "error"
            ;;
    esac
}

llm_state_read_field() {
    local field="$1"
    local fallback="${2:-}"
    local value

    if [[ ! -f "$LLM_BACKOFF_STATE_FILE" ]]; then
        printf '%s\n' "$fallback"
        return 0
    fi

    value=$(jq -r "$field // empty" "$LLM_BACKOFF_STATE_FILE" 2>/dev/null) || value=""
    if [[ -z "$value" ]]; then
        printf '%s\n' "$fallback"
    else
        printf '%s\n' "$value"
    fi
}

calculate_llm_backoff_seconds() {
    local failures="${1:-1}"
    local kind="${2:-error}"
    local delay="$LLM_BACKOFF_BASE_SECONDS"
    local steps

    if [[ ! "$failures" =~ ^[0-9]+$ ]] || (( failures < 1 )); then
        failures=1
    fi

    steps=$failures
    while (( steps > 0 )); do
        delay=$((delay * 2))
        if (( delay >= LLM_BACKOFF_MAX_SECONDS )); then
            delay="$LLM_BACKOFF_MAX_SECONDS"
            break
        fi
        steps=$((steps - 1))
    done

    if [[ "$kind" == "rate_limit" ]] && (( delay < LLM_RATE_LIMIT_MIN_SECONDS )); then
        delay="$LLM_RATE_LIMIT_MIN_SECONDS"
    fi

    printf '%s\n' "$delay"
}

record_llm_backoff_state() {
    local kind="${1:-error}"
    local detail="${2:-LLM call failed}"
    local now failures delay next_retry_epoch now_iso next_retry_iso payload

    failures=$(llm_state_read_field '.consecutive_failures' '0')
    if [[ ! "$failures" =~ ^[0-9]+$ ]]; then
        failures=0
    fi
    failures=$((failures + 1))

    delay=$(calculate_llm_backoff_seconds "$failures" "$kind")
    now=$(date -u +%s)
    next_retry_epoch=$((now + delay))
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    next_retry_iso=$(date -u -d "@$next_retry_epoch" +%Y-%m-%dT%H:%M:%SZ)

    payload=$(jq -n \
        --arg kind "$kind" \
        --arg detail "$detail" \
        --arg now_iso "$now_iso" \
        --arg next_retry_iso "$next_retry_iso" \
        --argjson failures "$failures" \
        --argjson delay "$delay" \
        --argjson next_retry_epoch "$next_retry_epoch" \
        '{
            kind: $kind,
            detail: $detail,
            consecutive_failures: $failures,
            delay_seconds: $delay,
            failed_at: $now_iso,
            next_retry_at: $next_retry_iso,
            next_retry_epoch: $next_retry_epoch
        }')

    state_atomic_write_string "$LLM_BACKOFF_STATE_FILE" "$payload"
    log WARNING "LLM backoff engaged: kind=${kind}, failures=${failures}, retry_in=${delay}s, next_retry=${next_retry_iso}"
}

clear_llm_backoff_state() {
    local payload
    payload=$(jq -n '{
        kind: null,
        detail: "",
        consecutive_failures: 0,
        delay_seconds: 0,
        failed_at: null,
        next_retry_at: null,
        next_retry_epoch: 0
    }')
    state_atomic_write_string "$LLM_BACKOFF_STATE_FILE" "$payload"
}

llm_backoff_remaining_seconds() {
    local next_retry_epoch now

    next_retry_epoch=$(llm_state_read_field '.next_retry_epoch' '0')
    if [[ ! "$next_retry_epoch" =~ ^[0-9]+$ ]]; then
        next_retry_epoch=0
    fi

    now=$(date -u +%s)
    if (( next_retry_epoch > now )); then
        printf '%s\n' $((next_retry_epoch - now))
    else
        printf '0\n'
    fi
}

log_llm_backoff_active() {
    local remaining="$1"
    local failures kind next_retry_at detail

    failures=$(llm_state_read_field '.consecutive_failures' '0')
    kind=$(llm_state_read_field '.kind' 'error')
    next_retry_at=$(llm_state_read_field '.next_retry_at' 'unknown')
    detail=$(llm_state_read_field '.detail' '')

    log WARNING "LLM backoff active: kind=${kind}, failures=${failures}, remaining=${remaining}s, next_retry=${next_retry_at}. Skipping LLM call."
    if [[ -n "$detail" ]]; then
        log INFO "Last LLM failure detail: $detail"
    fi
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
    LLM_FAILURE_DETAIL=""
    LLM_FAILURE_KIND=""
    LLM_RESPONSE_CONTENT=""

    local full_prompt
    full_prompt=$(printf '%s\n\n---\n\n%s\n\nRespond with ONLY valid JSON. No markdown, no explanation.' "$system_prompt" "$user_message")

    local response exit_code stderr_file
    stderr_file=$(mktemp)
    # shellcheck disable=SC2016 # Single quotes intentional: script is passed to bash -c
    response=$(timeout "$LLM_TIMEOUT" bash -c 'echo "$1" | claude -p --model haiku --output-format text 2>"$2"' _ "$full_prompt" "$stderr_file") && exit_code=0 || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        local stderr_output
        stderr_output=$(cat "$stderr_file" 2>/dev/null | single_line; rm -f "$stderr_file") # REASON: temp file may already be cleaned up
        if [[ $exit_code -eq 124 ]]; then
            LLM_FAILURE_DETAIL="claude -p timed out after ${LLM_TIMEOUT}s"
            log ERROR "$LLM_FAILURE_DETAIL"
        else
            LLM_FAILURE_DETAIL="claude -p call failed (exit code: $exit_code)"
            log ERROR "$LLM_FAILURE_DETAIL"
        fi
        if [[ -n "$stderr_output" ]]; then
            LLM_FAILURE_DETAIL="$stderr_output"
            log ERROR "claude -p stderr: $stderr_output"
        fi
        LLM_FAILURE_KIND=$(classify_llm_failure "$LLM_FAILURE_DETAIL")
        return 1
    fi

    rm -f "$stderr_file"

    if [[ -z "$response" ]]; then
        LLM_FAILURE_DETAIL="Empty response from claude -p"
        LLM_FAILURE_KIND=$(classify_llm_failure "$LLM_FAILURE_DETAIL")
        log ERROR "$LLM_FAILURE_DETAIL"
        return 1
    fi

    LLM_RESPONSE_CONTENT="$response"
    return 0
}

process_llm_response() {
    local response="$1"

    # Strip markdown code fences if present (```json ... ``` wrapper)
    response=$(echo "$response" | sed '/^```\(json\)\{0,1\}$/d')

    # Validate JSON
    if ! echo "$response" | jq empty 2>/dev/null; then # REASON: jq parse errors are less useful than our raw response log below.
        LLM_FAILURE_DETAIL="LLM response is not valid JSON"
        LLM_FAILURE_KIND=$(classify_llm_failure "$LLM_FAILURE_DETAIL")
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

    # Skip LLM calls while cooldown is active, but keep deterministic checks running.
    local llm_backoff_remaining
    llm_backoff_remaining=$(llm_backoff_remaining_seconds)
    if (( llm_backoff_remaining > 0 )); then
        log_llm_backoff_active "$llm_backoff_remaining"
        record_cycle_state "ok" "LLM backoff active"
        log INFO "===== Cycle complete ====="
        return 0
    fi

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
    if ! call_llm "$system_prompt" "$metrics"; then
        log ERROR "LLM call failed"
        record_llm_backoff_state "${LLM_FAILURE_KIND:-error}" "${LLM_FAILURE_DETAIL:-LLM call failed}"
        record_cycle_state "failed" "${LLM_FAILURE_DETAIL:-LLM call failed}"
        return 1
    fi
    local llm_response="$LLM_RESPONSE_CONTENT"

    # Save raw response for debugging
    state_atomic_write_string "${LOG_DIR}/last_response.json" "$llm_response"

    # Process response and execute actions
    if ! process_llm_response "$llm_response"; then
        log ERROR "Failed to process LLM response"
        record_llm_backoff_state "${LLM_FAILURE_KIND:-invalid_response}" "${LLM_FAILURE_DETAIL:-LLM response processing failed}"
        record_cycle_state "failed" "${LLM_FAILURE_DETAIL:-LLM response processing failed}"
        return 1
    fi

    clear_llm_backoff_state
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
                local llm_backoff_remaining
                llm_backoff_remaining=$(llm_backoff_remaining_seconds)
                if (( llm_backoff_remaining > SLEEP_INTERVAL )); then
                    log ERROR "Cycle failed, next loop in ${SLEEP_INTERVAL}s (LLM backoff ${llm_backoff_remaining}s remaining)"
                else
                    log ERROR "Cycle failed, will retry in ${SLEEP_INTERVAL}s"
                fi
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
