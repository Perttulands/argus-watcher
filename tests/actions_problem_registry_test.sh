#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

export ARGUS_STATE_DIR="$TEST_ROOT/state"
export ARGUS_PROBLEMS_FILE="$ARGUS_STATE_DIR/problems.jsonl"
export ARGUS_OBSERVATIONS_FILE="$TEST_ROOT/observations.md"
export ARGUS_RELAY_ENABLED=false
export ARGUS_RELAY_FALLBACK_FILE="$TEST_ROOT/relay-fallback.jsonl"
export ARGUS_BEADS_WORKDIR="$TEST_ROOT/workspace"
mkdir -p "$ARGUS_BEADS_WORKDIR"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
export FAKE_BR_OPEN_JSON="$TEST_ROOT/open.json"
export FAKE_BR_CREATE_ID="registry-bead"
echo "[]" > "$FAKE_BR_OPEN_JSON"

cat > "$FAKE_BIN/br" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi
case "$cmd" in
  list|search)
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

log_problem "warning" "disk" "Disk usage above threshold" "alert:telegram" "success" "null"

[[ -f "$ARGUS_PROBLEMS_FILE" ]] || { echo "problems file was not created" >&2; exit 1; }
jq -c . "$ARGUS_PROBLEMS_FILE" >/dev/null

first_type=$(jq -r '.type' "$ARGUS_PROBLEMS_FILE")
first_result=$(jq -r '.action_result' "$ARGUS_PROBLEMS_FILE")
assert_eq "$first_type" "disk" "first record type"
assert_eq "$first_result" "success" "first record result"

line_count_before=$(wc -l < "$ARGUS_PROBLEMS_FILE")
if execute_action '{"type":"restart_service","target":"fake-service","reason":"service down"}'; then
    echo "expected restart_service to fail for non-allowlisted service" >&2
    exit 1
fi
line_count_after=$(wc -l < "$ARGUS_PROBLEMS_FILE")
assert_eq "$line_count_after" "$((line_count_before + 1))" "failure should append one record"

last_record=$(tail -n1 "$ARGUS_PROBLEMS_FILE")
last_type=$(echo "$last_record" | jq -r '.type')
last_result=$(echo "$last_record" | jq -r '.action_result')
assert_eq "$last_type" "service" "failure record type"
assert_eq "$last_result" "failure" "failure record result"

execute_action '{"type":"log","observation":"Memory pressure high (92%)"}'
final_record=$(tail -n1 "$ARGUS_PROBLEMS_FILE")
final_type=$(echo "$final_record" | jq -r '.type')
final_result=$(echo "$final_record" | jq -r '.action_result')
assert_eq "$final_type" "memory" "log action inferred type"
assert_eq "$final_result" "success" "log action result"

jq -s 'map(has("ts") and has("severity") and has("type") and has("description") and has("action_taken") and has("action_result") and has("bead_id") and has("host")) | all' \
    "$ARGUS_PROBLEMS_FILE" | grep -qx true

echo "actions_problem_registry_test: PASS"
