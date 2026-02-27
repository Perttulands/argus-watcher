#!/usr/bin/env bash
set -euo pipefail

# Test collect_services from collectors.sh
# Mocks curl to simulate service up/down states.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/collectors.sh"

# --- Test 1: gateway UP (curl returns 200) ---
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "200"
EOF
chmod +x "$FAKE_BIN/curl"

output=$(collect_services)
[[ "$output" == *"=== Services ==="* ]] || { echo "FAIL: missing header" >&2; exit 1; }
[[ "$output" == *"UP"* ]] || { echo "FAIL: expected UP when curl returns 200" >&2; exit 1; }
[[ "$output" == *"HTTP 200"* ]] || { echo "FAIL: expected HTTP 200 in output" >&2; exit 1; }

# --- Test 2: gateway DOWN (curl fails) ---
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 7  # connection refused
EOF
chmod +x "$FAKE_BIN/curl"

output=$(collect_services)
[[ "$output" == *"DOWN"* ]] || { echo "FAIL: expected DOWN when curl fails" >&2; exit 1; }

# --- Test 3: custom port via ARGUS_GATEWAY_PORT ---
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Echo args so test can verify port
echo "200"
EOF
chmod +x "$FAKE_BIN/curl"

export ARGUS_GATEWAY_PORT=9999
output=$(collect_services)
[[ "$output" == *"9999"* ]] || { echo "FAIL: custom port not reflected in output" >&2; exit 1; }
unset ARGUS_GATEWAY_PORT

echo "collectors_services_test: PASS"
