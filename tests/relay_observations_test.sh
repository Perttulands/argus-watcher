#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
OBS_FILE="$TEST_ROOT/observations.md"
FALLBACK_FILE="$TEST_ROOT/relay-observations-fallback.jsonl"

cat > "$OBS_FILE" <<'EOF'
- **[2026-03-04T11:00:00Z]** Gateway recovered after restart
- **[2026-03-04T11:05:00Z]** Memory pressure elevated on polis
- **[2026-03-04T11:10:00Z]** Relay timeout observed
EOF

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

cat > "$FAKE_BIN/relay" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
chmod +x "$FAKE_BIN/relay"

output=$(
    ARGUS_OBSERVATIONS_FILE="$OBS_FILE" \
    ARGUS_RELAY_BIN="$FAKE_BIN/relay" \
    ARGUS_RELAY_OBSERVATIONS_FALLBACK_FILE="$FALLBACK_FILE" \
    ARGUS_OBSERVATIONS_LINES=2 \
    "$ROOT/scripts/relay-observations.sh"
)

[[ "$output" == *"Argus observations snapshot"* ]] || { echo "snapshot output missing" >&2; exit 1; }
[[ "$output" == *"delivery=fallback"* ]] || { echo "expected fallback delivery" >&2; exit 1; }
[[ -f "$FALLBACK_FILE" ]] || { echo "fallback observations file missing" >&2; exit 1; }
[[ "$(wc -l < "$FALLBACK_FILE")" -ge 1 ]] || { echo "fallback observations file empty" >&2; exit 1; }

line_window=$(jq -r '.line_window' "$FALLBACK_FILE")
[[ "$line_window" == "2" ]] || { echo "unexpected line_window in payload: $line_window" >&2; exit 1; }

total_entries=$(jq -r '.total_entries' "$FALLBACK_FILE")
[[ "$total_entries" == "3" ]] || { echo "unexpected total_entries in payload: $total_entries" >&2; exit 1; }

event_name=$(jq -r '.event' "$FALLBACK_FILE")
[[ "$event_name" == "argus.observations.snapshot" ]] || { echo "unexpected event name: $event_name" >&2; exit 1; }

echo "relay_observations_test: PASS"
