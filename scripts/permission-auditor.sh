#!/usr/bin/env bash
#
# permission-auditor.sh
# Audit file/directory permissions against an expected baseline.
# Run with: sudo bash permission-auditor.sh [baseline-file]
#
# Exit code 0 = all checks passed, 1 = one or more failed.
# Suitable for cron jobs and CI pipelines.
#
# Examples:
#   sudo bash permission-auditor.sh                    # Use default Samba baseline
#   sudo bash permission-auditor.sh custom-baseline    # Use custom baseline file

set -euo pipefail

# --- Configuration ---
# Root directory holding the Samba shares. Override for your own layout:
#   SHARE_ROOT=/mnt/storage sudo -E bash permission-auditor.sh
SHARE_ROOT="${SHARE_ROOT:-/srv/samba}"

# Default baseline for Samba share directories
# Format: path|owner|group|mode
DEFAULT_BASELINE=(
    "${SHARE_ROOT}/admin-vault|root|samba-admins|2770"
    "${SHARE_ROOT}/shared|root|samba-standard|2775"
    "${SHARE_ROOT}/media|root|samba-standard|2775"
)

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Usage ---
usage() {
    cat <<EOF
Usage: sudo bash $0 [baseline-file]

Arguments:
  baseline-file    Optional path to a custom baseline file (one entry per line)
                   Format: path|owner|group|mode
                   If not provided, uses the default Samba share baseline.

Baseline Format:
  /path/to/dir|owner|group|mode

  Example:
  /srv/samba/admin-vault|root|samba-admins|2770
  /srv/samba/shared|root|samba-standard|2775

Environment Variables:
  SHARE_ROOT       Root directory of the Samba shares (default: /srv/samba)

Exit Codes:
  0    All checks passed
  1    One or more checks failed

Options:
  --help    Show this help message

Examples:
  sudo bash $0
  sudo bash $0 /path/to/custom-baseline.txt
EOF
    exit 0
}

# --- Main ---
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
fi

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

# Load baseline
BASELINE=()
if [[ -n "${1:-}" ]]; then
    if [[ ! -f "$1" ]]; then
        error "Baseline file not found: $1"
        exit 1
    fi
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        BASELINE+=("$line")
    done < "$1"
    echo "Using custom baseline: $1"
else
    BASELINE=("${DEFAULT_BASELINE[@]}")
    echo "Using default Samba share baseline"
fi

echo ""
echo "=== Permission Audit Report ==="
echo ""

TOTAL=0
PASSED=0
FAILED=0

printf "%-35s %-15s %-15s %-10s %-10s\n" "PATH" "OWNER" "GROUP" "MODE" "STATUS"
printf "%-35s %-15s %-15s %-10s %-10s\n" "-----------------------------------" "---------------" "---------------" "----------" "----------"

for entry in "${BASELINE[@]}"; do
    IFS='|' read -r exp_path exp_owner exp_group exp_mode <<< "$entry"
    TOTAL=$((TOTAL + 1))

    # Check if path exists
    if [[ ! -e "$exp_path" ]]; then
        printf "%-35s %-15s %-15s %-10s " "$exp_path" "-" "-" "-"
        fail "Path does not exist"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Get actual values (Linux stat format, with macOS fallback)
    actual_owner=$(stat -c '%U' "$exp_path" 2>/dev/null || stat -f '%Su' "$exp_path")
    actual_group=$(stat -c '%G' "$exp_path" 2>/dev/null || stat -f '%Sg' "$exp_path")
    actual_mode=$(stat -c '%a' "$exp_path" 2>/dev/null || stat -f '%A' "$exp_path")

    # Compare
    local_failed=false
    details=""

    if [[ "$actual_owner" != "$exp_owner" ]]; then
        local_failed=true
        details+="owner: expected '$exp_owner', got '$actual_owner'. "
    fi

    if [[ "$actual_group" != "$exp_group" ]]; then
        local_failed=true
        details+="group: expected '$exp_group', got '$actual_group'. "
    fi

    if [[ "$actual_mode" != "$exp_mode" ]]; then
        local_failed=true
        details+="mode: expected '$exp_mode', got '$actual_mode'. "
    fi

    if $local_failed; then
        printf "%-35s %-15s %-15s %-10s " "$exp_path" "$actual_owner" "$actual_group" "$actual_mode"
        fail "$details"
        FAILED=$((FAILED + 1))
    else
        printf "%-35s %-15s %-15s %-10s " "$exp_path" "$actual_owner" "$actual_group" "$actual_mode"
        pass ""
        PASSED=$((PASSED + 1))
    fi
done

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "  Total:  $TOTAL"
echo -e "  Passed: ${GREEN}${PASSED}${NC}"
echo -e "  Failed: ${RED}${FAILED}${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    error "Audit FAILED — $FAILED issue(s) found."
    exit 1
else
    echo -e "${GREEN}[OK]${NC} Audit PASSED — all permissions match baseline."
    exit 0
fi