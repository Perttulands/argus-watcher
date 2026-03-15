#!/usr/bin/env bash
set -euo pipefail

# Tests for memory alert relay notifications and close_memory_bead.
# Updated for pol-22x2: create_bead replaced with send_relay_alert.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

export ARGUS_STATE_DIR="$TEST_ROOT/state"
export ARGUS_PROBLEMS_FILE="$ARGUS_STATE_DIR/problems.jsonl"
export ARGUS_DEDUP_FILE="$ARGUS_STATE_DIR/dedup.json"
export ARGUS_DEDUP_WINDOW=3600
export ARGUS_OBSERVATIONS_FILE="$TEST_ROOT/observations.md"
export ARGUS_RELAY_ENABLED=true
export ARGUS_RELAY_FALLBACK_FILE="$TEST_ROOT/relay-fallback.jsonl"
export ARGUS_BEADS_WORKDIR="$TEST_ROOT/workspace"
export ARGUS_BEAD_REPEAT_THRESHOLD=3
export ARGUS_BOOT_GRACE_SECONDS=120
export ARGUS_RESTART_BACKOFF_FILE="$TEST_ROOT/state/restart-backoff.json"
mkdir -p "$ARGUS_BEADS_WORKDIR"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
export FAKE_BR_LOG="$TEST_ROOT/br.log"
export FAKE_BR_SEARCH_JSON="$TEST_ROOT/search.json"
export FAKE_BR_CLOSE_LOG="$TEST_ROOT/close.log"
RELAY_LOG="$TEST_ROOT/relay.log"
touch "$FAKE_BR_LOG" "$FAKE_BR_CLOSE_LOG" "$RELAY_LOG"
echo "[]" > "$FAKE_BR_SEARCH_JSON"
export RELAY_LOG

# Mock relay
cat > "$FAKE_BIN/relay" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$RELAY_LOG"
EOF
chmod +x "$FAKE_BIN/relay"

# Mock curl for telegram
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true}'
EOF
chmod +x "$FAKE_BIN/curl"

# Fake br that supports search and close
cat > "$FAKE_BIN/br" <<'BREOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_BR_LOG"
cmd="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi
case "$cmd" in
  search)
    cat "$FAKE_BR_SEARCH_JSON"
    ;;
  close)
    echo "$*" >> "$FAKE_BR_CLOSE_LOG"
    echo "closed"
    ;;
  *)
    echo "unsupported command: $cmd" >&2
    exit 1
    ;;
esac
BREOF
chmod +x "$FAKE_BIN/br"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"

assert_eq() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" != "$want" ]]; then
        echo "ASSERTION FAILED: $label (got '$got', want '$want')" >&2
        exit 1
    fi
}

pass() {
    echo "  PASS: $1"
}

# ── Test 1: Memory alert sends relay notification ──

echo "=== Test 1: Memory alert sends relay ==="

execute_action '{"type":"alert","message":"Memory usage critical at 92% (14800MB/16000MB) — top process: node (PID 1234, running 2h)"}' || true # REASON: test intentionally continues after alert path.

relay_count=$(wc -l < "$RELAY_LOG" | tr -d ' ')
[[ "$relay_count" -ge 1 ]] || { echo "FAIL: relay not called for memory alert" >&2; exit 1; }
grep -q "ARGUS ALERT" "$RELAY_LOG" || { echo "FAIL: relay message missing ARGUS ALERT" >&2; exit 1; }
pass "memory alert sends relay notification"

# ── Test 2: close_memory_bead closes open memory bead ──

echo "=== Test 2: close_memory_bead ==="

cat > "$FAKE_BR_SEARCH_JSON" <<'EOF'
[{"id":"mem-bead-to-close","title":"[argus] memory: Memory usage critical"}]
EOF
> "$FAKE_BR_CLOSE_LOG"

closed_id=$(close_memory_bead)
assert_eq "$closed_id" "mem-bead-to-close" "close_memory_bead returns closed bead id"

close_called=$(grep -c "mem-bead-to-close" "$FAKE_BR_CLOSE_LOG" 2>/dev/null || echo 0) # REASON: missing close log should count as zero.
assert_eq "$close_called" "1" "br close called for memory bead"
pass "close_memory_bead closes open bead"

# ── Test 3: close_memory_bead is no-op when no open bead ──

echo "=== Test 3: close_memory_bead no-op ==="

echo "[]" > "$FAKE_BR_SEARCH_JSON"
> "$FAKE_BR_CLOSE_LOG"

closed_id=$(close_memory_bead)
assert_eq "$closed_id" "" "close_memory_bead returns empty when no open bead"

close_called=$(wc -l < "$FAKE_BR_CLOSE_LOG")
assert_eq "$close_called" "0" "br close not called when no memory bead"
pass "close_memory_bead no-op when no open bead"

echo ""
echo "actions_memory_bead_test: PASS"
