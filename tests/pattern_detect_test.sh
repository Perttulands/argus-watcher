#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PROBLEMS_FILE="$TEST_ROOT/problems.jsonl"
OUTPUT_FILE="$TEST_ROOT/pattern-analysis.json"
STATE_FILE="$TEST_ROOT/pattern-detect-state.json"
LOG_FILE="$TEST_ROOT/patterns.jsonl"
WORKDIR="$TEST_ROOT/workspace"
mkdir -p "$WORKDIR"

today="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$PROBLEMS_FILE" <<EOF
{"ts":"$today","severity":"warning","type":"service","description":"Service action for gateway: down","action_taken":"restart_service:gateway","action_result":"failure","bead_id":null,"host":"test"}
{"ts":"$today","severity":"warning","type":"service","description":"Service action for gateway: down","action_taken":"restart_service:gateway","action_result":"failure","bead_id":null,"host":"test"}
{"ts":"$today","severity":"warning","type":"service","description":"Service action for gateway: down","action_taken":"restart_service:gateway","action_result":"failure","bead_id":null,"host":"test"}
EOF

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
export FAKE_BR_LOG="$TEST_ROOT/br.log"
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
  create) echo "athena-pattern" ;;
  list) echo "[]" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/br"

run_detect() {
    ARGUS_PROBLEMS_FILE="$PROBLEMS_FILE" \
    ARGUS_PATTERN_OUTPUT_FILE="$OUTPUT_FILE" \
    ARGUS_PATTERN_DETECT_STATE_FILE="$STATE_FILE" \
    ARGUS_PATTERN_LOG_FILE="$LOG_FILE" \
    ARGUS_BEADS_WORKDIR="$WORKDIR" \
    "$ROOT/scripts/pattern-detect.sh" >/dev/null
}

run_detect
create_count_1=$(grep -c '^create ' "$FAKE_BR_LOG")
[[ "$create_count_1" -eq 1 ]] || { echo "expected one bead creation on first run" >&2; exit 1; }

run_detect
create_count_2=$(grep -c '^create ' "$FAKE_BR_LOG")
[[ "$create_count_2" -eq 1 ]] || { echo "expected no extra bead creation on second run" >&2; exit 1; }

[[ -f "$STATE_FILE" ]] || { echo "state file missing" >&2; exit 1; }
[[ -f "$LOG_FILE" ]] || { echo "pattern log missing" >&2; exit 1; }

echo "pattern_detect_test: PASS"
