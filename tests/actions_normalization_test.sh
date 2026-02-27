#!/usr/bin/env bash
set -euo pipefail

# actions_normalization_test.sh — tests for normalize_* and infer_* functions

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

# shellcheck disable=SC1091
source "$SCRIPT_DIR/actions.sh"

assert_eq() {
    local got="$1"
    local want="$2"
    local label="$3"
    if [[ "$got" != "$want" ]]; then
        echo "ASSERTION FAILED: $label (got '$got', want '$want')" >&2
        exit 1
    fi
}

# --- normalize_problem_type ---
assert_eq "$(normalize_problem_type "disk")" "disk" "normalize_problem_type: disk"
assert_eq "$(normalize_problem_type "memory")" "memory" "normalize_problem_type: memory"
assert_eq "$(normalize_problem_type "service")" "service" "normalize_problem_type: service"
assert_eq "$(normalize_problem_type "process")" "process" "normalize_problem_type: process"
assert_eq "$(normalize_problem_type "swap")" "swap" "normalize_problem_type: swap"
assert_eq "$(normalize_problem_type "bogus")" "process" "normalize_problem_type: unknown defaults to process"
assert_eq "$(normalize_problem_type "")" "process" "normalize_problem_type: empty defaults to process"
assert_eq "$(normalize_problem_type "DISK")" "process" "normalize_problem_type: uppercase not matched"

# --- normalize_problem_severity ---
assert_eq "$(normalize_problem_severity "critical")" "critical" "normalize_problem_severity: critical"
assert_eq "$(normalize_problem_severity "warning")" "warning" "normalize_problem_severity: warning"
assert_eq "$(normalize_problem_severity "info")" "info" "normalize_problem_severity: info"
assert_eq "$(normalize_problem_severity "bogus")" "info" "normalize_problem_severity: unknown defaults to info"
assert_eq "$(normalize_problem_severity "")" "info" "normalize_problem_severity: empty defaults to info"
assert_eq "$(normalize_problem_severity "CRITICAL")" "info" "normalize_problem_severity: uppercase not matched"

# --- infer_problem_type ---
assert_eq "$(infer_problem_type "Disk usage above 90%")" "disk" "infer_problem_type: disk keyword"
assert_eq "$(infer_problem_type "Low space on /tmp")" "disk" "infer_problem_type: space keyword"
assert_eq "$(infer_problem_type "/tmp cleanup needed")" "disk" "infer_problem_type: tmp keyword"
assert_eq "$(infer_problem_type "Cache directory growing")" "disk" "infer_problem_type: cache keyword"
assert_eq "$(infer_problem_type "Memory pressure high")" "memory" "infer_problem_type: memory keyword"
assert_eq "$(infer_problem_type "OOM killer triggered")" "memory" "infer_problem_type: oom keyword"
assert_eq "$(infer_problem_type "RSS limit exceeded")" "memory" "infer_problem_type: rss keyword"
assert_eq "$(infer_problem_type "Swap usage critical")" "swap" "infer_problem_type: swap keyword"
assert_eq "$(infer_problem_type "Thrashing detected")" "swap" "infer_problem_type: thrash keyword"
assert_eq "$(infer_problem_type "Service openclaw-gateway down")" "service" "infer_problem_type: service keyword"
assert_eq "$(infer_problem_type "Need to restart systemctl unit")" "service" "infer_problem_type: restart keyword"
assert_eq "$(infer_problem_type "Gateway not responding")" "service" "infer_problem_type: gateway keyword"
assert_eq "$(infer_problem_type "Some random observation")" "process" "infer_problem_type: unknown defaults to process"
assert_eq "$(infer_problem_type "")" "process" "infer_problem_type: empty defaults to process"

# --- infer_problem_severity ---
assert_eq "$(infer_problem_severity "Service CRITICAL")" "critical" "infer_problem_severity: critical keyword"
assert_eq "$(infer_problem_severity "Health check failed")" "critical" "infer_problem_severity: fail keyword"
assert_eq "$(infer_problem_severity "Gateway is down")" "critical" "infer_problem_severity: down keyword"
assert_eq "$(infer_problem_severity "Host unreachable")" "critical" "infer_problem_severity: unreachable keyword"
assert_eq "$(infer_problem_severity "Connection error detected")" "critical" "infer_problem_severity: error keyword"
assert_eq "$(infer_problem_severity "Memory warning threshold")" "warning" "infer_problem_severity: warn keyword"
assert_eq "$(infer_problem_severity "High CPU usage")" "warning" "infer_problem_severity: high keyword"
assert_eq "$(infer_problem_severity "All systems normal")" "info" "infer_problem_severity: no keywords defaults to info"
assert_eq "$(infer_problem_severity "")" "info" "infer_problem_severity: empty defaults to info"

# --- is_kill_allowlisted_process ---
is_kill_allowlisted_process "node" || { echo "FAIL: node should be allowlisted" >&2; exit 1; }
is_kill_allowlisted_process "claude" || { echo "FAIL: claude should be allowlisted" >&2; exit 1; }
is_kill_allowlisted_process "codex" || { echo "FAIL: codex should be allowlisted" >&2; exit 1; }
! is_kill_allowlisted_process "bash" || { echo "FAIL: bash should not be allowlisted" >&2; exit 1; }
! is_kill_allowlisted_process "" || { echo "FAIL: empty should not be allowlisted" >&2; exit 1; }
! is_kill_allowlisted_process "python" || { echo "FAIL: python should not be allowlisted" >&2; exit 1; }

# --- generate_problem_key ---
key1=$(generate_problem_key "disk" "Disk usage above 90%")
key2=$(generate_problem_key "disk" "Disk usage above 90%")
assert_eq "$key1" "$key2" "generate_problem_key: deterministic for same input"

key3=$(generate_problem_key "disk" "Different description")
[[ "$key1" != "$key3" ]] || { echo "FAIL: different descriptions should produce different keys" >&2; exit 1; }

# Key should start with normalized type
[[ "$key1" == disk:* ]] || { echo "FAIL: key should start with 'disk:'" >&2; exit 1; }

# Unknown type gets normalized
key4=$(generate_problem_key "bogus" "test")
[[ "$key4" == process:* ]] || { echo "FAIL: bogus type should normalize to process:" >&2; exit 1; }

# --- action_has_automatic_remediation ---
action_has_automatic_remediation "restart_service" || { echo "FAIL: restart_service should have remediation" >&2; exit 1; }
action_has_automatic_remediation "kill_pid" || { echo "FAIL: kill_pid should have remediation" >&2; exit 1; }
action_has_automatic_remediation "kill_tmux" || { echo "FAIL: kill_tmux should have remediation" >&2; exit 1; }
action_has_automatic_remediation "clean_disk" || { echo "FAIL: clean_disk should have remediation" >&2; exit 1; }
! action_has_automatic_remediation "alert" || { echo "FAIL: alert should not have remediation" >&2; exit 1; }
! action_has_automatic_remediation "log" || { echo "FAIL: log should not have remediation" >&2; exit 1; }
! action_has_automatic_remediation "unknown" || { echo "FAIL: unknown should not have remediation" >&2; exit 1; }

echo "actions_normalization_test: PASS"
