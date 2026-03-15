#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: test_tmux_collector.sh failed at line $LINENO" >&2' ERR

# Test: collect_agents picks up sessions from ARGUS_TMUX_TMPDIR socket dir.
# Validates pol-12nz: tmux collector reports detached claude-* sessions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# Mock tmux: detect socket path to simulate multiple socket dirs
# -S <path> = explicit socket, -L <name> = named server in TMUX_TMPDIR
cat > "$FAKE_BIN/tmux" <<'TMUXMOCK'
#!/usr/bin/env bash
socket_path=""
i=1
while [[ $i -le $# ]]; do
    arg="${!i}"
    if [[ "$arg" == "-S" ]]; then
        i=$((i + 1))
        socket_path="${!i}"
    fi
    i=$((i + 1))
done

for arg in "$@"; do
    if [[ "$arg" == "list-sessions" ]]; then
        if [[ "$socket_path" == *"openclaw"* ]]; then
            echo "    codex-worker-1"
            exit 0
        elif [[ "$socket_path" == *"tmux-socket"* ]] || [[ "$socket_path" == *"/default" && "$socket_path" != *"openclaw"* && -n "$socket_path" ]]; then
            echo "claude-athena: 2 windows (created Sat Mar 15 10:00:00 2026)"
            echo "claude-iris: 1 windows (created Sat Mar 15 11:00:00 2026)"
            exit 0
        else
            # Default socket: no sessions
            exit 1
        fi
    fi
done
exit 0
TMUXMOCK
chmod +x "$FAKE_BIN/tmux"

# Create fake TMUX_TMPDIR so the -d check passes
FAKE_TMUX_TMPDIR="$TEST_ROOT/tmux-socket"
mkdir -p "$FAKE_TMUX_TMPDIR"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"

# Set the custom tmux socket dir to our fake dir
export ARGUS_TMUX_TMPDIR="$FAKE_TMUX_TMPDIR"

output=$(collect_agents)

# --- Test 1: claude-* sessions from custom TMUX_TMPDIR are reported ---
echo "=== Test 1: custom TMUX_TMPDIR sessions detected ==="
if [[ "$output" == *"claude-athena"* ]]; then
    echo "PASS: claude-athena session found"
else
    echo "FAIL: claude-athena session NOT found in output" >&2
    echo "Output was: $output" >&2
    exit 1
fi

if [[ "$output" == *"claude-iris"* ]]; then
    echo "PASS: claude-iris session found"
else
    echo "FAIL: claude-iris session NOT found in output" >&2
    exit 1
fi

# --- Test 2: count includes custom socket sessions ---
echo "=== Test 2: session count includes custom socket ==="
if [[ "$output" == *"Count: 2"* ]] || [[ "$output" == *"Count: 3"* ]]; then
    echo "PASS: session count includes custom socket sessions"
else
    echo "FAIL: session count does not reflect custom socket sessions" >&2
    echo "Output was: $output" >&2
    exit 1
fi

# --- Test 3: openclaw socket sessions still reported ---
echo "=== Test 3: openclaw socket sessions still reported ==="
if [[ "$output" == *"codex-worker-1"* ]]; then
    echo "PASS: openclaw sessions still reported"
else
    echo "FAIL: openclaw sessions missing" >&2
    exit 1
fi

echo ""
echo "test_tmux_collector: ALL PASS"
