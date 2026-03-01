#!/usr/bin/env bash
set -euo pipefail

# Tests for service-down bead dedup, auto-resolve, and boot grace.
# Mirrors the test harness pattern from actions_bead_creation_test.sh.

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
export FAKE_BR_CREATE_ID="svc-bead-1"
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

# Fake systemctl — always fails restart (service not found) but allows is-active
cat > "$FAKE_BIN/systemctl" <<'SYSEOF'
#!/usr/bin/env bash
case "$1" in
  is-active) echo "inactive"; exit 1 ;;
  restart) echo "restart failed" >&2; exit 1 ;;
  *) exit 0 ;;
esac
SYSEOF
chmod +x "$FAKE_BIN/systemctl"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"

# Allow test services in the allowlist
ALLOWED_SERVICES=(openclaw-gateway test-svc)

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

# ── Test 1: DEDUP — second failure for same service reuses existing bead ──

echo "=== Test 1: Service bead dedup ==="

# First failure — no existing bead, should create
execute_action '{"type":"restart_service","target":"openclaw-gateway","reason":"service down"}' || true
create_count=$(awk '/^create /{count++} END{print count+0}' "$FAKE_BR_LOG")
assert_eq "$create_count" "1" "first failure creates one bead"
pass "first failure creates bead"

# Reset backoff state so second attempt is allowed
echo '{"services":{}}' > "$ARGUS_RESTART_BACKOFF_FILE"

# Now simulate an existing open bead in search results
cat > "$FAKE_BR_SEARCH_JSON" <<'EOF'
[{"id":"existing-svc-bead","title":"[argus] service: openclaw-gateway"}]
EOF

# Second failure — should find existing bead via label search, skip create
execute_action '{"type":"restart_service","target":"openclaw-gateway","reason":"service still down"}' || true
create_count_after=$(awk '/^create /{count++} END{print count+0}' "$FAKE_BR_LOG")
assert_eq "$create_count_after" "1" "second failure reuses existing bead (no extra create)"

last_bead_id=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.bead_id')
assert_eq "$last_bead_id" "existing-svc-bead" "reused bead id matches search result"
pass "second failure reuses existing bead"

# ── Test 2: AUTO-RESOLVE — successful restart closes open fail bead ──

echo "=== Test 2: Auto-resolve on recovery ==="

# Make systemctl succeed
cat > "$FAKE_BIN/systemctl" <<'SYSEOF'
#!/usr/bin/env bash
case "$1" in
  is-active) echo "active"; exit 0 ;;
  restart) exit 0 ;;
  *) exit 0 ;;
esac
SYSEOF
chmod +x "$FAKE_BIN/systemctl"

# Reset backoff state so restart is allowed
echo '{"services":{}}' > "$ARGUS_RESTART_BACKOFF_FILE"

# Ensure there's an open bead to close
cat > "$FAKE_BR_SEARCH_JSON" <<'EOF'
[{"id":"bead-to-close","title":"[argus] service: openclaw-gateway"}]
EOF

> "$FAKE_BR_CLOSE_LOG"
execute_action '{"type":"restart_service","target":"openclaw-gateway","reason":"service recovered check"}'

close_called=$(grep -c "bead-to-close" "$FAKE_BR_CLOSE_LOG" 2>/dev/null || echo 0)
assert_eq "$close_called" "1" "br close called for recovered service bead"
pass "auto-resolve closes open bead on recovery"

# ── Test 3: BOOT GRACE — skip bead creation during early boot ──

echo "=== Test 3: Boot grace period ==="

# Make systemctl fail again
cat > "$FAKE_BIN/systemctl" <<'SYSEOF'
#!/usr/bin/env bash
case "$1" in
  is-active) echo "inactive"; exit 1 ;;
  restart) echo "restart failed" >&2; exit 1 ;;
  *) exit 0 ;;
esac
SYSEOF
chmod +x "$FAKE_BIN/systemctl"

# Reset backoff and search state
echo '{"services":{}}' > "$ARGUS_RESTART_BACKOFF_FILE"
echo "[]" > "$FAKE_BR_SEARCH_JSON"

# Override system_uptime_seconds to report 30s (within grace period)
system_uptime_seconds() { echo 30; }

# Reset create count
> "$FAKE_BR_LOG"

execute_action '{"type":"restart_service","target":"test-svc","reason":"boot startup failure"}' || true

boot_create_count=$(awk '/^create /{count++} END{print count+0}' "$FAKE_BR_LOG")
assert_eq "$boot_create_count" "0" "no bead created during boot grace"

boot_result=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')
assert_eq "$boot_result" "boot-grace" "action_result is boot-grace"
pass "boot grace skips bead creation"

# ── Test 4: After boot grace expires, beads are created normally ──

echo "=== Test 4: Post-boot creates beads normally ==="

# Override uptime to be past grace period
system_uptime_seconds() { echo 999; }

# Reset backoff
echo '{"services":{}}' > "$ARGUS_RESTART_BACKOFF_FILE"
> "$FAKE_BR_LOG"

execute_action '{"type":"restart_service","target":"test-svc","reason":"real failure"}' || true

post_boot_create_count=$(awk '/^create /{count++} END{print count+0}' "$FAKE_BR_LOG")
assert_eq "$post_boot_create_count" "1" "bead created after boot grace expires"
pass "post-boot bead creation works"

# ── Test 5: Service labels passed to br create ──

echo "=== Test 5: Service labels in br create ==="

# Check that the create call includes service-specific labels
# The br fake logs all args as a single line; --labels value appears after -d body
if grep -q "service:test-svc" "$FAKE_BR_LOG" && grep -q "status:fail" "$FAKE_BR_LOG"; then
    pass "create includes service:name and status:fail labels"
else
    echo "ASSERTION FAILED: expected service labels in br log" >&2
    echo "Full br log:" >&2
    cat "$FAKE_BR_LOG" >&2
    exit 1
fi

echo ""
echo "actions_service_bead_test: PASS"
