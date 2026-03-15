#!/usr/bin/env bash
set -euo pipefail

# Test: dedup suppresses duplicate alerts within the dedup window.
# Updated for pol-22x2: bead_id is no longer populated (create_bead removed).

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
export ARGUS_BEADS_WORKDIR=""

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

RELAY_LOG="$TEST_ROOT/relay.log"
touch "$RELAY_LOG"
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

alert_message="Disk usage critical at 94%"
execute_action "{\"type\":\"alert\",\"message\":\"${alert_message}\"}"
first_result=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')
assert_eq "$first_result" "success" "first alert should execute"

problem_key=$(generate_problem_key "disk" "$alert_message")

# Second identical alert should be suppressed by dedup
execute_action "{\"type\":\"alert\",\"message\":\"${alert_message}\"}"
second_record=$(tail -n1 "$ARGUS_PROBLEMS_FILE")
second_result=$(echo "$second_record" | jq -r '.action_result')
assert_eq "$second_result" "suppressed" "second alert should be suppressed"

stored_last_seen=$(jq -r --arg key "$problem_key" '.keys[$key].last_seen // 0' "$ARGUS_DEDUP_FILE")
if [[ ! "$stored_last_seen" =~ ^[0-9]+$ ]] || (( stored_last_seen == 0 )); then
    echo "dedup state missing key timestamp" >&2
    exit 1
fi

echo "actions_dedup_test: PASS"
