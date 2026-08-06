#!/usr/bin/env bash
#
# samba-user-manager.sh
# Automate Samba user lifecycle: add, remove, enable, disable, list.
# Run with: sudo bash samba-user-manager.sh <command> [options]
#
# Examples:
#   sudo bash samba-user-manager.sh add alice standard
#   sudo bash samba-user-manager.sh remove alice
#   sudo bash samba-user-manager.sh list

set -euo pipefail

# --- Configuration ---
VALID_TIERS=("admin" "standard" "guest")
DRY_RUN=false

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
dry()   { echo -e "${CYAN}[DRY-RUN]${NC} $1"; }

# --- Usage ---
usage() {
    cat <<EOF
Usage: sudo bash $0 <command> [options]

Commands:
  add <username> <tier>     Create a Linux user, assign to Samba group, add to Samba DB
  remove <username>         Remove user from Samba and groups (optionally delete Linux user)
  enable <username>         Enable a disabled Samba user
  disable <username>        Disable a Samba user (prevent login without deleting)
  list                      List all Samba users with group membership

Tiers: admin, standard, guest

Options:
  --dry-run                 Show what would be done without making changes
  --help                    Show this help message

Examples:
  sudo bash $0 add alice standard
  sudo bash $0 add bob admin --dry-run
  sudo bash $0 remove alice
  sudo bash $0 list
EOF
    exit 0
}

# --- Helpers ---
tier_to_groups() {
    local tier="$1"
    case "$tier" in
        admin)    echo "samba-admins samba-standard" ;;
        standard) echo "samba-standard" ;;
        guest)    echo "samba-guests" ;;
    esac
}

tier_to_shell() {
    local tier="$1"
    case "$tier" in
        admin) echo "/bin/bash" ;;
        *)     echo "/bin/nologin" ;;
    esac
}

validate_tier() {
    local tier="$1"
    for valid in "${VALID_TIERS[@]}"; do
        [[ "$tier" == "$valid" ]] && return 0
    done
    error "Invalid tier '$tier'. Valid tiers: ${VALID_TIERS[*]}"
    exit 1
}

# --- Commands ---
cmd_add() {
    local username="$1"
    local tier="$2"

    validate_tier "$tier"

    local groups
    groups=$(tier_to_groups "$tier")
    local shell
    shell=$(tier_to_shell "$tier")

    echo ""
    echo "=== Adding Samba User: $username (tier: $tier) ==="

    # Create Linux user if needed
    if id "$username" > /dev/null 2>&1; then
        warn "Linux user '$username' already exists"
    else
        if $DRY_RUN; then
            dry "Would create Linux user '$username' with shell $shell"
        else
            useradd -m -s "$shell" "$username"
            info "Created Linux user '$username' (shell: $shell)"
        fi
    fi

    # Add to groups
    for group in $groups; do
        if ! getent group "$group" > /dev/null 2>&1; then
            error "Group '$group' does not exist. Create it first."
            exit 1
        fi
        if $DRY_RUN; then
            dry "Would add '$username' to group '$group'"
        else
            usermod -aG "$group" "$username"
            info "Added '$username' to group '$group'"
        fi
    done

    # Add to Samba database
    if pdbedit -L 2>/dev/null | grep -q "^${username}:"; then
        warn "Samba user '$username' already exists in database"
    else
        if $DRY_RUN; then
            dry "Would add '$username' to Samba database"
            dry "Would enable Samba user '$username'"
        else
            echo "--- Set Samba password for: $username ---"
            smbpasswd -a "$username"
            smbpasswd -e "$username"
            info "Added and enabled Samba user '$username'"
        fi
    fi

    echo ""
    info "User '$username' setup complete (tier: $tier)."
}

cmd_remove() {
    local username="$1"

    echo ""
    echo "=== Removing Samba User: $username ==="

    # Remove from Samba database
    if pdbedit -L 2>/dev/null | grep -q "^${username}:"; then
        if $DRY_RUN; then
            dry "Would remove '$username' from Samba database"
        else
            smbpasswd -x "$username"
            info "Removed '$username' from Samba database"
        fi
    else
        warn "Samba user '$username' not found in database"
    fi

    # Remove from Samba groups
    for group in samba-admins samba-standard samba-guests; do
        if id -nG "$username" 2>/dev/null | grep -qw "$group"; then
            if $DRY_RUN; then
                dry "Would remove '$username' from group '$group'"
            else
                gpasswd -d "$username" "$group" 2>/dev/null || true
                info "Removed '$username' from group '$group'"
            fi
        fi
    done

    echo ""
    info "Samba access removed for '$username'."
    echo "  To also delete the Linux user: sudo userdel -r $username"
}

cmd_enable() {
    local username="$1"

    echo ""
    if ! pdbedit -L 2>/dev/null | grep -q "^${username}:"; then
        error "Samba user '$username' not found in database"
        exit 1
    fi

    if $DRY_RUN; then
        dry "Would enable Samba user '$username'"
    else
        smbpasswd -e "$username"
        info "Enabled Samba user '$username'"
    fi
}

cmd_disable() {
    local username="$1"

    echo ""
    if ! pdbedit -L 2>/dev/null | grep -q "^${username}:"; then
        error "Samba user '$username' not found in database"
        exit 1
    fi

    if $DRY_RUN; then
        dry "Would disable Samba user '$username'"
    else
        smbpasswd -d "$username"
        info "Disabled Samba user '$username'"
    fi
}

cmd_list() {
    echo ""
    echo "=== Samba Users ==="
    echo ""

    if ! command -v pdbedit > /dev/null 2>&1; then
        error "pdbedit not found. Is Samba installed?"
        exit 1
    fi

    printf "%-20s %-40s\n" "USERNAME" "GROUPS"
    printf "%-20s %-40s\n" "--------------------" "----------------------------------------"

    while IFS=: read -r username _ _; do
        local groups
        groups=$(id -nG "$username" 2>/dev/null | tr ' ' '\n' | grep "^samba-" | tr '\n' ', ' | sed 's/,$//')
        if [[ -z "$groups" ]]; then
            groups="(none)"
        fi
        printf "%-20s %-40s\n" "$username" "$groups"
    done < <(pdbedit -L 2>/dev/null)

    echo ""
}

# --- Main ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

# Parse global flags
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --help|-h) usage ;;
        *) ARGS+=("$arg") ;;
    esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
    usage
fi

COMMAND="${ARGS[0]}"

case "$COMMAND" in
    add)
        if [[ ${#ARGS[@]} -lt 3 ]]; then
            error "Usage: $0 add <username> <tier>"
            echo "  Tiers: admin, standard, guest"
            exit 1
        fi
        cmd_add "${ARGS[1]}" "${ARGS[2]}"
        ;;
    remove)
        if [[ ${#ARGS[@]} -lt 2 ]]; then
            error "Usage: $0 remove <username>"
            exit 1
        fi
        cmd_remove "${ARGS[1]}"
        ;;
    enable)
        if [[ ${#ARGS[@]} -lt 2 ]]; then
            error "Usage: $0 enable <username>"
            exit 1
        fi
        cmd_enable "${ARGS[1]}"
        ;;
    disable)
        if [[ ${#ARGS[@]} -lt 2 ]]; then
            error "Usage: $0 disable <username>"
            exit 1
        fi
        cmd_disable "${ARGS[1]}"
        ;;
    list)
        cmd_list
        ;;
    *)
        error "Unknown command: $COMMAND"
        echo "  Valid commands: add, remove, enable, disable, list"
        echo "  Run '$0 --help' for usage."
        exit 1
        ;;
esac