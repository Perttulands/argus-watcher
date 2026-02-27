#!/usr/bin/env bash
set -euo pipefail

# Test collect_processes from collectors.sh
# Mocks pgrep, ps, tmux for deterministic process output.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# Mock pgrep: simulate 2 orphan node --test processes
cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-cf" ]]; then
    echo "2"
elif [[ "${1:-}" == "-f" ]]; then
    echo "12345"
    echo "12346"
fi
EOF
chmod +x "$FAKE_BIN/pgrep"

# Mock ps for oldest process age lookup
cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
echo "  02:30:00"
EOF
chmod +x "$FAKE_BIN/ps"

# Mock tmux: simulate sessions
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
# Check for -S (socket) flag
for arg in "$@"; do
    if [[ "$arg" == "list-sessions" ]]; then
        echo "session1: 1 windows (created Thu Feb 27 12:00:00 2026)"
        echo "session2: 2 windows (created Thu Feb 27 13:00:00 2026)"
        exit 0
    fi
done
echo "session1: 1 windows"
echo "session2: 2 windows"
EOF
chmod +x "$FAKE_BIN/tmux"

# Mock wc to avoid pipe issues — real wc will work with the mock tmux
# Use real wc since tmux mock outputs 2 lines

# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"

output=$(collect_processes)

# Verify header
[[ "$output" == *"=== Processes ==="* ]] || { echo "FAIL: missing header" >&2; exit 1; }

# Verify orphan count
[[ "$output" == *"Count: 2"* ]] || { echo "FAIL: orphan count should be 2" >&2; exit 1; }

# Verify oldest process age is shown
[[ "$output" == *"Oldest process age: 02:30:00"* ]] || { echo "FAIL: oldest age not shown" >&2; exit 1; }

# Verify tmux session count on openclaw socket
[[ "$output" == *"Tmux sessions on openclaw socket:"* ]] || { echo "FAIL: tmux header missing" >&2; exit 1; }

echo "collectors_processes_test: PASS"
