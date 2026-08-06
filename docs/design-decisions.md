# Design Decisions

Why each script was built, what manual process it replaces, and the design choices behind the implementation.

## Shared Design Principles

Every script in this repository follows the same core principles:

| Principle | Implementation |
|-----------|---------------|
| **Strict mode** | `set -euo pipefail` — exit on error, undefined variables, or pipe failures |
| **Root validation** | Check `$EUID` before running privileged operations |
| **Colored output** | `info()`, `warn()`, `error()` helpers for clear visual feedback |
| **Idempotency** | Check state before modifying — skip gracefully if already done |
| **Exit codes** | 0 = success, 1 = failure, suitable for cron, CI, and automation |
| **Parameterization** | Key values configurable via arguments or environment variables |

---

## samba-user-manager.sh

### Problem It Solves

Adding a Samba user requires 4-5 separate commands across two systems (Linux and Samba), with tier-specific logic for group assignment and shell access. Doing this manually is slow, error-prone (wrong group, wrong shell, forgotten `smbpasswd -e`), and hard to audit.

### What It Replaces

```bash
# Manual process for adding a standard user:
sudo useradd -m -s /bin/nologin alice
sudo usermod -aG samba-standard alice
sudo smbpasswd -a alice
sudo smbpasswd -e alice
```

The script consolidates this into one command with tier-aware logic, validation, and a `--dry-run` mode to preview changes.

### Key Decisions

- **Tier-based group mapping**: Admins are added to both `samba-admins` and `samba-standard` (matching the permission model in the file services repo). Standard and guest users only get their respective group.
- **Shell restriction**: Admin users get `/bin/bash`, all others get `/bin/nologin` to prevent SSH access.
- **Dry-run mode**: Critical for production use; allows previewing exactly what would happen before making changes.
- **No automatic Linux user deletion**: `remove` only removes Samba access. Deleting the Linux user is a separate, destructive action left to the operator.

---

## vpn-client-manager.sh

### Problem It Solves

Adding a WireGuard client requires generating a key pair, choosing the next available IP, editing the server config, creating a client config with the correct server public key and endpoint, and optionally generating a QR code. This is 6+ steps with multiple files to coordinate.

### What It Replaces

```bash
# Manual process:
cd /etc/wireguard
wg genkey | sudo tee client_phone_private.key | wg pubkey | sudo tee client_phone_public.key
sudo chmod 600 client_phone_private.key
# Manually edit wg0.conf to add [Peer] block
# Manually create client config file
# Manually figure out the next available IP
sudo wg syncconf wg0 <(wg-quick strip wg0)
```

### Key Decisions

- **Automatic IP assignment**: Parses existing `AllowedIPs` in the server config to find the highest assigned IP and increments it. Prevents IP collisions without maintaining a separate state file.
- **PrivateKey in client config**: Client configs embed the private key directly (using `PrivateKey =`) instead of `PostUp` loading, because mobile clients (WireGuard app) don't support `PostUp`.
- **Live reload**: Uses `wg syncconf` to apply changes without restarting the WireGuard interface, avoiding brief connectivity drops for existing clients.
- **Comment-based peer naming**: Each peer in the server config is preceded by a `# client-name` comment. This is used by both `list` and `remove` to identify peers without maintaining a separate database.

---

## permission-auditor.sh

### Problem It Solves

Permission drift happens silently — a user runs `chmod` or `chown` on a shared directory, or a file is created with wrong group ownership because setgid wasn't set. Without regular auditing, these changes go unnoticed until someone gets locked out.

### What It Replaces

```bash
# Manual process:
ls -ld /srv/samba/admin-vault    # Check owner, group, mode
ls -ld /srv/samba/shared
ls -ld /srv/samba/media
# Visually compare each one against expected values
```

### Key Decisions

- **Embedded default baseline**: The Samba share directories are built into the script as the default baseline, so it works out of the box with no configuration needed.
- **Custom baseline support**: For flexibility, a custom baseline file can be passed as an argument. This supports auditing arbitrary directory structures.
- **Exit code for automation**: Exit 0 on pass, 1 on fail: designed to be run from cron with alerting on non-zero exit.
- **Cross-platform stat**: Uses Linux `stat -c` with macOS `stat -f` fallback for compatibility.

---

## log-monitor.sh

### Problem It Solves

Security-relevant events (failed SSH logins, failed Samba authentication) are buried in log files that nobody reads until after an incident. Automated monitoring catches brute-force attempts and suspicious patterns early.

### What It Replaces

```bash
# Manual process:
sudo grep "Failed" /var/log/auth.log | tail -20
sudo grep -rhi "failed" /var/log/samba/ | tail -20
# Manually count IPs and look for patterns
```

### Key Decisions

- **Configurable threshold**: Default of 5 failures per IP catches real attacks while ignoring one-off typos. Adjustable via `--threshold`.
- **Dual log source**: Checks both SSH (`/var/log/auth.log` or `journalctl`) and Samba logs, since both are authentication vectors on this server.
- **IP extraction via regex**: Uses `grep -oP` to extract IPs from varied log formats, then counts occurrences per IP.
- **Optional file output**: `--output` appends to a file for persistent alerting, while still printing to stdout for interactive use.

---

## firewall-audit.sh

### Problem It Solves

Firewall rules can be accidentally flushed, overwritten by system updates, or modified without realizing the security implications. Regular auditing confirms that the expected rules are in place.

### What It Replaces

```bash
# Manual process:
sudo ufw status verbose       # or: sudo iptables -L -n
# Visually scan output for expected rules
# Easy to miss a missing rule in a long list
```

### Key Decisions

- **Auto-detect firewall type**: Checks for UFW first (since it's the recommended option in the docs), falls back to iptables. Supports both without user configuration.
- **Expected rules as code**: The baseline is defined as an array in the script, making it easy to version-control and review changes.
- **Default policy check**: Verifies the default incoming policy is DENY/DROP — the most critical firewall setting.
- **Exit code for automation**: Same pattern as permission-auditor — exit 0/1 for use in cron and CI.

---

## backup-configs.sh

### Problem It Solves

Before making changes to critical configs (`smb.conf`, `wg0.conf`, `sshd_config`, `fstab`), you should back them up. But manual backups are inconsistent, often forgotten, and don't get cleaned up.

### What It Replaces

```bash
# Manual process:
sudo cp /etc/samba/smb.conf ~/smb.conf.bak
sudo cp /etc/wireguard/wg0.conf ~/wg0.conf.bak
# No timestamps, no rotation, no verification
```

### Key Decisions

- **Timestamped directories**: Each backup is a complete snapshot in a `YYYYMMDD-HHMMSS` directory, making it easy to find a specific point in time.
- **Preserved permissions**: Uses `cp -p` so restored configs have the correct ownership and mode.
- **Automatic rotation**: Keeps the last N backups (default 7) and removes older ones, preventing unbounded disk usage.
- **Manifest file**: Each backup includes a `manifest.txt` listing all files with their permissions, so you can verify backup integrity without extracting.
- **Quiet mode**: `--quiet` suppresses all output for clean cron execution. Errors still print to stderr.
- **Missing file tolerance**: If a config file doesn't exist (e.g., WireGuard isn't installed yet), it's skipped with a warning rather than failing the entire backup.