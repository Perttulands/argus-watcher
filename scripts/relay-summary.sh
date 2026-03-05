#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: relay-summary.sh failed at line $LINENO" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ARGUS_RELAY_SUMMARY_ENABLED="${ARGUS_RELAY_SUMMARY_ENABLED:-true}"
ARGUS_RELAY_BIN="${ARGUS_RELAY_BIN:-$HOME/go/bin/relay}"
ARGUS_RELAY_TO="${ARGUS_RELAY_TO:-athena}"
ARGUS_RELAY_FROM="${ARGUS_RELAY_FROM:-argus}"
ARGUS_RELAY_TIMEOUT="${ARGUS_RELAY_TIMEOUT:-5}"
ARGUS_RELAY_SUMMARY_FALLBACK_FILE="${ARGUS_RELAY_SUMMARY_FALLBACK_FILE:-$ROOT_DIR/state/relay-summary-fallback.jsonl}"
ARGUS_DASHBOARD_URL="${ARGUS_DASHBOARD_URL:-}"

bool_true() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

if ! bool_true "$ARGUS_RELAY_SUMMARY_ENABLED"; then
    echo "Relay summary disabled"
    exit 0
fi

stats_file="$(mktemp)"
patterns_file="$(mktemp)"

"$SCRIPT_DIR/argus-stats.sh" "$stats_file" >/dev/null
"$SCRIPT_DIR/pattern-analysis.sh" >/dev/null
cp "${ARGUS_PATTERN_OUTPUT_FILE:-$ROOT_DIR/state/pattern-analysis.json}" "$patterns_file"

total_problems=$(jq -r '.total_problems // 0' "$stats_file")
success_rate=$(jq -r '.action_success_rate // 0' "$stats_file")
pattern_count=$(jq -r '.patterns | length' "$patterns_file")

summary_text="Argus daily summary: problems=${total_problems}, success_rate=$(printf '%.1f' "$success_rate")%, patterns=${pattern_count}"
if [[ -n "$ARGUS_DASHBOARD_URL" ]]; then
    summary_text="${summary_text}, dashboard=${ARGUS_DASHBOARD_URL}"
fi

payload=$(jq -n \
    --arg type "summary" \
    --arg source "argus" \
    --arg event "argus.daily_summary" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg text "$summary_text" \
    --arg problems_url "$ARGUS_DASHBOARD_URL" \
    --argjson stats "$(cat "$stats_file")" \
    --argjson patterns "$(cat "$patterns_file")" \
    '{
        type: $type,
        source: $source,
        event: $event,
        timestamp: $ts,
        summary: $text,
        problems_url: (if $problems_url == "" then null else $problems_url end),
        stats: $stats,
        patterns: $patterns
    }')

relay_ok=false
if [[ -x "$ARGUS_RELAY_BIN" ]]; then
    if timeout "$ARGUS_RELAY_TIMEOUT" "$ARGUS_RELAY_BIN" send "$ARGUS_RELAY_TO" "$payload" \
        --agent "$ARGUS_RELAY_FROM" \
        --priority medium \
        --tag "argus,summary,daily" >/dev/null 2>&1; then
        relay_ok=true
    fi
fi

if [[ "$relay_ok" != "true" ]]; then
    mkdir -p "$(dirname "$ARGUS_RELAY_SUMMARY_FALLBACK_FILE")"
    printf '%s\n' "$payload" >> "$ARGUS_RELAY_SUMMARY_FALLBACK_FILE"

    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        tg_payload=$(jq -n --arg chat_id "$TELEGRAM_CHAT_ID" --arg text "$summary_text" '{chat_id:$chat_id,text:$text,disable_web_page_preview:true}')
        curl -s -m 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$tg_payload" >/dev/null 2>&1 || true # REASON: Telegram fallback is best-effort and must never fail the summary run.
    fi
fi

echo "$summary_text"
