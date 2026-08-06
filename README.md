# Security Automation Scripts

Bash scripts to automate security operations for a Samba file server and WireGuard VPN — user lifecycle management, permission auditing, log monitoring, firewall verification, and configuration backups.

## Script Inventory

| Script | What It Does | What It Automates |
|--------|-------------|-------------------|
| [samba-user-manager.sh](scripts/samba-user-manager.sh) | Add, remove, enable, disable Samba users | Manual `useradd`, `usermod`, `smbpasswd` commands |
| [vpn-client-manager.sh](scripts/vpn-client-manager.sh) | Add, remove, list WireGuard VPN clients | Key generation, config file creation, peer management |
| [permission-auditor.sh](scripts/permission-auditor.sh) | Audit file permissions against expected baseline | Manual `ls -ld` and `stat` checks on every directory |
| [log-monitor.sh](scripts/log-monitor.sh) | Scan logs for failed auth and suspicious activity | Manually reading Samba and SSH log files |
| [firewall-audit.sh](scripts/firewall-audit.sh) | Verify firewall rules match expected configuration | Manual `ufw status` / `iptables -L` review |
| [backup-configs.sh](scripts/backup-configs.sh) | Backup critical configs with timestamp and rotation | Manual `cp` of config files before changes |

## What's Covered

- **Samba user lifecycle** — create, enable, disable, and remove users with proper group assignment across 3 tiers (Admin, Standard, Guest)
- **WireGuard client provisioning** — generate keys, assign IPs, create configs, and optionally generate QR codes for mobile
- **Permission auditing** — detect permission drift by comparing actual file ownership and modes against a defined baseline
- **Log monitoring** — parse Samba and SSH logs for failed authentication attempts and flag repeat offenders
- **Firewall verification** — confirm firewall rules match expected configuration to catch misconfigurations
- **Configuration backups** — automated, timestamped backups of critical config files with rotation

## Real-World Context

These scripts were built to manage a live Arch Linux server running Samba and WireGuard VPN. Each script replaces a manual, error-prone process with a repeatable, auditable automation — reducing the chance of misconfiguration and making routine operations faster.

## Usage Examples

```bash
# Add a new standard-tier Samba user
sudo bash scripts/samba-user-manager.sh add alice standard

# List all Samba users with their group membership
sudo bash scripts/samba-user-manager.sh list

# Add a new VPN client and generate a QR code
sudo bash scripts/vpn-client-manager.sh add phone --qr

# Audit permissions against the default baseline
sudo bash scripts/permission-auditor.sh

# Check for failed SSH/Samba logins in the last hour
sudo bash scripts/log-monitor.sh --hours 1

# Verify firewall rules match expected config
sudo bash scripts/firewall-audit.sh

# Backup all critical configs
sudo bash scripts/backup-configs.sh
```

## Documentation

| Doc | Description |
|-----|-------------|
| [Script Usage Guide](docs/script-usage-guide.md) | Detailed syntax, options, and examples for every script |
| [Design Decisions](docs/design-decisions.md) | Why each script was built and the design choices behind it |

## Technologies

- **Bash** — All scripts written in portable Bash with strict mode (`set -euo pipefail`)
- **Samba** — `smbpasswd`, `pdbedit` for user management
- **WireGuard** — `wg`, `wg-quick`, `wg syncconf` for VPN management
- **iptables / UFW** — Firewall rule inspection
- **cron / systemd timers** — Scheduling for audits and backups

## Related Projects

This repo is part of a 3-part lab security series:

1. [secure-remote-access-lab](https://github.com/Ruben0372/secure-remote-access-lab) — VPN, SSH hardening, firewall configuration
2. [secure-file-services-access-control](https://github.com/Ruben0372/secure-file-services-access-control) — Samba file server with tiered access control
3. **security-automation-scripts** (this repo) — Scripts to automate security operations
