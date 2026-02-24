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
export ARGUS_BEAD_REPEAT_THRESHOLD=3
mkdir -p "$ARGUS_BEADS_WORKDIR"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
export FAKE_BR_LOG="$TEST_ROOT/br.log"
export FAKE_BR_OPEN_JSON="$TEST_ROOT/open.json"
export FAKE_BR_CREATE_ID="athena-fake"
touch "$FAKE_BR_LOG"

cat > "$FAKE_BIN/br" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$FAKE_BR_LOG"
cmd="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi
case "$cmd" in
  list)
    if [[ -f "$FAKE_BR_OPEN_JSON" ]]; then
      cat "$FAKE_BR_OPEN_JSON"
    else
      echo "[]"
    fi
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

# 1) Failed action should create a bead and store bead_id in registry
if execute_action '{"type":"restart_service","target":"gateway","reason":"service down"}'; then
    echo "expected restart_service to fail because service is not allowlisted" >&2
    exit 1
fi

first_bead_id=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.bead_id')
first_result=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.action_result')
assert_eq "$first_result" "failure" "failed action result"
assert_eq "$first_bead_id" "athena-fake" "bead id persisted for failed action"

create_count=$(awk '/^create /{count++} END{print count+0}' "$FAKE_BR_LOG")
assert_eq "$create_count" "1" "first creation call count"

# 2) Existing open bead should be reused (dedup) instead of creating a new one
dedup_message="Disk pressure high 95%"
problem_key=$(generate_problem_key "disk" "$dedup_message")
cat > "$FAKE_BR_OPEN_JSON" <<EOF
[
  {"id":"athena-open","description":"Problem key: ${problem_key}"}
]
EOF

execute_action "{\"type\":\"log\",\"observation\":\"${dedup_message}\"}"
second_bead_id=$(tail -n1 "$ARGUS_PROBLEMS_FILE" | jq -r '.bead_id')
assert_eq "$second_bead_id" "athena-open" "existing open bead id should be reused"

create_count_after=$(awk '/^create /{count++} END{print count+0}' "$FAKE_BR_LOG")
assert_eq "$create_count_after" "1" "no extra create call when open bead exists"

echo "actions_bead_creation_test: PASS"
