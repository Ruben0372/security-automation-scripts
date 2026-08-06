#!/usr/bin/env bash
#
# vpn-client-manager.sh
# Automate WireGuard VPN client provisioning: add, remove, list.
# Run with: sudo bash vpn-client-manager.sh <command> [options]
#
# Examples:
#   sudo bash vpn-client-manager.sh add phone --qr
#   sudo bash vpn-client-manager.sh remove phone
#   sudo bash vpn-client-manager.sh list

set -euo pipefail

# --- Configuration ---
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_CONF="${WG_DIR}/${WG_INTERFACE}.conf"
VPN_SUBNET="${VPN_SUBNET:-10.0.0}"
SERVER_PORT="${SERVER_PORT:-51820}"
SERVER_ENDPOINT="${SERVER_ENDPOINT:-<SERVER-PUBLIC-IP>:${SERVER_PORT}}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"
CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-10.0.0.0/24, 192.168.0.0/16}"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Usage ---
usage() {
    cat <<EOF
Usage: sudo bash $0 <command> [options]

Commands:
  add <client-name> [--qr]   Generate keys, assign IP, create config, add peer
  remove <client-name>       Remove peer from server config and delete key files
  list                       Show all configured peers with their IPs

Options:
  --qr          Generate a QR code for mobile import (requires qrencode)
  --help        Show this help message

Environment Variables:
  WG_DIR             WireGuard config directory (default: /etc/wireguard)
  WG_INTERFACE       WireGuard interface name (default: wg0)
  SERVER_ENDPOINT    Server public IP:port (default: <SERVER-PUBLIC-IP>:51820)
  CLIENT_DNS         DNS for client configs (default: 1.1.1.1)
  VPN_SUBNET         First 3 octets of VPN subnet (default: 10.0.0)

Examples:
  sudo bash $0 add laptop
  sudo bash $0 add phone --qr
  sudo bash $0 remove laptop
  sudo bash $0 list
EOF
    exit 0
}

# --- Helpers ---
get_next_ip() {
    # Find the highest assigned IP in the server config and increment
    local max_ip=1  # Server is .1

    if [[ -f "$WG_CONF" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ AllowedIPs.*${VPN_SUBNET}\.([0-9]+) ]]; then
                local ip_num="${BASH_REMATCH[1]}"
                if (( ip_num > max_ip )); then
                    max_ip=$ip_num
                fi
            fi
        done < "$WG_CONF"
    fi

    local next_ip=$(( max_ip + 1 ))

    if (( next_ip > 254 )); then
        error "No available IPs in ${VPN_SUBNET}.0/24 (all 254 addresses assigned)"
        exit 1
    fi

    echo "$next_ip"
}

get_server_public_key() {
    local key_file="${WG_DIR}/server_public.key"
    if [[ -f "$key_file" ]]; then
        cat "$key_file"
    else
        error "Server public key not found at $key_file"
        echo "  Generate with: wg genkey | sudo tee ${WG_DIR}/server_private.key | wg pubkey | sudo tee ${WG_DIR}/server_public.key"
        exit 1
    fi
}

# --- Commands ---
cmd_add() {
    local client_name="$1"
    local generate_qr="$2"

    local private_key_file="${WG_DIR}/client_${client_name}_private.key"
    local public_key_file="${WG_DIR}/client_${client_name}_public.key"
    local client_conf="${WG_DIR}/client_${client_name}.conf"

    echo ""
    echo "=== Adding VPN Client: $client_name ==="

    # Check if client already exists
    if [[ -f "$private_key_file" ]] || [[ -f "$public_key_file" ]]; then
        error "Client '$client_name' already exists. Remove it first: $0 remove $client_name"
        exit 1
    fi

    if ! [[ -f "$WG_CONF" ]]; then
        error "WireGuard config not found at $WG_CONF"
        exit 1
    fi

    # Generate key pair
    wg genkey | tee "$private_key_file" | wg pubkey > "$public_key_file"
    chmod 600 "$private_key_file"
    info "Generated key pair for '$client_name'"

    local client_public_key
    client_public_key=$(cat "$public_key_file")
    local server_public_key
    server_public_key=$(get_server_public_key)

    # Assign next available IP
    local ip_num
    ip_num=$(get_next_ip)
    local client_ip="${VPN_SUBNET}.${ip_num}"
    info "Assigned IP: ${client_ip}/24"

    # Add peer to server config
    cat >> "$WG_CONF" <<EOF

# ${client_name}
[Peer]
PublicKey = ${client_public_key}
AllowedIPs = ${client_ip}/32
EOF
    info "Added peer to server config ($WG_CONF)"

    # Create client config
    cat > "$client_conf" <<EOF
[Interface]
Address = ${client_ip}/24
DNS = ${CLIENT_DNS}
PrivateKey = $(cat "$private_key_file")

[Peer]
PublicKey = ${server_public_key}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
Endpoint = ${SERVER_ENDPOINT}
PersistentKeepalive = 25
EOF
    chmod 600 "$client_conf"
    info "Created client config: $client_conf"

    # Reload WireGuard
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
        info "Reloaded WireGuard config (wg syncconf)"
    else
        warn "WireGuard is not running — skipping live reload"
    fi

    # Generate QR code
    if [[ "$generate_qr" == "true" ]]; then
        if command -v qrencode > /dev/null 2>&1; then
            echo ""
            echo "=== QR Code (scan with WireGuard mobile app) ==="
            echo ""
            qrencode -t ansiutf8 < "$client_conf"
        else
            warn "qrencode is not installed. Install with: sudo pacman -S qrencode"
        fi
    fi

    # Summary
    echo ""
    echo "=== Summary ==="
    echo "  Client:     $client_name"
    echo "  IP:         ${client_ip}/24"
    echo "  Config:     $client_conf"
    echo "  Private key: $private_key_file"
    echo "  Public key:  $public_key_file"
    echo ""
    info "VPN client '$client_name' added successfully."
}

