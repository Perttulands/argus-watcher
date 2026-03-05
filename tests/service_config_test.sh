#!/usr/bin/env bash
set -euo pipefail

# Test that argus.service configuration allows tmux socket access.
# PrivateTmp=true isolates /tmp, hiding the user's tmux socket at
# /tmp/tmux-<UID>/default. Argus needs PrivateTmp=false to see sessions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_FILE="$SCRIPT_DIR/argus.service"

if [[ ! -f "$SERVICE_FILE" ]]; then
    echo "FAIL: argus.service not found at $SERVICE_FILE" >&2
    exit 1
fi

# --- Test 1: PrivateTmp must not be true ---
if grep -qE '^\s*PrivateTmp\s*=\s*true' "$SERVICE_FILE"; then
    echo "FAIL: PrivateTmp=true breaks tmux session counting (socket in /tmp is invisible)" >&2
    exit 1
fi

# --- Test 2: Service runs as polis user ---
if ! grep -qE '^\s*User\s*=\s*polis' "$SERVICE_FILE"; then
    echo "FAIL: Service must run as User=polis to see polis tmux sessions" >&2
    exit 1
fi

echo "service_config_test: PASS"
