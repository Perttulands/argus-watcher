#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: relay-observations failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/scripts/lib/state.sh"

ARGUS_OBSERVATIONS_FILE="${ARGUS_OBSERVATIONS_FILE:-$ROOT_DIR/state/observations.md}"
ARGUS_RELAY_BIN="${ARGUS_RELAY_BIN:-$HOME/go/bin/relay}"
ARGUS_RELAY_TO="${ARGUS_RELAY_TO:-athena}"
ARGUS_RELAY_FROM="${ARGUS_RELAY_FROM:-argus}"
ARGUS_RELAY_TIMEOUT="${ARGUS_RELAY_TIMEOUT:-5}"
ARGUS_RELAY_OBSERVATIONS_FALLBACK_FILE="${ARGUS_RELAY_OBSERVATIONS_FALLBACK_FILE:-$ROOT_DIR/state/relay-observations-fallback.jsonl}"
ARGUS_OBSERVATIONS_LINES="${ARGUS_OBSERVATIONS_LINES:-50}"
ARGUS_OBSERVATIONS_MAX_BYTES="${ARGUS_OBSERVATIONS_MAX_BYTES:-12000}"

if [[ ! "$ARGUS_RELAY_TIMEOUT" =~ ^[0-9]+$ ]] || (( ARGUS_RELAY_TIMEOUT < 1 || ARGUS_RELAY_TIMEOUT > 300 )); then
    echo "ERROR: ARGUS_RELAY_TIMEOUT must be an integer in range 1-300" >&2
    exit 1
fi

if [[ ! "$ARGUS_OBSERVATIONS_LINES" =~ ^[0-9]+$ ]] || (( ARGUS_OBSERVATIONS_LINES < 1 || ARGUS_OBSERVATIONS_LINES > 500 )); then
    echo "ERROR: ARGUS_OBSERVATIONS_LINES must be an integer in range 1-500" >&2
    exit 1
fi

if [[ ! "$ARGUS_OBSERVATIONS_MAX_BYTES" =~ ^[0-9]+$ ]] || (( ARGUS_OBSERVATIONS_MAX_BYTES < 256 || ARGUS_OBSERVATIONS_MAX_BYTES > 200000 )); then
    echo "ERROR: ARGUS_OBSERVATIONS_MAX_BYTES must be an integer in range 256-200000" >&2
    exit 1
fi

observations_text=""
trimmed=false
total_entries=0
file_size_bytes=0

if [[ -f "$ARGUS_OBSERVATIONS_FILE" ]]; then
    if observations_text_out=$(tail -n "$ARGUS_OBSERVATIONS_LINES" "$ARGUS_OBSERVATIONS_FILE"); then
        observations_text="$observations_text_out"
    else
        observations_text=""
    fi

    if total_entries_out=$(grep -cE '^- \*\*\[[^]]+\]\*\* ' "$ARGUS_OBSERVATIONS_FILE"); then
        total_entries="$total_entries_out"
    else
        total_entries=0
    fi

    if file_size_out=$(wc -c < "$ARGUS_OBSERVATIONS_FILE"); then
        file_size_bytes="$file_size_out"
    else
        file_size_bytes=0
    fi
fi

if (( ${#observations_text} > ARGUS_OBSERVATIONS_MAX_BYTES )); then
    observations_text="${observations_text: -ARGUS_OBSERVATIONS_MAX_BYTES}"
    trimmed=true
fi

payload=$(jq -n \
    --arg type "observation_snapshot" \
    --arg source "argus" \
    --arg event "argus.observations.snapshot" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg file "$ARGUS_OBSERVATIONS_FILE" \
    --arg observations "$observations_text" \
    --argjson line_window "$ARGUS_OBSERVATIONS_LINES" \
    --argjson total_entries "$total_entries" \
    --argjson file_size_bytes "$file_size_bytes" \
    --argjson trimmed "$trimmed" \
    '{
        type: $type,
        source: $source,
        event: $event,
        timestamp: $ts,
        line_window: $line_window,
        total_entries: $total_entries,
        file_size_bytes: $file_size_bytes,
        observations_file: $file,
        trimmed: $trimmed,
        observations_markdown: $observations
    }')

relay_ok=false
if [[ -x "$ARGUS_RELAY_BIN" ]]; then
    if timeout "$ARGUS_RELAY_TIMEOUT" "$ARGUS_RELAY_BIN" send "$ARGUS_RELAY_TO" "$payload" \
        --agent "$ARGUS_RELAY_FROM" \
        --priority low \
        --tag "argus,observations,snapshot" >/dev/null 2>&1; then
        relay_ok=true
    fi
fi

if [[ "$relay_ok" != "true" ]]; then
    state_atomic_append_line "$ARGUS_RELAY_OBSERVATIONS_FALLBACK_FILE" "$payload"
fi

delivery="relay"
[[ "$relay_ok" == "true" ]] || delivery="fallback"
echo "Argus observations snapshot: entries=${total_entries}, window=${ARGUS_OBSERVATIONS_LINES}, delivery=${delivery}"
