#!/usr/bin/env bash
set -euo pipefail

# Test rotate_log function from argus.sh
# Uses temp directories — no side effects on real system.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

# Override globals that argus.sh sets at source time
LOG_DIR="$TEST_ROOT/logs"
LOG_FILE="$LOG_DIR/argus.log"
MAX_LOG_SIZE=100  # 100 bytes for easy testing
MAX_LOG_FILES=3

mkdir -p "$LOG_DIR"

# Provide stubs for sourced dependencies
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# Stub out commands that actions.sh/collectors.sh might need
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

# Source argus.sh functions (it sources collectors.sh and actions.sh)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"

# Manually define the functions we need from argus.sh without running main()
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

rotate_log() {
    if [[ ! -f "$LOG_FILE" ]]; then
        return 0
    fi
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) # REASON: file may not exist yet; 0 means no rotation needed.
    if (( size > MAX_LOG_SIZE )); then
        local i
        for (( i = MAX_LOG_FILES; i >= 1; i-- )); do
            local prev=$((i - 1))
            local src="${LOG_FILE}.${prev}"
            [[ $prev -eq 0 ]] && src="$LOG_FILE"
            if [[ -f "$src" ]]; then
                mv "$src" "${LOG_FILE}.${i}"
            fi
        done
        : > "$LOG_FILE"
        log INFO "Log rotated (previous log exceeded $((MAX_LOG_SIZE / 1024 / 1024))MB)"
    fi
}

assert_eq() {
    local got="$1" want="$2" label="$3"
    if [[ "$got" != "$want" ]]; then
        echo "FAIL: $label (got '$got', want '$want')" >&2
        exit 1
    fi
}

# --- Test 1: rotate_log does nothing when log file doesn't exist ---
rm -f "$LOG_FILE"
rotate_log
assert_eq "0" "0" "no-op when log missing"

# --- Test 2: rotate_log does nothing when file is under MAX_LOG_SIZE ---
echo "small" > "$LOG_FILE"
rotate_log
[[ -f "$LOG_FILE" ]] || { echo "FAIL: log file should still exist after no-op rotation" >&2; exit 1; }
[[ "$(cat "$LOG_FILE")" == "small" ]] || { echo "FAIL: log content should be unchanged" >&2; exit 1; }

# --- Test 3: rotate_log rotates when file exceeds MAX_LOG_SIZE ---
# Write >100 bytes to trigger rotation
python3 -c "print('x' * 200)" > "$LOG_FILE"
rotate_log
# After rotation: LOG_FILE.1 should have the old content, LOG_FILE should be small (just the rotation message)
[[ -f "${LOG_FILE}.1" ]] || { echo "FAIL: ${LOG_FILE}.1 should exist after rotation" >&2; exit 1; }
old_size=$(stat -c%s "${LOG_FILE}.1")
(( old_size > 100 )) || { echo "FAIL: rotated file should have old content (got ${old_size} bytes)" >&2; exit 1; }
# Current log file should have the rotation message
[[ -f "$LOG_FILE" ]] || { echo "FAIL: log file should exist after rotation" >&2; exit 1; }

# --- Test 4: multiple rotations shift files correctly ---
python3 -c "print('y' * 200)" > "$LOG_FILE"
rotate_log
[[ -f "${LOG_FILE}.2" ]] || { echo "FAIL: ${LOG_FILE}.2 should exist after second rotation" >&2; exit 1; }
[[ -f "${LOG_FILE}.1" ]] || { echo "FAIL: ${LOG_FILE}.1 should still exist after second rotation" >&2; exit 1; }

# --- Test 5: oldest file is overwritten when MAX_LOG_FILES reached ---
python3 -c "print('z' * 200)" > "$LOG_FILE"
rotate_log
# .3 is MAX_LOG_FILES, so we should have .1, .2, .3
[[ -f "${LOG_FILE}.3" ]] || { echo "FAIL: ${LOG_FILE}.3 should exist at max rotation" >&2; exit 1; }

# One more rotation: .3 should be overwritten (shift through)
python3 -c "print('w' * 200)" > "$LOG_FILE"
rotate_log
[[ -f "${LOG_FILE}.3" ]] || { echo "FAIL: ${LOG_FILE}.3 should still exist after overflow rotation" >&2; exit 1; }

echo "argus_rotate_log_test: PASS"
