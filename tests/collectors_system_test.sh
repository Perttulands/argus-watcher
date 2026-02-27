#!/usr/bin/env bash
set -euo pipefail

# Test collect_system from collectors.sh
# Mocks free, df, nproc, uptime to produce deterministic output.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# Mock free -m output (60% used)
cat > "$FAKE_BIN/free" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then
    echo "               total        used        free      shared  buff/cache   available"
    echo "Mem:           16000        9600        2400         200        4000        6400"
    echo "Swap:           4000         200        3800"
elif [[ "${1:-}" == "-h" ]]; then
    echo "               total        used        free      shared  buff/cache   available"
    echo "Mem:           15Gi       9.4Gi       2.3Gi       195Mi       3.9Gi       6.3Gi"
    echo "Swap:          3.9Gi       195Mi       3.7Gi"
fi
EOF
chmod +x "$FAKE_BIN/free"

# Mock df
cat > "$FAKE_BIN/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/sda1        50G   30G   20G  60% /"
EOF
chmod +x "$FAKE_BIN/df"

# Mock nproc
cat > "$FAKE_BIN/nproc" <<'EOF'
#!/usr/bin/env bash
echo "4"
EOF
chmod +x "$FAKE_BIN/nproc"

# Mock uptime
cat > "$FAKE_BIN/uptime" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" ]]; then
    echo "up 5 days, 3 hours"
else
    echo " 18:00:00 up 5 days, 3:00, 2 users, load average: 0.50, 0.40, 0.35"
fi
EOF
chmod +x "$FAKE_BIN/uptime"

# Mock ps (not a memory hog, so won't trigger critical path)
cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
echo "  123 bash        0.5  4096 01:00:00"
EOF
chmod +x "$FAKE_BIN/ps"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"

output=$(collect_system)

# Verify section header
[[ "$output" == *"=== System ==="* ]] || { echo "FAIL: missing header" >&2; exit 1; }

# Verify memory parsing
[[ "$output" == *"Used: 9600MB / 16000MB (60%)"* ]] || { echo "FAIL: memory percentage not computed correctly" >&2; exit 1; }
[[ "$output" == *"Available: 6400MB"* ]] || { echo "FAIL: available memory missing" >&2; exit 1; }

# Verify swap
[[ "$output" == *"Swap: 200MB / 4000MB (5%)"* ]] || { echo "FAIL: swap not parsed correctly" >&2; exit 1; }

# Verify disk
[[ "$output" == *"Disk (/):"* ]] || { echo "FAIL: disk header missing" >&2; exit 1; }
[[ "$output" == *"/dev/sda1"* ]] || { echo "FAIL: disk info missing" >&2; exit 1; }

# Verify CPU cores
[[ "$output" == *"CPU cores: 4"* ]] || { echo "FAIL: CPU cores missing" >&2; exit 1; }

# Verify load average
[[ "$output" == *"Load average:"* ]] || { echo "FAIL: load average header missing" >&2; exit 1; }

# Verify uptime
[[ "$output" == *"up 5 days"* ]] || { echo "FAIL: uptime missing" >&2; exit 1; }

# Verify no critical memory pressure (60% < 90%)
[[ "$output" != *"Memory pressure: CRITICAL"* ]] || { echo "FAIL: should not be critical at 60%" >&2; exit 1; }

echo "collectors_system_test: PASS"
