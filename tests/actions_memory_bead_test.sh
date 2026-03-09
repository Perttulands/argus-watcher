#!/usr/bin/env bash
set -euo pipefail

# Tests for memory alert bead dedup via label search.
# Mirrors the test harness pattern from actions_service_bead_test.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

export ARGUS_STATE_DIR="$TEST_ROOT/state"
export ARGUS_PROBLEMS_FILE="$ARGUS_STATE_DIR/problems.jsonl"
export ARGUS_DEDUP_FILE="$ARGUS_STATE_DIR/dedup.json"
export ARGUS_DEDUP_WINDOW=3600
export ARGUS_OBSERVATIONS_FILE="$TEST_ROOT/observations.md"
export ARGUS_RELAY_ENABLED=false
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
export FAKE_BR_OPEN_JSON="$TEST_ROOT/open.json"
export FAKE_BR_CREATE_ID="mem-bead-1"
export FAKE_BR_CLOSE_LOG="$TEST_ROOT/close.log"
touch "$FAKE_BR_LOG" "$FAKE_BR_CLOSE_LOG"
echo "[]" > "$FAKE_BR_SEARCH_JSON"
echo "[]" > "$FAKE_BR_OPEN_JSON"

# Fake br that supports list, search, create, close
cat > "$FAKE_BIN/br" <<'BREOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_BR_LOG"
cmd="${1:-}"
if [[ $# -gt 0 ]]; then shift; fi
case "$cmd" in
  list)
    cat "$FAKE_BR_OPEN_JSON"
    ;;
  search)
    cat "$FAKE_BR_SEARCH_JSON"
    ;;
  create)
    echo "${FAKE_BR_CREATE_ID}"
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

# ── Test 1: DEDUP — second memory alert reuses existing bead ──

echo "=== Test 1: Memory bead dedup ==="

# First alert — no existing bead, should create
execute_action '{"type":"alert","message":"Memory usage critical at 92% (14800MB/16000MB) — top process: node (PID 1234, running 2h)"}' || true # REASON: test intentionally continues after alert path.
create_count=$(awk '/^create /{count++} END{print count+0}' "$FAKE_BR_LOG")
assert_eq "$create_count" "1" "first memory alert creates one bead"
pass "first memory alert creates bead"

# Now simulate an existing open memory bead in search results
cat > "$FAKE_BR_SEARCH_JSON" <<'EOF'
[{"id":"existing-mem-bead","title":"[argus] memory: Memory usage critical"}]
EOF

# Second alert with different stats — should find existing bead via label search, skip create
execute_action '{"type":"alert","message":"Memory usage critical at 93% (14900MB/16000MB) — top process: node (PID 1234, running 2h5m)"}' || true # REASON: test intentionally continues after alert path.
create_count_after=$(awk '/^create /{count++} END{print count+0}' "$FAKE_BR_LOG")
assert_eq "$create_count_after" "1" "second memory alert reuses existing bead (no extra create)"

last_bead_id=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.bead_id')
assert_eq "$last_bead_id" "existing-mem-bead" "reused bead id matches search result"
pass "second memory alert reuses existing bead"

# ── Test 2: Memory labels set correctly on creation ──

echo "=== Test 2: Memory labels in br create ==="

# Check that the first create call includes memory-specific labels
if grep -q "type:memory" "$FAKE_BR_LOG" && grep -q "status:active" "$FAKE_BR_LOG"; then
    pass "create includes type:memory and status:active labels"
else
    echo "ASSERTION FAILED: expected memory labels in br log" >&2
    echo "Full br log:" >&2
    cat "$FAKE_BR_LOG" >&2
    exit 1
fi

# ── Test 3: close_memory_bead closes open memory bead ──

echo "=== Test 3: close_memory_bead ==="

cat > "$FAKE_BR_SEARCH_JSON" <<'EOF'
[{"id":"mem-bead-to-close","title":"[argus] memory: Memory usage critical"}]
EOF
> "$FAKE_BR_CLOSE_LOG"

closed_id=$(close_memory_bead)
assert_eq "$closed_id" "mem-bead-to-close" "close_memory_bead returns closed bead id"

close_called=$(grep -c "mem-bead-to-close" "$FAKE_BR_CLOSE_LOG" 2>/dev/null || echo 0) # REASON: missing close log should count as zero.
assert_eq "$close_called" "1" "br close called for memory bead"
pass "close_memory_bead closes open bead"

# ── Test 4: close_memory_bead is no-op when no open bead ──

echo "=== Test 4: close_memory_bead no-op ==="

echo "[]" > "$FAKE_BR_SEARCH_JSON"
> "$FAKE_BR_CLOSE_LOG"

closed_id=$(close_memory_bead)
assert_eq "$closed_id" "" "close_memory_bead returns empty when no open bead"

close_called=$(wc -l < "$FAKE_BR_CLOSE_LOG")
assert_eq "$close_called" "0" "br close not called when no memory bead"
pass "close_memory_bead no-op when no open bead"

echo ""
echo "actions_memory_bead_test: PASS"
