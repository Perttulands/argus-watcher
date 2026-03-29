# Argus configuration
# Inject with: op inject -i argus.env.tpl -o argus.env

TELEGRAM_BOT_TOKEN={{ op://polis-city/telegram-argus/bot-token }}
TELEGRAM_CHAT_ID={{ op://polis-city/telegram-argus/chat-id }}

# Polis overrides (paths — not secrets)
ARGUS_STATE_DIR=${POLIS_ROOT:-/home/polis}/tools/argus/state
ARGUS_BEADS_WORKDIR=${POLIS_ROOT:-/home/polis}/projects
ARGUS_RELAY_ENABLED=false
ARGUS_RELAY_FALLBACK_FILE=${POLIS_ROOT:-/home/polis}/tools/argus/state/relay-fallback.jsonl
ARGUS_RELAY_SUMMARY_FALLBACK_FILE=${POLIS_ROOT:-/home/polis}/tools/argus/state/relay-summary-fallback.jsonl
ARGUS_MEMORY_DIR=${POLIS_ROOT:-/home/polis}/agents/athena/workspace/memory
ARGUS_GATEWAY_PORT=19003
