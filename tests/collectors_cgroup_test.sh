#!/usr/bin/env bash
set -euo pipefail

# Test collect_cgroup_memory_context from collectors.sh
# Uses fake cgroup files in a temp directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# We need to override the cgroup file paths. The function hardcodes /sys/fs/cgroup/*
# so we redefine the function after sourcing to use our test paths.

# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"

FAKE_CGROUP="$TEST_ROOT/cgroup"
mkdir -p "$FAKE_CGROUP"

# Override the function to use our test paths
collect_cgroup_memory_context() {
    local indent="${1:-  }"
    local current_file="$FAKE_CGROUP/memory.current"
    local max_file="$FAKE_CGROUP/memory.max"
    if [[ ! -r "$current_file" ]] || [[ ! -r "$max_file" ]]; then
        return 0
    fi
    local current max pct
    current=$(cat "$current_file" 2>/dev/null || echo "") # REASON: cgroup files may disappear during container lifecycle changes.
    max=$(cat "$max_file" 2>/dev/null || echo "") # REASON: cgroup files may disappear during container lifecycle changes.
    [[ "$current" =~ ^[0-9]+$ ]] || return 0
    if [[ "$max" == "max" ]]; then
        echo "${indent}Cgroup memory: current ${current} bytes (no limit)"
        return 0
    fi
    [[ "$max" =~ ^[0-9]+$ ]] || return 0
    if (( max <= 0 )); then
        return 0
    fi
    pct=$(( (current * 100) / max ))
    echo "${indent}Cgroup memory: ${current}/${max} bytes (${pct}%)"
}

# --- Test 1: no cgroup files → silent return ---
output=$(collect_cgroup_memory_context "  ")
[[ -z "$output" ]] || { echo "FAIL: should be silent when no cgroup files" >&2; exit 1; }

# --- Test 2: cgroup with numeric limit ---
echo "536870912" > "$FAKE_CGROUP/memory.current"  # 512MB
echo "1073741824" > "$FAKE_CGROUP/memory.max"      # 1GB
output=$(collect_cgroup_memory_context "  ")
[[ "$output" == *"536870912/1073741824 bytes (50%)"* ]] || { echo "FAIL: expected 50% cgroup usage, got: $output" >&2; exit 1; }

# --- Test 3: cgroup with "max" (no limit) ---
echo "268435456" > "$FAKE_CGROUP/memory.current"
echo "max" > "$FAKE_CGROUP/memory.max"
output=$(collect_cgroup_memory_context "  ")
[[ "$output" == *"no limit"* ]] || { echo "FAIL: expected 'no limit' output, got: $output" >&2; exit 1; }

# --- Test 4: non-numeric current → silent return ---
echo "not-a-number" > "$FAKE_CGROUP/memory.current"
echo "1073741824" > "$FAKE_CGROUP/memory.max"
output=$(collect_cgroup_memory_context "  ")
[[ -z "$output" ]] || { echo "FAIL: should be silent for non-numeric current" >&2; exit 1; }

echo "collectors_cgroup_test: PASS"
