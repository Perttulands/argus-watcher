#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: argus-stats.sh failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROBLEMS_FILE="${ARGUS_PROBLEMS_FILE:-$ROOT_DIR/state/problems.jsonl}"
WINDOW_DAYS="${ARGUS_STATS_WINDOW_DAYS:-7}"
OUTPUT_FILE="${1:-}"

cutoff_epoch=$(( $(date -u +%s) - (WINDOW_DAYS * 86400) ))

if [[ ! -f "$PROBLEMS_FILE" ]]; then
    payload=$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson days "$WINDOW_DAYS" '
        {
            generated_at: $ts,
            window_days: $days,
            total_problems: 0,
            by_type: {},
            by_severity: {},
            action_results: {},
            action_success_rate: 0,
            hourly: [],
            daily: []
        }')
    if [[ -n "$OUTPUT_FILE" ]]; then
        printf '%s\n' "$payload" > "$OUTPUT_FILE"
    else
        printf '%s\n' "$payload"
    fi
    exit 0
fi

payload=$(jq -s --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson days "$WINDOW_DAYS" --argjson cutoff "$cutoff_epoch" '
    def recent: map(select((.ts | fromdateiso8601? // 0) >= $cutoff));
    def by_field($field):
        reduce .[] as $item ({}; .[$item[$field]] = ((.[$item[$field]] // 0) + 1));

    (recent) as $r
    | ($r | length) as $total
    | ($r | map(select(.action_result == "success")) | length) as $success
    | {
        generated_at: $ts,
        window_days: $days,
        total_problems: $total,
        by_type: ($r | by_field("type")),
        by_severity: ($r | by_field("severity")),
        action_results: ($r | by_field("action_result")),
        action_success_rate: (if $total > 0 then (($success / $total) * 100) else 0 end),
        hourly: (
            $r
            | group_by(.ts[0:13])
            | map({bucket: (.[0].ts[0:13] + ":00Z"), count: length})
            | sort_by(.bucket)
        ),
        daily: (
            $r
            | group_by(.ts[0:10])
            | map({bucket: .[0].ts[0:10], count: length})
            | sort_by(.bucket)
        )
    }
' "$PROBLEMS_FILE")

if [[ -n "$OUTPUT_FILE" ]]; then
    printf '%s\n' "$payload" > "$OUTPUT_FILE"
else
    printf '%s\n' "$payload"
fi
