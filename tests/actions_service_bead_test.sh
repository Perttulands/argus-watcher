#!/usr/bin/env bash
set -euo pipefail

# Tests for service-down relay alerts, auto-resolve, and boot grace.
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
export FAKE_BR_OPEN_JSON="$TEST_ROOT/open.json"
export FAKE_BR_CLOSE_LOG="$TEST_ROOT/close.log"
RELAY_LOG="$TEST_ROOT/relay.log"
touch "$FAKE_BR_LOG" "$FAKE_BR_CLOSE_LOG" "$RELAY_LOG"
echo "[]" > "$FAKE_BR_SEARCH_JSON"
echo "[]" > "$FAKE_BR_OPEN_JSON"
export RELAY_LOG

# Mock relay
cat > "$FAKE_BIN/relay" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$RELAY_LOG"
EOF
chmod +x "$FAKE_BIN/relay"

# Fake br that supports search, close (no create needed)
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

# Fake systemctl — always fails restart
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

# ── Test 1: Failed restart sends relay alert ──

echo "=== Test 1: Failed restart sends relay alert ==="

execute_action '{"type":"restart_service","target":"openclaw-gateway","reason":"service down"}' || true # REASON: test intentionally continues after simulated failure.

relay_count=$(wc -l < "$RELAY_LOG" | tr -d ' ')
[[ "$relay_count" -ge 1 ]] || { echo "FAIL: relay not called for failed service restart" >&2; exit 1; }
grep -q "ARGUS ALERT" "$RELAY_LOG" || { echo "FAIL: relay message missing ARGUS ALERT" >&2; exit 1; }
pass "failed restart sends relay alert"

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

close_called=$(grep -c "bead-to-close" "$FAKE_BR_CLOSE_LOG" 2>/dev/null || echo 0) # REASON: missing close log should count as zero for assertions.
assert_eq "$close_called" "1" "br close called for recovered service bead"
pass "auto-resolve closes open bead on recovery"

# ── Test 3: BOOT GRACE — skip relay alert during early boot ──

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

# Reset relay log to count new alerts
> "$RELAY_LOG"

execute_action '{"type":"restart_service","target":"test-svc","reason":"boot startup failure"}' || true # REASON: test intentionally continues after simulated failure.

boot_result=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')
assert_eq "$boot_result" "boot-grace" "action_result is boot-grace"

boot_relay_count=$(wc -l < "$RELAY_LOG" | tr -d ' ')
assert_eq "$boot_relay_count" "0" "no relay alert during boot grace"
pass "boot grace skips relay alert"

# ── Test 4: Post-boot failures trigger relay alerts ──

echo "=== Test 4: Post-boot sends relay alerts ==="

system_uptime_seconds() { echo 999; }
echo '{"services":{}}' > "$ARGUS_RESTART_BACKOFF_FILE"
> "$RELAY_LOG"

execute_action '{"type":"restart_service","target":"test-svc","reason":"real failure"}' || true # REASON: test intentionally continues after simulated failure.

post_boot_relay_count=$(wc -l < "$RELAY_LOG" | tr -d ' ')
[[ "$post_boot_relay_count" -ge 1 ]] || { echo "FAIL: no relay alert after boot grace expires" >&2; exit 1; }
pass "post-boot failures send relay alerts"

echo ""
echo "actions_service_bead_test: PASS"
