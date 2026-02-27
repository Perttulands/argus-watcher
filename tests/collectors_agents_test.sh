#!/usr/bin/env bash
set -euo pipefail

# Test collect_agents from collectors.sh
# Mocks tmux for deterministic agent session output.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"

# --- Test 1: tmux with sessions ---
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
# Detect socket mode vs default
socket_mode=false
for arg in "$@"; do
    [[ "$arg" == "-S" ]] && socket_mode=true
done

for arg in "$@"; do
    if [[ "$arg" == "list-sessions" ]]; then
        if $socket_mode; then
            echo "    coding-agent-1"
            exit 0
        fi
        echo "athena (2 windows, created Thu Feb 27 12:00:00 2026)"
        echo "argus (1 windows, created Thu Feb 27 13:00:00 2026)"
        exit 0
    fi
done
echo "athena"
echo "argus"
EOF
chmod +x "$FAKE_BIN/tmux"

# Mock wc — use real wc, it works fine

output=$(collect_agents)

# Verify header
[[ "$output" == *"=== Agents ==="* ]] || { echo "FAIL: missing header" >&2; exit 1; }

# Verify standard tmux count
[[ "$output" == *"Count: 2"* ]] || { echo "FAIL: expected 2 standard sessions" >&2; exit 1; }

# Verify openclaw section
[[ "$output" == *"OpenClaw socket sessions:"* ]] || { echo "FAIL: openclaw header missing" >&2; exit 1; }
[[ "$output" == *"coding-agent-1"* ]] || { echo "FAIL: openclaw session not listed" >&2; exit 1; }

# --- Test 2: no tmux sessions ---
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1  # no server running
EOF
chmod +x "$FAKE_BIN/tmux"

output=$(collect_agents)
[[ "$output" == *"Count: 0"* ]] || { echo "FAIL: expected 0 sessions when tmux unavailable" >&2; exit 1; }
[[ "$output" == *"None"* ]] || { echo "FAIL: expected 'None' for openclaw sessions" >&2; exit 1; }

echo "collectors_agents_test: PASS"
