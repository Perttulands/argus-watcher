#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
HOME_DIR="$TEST_ROOT/home"
mkdir -p "$HOME_DIR"

assert_source_ok() {
    if ! env -i HOME="$HOME_DIR" PATH="$PATH" bash -c "source '$SCRIPT_DIR/actions.sh'" >/dev/null 2>"$TEST_ROOT/ok.err"; then
        echo "expected actions.sh to source successfully with defaults" >&2
        cat "$TEST_ROOT/ok.err" >&2
        exit 1
    fi
}

assert_invalid_env() {
    local var_name="$1"
    local value="$2"
    local stderr_file="$TEST_ROOT/${var_name}.err"

    if env -i HOME="$HOME_DIR" PATH="$PATH" "${var_name}=${value}" bash -c "source '$SCRIPT_DIR/actions.sh'" >/dev/null 2>"$stderr_file"; then
        echo "expected source to fail for ${var_name}=${value}" >&2
        exit 1
    fi

    if ! grep -q "$var_name" "$stderr_file"; then
        echo "expected error output to reference ${var_name}" >&2
        cat "$stderr_file" >&2
        exit 1
    fi
}

assert_source_ok
assert_invalid_env "ARGUS_RELAY_TIMEOUT" "0"
assert_invalid_env "ARGUS_BEAD_REPEAT_THRESHOLD" "bad"
assert_invalid_env "ARGUS_BEAD_REPEAT_WINDOW_SECONDS" "9999999"
assert_invalid_env "ARGUS_DEDUP_WINDOW" "0"
assert_invalid_env "ARGUS_DEDUP_RETENTION_SECONDS" "oops"
assert_invalid_env "ARGUS_DISK_CLEAN_MAX_AGE_DAYS" "x"
assert_invalid_env "ARGUS_RESTART_BACKOFF_SECOND_DELAY" "-1"
assert_invalid_env "ARGUS_RESTART_BACKOFF_THIRD_DELAY" "0"
assert_invalid_env "ARGUS_RESTART_COOLDOWN_SECONDS" "200000"

echo "actions_int_env_validation_test: PASS"
