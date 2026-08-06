#!/usr/bin/env bash
#
# firewall-audit.sh
# Verify current firewall rules match expected configuration.
# Run with: sudo bash firewall-audit.sh
#
# Exit code 0 = all checks passed, 1 = one or more failed.
# Suitable for cron jobs and CI pipelines.
#
# Examples:
#   sudo bash firewall-audit.sh
#   sudo bash firewall-audit.sh --verbose

set -euo pipefail

# --- Configuration ---
# Expected rules to verify
# Format: description|port|protocol|source (source is optional, "any" if omitted)
EXPECTED_RULES=(
    "SSH access|22|tcp|any"
    "WireGuard VPN|51820|udp|any"
    "Samba SMB from LAN|445|tcp|192.168"
    "Samba NetBIOS from LAN|139|tcp|192.168"
    "Samba SMB from VPN|445|tcp|10.0.0"
    "Samba NetBIOS from VPN|139|tcp|10.0.0"
)

VERBOSE=false

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
info()  { echo -e "${GREEN}[OK]${NC} $1"; }

# --- Usage ---
usage() {
    cat <<EOF
Usage: sudo bash $0 [options]

Verifies that firewall rules match the expected configuration for a
WireGuard + Samba server.

Options:
  --verbose     Show the full firewall rule output
  --help        Show this help message

Exit Codes:
  0    All expected rules are present
  1    One or more expected rules are missing

Examples:
  sudo bash $0
  sudo bash $0 --verbose
EOF
    exit 0
}

# --- Parse Arguments ---
for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=true ;;
        --help|-h) usage ;;
        *) error "Unknown option: $arg"; usage ;;
    esac
done

# --- Checks ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

echo ""
echo "=== Firewall Audit ==="
echo ""

# --- Detect Firewall Type ---
FIREWALL_TYPE=""
RULES_OUTPUT=""

if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    FIREWALL_TYPE="ufw"
    RULES_OUTPUT=$(ufw status verbose 2>/dev/null)
    info "Detected active firewall: UFW"
elif command -v iptables > /dev/null 2>&1; then
    FIREWALL_TYPE="iptables"
    RULES_OUTPUT=$(iptables -L -n 2>/dev/null)
    info "Detected active firewall: iptables"
else
    error "No supported firewall found (checked ufw and iptables)"
    exit 1
fi

# --- Check Default Policy ---
echo ""
echo "=== Default Policy ==="
echo ""

if [[ "$FIREWALL_TYPE" == "ufw" ]]; then
    if echo "$RULES_OUTPUT" | grep -q "Default: deny (incoming)"; then
        pass "Default incoming policy: DENY"
    else
        fail "Default incoming policy is NOT deny"
    fi
elif [[ "$FIREWALL_TYPE" == "iptables" ]]; then
    local_policy=$(iptables -L INPUT -n 2>/dev/null | head -1)
    if echo "$local_policy" | grep -q "DROP\|REJECT"; then
        pass "Default INPUT policy: DROP"
    else
        fail "Default INPUT policy is NOT DROP (got: $local_policy)"
    fi
fi

# --- Show Full Rules (verbose) ---
if $VERBOSE; then
    echo ""
    echo "=== Full Firewall Rules ==="
    echo ""
    echo "$RULES_OUTPUT"
fi

# --- Check Expected Rules ---
echo ""
echo "=== Expected Rules Check ==="
echo ""

TOTAL=0
PASSED=0
FAILED=0

for entry in "${EXPECTED_RULES[@]}"; do
    IFS='|' read -r desc port proto source <<< "$entry"
    TOTAL=$((TOTAL + 1))

    found=false

    if [[ "$FIREWALL_TYPE" == "ufw" ]]; then
        # Check UFW output for the port
        if [[ "$source" == "any" ]]; then
            if echo "$RULES_OUTPUT" | grep -q "${port}/${proto}\|${port}"; then
                found=true
            fi
        else
            if echo "$RULES_OUTPUT" | grep -q "${port}" && echo "$RULES_OUTPUT" | grep -q "${source}"; then
                found=true
            fi
        fi
    elif [[ "$FIREWALL_TYPE" == "iptables" ]]; then
        # Check iptables output for the port and source
        if [[ "$source" == "any" ]]; then
            if echo "$RULES_OUTPUT" | grep -q "dpt:${port}"; then
                found=true
            fi
        else
            if echo "$RULES_OUTPUT" | grep "${source}" 2>/dev/null | grep -q "dpt:${port}"; then
                found=true
            fi
        fi
    fi

    if $found; then
        pass "$desc (port ${port}/${proto} from ${source})"
        PASSED=$((PASSED + 1))
    else
        fail "$desc (port ${port}/${proto} from ${source}) — RULE NOT FOUND"
        FAILED=$((FAILED + 1))
    fi
done

# --- Check for WireGuard Forwarding ---
echo ""
echo "=== VPN Forwarding ==="
echo ""

if [[ "$FIREWALL_TYPE" == "iptables" ]]; then
    forward_rules=$(iptables -L FORWARD -n 2>/dev/null)
    if echo "$forward_rules" | grep -q "wg0"; then
        pass "WireGuard forwarding rules present (wg0)"
    else
        fail "No WireGuard forwarding rules found for wg0"
        FAILED=$((FAILED + 1))
    fi
    TOTAL=$((TOTAL + 1))
elif [[ "$FIREWALL_TYPE" == "ufw" ]]; then
    # UFW handles forwarding differently (via /etc/ufw/before.rules)
    warn "UFW detected — check /etc/ufw/before.rules for VPN forwarding"
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "  Firewall: $FIREWALL_TYPE"
echo "  Total:    $TOTAL"
echo -e "  Passed:   ${GREEN}${PASSED}${NC}"
echo -e "  Failed:   ${RED}${FAILED}${NC}"
echo ""

if [[ $FAILED -gt 0 ]]; then
    error "Audit FAILED — $FAILED rule(s) missing or misconfigured."
    exit 1
else
    info "Audit PASSED — all expected rules are present."
    exit 0
fi