cmd_remove() {
    local client_name="$1"

    local private_key_file="${WG_DIR}/client_${client_name}_private.key"
    local public_key_file="${WG_DIR}/client_${client_name}_public.key"
    local client_conf="${WG_DIR}/client_${client_name}.conf"

    echo ""
    echo "=== Removing VPN Client: $client_name ==="

    # Remove peer from server config
    if [[ -f "$WG_CONF" ]] && grep -q "# ${client_name}" "$WG_CONF"; then
        # Remove the comment line, [Peer] block, and following lines until next section or EOF
        local temp_conf
        temp_conf=$(mktemp)
        awk -v name="# ${client_name}" '
            $0 == name { skip=1; next }
            skip && /^\[/ { skip=0 }
            skip && /^$/ { next }
            !skip { print }
        ' "$WG_CONF" > "$temp_conf"
        mv "$temp_conf" "$WG_CONF"
        info "Removed peer from server config"
    else
        warn "Peer '$client_name' not found in server config"
    fi

    # Delete key files and client config
    local removed=false
    for file in "$private_key_file" "$public_key_file" "$client_conf"; do
        if [[ -f "$file" ]]; then
            rm "$file"
            info "Deleted: $file"
            removed=true
        fi
    done

    if ! $removed; then
        warn "No key files or config found for '$client_name'"
    fi

    # Reload WireGuard
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
        wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
        info "Reloaded WireGuard config (wg syncconf)"
    fi

    echo ""
    info "VPN client '$client_name' removed."
}

cmd_list() {
    echo ""
    echo "=== WireGuard Peers ==="
    echo ""

    if ! [[ -f "$WG_CONF" ]]; then
        error "WireGuard config not found at $WG_CONF"
        exit 1
    fi

    printf "%-20s %-20s %-50s\n" "CLIENT" "IP" "PUBLIC KEY"
    printf "%-20s %-20s %-50s\n" "--------------------" "--------------------" "--------------------------------------------------"

    local current_name=""
    local current_key=""
    local current_ip=""

    while IFS= read -r line; do
        # Capture comment lines as client names
        if [[ "$line" =~ ^#\ (.+) ]] && [[ ! "$line" =~ ^#\ === ]]; then
            current_name="${BASH_REMATCH[1]}"
        fi

        if [[ "$line" =~ ^PublicKey\ =\ (.+) ]]; then
            current_key="${BASH_REMATCH[1]}"
        fi

        if [[ "$line" =~ ^AllowedIPs\ =\ (.+)/32 ]]; then
            current_ip="${BASH_REMATCH[1]}"
        fi

        # Print when we have a complete peer
        if [[ -n "$current_key" ]] && [[ -n "$current_ip" ]]; then
            if [[ -z "$current_name" ]]; then
                current_name="(unnamed)"
            fi
            printf "%-20s %-20s %-50s\n" "$current_name" "$current_ip" "$current_key"
            current_name=""
            current_key=""
            current_ip=""
        fi
    done < "$WG_CONF"

    echo ""

    # Show live status if WireGuard is running
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" 2>/dev/null; then
        echo "=== Live Status ==="
        echo ""
        wg show "$WG_INTERFACE"
    fi
}

# --- Main ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)"
    exit 1
fi

# Parse arguments
GENERATE_QR=false
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --qr) GENERATE_QR=true ;;
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
        if [[ ${#ARGS[@]} -lt 2 ]]; then
            error "Usage: $0 add <client-name> [--qr]"
            exit 1
        fi
        cmd_add "${ARGS[1]}" "$GENERATE_QR"
        ;;
    remove)
        if [[ ${#ARGS[@]} -lt 2 ]]; then
            error "Usage: $0 remove <client-name>"
            exit 1
        fi
        cmd_remove "${ARGS[1]}"
        ;;
    list)
        cmd_list
        ;;
    *)
        error "Unknown command: $COMMAND"
        echo "  Valid commands: add, remove, list"
        echo "  Run '$0 --help' for usage."
        exit 1
        ;;
esac