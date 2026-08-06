# Script Usage Guide

Detailed usage instructions for every script in this repository.

## Prerequisites

All scripts require:
- Linux server (tested on Arch Linux)
- Root or sudo access
- Bash 4.0+

Individual scripts may have additional dependencies noted in their sections.

---

## samba-user-manager.sh

Automate the full Samba user lifecycle: create, remove, enable, disable, and list users.

### Prerequisites

- Samba installed (`smbpasswd`, `pdbedit` available)
- Samba groups already created (`samba-admins`, `samba-standard`, `samba-guests`)

### Syntax

```bash
sudo bash scripts/samba-user-manager.sh <command> [options]
```

### Commands

| Command | Arguments | Description |
|---------|-----------|-------------|
| `add` | `<username> <tier>` | Create Linux user, add to group, add to Samba DB |
| `remove` | `<username>` | Remove from Samba and groups |
| `enable` | `<username>` | Enable a disabled Samba user |
| `disable` | `<username>` | Disable without deleting |
| `list` | (none) | Show all Samba users with groups |

Tiers: `admin`, `standard`, `guest`

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Show what would happen without making changes |
| `--help` | Show usage information |

### Examples

```bash
# Add a standard-tier user
sudo bash scripts/samba-user-manager.sh add alice standard

# Preview what adding an admin would do
sudo bash scripts/samba-user-manager.sh add bob admin --dry-run

# List all users with their group membership
sudo bash scripts/samba-user-manager.sh list

# Temporarily disable a user
sudo bash scripts/samba-user-manager.sh disable alice

# Re-enable them later
sudo bash scripts/samba-user-manager.sh enable alice

# Remove a user from Samba (Linux account remains)
sudo bash scripts/samba-user-manager.sh remove alice
```

### Expected Output (add)

```
=== Adding Samba User: alice (tier: standard) ===
[OK] Created Linux user 'alice' (shell: /bin/nologin)
[OK] Added 'alice' to group 'samba-standard'
--- Set Samba password for: alice ---
New SMB password:
Retype new SMB password:
[OK] Added and enabled Samba user 'alice'

[OK] User 'alice' setup complete (tier: standard).
```

---

## vpn-client-manager.sh

Automate WireGuard VPN client provisioning: key generation, IP assignment, config creation, and QR codes.

### Prerequisites

- WireGuard installed and configured (`wg`, `wg-quick`)
- Server keys generated at `/etc/wireguard/server_public.key`
- `qrencode` installed (only for `--qr` option)

### Syntax

```bash
sudo bash scripts/vpn-client-manager.sh <command> [options]
```

### Commands

| Command | Arguments | Description |
|---------|-----------|-------------|
| `add` | `<client-name> [--qr]` | Generate keys, assign IP, create config |
| `remove` | `<client-name>` | Remove peer and delete key files |
| `list` | (none) | Show all configured peers |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WG_DIR` | `/etc/wireguard` | WireGuard config directory |
| `WG_INTERFACE` | `wg0` | WireGuard interface name |
| `SERVER_ENDPOINT` | `<SERVER-PUBLIC-IP>:51820` | Server endpoint for client configs |
| `CLIENT_DNS` | `1.1.1.1` | DNS server for client configs |
| `VPN_SUBNET` | `10.0.0` | First 3 octets of VPN subnet |

### Examples

```bash
# Add a client for a phone with QR code
sudo bash scripts/vpn-client-manager.sh add phone --qr

# Add a client for a laptop
SERVER_ENDPOINT="vpn.example.com:51820" sudo bash scripts/vpn-client-manager.sh add laptop

# List all configured peers
sudo bash scripts/vpn-client-manager.sh list

# Remove a client
sudo bash scripts/vpn-client-manager.sh remove phone
```

### Expected Output (add)

```
=== Adding VPN Client: phone ===
[OK] Generated key pair for 'phone'
[OK] Assigned IP: 10.0.0.2/24
[OK] Added peer to server config (/etc/wireguard/wg0.conf)
[OK] Created client config: /etc/wireguard/client_phone.conf
[OK] Reloaded WireGuard config (wg syncconf)

=== Summary ===
  Client:     phone
  IP:         10.0.0.2/24
  Config:     /etc/wireguard/client_phone.conf
  Private key: /etc/wireguard/client_phone_private.key
  Public key:  /etc/wireguard/client_phone_public.key

[OK] VPN client 'phone' added successfully.
```

---

## permission-auditor.sh

Audit file and directory permissions against an expected baseline. Reports PASS/FAIL for each path.

### Prerequisites

- The directories being audited must exist
- `stat` command available

### Syntax

```bash
sudo bash scripts/permission-auditor.sh [baseline-file]
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `baseline-file` | No | Path to a custom baseline file. Uses default Samba baseline if omitted. |

