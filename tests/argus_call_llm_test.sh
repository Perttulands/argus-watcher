#!/usr/bin/env bash
set -euo pipefail

# Test call_llm function from argus.sh
# Mocks the `claude` CLI to verify prompt construction and error handling.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

LOG_DIR="$TEST_ROOT/logs"
LOG_FILE="$LOG_DIR/argus.log"
mkdir -p "$LOG_DIR"

LLM_TIMEOUT=5

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# Stub br for actions.sh sourcing
cat > "$FAKE_BIN/br" <<'STUBEOF'
#!/usr/bin/env bash
echo "[]"
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

# Define log and call_llm from argus.sh
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

call_llm() {
    local system_prompt="$1"
    local user_message="$2"
    local full_prompt
    full_prompt=$(printf '%s\n\n---\n\n%s\n\nRespond with ONLY valid JSON. No markdown, no explanation.' "$system_prompt" "$user_message")
    local response exit_code stderr_file
    stderr_file=$(mktemp)
    # shellcheck disable=SC2016
    response=$(timeout "$LLM_TIMEOUT" bash -c 'echo "$1" | claude -p --model haiku --output-format text 2>"$2"' _ "$full_prompt" "$stderr_file") && exit_code=0 || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        local stderr_output
        stderr_output=$(cat "$stderr_file" 2>/dev/null; rm -f "$stderr_file") # REASON: temp file may already be cleaned up
        if [[ $exit_code -eq 124 ]]; then
            log ERROR "claude -p timed out after ${LLM_TIMEOUT}s"
        else
            log ERROR "claude -p call failed (exit code: $exit_code)"
        fi
        [[ -n "$stderr_output" ]] && log ERROR "claude -p stderr: $stderr_output"
        return 1
    fi
    rm -f "$stderr_file"
    if [[ -z "$response" ]]; then
        log ERROR "Empty response from claude -p"
        return 1
    fi
    echo "$response"
}

CAPTURED_STDIN="$TEST_ROOT/captured_stdin.txt"

# --- Test 1: successful call with mock claude ---
cat > "$FAKE_BIN/claude" <<MOCKEOF
#!/usr/bin/env bash
# Capture stdin for verification
cat > "$CAPTURED_STDIN"
echo '{"assessment":"all good","actions":[]}'
MOCKEOF
chmod +x "$FAKE_BIN/claude"

: > "$LOG_FILE"
result=$(call_llm "You are a monitor" "CPU: 5% Memory: 30%")

# Verify the response was captured
[[ "$result" == '{"assessment":"all good","actions":[]}' ]] || { echo "FAIL: unexpected response: $result" >&2; exit 1; }

# Verify prompt construction: system_prompt + separator + user_message + JSON instruction
captured=$(cat "$CAPTURED_STDIN")
[[ "$captured" == *"You are a monitor"* ]] || { echo "FAIL: system prompt not in stdin" >&2; exit 1; }
[[ "$captured" == *"---"* ]] || { echo "FAIL: separator not in stdin" >&2; exit 1; }
[[ "$captured" == *"CPU: 5% Memory: 30%"* ]] || { echo "FAIL: user message not in stdin" >&2; exit 1; }
[[ "$captured" == *"Respond with ONLY valid JSON"* ]] || { echo "FAIL: JSON instruction not in stdin" >&2; exit 1; }

# --- Test 2: claude returns non-zero exit code ---
cat > "$FAKE_BIN/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "some error" >&2
exit 1
MOCKEOF
chmod +x "$FAKE_BIN/claude"

: > "$LOG_FILE"
if call_llm "sys" "msg" 2>/dev/null; then # REASON: test intentionally triggers error; stderr noise is expected
    echo "FAIL: should fail on non-zero exit" >&2
    exit 1
fi
grep -q "call failed" "$LOG_FILE" || { echo "FAIL: should log failure" >&2; exit 1; }

# --- Test 3: claude returns empty response ---
cat > "$FAKE_BIN/claude" <<'MOCKEOF'
#!/usr/bin/env bash
# read stdin to avoid broken pipe
cat > /dev/null
# output nothing
MOCKEOF
chmod +x "$FAKE_BIN/claude"

: > "$LOG_FILE"
if call_llm "sys" "msg" 2>/dev/null; then # REASON: test intentionally triggers error; stderr noise is expected
    echo "FAIL: should fail on empty response" >&2
    exit 1
fi
grep -q "Empty response" "$LOG_FILE" || { echo "FAIL: should log empty response error" >&2; exit 1; }

# --- Test 4: claude times out ---
cat > "$FAKE_BIN/claude" <<'MOCKEOF'
#!/usr/bin/env bash
cat > /dev/null
sleep 30
MOCKEOF
chmod +x "$FAKE_BIN/claude"

LLM_TIMEOUT=1
: > "$LOG_FILE"
if call_llm "sys" "msg" 2>/dev/null; then # REASON: test intentionally triggers timeout; stderr noise is expected
    echo "FAIL: should fail on timeout" >&2
    exit 1
fi
grep -q "timed out" "$LOG_FILE" || { echo "FAIL: should log timeout" >&2; exit 1; }

echo "argus_call_llm_test: PASS"
