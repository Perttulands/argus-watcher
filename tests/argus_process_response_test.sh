#!/usr/bin/env bash
set -euo pipefail

# Test process_llm_response function from argus.sh
# Validates JSON parsing, assessment extraction, observation logging, and action dispatch.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

LOG_DIR="$TEST_ROOT/logs"
LOG_FILE="$LOG_DIR/argus.log"
mkdir -p "$LOG_DIR"

HOSTNAME_CACHED="test-host"

# Set up action dependencies
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

cat > "$FAKE_BIN/br" <<'STUBEOF'
#!/usr/bin/env bash
cmd="${1:-}"
case "$cmd" in
  list) echo "[]" ;;
  create) echo "test-bead" ;;
  *) exit 1 ;;
esac
STUBEOF
chmod +x "$FAKE_BIN/br"

export ARGUS_STATE_DIR="$TEST_ROOT/state"
export ARGUS_PROBLEMS_FILE="$ARGUS_STATE_DIR/problems.jsonl"
export ARGUS_DEDUP_FILE="$ARGUS_STATE_DIR/dedup.json"
export ARGUS_OBSERVATIONS_FILE="$TEST_ROOT/observations.md"
export ARGUS_RELAY_ENABLED=false
export ARGUS_RELAY_FALLBACK_FILE="$TEST_ROOT/relay-fallback.jsonl"
export ARGUS_BEADS_WORKDIR="$TEST_ROOT/workspace"
mkdir -p "$ARGUS_BEADS_WORKDIR"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"

# Define log and process_llm_response from argus.sh
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

process_llm_response() {
    local response="$1"
    response=$(echo "$response" | sed '/^```\(json\)\{0,1\}$/d')
    if ! echo "$response" | jq empty 2>/dev/null; then
        log ERROR "LLM response is not valid JSON"
        log ERROR "Raw response (first 500 chars): ${response:0:500}"
        return 1
    fi
    local assessment
    assessment=$(echo "$response" | jq -r '.assessment // "No assessment provided"')
    log INFO "Assessment: $assessment"
    local obs_output
    obs_output=$(echo "$response" | jq -r 'if .observations then .observations[] else empty end' 2>/dev/null) || true
    if [[ -n "$obs_output" ]]; then
        log INFO "Observations:"
        while IFS= read -r obs; do
            [[ -n "$obs" ]] && log INFO "  - $obs"
        done <<< "$obs_output"
    fi
    local actions_output
    actions_output=$(echo "$response" | jq -c 'if .actions then .actions[] else empty end' 2>/dev/null) || true
    if [[ -z "$actions_output" ]]; then
        log INFO "No actions to execute"
        return 0
    fi
    log INFO "Executing actions:"
    local action_count=0
    while IFS= read -r action; do
        [[ -z "$action" ]] && continue
        action_count=$((action_count + 1))
        local action_type
        action_type=$(echo "$action" | jq -r '.type // "unknown"')
        log INFO "  Action $action_count: $action_type"
        if execute_action "$action"; then
            log INFO "  Action $action_count ($action_type) completed"
        else
            log ERROR "  Action $action_count ($action_type) failed"
        fi
    done <<< "$actions_output"
    log INFO "Executed $action_count action(s)"
}

assert_eq() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $label (got '$got', want '$want')" >&2
        exit 1
    fi
}

# --- Test 1: invalid JSON returns error ---
: > "$LOG_FILE"
if process_llm_response "not json at all"; then
    echo "FAIL: should return non-zero for invalid JSON" >&2
    exit 1
fi
grep -q "not valid JSON" "$LOG_FILE" || { echo "FAIL: should log JSON error" >&2; exit 1; }

# --- Test 2: valid JSON with assessment and no actions ---
: > "$LOG_FILE"
process_llm_response '{"assessment":"all systems nominal","observations":["disk ok","memory ok"]}'
grep -q "Assessment: all systems nominal" "$LOG_FILE" || { echo "FAIL: assessment not logged" >&2; exit 1; }
grep -q "disk ok" "$LOG_FILE" || { echo "FAIL: observation 'disk ok' not logged" >&2; exit 1; }
grep -q "memory ok" "$LOG_FILE" || { echo "FAIL: observation 'memory ok' not logged" >&2; exit 1; }
grep -q "No actions to execute" "$LOG_FILE" || { echo "FAIL: should log no actions" >&2; exit 1; }

# --- Test 3: valid JSON with a log action ---
: > "$LOG_FILE"
process_llm_response '{"assessment":"test","actions":[{"type":"log","message":"test log entry"}]}'
grep -q "Action 1: log" "$LOG_FILE" || { echo "FAIL: action type not logged" >&2; exit 1; }
grep -q "Executed 1 action" "$LOG_FILE" || { echo "FAIL: action count not logged" >&2; exit 1; }

# --- Test 4: markdown code fences are stripped ---
: > "$LOG_FILE"
fenced_response='```json
{"assessment":"fenced response","observations":["clean"]}
```'
process_llm_response "$fenced_response"
grep -q "Assessment: fenced response" "$LOG_FILE" || { echo "FAIL: fenced JSON not parsed" >&2; exit 1; }

# --- Test 5: missing assessment field gives default ---
: > "$LOG_FILE"
process_llm_response '{"observations":["no assessment field"]}'
grep -q "Assessment: No assessment provided" "$LOG_FILE" || { echo "FAIL: default assessment not used" >&2; exit 1; }

echo "argus_process_response_test: PASS"
