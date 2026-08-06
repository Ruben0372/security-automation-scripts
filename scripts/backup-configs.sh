#!/usr/bin/env bash
#
# backup-configs.sh
# Backup critical configuration files with timestamps and rotation.
# Run with: sudo bash backup-configs.sh [options]
#
# Suitable for cron: sudo bash backup-configs.sh --quiet
#
# Examples:
#   sudo bash backup-configs.sh
#   sudo bash backup-configs.sh --dest /mnt/backups --keep 14
#   sudo bash backup-configs.sh --quiet

set -euo pipefail

# --- Configuration ---
BACKUP_DEST="${BACKUP_DEST:-/root/config-backups}"
KEEP_COUNT="${KEEP_COUNT:-7}"
QUIET=false

# Files to backup (add or remove as needed)
BACKUP_FILES=(
    "/etc/samba/smb.conf"
    "/etc/wireguard/wg0.conf"
    "/etc/fstab"
    "/etc/ssh/sshd_config"
)

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { $QUIET || echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { $QUIET || echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Usage ---
usage() {
    cat <<EOF
Usage: sudo bash $0 [options]

Backs up critical configuration files to a timestamped directory
with automatic rotation of old backups.

Options:
  --dest <path>     Backup destination directory (default: /root/config-backups)
  --keep <N>        Number of backups to keep (default: 7)
  --quiet           Suppress output (for cron)
  --help            Show this help message

Environment Variables:
  BACKUP_DEST       Backup destination (default: /root/config-backups)
  KEEP_COUNT        Backups to retain (default: 7)

Files Backed Up:
  /etc/samba/smb.conf
  /etc/wireguard/wg0.conf
  /etc/fstab
  /etc/ssh/sshd_config

Examples:
  sudo bash $0
  sudo bash $0 --dest /mnt/backups --keep 14
  sudo bash $0 --quiet

Cron Example (daily at 2am):
  0 2 * * * /usr/bin/bash /path/to/backup-configs.sh --quiet
EOF
    exit 0
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)  BACKUP_DEST="$2"; shift 2 ;;
        --keep)  KEEP_COUNT="$2"; shift 2 ;;
        --quiet) QUIET=true; shift ;;
        --help|-h) usage ;;
        *) error "Unknown option: $1"; usage ;;
    esac
done

# --- Checks ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

# --- Create Backup ---
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
BACKUP_DIR="${BACKUP_DEST}/${TIMESTAMP}"

$QUIET || echo ""
$QUIET || echo "=== Configuration Backup ==="
$QUIET || echo "  Destination: $BACKUP_DIR"
$QUIET || echo "  Keep last:   $KEEP_COUNT backups"
$QUIET || echo ""

mkdir -p "$BACKUP_DIR"

BACKED_UP=0
SKIPPED=0

for file in "${BACKUP_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        # Preserve directory structure in backup
        local_dir="${BACKUP_DIR}$(dirname "$file")"
        mkdir -p "$local_dir"
        cp -p "$file" "$local_dir/"
        info "Backed up: $file"
        BACKED_UP=$((BACKED_UP + 1))
    else
        warn "Skipped (not found): $file"
        SKIPPED=$((SKIPPED + 1))
    fi
done

# --- Create Manifest ---
{
    echo "Backup Manifest"
    echo "==============="
    echo "Date:     $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Hostname: $(hostname)"
    echo ""
    echo "Files:"
    find "$BACKUP_DIR" -type f -not -name "manifest.txt" | sort | while read -r f; do
        echo "  $f ($(stat -c '%a %U:%G' "$f" 2>/dev/null || stat -f '%A %Su:%Sg' "$f"))"
    done
} > "${BACKUP_DIR}/manifest.txt"

info "Created manifest: ${BACKUP_DIR}/manifest.txt"

# --- Rotate Old Backups ---
$QUIET || echo ""
$QUIET || echo "=== Rotating Old Backups ==="

# Count existing backups (directories only)
BACKUP_COUNT=$(find "$BACKUP_DEST" -mindepth 1 -maxdepth 1 -type d | wc -l)

if (( BACKUP_COUNT > KEEP_COUNT )); then
    # Remove oldest backups beyond the keep count
    REMOVE_COUNT=$((BACKUP_COUNT - KEEP_COUNT))
    find "$BACKUP_DEST" -mindepth 1 -maxdepth 1 -type d | sort | head -n "$REMOVE_COUNT" | while read -r old_backup; do
        rm -rf "$old_backup"
        info "Removed old backup: $old_backup"
    done
else
    info "No rotation needed ($BACKUP_COUNT of $KEEP_COUNT slots used)"
fi

# --- Summary ---
$QUIET || echo ""
$QUIET || echo "=== Summary ==="
$QUIET || echo "  Backed up: $BACKED_UP file(s)"
$QUIET || echo "  Skipped:   $SKIPPED file(s)"
$QUIET || echo "  Location:  $BACKUP_DIR"
$QUIET || echo ""
info "Backup complete."