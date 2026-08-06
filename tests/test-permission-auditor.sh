#!/usr/bin/env bash
#
# test-permission-auditor.sh
# Basic tests for permission-auditor.sh
# Run with: sudo bash tests/test-permission-auditor.sh
#
# Creates a temporary directory structure, runs the auditor, and verifies results.

set -euo pipefail

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

# --- Setup ---
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDITOR="${SCRIPT_DIR}/scripts/permission-auditor.sh"
TEST_DIR=$(mktemp -d)
BASELINE_FILE=$(mktemp)
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
    rm -rf "$TEST_DIR" "$BASELINE_FILE"
}
trap cleanup EXIT

echo ""
echo "=== Permission Auditor Tests ==="
echo "  Test directory: $TEST_DIR"
echo "  Auditor script: $AUDITOR"
echo ""

if [[ ! -f "$AUDITOR" ]]; then
    fail "Auditor script not found at $AUDITOR"
    exit 1
fi

# --- Create Test Structure ---
mkdir -p "$TEST_DIR/dir-correct"
mkdir -p "$TEST_DIR/dir-wrong-mode"
mkdir -p "$TEST_DIR/dir-wrong-owner"

chown root:root "$TEST_DIR/dir-correct"
chmod 2770 "$TEST_DIR/dir-correct"

chown root:root "$TEST_DIR/dir-wrong-mode"
chmod 755 "$TEST_DIR/dir-wrong-mode"

chown nobody:root "$TEST_DIR/dir-wrong-owner"
chmod 2770 "$TEST_DIR/dir-wrong-owner"

# --- Test 1: All permissions correct ---
echo "--- Test 1: All permissions match baseline ---"
TESTS_RUN=$((TESTS_RUN + 1))

cat > "$BASELINE_FILE" <<EOF
${TEST_DIR}/dir-correct|root|root|2770
EOF

if bash "$AUDITOR" "$BASELINE_FILE" > /dev/null 2>&1; then
    pass "Auditor exits 0 when permissions match"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    fail "Auditor should exit 0 when permissions match"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# --- Test 2: Wrong mode detected ---
echo "--- Test 2: Wrong mode is detected ---"
TESTS_RUN=$((TESTS_RUN + 1))

cat > "$BASELINE_FILE" <<EOF
${TEST_DIR}/dir-wrong-mode|root|root|2770
EOF

if bash "$AUDITOR" "$BASELINE_FILE" > /dev/null 2>&1; then
    fail "Auditor should exit 1 when mode is wrong (expected 2770, actual 755)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    pass "Auditor exits 1 when mode doesn't match"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# --- Test 3: Wrong owner detected ---
echo "--- Test 3: Wrong owner is detected ---"
TESTS_RUN=$((TESTS_RUN + 1))

cat > "$BASELINE_FILE" <<EOF
${TEST_DIR}/dir-wrong-owner|root|root|2770
EOF

if bash "$AUDITOR" "$BASELINE_FILE" > /dev/null 2>&1; then
    fail "Auditor should exit 1 when owner is wrong (expected root, actual nobody)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    pass "Auditor exits 1 when owner doesn't match"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# --- Test 4: Missing path detected ---
echo "--- Test 4: Missing path is detected ---"
TESTS_RUN=$((TESTS_RUN + 1))

cat > "$BASELINE_FILE" <<EOF
${TEST_DIR}/nonexistent-dir|root|root|2770
EOF

if bash "$AUDITOR" "$BASELINE_FILE" > /dev/null 2>&1; then
    fail "Auditor should exit 1 when path doesn't exist"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    pass "Auditor exits 1 when path doesn't exist"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# --- Test 5: Mixed results (some pass, some fail) ---
echo "--- Test 5: Mixed pass/fail baseline ---"
TESTS_RUN=$((TESTS_RUN + 1))

cat > "$BASELINE_FILE" <<EOF
${TEST_DIR}/dir-correct|root|root|2770
${TEST_DIR}/dir-wrong-mode|root|root|2770
EOF

if bash "$AUDITOR" "$BASELINE_FILE" > /dev/null 2>&1; then
    fail "Auditor should exit 1 when any check fails"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    pass "Auditor exits 1 when any check fails (even if some pass)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# --- Summary ---
echo ""
echo "=== Test Results ==="
echo "  Total:  $TESTS_RUN"
echo -e "  Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "  Failed: ${RED}${TESTS_FAILED}${NC}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    fail "$TESTS_FAILED test(s) failed."
    exit 1
else
    pass "All tests passed."
    exit 0
fi