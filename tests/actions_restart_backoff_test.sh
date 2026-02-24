#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

export ARGUS_STATE_DIR="$TEST_ROOT/state"
export ARGUS_PROBLEMS_FILE="$ARGUS_STATE_DIR/problems.jsonl"
export ARGUS_DEDUP_FILE="$ARGUS_STATE_DIR/dedup.json"
export ARGUS_OBSERVATIONS_FILE="$TEST_ROOT/observations.md"
export ARGUS_RELAY_ENABLED=false
export ARGUS_RELAY_FALLBACK_FILE="$TEST_ROOT/relay-fallback.jsonl"
export ARGUS_BEADS_WORKDIR="$TEST_ROOT/workspace"
mkdir -p "$ARGUS_BEADS_WORKDIR"

export ARGUS_RESTART_BACKOFF_FILE="$TEST_ROOT/restart-backoff.json"
export ARGUS_RESTART_BACKOFF_SECOND_DELAY=1
export ARGUS_RESTART_BACKOFF_THIRD_DELAY=2
export ARGUS_RESTART_COOLDOWN_SECONDS=5

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
export FAKE_SYSTEMCTL_LOG="$TEST_ROOT/systemctl-restart.log"
touch "$FAKE_SYSTEMCTL_LOG"

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
unit="${2:-}"
case "$cmd" in
  is-active)
    echo "inactive"
    ;;
  restart)
    echo "$unit" >> "$FAKE_SYSTEMCTL_LOG"
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/systemctl"

cat > "$FAKE_BIN/br" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi
case "$cmd" in
  list) echo "[]" ;;
  create) echo "athena-backoff" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/br"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"
ALLOWED_SERVICES=("gateway")

# Attempt 1: failure
if execute_action '{"type":"restart_service","target":"gateway","reason":"gateway down"}'; then
    echo "attempt1 expected failure" >&2
    exit 1
fi
[[ "$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')" == "failure" ]] || { echo "attempt1 result mismatch" >&2; exit 1; }

# Attempt 2 too early: skipped
execute_action '{"type":"restart_service","target":"gateway","reason":"gateway down"}'
[[ "$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')" == "skipped" ]] || { echo "attempt2 expected skipped" >&2; exit 1; }

sleep 1
# Attempt 2 after wait: failure
if execute_action '{"type":"restart_service","target":"gateway","reason":"gateway down"}'; then
    echo "attempt2 execution expected failure" >&2
    exit 1
fi

# Attempt 3 too early: skipped
execute_action '{"type":"restart_service","target":"gateway","reason":"gateway down"}'
[[ "$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')" == "skipped" ]] || { echo "attempt3 expected skipped" >&2; exit 1; }

sleep 2
# Attempt 3 after wait: failure
if execute_action '{"type":"restart_service","target":"gateway","reason":"gateway down"}'; then
    echo "attempt3 execution expected failure" >&2
    exit 1
fi

# Attempt 4: loop detection + cooldown
if execute_action '{"type":"restart_service","target":"gateway","reason":"gateway down"}'; then
    echo "attempt4 expected loop-detected failure" >&2
    exit 1
fi

last_record="$(tail -n1 "$ARGUS_PROBLEMS_FILE")"
[[ "$(echo "$last_record" | jq -r '.action_result')" == "failure" ]] || { echo "attempt4 expected failure result" >&2; exit 1; }
[[ "$(echo "$last_record" | jq -r '.description')" == *"restart_backoff=loop-detected"* ]] || { echo "loop detection marker missing" >&2; exit 1; }

restart_invocations=$(wc -l < "$FAKE_SYSTEMCTL_LOG")
[[ "$restart_invocations" -eq 3 ]] || { echo "expected exactly 3 restart invocations, got $restart_invocations" >&2; exit 1; }

cooldown_until=$(jq -r '.services.gateway.cooldown_until // 0' "$ARGUS_RESTART_BACKOFF_FILE")
now=$(date -u +%s)
if [[ ! "$cooldown_until" =~ ^[0-9]+$ ]] || (( cooldown_until <= now )); then
    echo "cooldown timestamp not set correctly" >&2
    exit 1
fi

echo "actions_restart_backoff_test: PASS"
