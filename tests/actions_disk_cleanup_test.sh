#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

export ARGUS_STATE_DIR="$TEST_ROOT/state"
export ARGUS_PROBLEMS_FILE="$ARGUS_STATE_DIR/problems.jsonl"
export ARGUS_DEDUP_FILE="$ARGUS_STATE_DIR/dedup.json"
export ARGUS_OBSERVATIONS_FILE="$TEST_ROOT/observations.md"
export ARGUS_RELAY_ENABLED=false
export ARGUS_RELAY_FALLBACK_FILE="$TEST_ROOT/relay-fallback.jsonl"
export ARGUS_BEADS_WORKDIR="$TEST_ROOT/workspace"
mkdir -p "$ARGUS_BEADS_WORKDIR"
export ARGUS_DISK_CLEAN_DRY_RUN=true

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"
cat > "$FAKE_BIN/br" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi
case "$cmd" in
  list) echo "[]" ;;
  create) echo "athena-disk-clean" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/br"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"

execute_action '{"type":"clean_disk","reason":"disk usage above 90%"}'
record=$(tail -n1 "$ARGUS_PROBLEMS_FILE")

record_type=$(echo "$record" | jq -r '.type')
action_taken=$(echo "$record" | jq -r '.action_taken')
action_result=$(echo "$record" | jq -r '.action_result')
description=$(echo "$record" | jq -r '.description')

[[ "$record_type" == "disk" ]] || { echo "expected disk record type" >&2; exit 1; }
[[ "$action_taken" == "clean_disk:safelist" ]] || { echo "expected clean_disk action_taken" >&2; exit 1; }
[[ "$action_result" == "success" ]] || { echo "expected clean_disk success result" >&2; exit 1; }
[[ "$description" == *"reclaimed_bytes="* ]] || { echo "expected reclaimed_bytes in description" >&2; exit 1; }
[[ "$description" == *"before_pct="* ]] || { echo "expected before_pct in description" >&2; exit 1; }
[[ "$description" == *"after_pct="* ]] || { echo "expected after_pct in description" >&2; exit 1; }

echo "actions_disk_cleanup_test: PASS"
