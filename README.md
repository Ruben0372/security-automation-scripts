# Security Automation Scripts

A set of Bash scripts that automate routine security operations on a home-lab Linux file server: Samba user lifecycle management, WireGuard VPN client provisioning, permission drift auditing, log-based detection, firewall verification, and configuration backups. Each script replaces a manual, error-prone sequence of commands with a single repeatable, auditable operation. They are written in strict-mode Bash with no runtime dependencies beyond the tools they wrap, they print human-readable reports, and the audit scripts return meaningful exit codes so they can be scheduled from cron or a systemd timer and alert on failure.

## What it does

- **Samba user management.** Creates and removes users across three access tiers (admin, standard, guest), handling the Linux account, the group assignment, and the Samba password database in one step. Users can be disabled and re-enabled without deleting them, and a `list` command shows every Samba user with their group membership.
- **WireGuard client provisioning.** Generates a keypair, picks the next free IP by parsing the existing peer list, writes a ready-to-use client config, appends the peer to the server config, and reloads the interface live with `wg syncconf` so existing clients are not dropped. Optionally emits a QR code for importing on mobile.
- **Permission drift auditing.** Compares the actual owner, group, and mode of each shared directory against a declared baseline and reports every mismatch. Permission drift is normally silent, a stray `chmod` or a missing setgid bit goes unnoticed until someone is locked out or a file is exposed to the wrong tier.
- **Log-based detection and monitoring.** Parses Samba and SSH logs for failed authentication attempts over a configurable window, aggregates them by source IP, and flags any address that crosses a failure threshold.
- **Firewall verification.** Checks that the expected rules for a WireGuard and Samba host are actually present, catching rules that were dropped by a flush, a reboot, or a manual change.
- **Configuration backups.** Copies the critical config files to a timestamped directory and rotates old backups, so there is always a known-good copy to fall back on before a change.

## Quick Start

```bash
git clone https://github.com/Ruben0372/security-automation-scripts.git
cd security-automation-scripts

# Every script documents itself
bash scripts/permission-auditor.sh --help

# Preview a change without applying it
sudo bash scripts/samba-user-manager.sh add alice standard --dry-run

# Audit permissions against your own share root
SHARE_ROOT=/srv/samba sudo -E bash scripts/permission-auditor.sh

# Look for failed logins in the last hour
sudo bash scripts/log-monitor.sh --hours 1 --threshold 3
```

Most scripts need root because they touch `/etc` and the Samba and WireGuard databases. Start with `--help` on any script, and use `--dry-run` where it is offered before running anything that mutates state.

## Script Reference

### scripts/samba-user-manager.sh

Manages the full Samba user lifecycle: the Linux account, the tier group, and the Samba password database, which normally means running `useradd`, `usermod`, and `smbpasswd` by hand and keeping them consistent.

```bash
sudo bash scripts/samba-user-manager.sh add <username> <admin|standard|guest>
sudo bash scripts/samba-user-manager.sh remove <username>
sudo bash scripts/samba-user-manager.sh disable <username>
sudo bash scripts/samba-user-manager.sh enable <username>
sudo bash scripts/samba-user-manager.sh list
```

Supports `--dry-run` to print the intended actions without applying them.

### scripts/vpn-client-manager.sh

Adds, removes, and lists WireGuard peers. IP assignment is derived from the existing `AllowedIPs` entries in the server config, so no separate state file is needed and collisions are avoided. Peers are tagged with a name comment so `list` and `remove` can identify them.

```bash
sudo bash scripts/vpn-client-manager.sh add laptop
sudo bash scripts/vpn-client-manager.sh add phone --qr
sudo bash scripts/vpn-client-manager.sh remove laptop
sudo bash scripts/vpn-client-manager.sh list
```

Configurable via `WG_DIR`, `WG_INTERFACE`, `SERVER_ENDPOINT`, `CLIENT_DNS`, and `VPN_SUBNET`. Set `SERVER_ENDPOINT` to your own host and port before generating client configs. The `--qr` flag requires `qrencode`.

### scripts/permission-auditor.sh

Audits directories against a baseline of `path|owner|group|mode` entries. Exits 0 when everything matches and 1 when any check fails, which makes it usable as a cron job or a CI step.

```bash
sudo bash scripts/permission-auditor.sh
sudo bash scripts/permission-auditor.sh /path/to/custom-baseline.txt
SHARE_ROOT=/mnt/storage sudo -E bash scripts/permission-auditor.sh
```

