#!/usr/bin/env bash
set -euo pipefail

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
mkdir -p "$ARGUS_BEADS_WORKDIR"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
export FAKE_BR_OPEN_JSON="$TEST_ROOT/open.json"
export FAKE_BR_CREATE_ID="athena-dedup"
touch "$FAKE_BR_OPEN_JSON"
echo "[]" > "$FAKE_BR_OPEN_JSON"

cat > "$FAKE_BIN/br" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi
case "$cmd" in
  list)
    cat "$FAKE_BR_OPEN_JSON"
    ;;
  create)
    echo "${FAKE_BR_CREATE_ID}"
    ;;
  *)
    echo "unsupported command: $cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/br"

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
cat > "$FAKE_BR_OPEN_JSON" <<EOF
[{"id":"athena-open","description":"Problem key: ${problem_key}"}]
EOF

execute_action "{\"type\":\"alert\",\"message\":\"${alert_message}\"}"
second_record=$(tail -n1 "$ARGUS_PROBLEMS_FILE")
second_result=$(echo "$second_record" | jq -r '.action_result')
second_bead=$(echo "$second_record" | jq -r '.bead_id')
assert_eq "$second_result" "suppressed" "second alert should be suppressed"
assert_eq "$second_bead" "athena-open" "suppressed alert should reuse existing bead id"

stored_last_seen=$(jq -r --arg key "$problem_key" '.keys[$key].last_seen // 0' "$ARGUS_DEDUP_FILE")
if [[ ! "$stored_last_seen" =~ ^[0-9]+$ ]] || (( stored_last_seen == 0 )); then
    echo "dedup state missing key timestamp" >&2
    exit 1
fi

echo "actions_dedup_test: PASS"
