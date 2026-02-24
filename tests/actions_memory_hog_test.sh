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
  create) echo "athena-memory" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/br"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"

execute_action '{"type":"alert","message":"Memory usage critical at 95%"}'
record=$(tail -n1 "$ARGUS_PROBLEMS_FILE")

type_value=$(echo "$record" | jq -r '.type')
description=$(echo "$record" | jq -r '.description')

[[ "$type_value" == "memory" ]] || { echo "expected memory problem type" >&2; exit 1; }
[[ "$description" == *"hog_pid="* ]] || { echo "expected hog_pid in description" >&2; exit 1; }
[[ "$description" == *"hog_rss_kb="* ]] || { echo "expected hog_rss_kb in description" >&2; exit 1; }
[[ "$description" == *"hog_runtime="* ]] || { echo "expected hog_runtime in description" >&2; exit 1; }

echo "actions_memory_hog_test: PASS"
