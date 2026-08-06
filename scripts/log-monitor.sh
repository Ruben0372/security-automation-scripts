#!/usr/bin/env bash
#
# log-monitor.sh
# Parse Samba and SSH logs for failed authentication attempts.
# Run with: sudo bash log-monitor.sh [options]
#
# Examples:
#   sudo bash log-monitor.sh
#   sudo bash log-monitor.sh --hours 1
#   sudo bash log-monitor.sh --threshold 3 --output /tmp/alerts.log

set -euo pipefail

# --- Configuration ---
HOURS="${HOURS:-24}"
THRESHOLD="${THRESHOLD:-5}"
OUTPUT_FILE=""
SAMBA_LOG_DIR="${SAMBA_LOG_DIR:-/var/log/samba}"
AUTH_LOG="${AUTH_LOG:-/var/log/auth.log}"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
alert() { echo -e "${RED}[ALERT]${NC} $1"; }

# --- Usage ---
usage() {
    cat <<EOF
Usage: sudo bash $0 [options]

Scans Samba and SSH logs for failed authentication attempts and
reports repeat offenders.

Options:
  --hours <N>         Look back N hours (default: 24)
  --threshold <N>     Alert if an IP has more than N failures (default: 5)
  --output <file>     Write alerts to a file
  --help              Show this help message

Environment Variables:
  SAMBA_LOG_DIR       Samba log directory (default: /var/log/samba)
  AUTH_LOG            Auth log path (default: /var/log/auth.log)
  HOURS               Lookback period in hours (default: 24)
  THRESHOLD           Failure threshold for alerts (default: 5)

Examples:
  sudo bash $0
  sudo bash $0 --hours 1 --threshold 3
  sudo bash $0 --output /tmp/security-alerts.log
EOF
    exit 0
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours)    HOURS="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --output)   OUTPUT_FILE="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *)          error "Unknown option: $1"; usage ;;
    esac
done

# --- Checks ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CUTOFF=$(date -d "-${HOURS} hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
         date -v-${HOURS}H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
         echo "")

echo ""
echo "=== Security Log Monitor ==="
echo "  Time range: last $HOURS hour(s)"
echo "  Threshold:  $THRESHOLD failures per IP"
echo "  Scan time:  $TIMESTAMP"
echo ""

ALERT_COUNT=0
REPORT=""

# --- Scan SSH Logs ---
echo "=== SSH Authentication Failures ==="
echo ""

SSH_FAILURES=""
if [[ -f "$AUTH_LOG" ]]; then
    SSH_FAILURES=$(grep -i "failed\|failure\|invalid user" "$AUTH_LOG" 2>/dev/null | tail -500 || true)
elif command -v journalctl > /dev/null 2>&1; then
    SSH_FAILURES=$(journalctl -u sshd --since "${HOURS} hours ago" --no-pager 2>/dev/null | \
                   grep -i "failed\|failure\|invalid user" || true)
else
    warn "No SSH log source found (tried $AUTH_LOG and journalctl)"
fi

if [[ -n "$SSH_FAILURES" ]]; then
    # Extract IPs from failed attempts and count occurrences
    SSH_IP_COUNTS=$(echo "$SSH_FAILURES" | \
        grep -oP '(\d{1,3}\.){3}\d{1,3}' | \
        sort | uniq -c | sort -rn || true)

    if [[ -n "$SSH_IP_COUNTS" ]]; then
        printf "  %-8s %-20s %s\n" "COUNT" "IP ADDRESS" "STATUS"
        printf "  %-8s %-20s %s\n" "--------" "--------------------" "----------"

        while read -r count ip; do
            if (( count >= THRESHOLD )); then
                printf "  %-8s %-20s " "$count" "$ip"
                alert "EXCEEDS THRESHOLD"
                ALERT_COUNT=$((ALERT_COUNT + 1))
                REPORT+="SSH: $ip — $count failures\n"
            else
                printf "  %-8s %-20s " "$count" "$ip"
                info ""
            fi
        done <<< "$SSH_IP_COUNTS"
    else
        info "No failed SSH attempts found"
    fi
else
    info "No failed SSH attempts found"
fi

echo ""

# --- Scan Samba Logs ---
echo "=== Samba Authentication Failures ==="
echo ""

SAMBA_FAILURES=""
if [[ -d "$SAMBA_LOG_DIR" ]]; then
    SAMBA_FAILURES=$(grep -rhi "authentication.*failed\|NT_STATUS_LOGON_FAILURE\|NT_STATUS_ACCESS_DENIED" \
                     "$SAMBA_LOG_DIR"/ 2>/dev/null | tail -500 || true)
else
    warn "Samba log directory not found: $SAMBA_LOG_DIR"
fi

if [[ -n "$SAMBA_FAILURES" ]]; then
    SAMBA_IP_COUNTS=$(echo "$SAMBA_FAILURES" | \
        grep -oP '(\d{1,3}\.){3}\d{1,3}' | \
        sort | uniq -c | sort -rn || true)

    if [[ -n "$SAMBA_IP_COUNTS" ]]; then
        printf "  %-8s %-20s %s\n" "COUNT" "IP ADDRESS" "STATUS"
        printf "  %-8s %-20s %s\n" "--------" "--------------------" "----------"

        while read -r count ip; do
            if (( count >= THRESHOLD )); then
                printf "  %-8s %-20s " "$count" "$ip"
                alert "EXCEEDS THRESHOLD"
                ALERT_COUNT=$((ALERT_COUNT + 1))
                REPORT+="Samba: $ip — $count failures\n"
            else
                printf "  %-8s %-20s " "$count" "$ip"
                info ""
            fi
        done <<< "$SAMBA_IP_COUNTS"
    else
        info "No failed Samba attempts found"
    fi
else
    info "No failed Samba attempts found"
fi

# --- Write Output File ---
if [[ -n "$OUTPUT_FILE" ]] && [[ $ALERT_COUNT -gt 0 ]]; then
    {
        echo "=== Security Alert Report ==="
        echo "Generated: $TIMESTAMP"
        echo "Lookback:  $HOURS hour(s)"
        echo "Threshold: $THRESHOLD"
        echo ""
        echo "Alerts:"
        echo -e "$REPORT"
    } >> "$OUTPUT_FILE"
    info "Alerts written to: $OUTPUT_FILE"
fi

# --- Summary ---
echo ""
echo "=== Summary ==="
echo "  Time range:   last $HOURS hour(s)"
echo "  Threshold:    $THRESHOLD failures per IP"

if [[ $ALERT_COUNT -gt 0 ]]; then
    echo -e "  Alerts:       ${RED}${ALERT_COUNT}${NC}"
    echo ""
    alert "$ALERT_COUNT IP(s) exceeded the failure threshold."
else
    echo -e "  Alerts:       ${GREEN}0${NC}"
    echo ""
    info "No suspicious activity detected."
fi