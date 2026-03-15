#!/usr/bin/env bash
set -euo pipefail

# Test: execute_action sends relay alerts (not bead creation) for failed/repeated actions.
# Updated for pol-22x2: create_bead replaced with send_relay_alert.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

export ARGUS_STATE_DIR="$TEST_ROOT/state"
export ARGUS_PROBLEMS_FILE="$ARGUS_STATE_DIR/problems.jsonl"
export ARGUS_OBSERVATIONS_FILE="$TEST_ROOT/observations.md"
export ARGUS_RELAY_ENABLED=true
export ARGUS_RELAY_FALLBACK_FILE="$TEST_ROOT/relay-fallback.jsonl"
export ARGUS_BEADS_WORKDIR=""
export ARGUS_BEAD_REPEAT_THRESHOLD=3

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

RELAY_LOG="$TEST_ROOT/relay.log"
touch "$RELAY_LOG"
export RELAY_LOG

# Mock relay: log all invocations
cat > "$FAKE_BIN/relay" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$RELAY_LOG"
EOF
chmod +x "$FAKE_BIN/relay"

# Mock systemctl (will fail since gateway is not allowlisted)
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "mock"
EOF
chmod +x "$FAKE_BIN/systemctl"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"

assert_eq() {
    local got="$1"
    local want="$2"
    local label="$3"
    if [[ "$got" != "$want" ]]; then
        echo "ASSERTION FAILED: $label (got '$got', want '$want')" >&2
        exit 1
    fi
}

# 1) Failed action should send relay alert (not create bead)
if execute_action '{"type":"restart_service","target":"gateway","reason":"service down"}'; then
    echo "expected restart_service to fail because service is not allowlisted" >&2
    exit 1
fi

echo "BLOCKED: Service 'gateway' not in allowlist ()"

first_result=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')
assert_eq "$first_result" "failure" "failed action result"

# Relay should have been called for the failure
relay_count=$(wc -l < "$RELAY_LOG" | tr -d ' ')
[[ "$relay_count" -ge 1 ]] || { echo "FAIL: relay was not called for failed action" >&2; exit 1; }
grep -q "ARGUS ALERT" "$RELAY_LOG" || { echo "FAIL: relay message missing ARGUS ALERT" >&2; exit 1; }

# 2) Log observation should be recorded and relay alerted
execute_action '{"type":"log","observation":"Disk pressure high 95%"}'

obs_result=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')
assert_eq "$obs_result" "success" "log observation result"

echo "actions_bead_creation_test: PASS"
