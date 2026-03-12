#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: relay-drain failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/scripts/lib/state.sh"

ARGUS_RELAY_BIN="${ARGUS_RELAY_BIN:-$HOME/go/bin/relay}"
ARGUS_RELAY_TO="${ARGUS_RELAY_TO:-athena}"
ARGUS_RELAY_FROM="${ARGUS_RELAY_FROM:-argus}"
ARGUS_RELAY_TIMEOUT="${ARGUS_RELAY_TIMEOUT:-5}"
ARGUS_RELAY_DRAIN_MAX_ITEMS="${ARGUS_RELAY_DRAIN_MAX_ITEMS:-100}"
ARGUS_RELAY_FALLBACK_FILE="${ARGUS_RELAY_FALLBACK_FILE:-$ROOT_DIR/state/relay-fallback.jsonl}"
ARGUS_RELAY_OBSERVATIONS_FALLBACK_FILE="${ARGUS_RELAY_OBSERVATIONS_FALLBACK_FILE:-$ROOT_DIR/state/relay-observations-fallback.jsonl}"
ARGUS_RELAY_SUMMARY_FALLBACK_FILE="${ARGUS_RELAY_SUMMARY_FALLBACK_FILE:-$ROOT_DIR/state/relay-summary-fallback.jsonl}"

if [[ ! "$ARGUS_RELAY_TIMEOUT" =~ ^[0-9]+$ ]] || (( ARGUS_RELAY_TIMEOUT < 1 || ARGUS_RELAY_TIMEOUT > 300 )); then
    echo "ERROR: ARGUS_RELAY_TIMEOUT must be an integer in range 1-300" >&2
    exit 1
fi

if [[ ! "$ARGUS_RELAY_DRAIN_MAX_ITEMS" =~ ^[0-9]+$ ]] || (( ARGUS_RELAY_DRAIN_MAX_ITEMS < 1 || ARGUS_RELAY_DRAIN_MAX_ITEMS > 10000 )); then
    echo "ERROR: ARGUS_RELAY_DRAIN_MAX_ITEMS must be an integer in range 1-10000" >&2
    exit 1
fi

relay_send_payload() {
    local payload="$1"
    local event priority tag
    event=$(jq -r '.event // ""' <<< "$payload" 2>/dev/null || echo "")

    priority="high"
    tag="argus,problem,alert"
    case "$event" in
        argus.observations.snapshot)
            priority="low"
            tag="argus,observations,snapshot"
            ;;
        argus.daily_summary)
            priority="medium"
            tag="argus,summary,daily"
            ;;
        argus.problem)
            priority="high"
            tag="argus,problem,alert"
            ;;
    esac

    [[ -x "$ARGUS_RELAY_BIN" ]] || return 1
    timeout "$ARGUS_RELAY_TIMEOUT" "$ARGUS_RELAY_BIN" send "$ARGUS_RELAY_TO" "$payload" \
        --agent "$ARGUS_RELAY_FROM" \
        --priority "$priority" \
        --tag "$tag" >/dev/null 2>&1
}

drain_file() {
    local file="$1"
    local name
    name=$(basename "$file")

    if [[ ! -f "$file" ]]; then
        echo "$name: drained=0 failed=0 pending=0"
        return 0
    fi

    local lock_dir
    lock_dir=$(state_acquire_lock "$file") || return 1

    local input_copy pending_copy
    input_copy=$(mktemp "${file}.drain-input.XXXXXX")
    pending_copy=$(mktemp "${file}.drain-pending.XXXXXX")
    cp "$file" "$input_copy"
    : > "$pending_copy"

    local drained=0 failed=0 pending=0 processed=0
    while IFS= read -r payload || [[ -n "$payload" ]]; do
        [[ -n "$payload" ]] || continue
        if (( processed >= ARGUS_RELAY_DRAIN_MAX_ITEMS )); then
            printf '%s\n' "$payload" >> "$pending_copy"
            pending=$((pending + 1))
            continue
        fi

        if relay_send_payload "$payload"; then
            drained=$((drained + 1))
        else
            printf '%s\n' "$payload" >> "$pending_copy"
            failed=$((failed + 1))
            pending=$((pending + 1))
        fi
        processed=$((processed + 1))
    done < "$input_copy"

    if (( pending > 0 )); then
        state_atomic_write_from_stdin "$file" < "$pending_copy"
    else
        rm -f "$file"
    fi

    rm -f "$input_copy" "$pending_copy"
    state_release_lock "$lock_dir"
    echo "$name: drained=$drained failed=$failed pending=$pending"
}

drain_file "$ARGUS_RELAY_FALLBACK_FILE"
drain_file "$ARGUS_RELAY_OBSERVATIONS_FALLBACK_FILE"
drain_file "$ARGUS_RELAY_SUMMARY_FALLBACK_FILE"
