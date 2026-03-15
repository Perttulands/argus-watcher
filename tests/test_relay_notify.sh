#!/usr/bin/env bash
set -euo pipefail

# Test: actions.sh uses relay send (not create_bead) for alert escalation.
# Validates pol-22x2: create_bead replaced with relay send athena.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

RELAY_LOG="$TEST_ROOT/relay.log"
touch "$RELAY_LOG"

# Mock relay: log all invocations
cat > "$FAKE_BIN/relay" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$RELAY_LOG"
MOCK
chmod +x "$FAKE_BIN/relay"
export RELAY_LOG

# Mock br: no-op (should not be called for bead creation)
BR_LOG="$TEST_ROOT/br.log"
touch "$BR_LOG"
cat > "$FAKE_BIN/br" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$BR_LOG"
echo "mock-bead-id"
MOCK
chmod +x "$FAKE_BIN/br"
export BR_LOG

# Mock curl (for telegram)
cat > "$FAKE_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"ok":true}'
MOCK
chmod +x "$FAKE_BIN/curl"

# Mock systemctl
cat > "$FAKE_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
echo "mock"
MOCK
chmod +x "$FAKE_BIN/systemctl"

export PATH="$FAKE_BIN:$PATH"

# --- Test 1: send_relay_alert calls relay, not create_bead ---
echo "=== Test 1: send_relay_alert calls relay ==="

STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STATE_DIR"

# Source actions.sh in a subshell to test send_relay_alert
(
    export ARGUS_STATE_DIR="$STATE_DIR"
    export ARGUS_RELAY_ENABLED="true"
    export ARGUS_RELAY_BIN="$FAKE_BIN/relay"
    export ARGUS_RELAY_TO="athena"
    export ARGUS_RELAY_FROM="argus"
    export ARGUS_RELAY_TIMEOUT="5"
    export ARGUS_BEADS_WORKDIR=""
    export ARGUS_PROBLEMS_FILE="$STATE_DIR/problems.jsonl"
    export ARGUS_INCIDENTS_FILE="$STATE_DIR/incidents.jsonl"
    source "$ROOT/actions.sh"
    send_relay_alert "process" "warning" "test alert: high CPU" "log:observation" "success" "test-key-123" "3"
)

if [[ -s "$RELAY_LOG" ]]; then
    echo "PASS: relay was invoked"
else
    echo "FAIL: relay was NOT invoked" >&2
    exit 1
fi

if grep -q "athena" "$RELAY_LOG"; then
    echo "PASS: relay sent to athena"
else
    echo "FAIL: relay did not target athena" >&2
    exit 1
fi

if grep -q "ARGUS ALERT" "$RELAY_LOG"; then
    echo "PASS: relay message contains ARGUS ALERT"
else
    echo "FAIL: relay message missing ARGUS ALERT prefix" >&2
    exit 1
fi

# --- Test 2: create_bead function is removed (dead code cleanup) ---
echo "=== Test 2: create_bead is not called in action dispatch ==="

# Verify create_bead is not invoked anywhere in the action dispatch path
# (it should only exist as a dead function definition, or not at all)
if grep '^[^#]*create_bead ' "$ROOT/actions.sh" | grep -qv '^create_bead()'; then
    echo "FAIL: create_bead is still called (not just defined)" >&2
    exit 1
fi
echo "PASS: create_bead is not called in action dispatch"

# --- Test 3: ARGUS_BEADS_WORKDIR has no hardcoded default ---
echo "=== Test 3: ARGUS_BEADS_WORKDIR has no hardcoded default ==="

if grep -q 'ARGUS_BEADS_WORKDIR.*athena' "$ROOT/actions.sh"; then
    echo "FAIL: ARGUS_BEADS_WORKDIR still references athena workspace" >&2
    exit 1
fi

if grep -q 'ARGUS_BEADS_WORKDIR.*~/\|ARGUS_BEADS_WORKDIR.*\$HOME' "$ROOT/actions.sh"; then
    echo "FAIL: ARGUS_BEADS_WORKDIR has a hardcoded path fallback" >&2
    exit 1
fi
echo "PASS: ARGUS_BEADS_WORKDIR is env-only (no hardcoded fallback)"

echo ""
echo "test_relay_notify: ALL PASS"
