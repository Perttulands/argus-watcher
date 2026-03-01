#!/usr/bin/env bash
# notify-telegram.sh — lightweight Telegram sender for Argus lifecycle events
# Usage: ./notify-telegram.sh "message text"
# Sources argus.env for bot token and chat ID.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/argus.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

MESSAGE="${1:-}"
if [[ -z "$MESSAGE" ]]; then
    echo "Usage: $0 <message>" >&2
    exit 1
fi

# Prepend hostname
HOSTNAME_TAG=$(hostname -f 2>/dev/null || hostname)
MESSAGE="[${HOSTNAME_TAG}] ${MESSAGE}"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "WARNING: Telegram credentials not configured" >&2
    exit 1
fi

PAYLOAD=$(jq -n \
    --arg chat_id "$TELEGRAM_CHAT_ID" \
    --arg text "$MESSAGE" \
    '{chat_id: $chat_id, text: $text, disable_web_page_preview: true}')

# Best-effort send with short timeout (system may be shutting down)
HTTP_CODE=$(curl -s -m 10 -w '%{http_code}' -o /dev/null -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null) || true

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "Telegram notification sent"
else
    echo "Telegram send failed (HTTP $HTTP_CODE)" >&2
fi
