#!/usr/bin/env bash
set -euo pipefail

# actions_cleanup_test.sh — tests for remove_old_entries and remove_old_archives

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

# --- remove_old_entries tests ---

# Test 1: nonexistent directory returns 0
result=$(remove_old_entries "$TEST_ROOT/nonexistent" 7 "execute")
assert_eq "$result" "0" "remove_old_entries: nonexistent dir returns 0"

# Test 2: empty directory returns 0
empty_dir="$TEST_ROOT/empty_dir"
mkdir -p "$empty_dir"
result=$(remove_old_entries "$empty_dir" 7 "execute")
assert_eq "$result" "0" "remove_old_entries: empty dir returns 0"

# Test 3: expired files are removed
expired_dir="$TEST_ROOT/expired_entries"
mkdir -p "$expired_dir"
touch "$expired_dir/old_file_a"
touch "$expired_dir/old_file_b"
touch "$expired_dir/old_file_c"
# Backdate to 10 days ago
touch -d "10 days ago" "$expired_dir/old_file_a"
touch -d "10 days ago" "$expired_dir/old_file_b"
touch -d "10 days ago" "$expired_dir/old_file_c"
result=$(remove_old_entries "$expired_dir" 7 "execute")
assert_eq "$result" "3" "remove_old_entries: 3 expired files removed"
# Verify they are actually gone
remaining=$(find "$expired_dir" -mindepth 1 | wc -l)
assert_eq "$remaining" "0" "remove_old_entries: no files remain after cleanup"

# Test 4: recent files are preserved
mixed_dir="$TEST_ROOT/mixed_entries"
mkdir -p "$mixed_dir"
touch "$mixed_dir/recent_file"
touch "$mixed_dir/old_file"
touch -d "10 days ago" "$mixed_dir/old_file"
result=$(remove_old_entries "$mixed_dir" 7 "execute")
assert_eq "$result" "1" "remove_old_entries: only old file removed"
[[ -f "$mixed_dir/recent_file" ]] || { echo "recent_file should be preserved" >&2; exit 1; }
[[ ! -f "$mixed_dir/old_file" ]] || { echo "old_file should be removed" >&2; exit 1; }

# Test 5: dry-run counts but does not delete
dryrun_dir="$TEST_ROOT/dryrun_entries"
mkdir -p "$dryrun_dir"
touch "$dryrun_dir/file1"
touch "$dryrun_dir/file2"
touch -d "10 days ago" "$dryrun_dir/file1"
touch -d "10 days ago" "$dryrun_dir/file2"
result=$(remove_old_entries "$dryrun_dir" 7 "dry-run")
assert_eq "$result" "2" "remove_old_entries: dry-run counts 2"
[[ -f "$dryrun_dir/file1" ]] || { echo "dry-run should preserve file1" >&2; exit 1; }
[[ -f "$dryrun_dir/file2" ]] || { echo "dry-run should preserve file2" >&2; exit 1; }

# --- remove_old_archives tests ---

# Test 6: nonexistent directory returns 0
result=$(remove_old_archives "$TEST_ROOT/nonexistent" 7 "execute")
assert_eq "$result" "0" "remove_old_archives: nonexistent dir returns 0"

# Test 7: empty directory returns 0
empty_archive_dir="$TEST_ROOT/empty_archives"
mkdir -p "$empty_archive_dir"
result=$(remove_old_archives "$empty_archive_dir" 7 "execute")
assert_eq "$result" "0" "remove_old_archives: empty dir returns 0"

# Test 8: expired archives are removed
archive_dir="$TEST_ROOT/archives"
mkdir -p "$archive_dir"
touch "$archive_dir/app.log.1.gz"
touch "$archive_dir/app.log.2.gz"
touch -d "10 days ago" "$archive_dir/app.log.1.gz"
touch -d "10 days ago" "$archive_dir/app.log.2.gz"
result=$(remove_old_archives "$archive_dir" 7 "execute")
assert_eq "$result" "2" "remove_old_archives: 2 expired archives removed"

# Test 9: recent archives are preserved
mixed_archive_dir="$TEST_ROOT/mixed_archives"
mkdir -p "$mixed_archive_dir"
touch "$mixed_archive_dir/app.log.1.gz"   # recent
touch "$mixed_archive_dir/app.log.2.gz"   # old
touch -d "10 days ago" "$mixed_archive_dir/app.log.2.gz"
result=$(remove_old_archives "$mixed_archive_dir" 7 "execute")
assert_eq "$result" "1" "remove_old_archives: only old archive removed"
[[ -f "$mixed_archive_dir/app.log.1.gz" ]] || { echo "recent archive should be preserved" >&2; exit 1; }

# Test 10: non-archive files are not touched
nonarchive_dir="$TEST_ROOT/nonarchive"
mkdir -p "$nonarchive_dir"
touch "$nonarchive_dir/app.log"
touch "$nonarchive_dir/notes.txt"
touch -d "10 days ago" "$nonarchive_dir/app.log"
touch -d "10 days ago" "$nonarchive_dir/notes.txt"
result=$(remove_old_archives "$nonarchive_dir" 7 "execute")
assert_eq "$result" "0" "remove_old_archives: non-archive files ignored"
[[ -f "$nonarchive_dir/app.log" ]] || { echo "app.log should not be touched" >&2; exit 1; }
[[ -f "$nonarchive_dir/notes.txt" ]] || { echo "notes.txt should not be touched" >&2; exit 1; }

# Test 11: dry-run counts but does not delete archives
dryrun_archive_dir="$TEST_ROOT/dryrun_archives"
mkdir -p "$dryrun_archive_dir"
touch "$dryrun_archive_dir/app.log.1.gz"
touch -d "10 days ago" "$dryrun_archive_dir/app.log.1.gz"
result=$(remove_old_archives "$dryrun_archive_dir" 7 "dry-run")
assert_eq "$result" "1" "remove_old_archives: dry-run counts 1"
[[ -f "$dryrun_archive_dir/app.log.1.gz" ]] || { echo "dry-run should preserve archive" >&2; exit 1; }

echo "actions_cleanup_test: PASS"