The built-in baseline covers the three share tiers under `SHARE_ROOT`, which defaults to `/srv/samba`. Point `SHARE_ROOT` at your own layout, or pass a baseline file to audit an arbitrary directory tree.

### scripts/log-monitor.sh

Scans Samba and SSH logs for failed authentication attempts, groups them by source IP, and marks addresses that exceed the threshold.

```bash
sudo bash scripts/log-monitor.sh
sudo bash scripts/log-monitor.sh --hours 1 --threshold 3
sudo bash scripts/log-monitor.sh --output /tmp/security-alerts.log
```

Configurable via `SAMBA_LOG_DIR`, `AUTH_LOG`, `HOURS`, and `THRESHOLD`.

### scripts/firewall-audit.sh

Verifies that the expected firewall rules for a WireGuard and Samba host are present. Exits 0 when all expected rules are found and 1 when any are missing.

```bash
sudo bash scripts/firewall-audit.sh
sudo bash scripts/firewall-audit.sh --verbose
```

### scripts/backup-configs.sh

Backs up `smb.conf`, `wg0.conf`, `fstab`, and `sshd_config` into a timestamped directory, then prunes old backups beyond the retention count.

```bash
sudo bash scripts/backup-configs.sh
sudo bash scripts/backup-configs.sh --dest /mnt/backups --keep 14
sudo bash scripts/backup-configs.sh --quiet   # for cron
```

Configurable via `BACKUP_DEST` and `KEEP_COUNT`. The file list is defined near the top of the script; edit it to match what you actually run.

## Requirements

- Bash 4 or newer, and a Linux host. The scripts were developed and used on Arch Linux and should work on any modern distribution.
- Root access, since the scripts read and write `/etc` and the Samba and WireGuard state.
- `samba` (`smbpasswd`, `pdbedit`) for the user management script.
- `wireguard-tools` (`wg`, `wg-quick`) for the VPN script, plus `qrencode` if you want QR output.
- `ufw` or `iptables` for the firewall audit.
- Samba and SSH writing to readable log files for the log monitor.

Scripts that depend on a tool check for it and fail with a clear message rather than half-completing an operation.

## Testing

```bash
sudo bash tests/test-permission-auditor.sh
```

The test builds a throwaway directory tree in `mktemp -d`, runs the auditor against generated baselines covering passing, failing, and mixed cases, and cleans up afterward. It does not touch any real share.

## Documentation

| Doc | Description |
|-----|-------------|
| [Script Usage Guide](docs/script-usage-guide.md) | Full syntax, options, and sample output for every script |
| [Design Decisions](docs/design-decisions.md) | The problem each script solves and the reasoning behind its design |

## Safety and Scope

This is home-lab tooling, not a hardened product. Read it with that in mind:

- **Review before running.** These scripts run as root and modify system configuration, user accounts, and VPN state. Read the script and run `--help` first. Use `--dry-run` where it is available.
- **Run at your own risk.** There is no warranty. Test on a machine you can afford to break before pointing any of this at something you care about.
- **The defaults are examples, not your environment.** Share paths, log locations, VPN subnet, server endpoint, and the firewall rule expectations are defaults from one specific setup. Override them through the documented environment variables or edit the configuration block at the top of each script.
- **Detection is best-effort.** The log monitor does simple pattern matching over log files. It is a lightweight tripwire, not an IDS, and it will not catch an attacker who avoids failed authentication.
- **Handle generated keys carefully.** The VPN script writes private keys to disk and embeds them in client configs, which is what mobile WireGuard clients require. Keep those files root-only and do not commit them. The `.gitignore` excludes `*.key`, `*.pem`, `.env`, and credential files, but that is a safety net, not a substitute for care.
- **No multi-user access control.** The scripts assume a single trusted administrator with root. There is no approval workflow, no audit trail beyond what the scripts print, and no protection against a careless operator.

## Related Projects

Part of a three-part home-lab security series:

1. [secure-remote-access-lab](https://github.com/Ruben0372/secure-remote-access-lab), covering VPN, SSH hardening, and firewall configuration
2. [secure-file-services-access-control](https://github.com/Ruben0372/secure-file-services-access-control), covering the Samba file server and its tiered access control
3. **security-automation-scripts** (this repo), the scripts that automate operating the above

## License

MIT. See [LICENSE](LICENSE).
