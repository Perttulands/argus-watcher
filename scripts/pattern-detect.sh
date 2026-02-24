#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ANALYSIS_SCRIPT="${ARGUS_PATTERN_ANALYSIS_SCRIPT:-$SCRIPT_DIR/pattern-analysis.sh}"
ANALYSIS_FILE="${ARGUS_PATTERN_OUTPUT_FILE:-$ROOT_DIR/state/pattern-analysis.json}"
STATE_FILE="${ARGUS_PATTERN_DETECT_STATE_FILE:-$ROOT_DIR/state/pattern-detect-state.json}"
PATTERN_LOG_FILE="${ARGUS_PATTERN_LOG_FILE:-$ROOT_DIR/state/patterns.jsonl}"
BEADS_WORKDIR="${ARGUS_BEADS_WORKDIR:-$HOME/athena/workspace}"

mkdir -p "$(dirname "$STATE_FILE")"
mkdir -p "$(dirname "$PATTERN_LOG_FILE")"

"$ANALYSIS_SCRIPT" >/dev/null

pattern_count=$(jq -r '.patterns | length' "$ANALYSIS_FILE" 2>/dev/null || echo 0) # REASON: malformed analysis output should be treated as zero patterns.
if [[ ! "$pattern_count" =~ ^[0-9]+$ ]] || (( pattern_count == 0 )); then
    echo "No patterns detected"
    exit 0
fi

signature=$(jq -c '.patterns' "$ANALYSIS_FILE" | sha256sum | awk '{print $1}')
today_utc=$(date -u +%F)

if [[ -f "$STATE_FILE" ]]; then
    last_signature=$(jq -r '.last_signature // ""' "$STATE_FILE" 2>/dev/null || echo "") # REASON: missing/corrupt state should allow detection run to continue.
    last_date=$(jq -r '.last_bead_date // ""' "$STATE_FILE" 2>/dev/null || echo "") # REASON: missing/corrupt state should allow detection run to continue.
    if [[ "$last_signature" == "$signature" ]] && [[ "$last_date" == "$today_utc" ]]; then
        echo "Patterns already reported today"
        exit 0
    fi
fi

title="[argus] pattern-analysis: recurring operational patterns"
summary_lines=$(jq -r '.patterns[] | "- [" + .severity + "] " + .summary + " Recommendation: " + .recommendation' "$ANALYSIS_FILE")
body=$(cat <<EOF
Argus pattern detection summary ($(date -u +%Y-%m-%dT%H:%M:%SZ))

Window days: $(jq -r '.window_days' "$ANALYSIS_FILE")
Total problems analyzed: $(jq -r '.total_problems' "$ANALYSIS_FILE")
Pattern count: $pattern_count

$summary_lines

Signature: $signature
EOF
)

bead_id=""
if command -v br >/dev/null 2>&1; then # REASON: bead integration is optional.
    bead_id=$(cd "$BEADS_WORKDIR" && br create "$title" \
        -d "$body" \
        --labels argus,pattern \
        --priority 2 \
        --silent 2>/dev/null || true) # REASON: pattern reporting should continue even if bead creation fails.
    bead_id=$(echo "$bead_id" | tr -d '[:space:]')
fi

jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg signature "$signature" \
    --argjson pattern_count "$pattern_count" \
    --arg bead_id "$bead_id" \
    '{ts:$ts, signature:$signature, pattern_count:$pattern_count, bead_id:(if $bead_id == "" then null else $bead_id end)}' >> "$PATTERN_LOG_FILE"

jq -n \
    --arg signature "$signature" \
    --arg date "$today_utc" \
    --arg bead_id "$bead_id" \
    '{last_signature:$signature, last_bead_date:$date, last_bead_id:(if $bead_id == "" then null else $bead_id end)}' > "$STATE_FILE"

echo "Pattern detection reported (${pattern_count} patterns)"
