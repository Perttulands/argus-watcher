#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

FALLBACK_FILE="$TEST_ROOT/relay-fallback.jsonl"
OBS_FALLBACK_FILE="$TEST_ROOT/relay-observations-fallback.jsonl"
SUMMARY_FALLBACK_FILE="$TEST_ROOT/relay-summary-fallback.jsonl"
LOG_FILE="$TEST_ROOT/relay.log"

cat > "$FALLBACK_FILE" <<'EOF'
{"event":"argus.problem","message":"disk pressure"}
{"event":"argus.problem","message":"memory pressure"}
EOF

cat > "$OBS_FALLBACK_FILE" <<'EOF'
{"event":"argus.observations.snapshot","message":"snapshot"}
EOF

cat > "$SUMMARY_FALLBACK_FILE" <<'EOF'
{"event":"argus.daily_summary","message":"summary"}
EOF

cat > "$FAKE_BIN/relay" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ARGUS_TEST_RELAY_LOG"
case "$3" in
  *memory\ pressure*)
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$FAKE_BIN/relay"

export ARGUS_TEST_RELAY_LOG="$LOG_FILE"

output=$(
    ARGUS_RELAY_BIN="$FAKE_BIN/relay" \
    ARGUS_RELAY_FALLBACK_FILE="$FALLBACK_FILE" \
    ARGUS_RELAY_OBSERVATIONS_FALLBACK_FILE="$OBS_FALLBACK_FILE" \
    ARGUS_RELAY_SUMMARY_FALLBACK_FILE="$SUMMARY_FALLBACK_FILE" \
    ARGUS_RELAY_DRAIN_MAX_ITEMS=10 \
    "$ROOT/scripts/relay-drain.sh"
)

[[ "$output" == *"relay-fallback.jsonl: drained=1 failed=1 pending=1"* ]] || {
    echo "unexpected relay drain output for alerts: $output" >&2
    exit 1
}
[[ "$output" == *"relay-observations-fallback.jsonl: drained=1 failed=0 pending=0"* ]] || {
    echo "unexpected relay drain output for observations: $output" >&2
    exit 1
}
[[ "$output" == *"relay-summary-fallback.jsonl: drained=1 failed=0 pending=0"* ]] || {
    echo "unexpected relay drain output for summary: $output" >&2
    exit 1
}

[[ -f "$FALLBACK_FILE" ]] || { echo "expected alert fallback file to remain for failed item" >&2; exit 1; }
[[ "$(wc -l < "$FALLBACK_FILE")" == "1" ]] || { echo "expected one pending alert after drain" >&2; exit 1; }
grep -q 'memory pressure' "$FALLBACK_FILE" || { echo "failed alert was not retained" >&2; exit 1; }

[[ ! -f "$OBS_FALLBACK_FILE" ]] || { echo "observations fallback file should be removed after successful drain" >&2; exit 1; }
[[ ! -f "$SUMMARY_FALLBACK_FILE" ]] || { echo "summary fallback file should be removed after successful drain" >&2; exit 1; }

[[ "$(wc -l < "$LOG_FILE")" == "4" ]] || { echo "expected four relay send attempts" >&2; exit 1; }

echo "relay_drain_test: PASS"
