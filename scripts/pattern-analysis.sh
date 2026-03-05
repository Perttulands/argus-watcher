#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: pattern-analysis.sh failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROBLEMS_FILE="${ARGUS_PROBLEMS_FILE:-$ROOT_DIR/state/problems.jsonl}"
OUTPUT_FILE="${ARGUS_PATTERN_OUTPUT_FILE:-$ROOT_DIR/state/pattern-analysis.json}"
WINDOW_DAYS="${ARGUS_PATTERN_WINDOW_DAYS:-7}"

mkdir -p "$(dirname "$OUTPUT_FILE")"

if [[ ! -f "$PROBLEMS_FILE" ]]; then
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson days "$WINDOW_DAYS" \
        '{generated_at:$ts, window_days:$days, total_problems:0, patterns:[]}' > "$OUTPUT_FILE"
    echo "$OUTPUT_FILE"
    exit 0
fi

cutoff_epoch=$(( $(date -u +%s) - (WINDOW_DAYS * 86400) ))

jq -s \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson cutoff "$cutoff_epoch" \
    --argjson days "$WINDOW_DAYS" '
    def epoch: (.ts | fromdateiso8601? // 0);
    def recent: map(select(epoch >= $cutoff));
    (recent) as $r
    | ($r
        | map(select(.type == "service" and (.action_taken | startswith("restart_service"))))
        | group_by(.ts[0:10])
        | map(select(length >= 3)
            | {
                id: ("service-restarts-" + .[0].ts[0:10]),
                type: "service_restart_spike",
                severity: "warning",
                summary: ("Service restarts spiked on " + .[0].ts[0:10] + " (" + (length|tostring) + " restarts)."),
                recommendation: "Investigate root causes before retrying restarts automatically.",
                data: {day: .[0].ts[0:10], count: length}
            })
      ) as $service_patterns
    | ($r | map(select(.type == "disk"))) as $disk_events
    | (if (($disk_events | length) >= 3 and (($disk_events | map(.ts[0:10]) | unique | length) >= 2)) then
        [{
            id: "disk-pressure-trend",
            type: "disk_pressure_trend",
            severity: "warning",
            summary: ("Disk problems occurred " + (($disk_events | length)|tostring) + " times over " + (($disk_events | map(.ts[0:10]) | unique | length)|tostring) + " day(s)."),
            recommendation: "Review disk growth sources and expand cleanup/retention controls.",
            data: {count: ($disk_events | length)}
        }]
      else [] end) as $disk_patterns
    | ($r
        | map(select(.type == "memory"))
        | map(. + {hog: (try (.description | capture("hog_process=(?<name>[^,; ]+)").name) catch "unknown")})
        | map(select(.hog != "unknown"))
        | group_by(.hog)
        | map(select(length >= 3)
            | {
                id: ("memory-hog-" + .[0].hog),
                type: "memory_hog_recurring",
                severity: "warning",
                summary: ("Recurring memory pressure linked to process " + .[0].hog + " (" + (length|tostring) + " events)."),
                recommendation: "Inspect this process for leaks or runaway workloads.",
                data: {process: .[0].hog, count: length}
            })
      ) as $memory_patterns
    | ($r
        | group_by(.ts[11:13])
        | map(select(length >= 3)
            | {
                id: ("time-correlation-" + .[0].ts[11:13]),
                type: "time_correlation",
                severity: "info",
                summary: ("Problems cluster around UTC hour " + .[0].ts[11:13] + ":00 (" + (length|tostring) + " events)."),
                recommendation: "Check cron/jobs or deployment activity around this hour.",
                data: {hour_utc: .[0].ts[11:13], count: length}
            })
      ) as $time_patterns
    | {
        generated_at: $ts,
        window_days: $days,
        total_problems: ($r | length),
        patterns: ($service_patterns + $disk_patterns + $memory_patterns + $time_patterns)
      }
' "$PROBLEMS_FILE" > "$OUTPUT_FILE"

echo "$OUTPUT_FILE"