### Baseline Format

One entry per line: `path|owner|group|mode`

```
/srv/samba/admin-vault|root|samba-admins|2770
/srv/samba/shared|root|samba-standard|2775
/srv/samba/media|root|samba-standard|2775
```

### Examples

```bash
# Audit with default Samba baseline
sudo bash scripts/permission-auditor.sh

# Audit with a custom baseline
sudo bash scripts/permission-auditor.sh /path/to/my-baseline.txt
```

### Expected Output

```
Using default Samba share baseline

=== Permission Audit Report ===

PATH                                OWNER           GROUP           MODE       STATUS
-----------------------------------...
/srv/samba/admin-vault           root            samba-admins    2770         [PASS]
/srv/samba/shared                root            samba-standard  2775         [PASS]
/srv/samba/media                 root            samba-standard  2775         [PASS]

=== Summary ===
  Total:  3
  Passed: 3
  Failed: 0

[OK] Audit PASSED — all permissions match baseline.
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All checks passed |
| 1 | One or more checks failed |

---

## log-monitor.sh

Parse Samba and SSH logs for failed authentication attempts, flagging IPs that exceed a configurable threshold.

### Prerequisites

- Access to `/var/log/auth.log` or `journalctl` (for SSH)
- Access to `/var/log/samba/` (for Samba)

### Syntax

```bash
sudo bash scripts/log-monitor.sh [options]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--hours <N>` | 24 | Look back N hours |
| `--threshold <N>` | 5 | Alert threshold per IP |
| `--output <file>` | (none) | Write alerts to a file |

### Examples

```bash
# Scan last 24 hours with default threshold
sudo bash scripts/log-monitor.sh

# Scan last hour, lower threshold
sudo bash scripts/log-monitor.sh --hours 1 --threshold 3

# Write alerts to a file
sudo bash scripts/log-monitor.sh --output /var/log/security-alerts.log
```

### Expected Output

```
=== Security Log Monitor ===
  Time range: last 24 hour(s)
  Threshold:  5 failures per IP

=== SSH Authentication Failures ===

  COUNT    IP ADDRESS           STATUS
  -------- -------------------- ----------
  12       203.0.113.45           [ALERT] EXCEEDS THRESHOLD
  3        198.51.100.22          [OK]

=== Samba Authentication Failures ===

  [OK] No failed Samba attempts found

=== Summary ===
  Alerts: 1

[ALERT] 1 IP(s) exceeded the failure threshold.
```

---

## firewall-audit.sh

Verify that current firewall rules match the expected configuration for a WireGuard + Samba server.

### Prerequisites

- UFW or iptables active
- Firewall rules already applied

### Syntax

```bash
sudo bash scripts/firewall-audit.sh [options]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--verbose` | off | Show full firewall rule output |

### Examples

```bash
# Run the audit
sudo bash scripts/firewall-audit.sh

# Run with full rule output
sudo bash scripts/firewall-audit.sh --verbose
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All expected rules are present |
| 1 | One or more expected rules are missing |

---

## backup-configs.sh

Backup critical configuration files with timestamps and automatic rotation.

### Prerequisites

- The config files to backup must exist (missing files are skipped with a warning)

### Syntax

```bash
sudo bash scripts/backup-configs.sh [options]
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--dest <path>` | `/root/config-backups` | Backup destination directory |
| `--keep <N>` | 7 | Number of backups to retain |
| `--quiet` | off | Suppress output (for cron) |

### Files Backed Up

- `/etc/samba/smb.conf`
- `/etc/wireguard/wg0.conf`
- `/etc/fstab`
- `/etc/ssh/sshd_config`

### Examples

```bash
# Backup with defaults
sudo bash scripts/backup-configs.sh

# Custom destination, keep 14 backups
sudo bash scripts/backup-configs.sh --dest /mnt/backups --keep 14

# Quiet mode for cron
sudo bash scripts/backup-configs.sh --quiet
```

### Cron Setup

```bash
# Run daily at 2am
0 2 * * * /usr/bin/bash /path/to/scripts/backup-configs.sh --quiet
```

### Backup Structure

```
/root/config-backups/
├── 20260301-020000/
│   ├── etc/samba/smb.conf
│   ├── etc/wireguard/wg0.conf
│   ├── etc/fstab
│   ├── etc/ssh/sshd_config
│   └── manifest.txt
├── 20260302-020000/
│   └── ...
```