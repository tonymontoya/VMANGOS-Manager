# CLI Reference

Complete command reference for `vmangos-manager`. If you are learning the product, start with the [User Guide](user-guide.md).

---

## 📍 Default Paths

| Path | Location |
|---|---|
| Binary | `/opt/mangos/manager/bin/vmangos-manager` |
| Config | `/opt/mangos/manager/config/manager.conf` |
| DB password file | `/opt/mangos/manager/config/.dbpass` |

---

## 🛠️ Install the CLI

From a source checkout:

```bash
cd manager
make test
sudo make install PREFIX=/opt/mangos/manager
```

Or use the install helper:

```bash
sudo ./manager/install_manager.sh --run-tests
```

To uninstall (preserves `config/`):

```bash
cd manager
sudo make uninstall PREFIX=/opt/mangos/manager
```

---

## 🌐 Global Options

```text
-c, --config FILE      Configuration file path
-f, --format text|json Output format
-v, --verbose          Enable verbose output
-h, --help             Show help
--version              Show version
```

---

## 📋 Command Overview

| Command | Purpose |
|---|---|
| `server` | Start, stop, restart, status of auth/world services |
| `dashboard` | Launch the Textual TUI |
| `logs` | Rotation status, recent events, test config |
| `account` | Create, list, modify GM level, ban, unban, password reset |
| `backup` | Create, list, verify, restore, clean, schedule |
| `schedule` | Honor/restart schedules, list, simulate, cancel |
| `config` | Create, detect, validate, show configuration |
| `update` | Check, inspect, plan, apply core updates |

---

## 🖥️ Dashboard

```bash
/opt/mangos/manager/bin/vmangos-manager dashboard [--refresh SECONDS] [--theme dark|light]
/opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
```

- `--bootstrap` creates the Python venv and installs Textual (one-time).
- Default refresh interval is `2` seconds.
- The dashboard consumes the same JSON surfaces used by the CLI.

---

## 🎮 Server

```bash
/opt/mangos/manager/bin/vmangos-manager server start [--wait] [--timeout SECONDS]
/opt/mangos/manager/bin/vmangos-manager server stop [--graceful|--force] [--timeout SECONDS]
/opt/mangos/manager/bin/vmangos-manager server restart [--timeout SECONDS]
/opt/mangos/manager/bin/vmangos-manager server status [--format text|json] [--watch] [--interval SECONDS]
```

- `start --wait` performs bounded post-start health verification.
- `status --watch` is text-only; default interval is `2`s.
- Status output includes service state, process details, DB connectivity, disk space, player count, host metrics, alerts, and recent events.

---

## 📝 Logs

```bash
/opt/mangos/manager/bin/vmangos-manager logs status [--format text|json]
/opt/mangos/manager/bin/vmangos-manager logs recent [--source all|auth|world] [--window 15m|1h|1d] [--severity all|debug|info|notice|warning|error|critical|alert] [--limit N] [--format text|json]
/opt/mangos/manager/bin/vmangos-manager logs recent [--source ...] [--window ...] [--severity ...] [--limit N] [--watch|--follow] [--interval SECONDS]
/opt/mangos/manager/bin/vmangos-manager logs rotate [--force]
/opt/mangos/manager/bin/vmangos-manager logs test-config
```

- `logs status` checks log-rotation posture and disk headroom.
- `logs recent` queries `journald` for realm sources (`auth`, `world`, or `all`).
- Default recent filters: `source=all`, `window=15m`, `severity=all`, `limit=25`.
- Watch/follow mode re-runs the current filter set every interval (text-only).

---

## ⏰ Schedule

```bash
/opt/mangos/manager/bin/vmangos-manager schedule honor --time 06:00 --daily [--timezone UTC]
/opt/mangos/manager/bin/vmangos-manager schedule restart --time 04:00 --weekly Sun [--timezone UTC] [--announce "Weekly maintenance"] [--warnings 30,15,5,1]
/opt/mangos/manager/bin/vmangos-manager schedule list [--format text|json]
/opt/mangos/manager/bin/vmangos-manager schedule simulate <job-id>
/opt/mangos/manager/bin/vmangos-manager schedule cancel <job-id>
```

- Schedules are stored under the Manager state directory and rendered into `systemd` timer/service units.
- `schedule restart` uses journal-only warnings unless `maintenance.announce_command` is configured.
- `schedule honor` requires `maintenance.honor_command` in `manager.conf`.
- Default restart warnings: `30,15,5,1`.

---

## 👤 Account

```bash
/opt/mangos/manager/bin/vmangos-manager account create <username> [--password-file PATH|--password-env]
/opt/mangos/manager/bin/vmangos-manager account list [--online]
/opt/mangos/manager/bin/vmangos-manager account setgm <username> <0-3>
/opt/mangos/manager/bin/vmangos-manager account ban <username> <duration> --reason "<words>"
/opt/mangos/manager/bin/vmangos-manager account unban <username>
/opt/mangos/manager/bin/vmangos-manager account password <username> [--password-file PATH|--password-env]
```

- Passwords are **never** accepted as positional arguments.
- Supported inputs: interactive prompt, `--password-file`, `--password-env`.
- Usernames are normalized to uppercase to match the VMANGOS auth model.

---

## 💾 Backup

```bash
/opt/mangos/manager/bin/vmangos-manager backup now [--verify]
/opt/mangos/manager/bin/vmangos-manager backup list [--format text|json]
/opt/mangos/manager/bin/vmangos-manager backup verify <file> [--level 1|2]
/opt/mangos/manager/bin/vmangos-manager backup restore <file> [--dry-run]
/opt/mangos/manager/bin/vmangos-manager backup clean [--keep-last N]
/opt/mangos/manager/bin/vmangos-manager backup schedule status [--format text|json]
/opt/mangos/manager/bin/vmangos-manager backup schedule --daily HH:MM
/opt/mangos/manager/bin/vmangos-manager backup schedule --weekly "Sun 04:00"
```

---

## ⚙️ Config

```bash
/opt/mangos/manager/bin/vmangos-manager config create [--path FILE]
/opt/mangos/manager/bin/vmangos-manager config detect [--format text|json]
/opt/mangos/manager/bin/vmangos-manager config validate [--format text|json]
/opt/mangos/manager/bin/vmangos-manager config show [--format text|json]
```

- `config detect` is **read-only**. It inspects install roots, parses `mangosd.conf` / `realmd.conf`, matches `systemd` service names, and prints a proposed `manager.conf` with confidence scoring.
- `config create` generates a default config including `[maintenance]` settings.

---

## 🔄 Update

```bash
/opt/mangos/manager/bin/vmangos-manager update check
/opt/mangos/manager/bin/vmangos-manager --format json update check
/opt/mangos/manager/bin/vmangos-manager update inspect
/opt/mangos/manager/bin/vmangos-manager --format json update inspect
/opt/mangos/manager/bin/vmangos-manager update plan
/opt/mangos/manager/bin/vmangos-manager --format json update plan --include-db
/opt/mangos/manager/bin/vmangos-manager update apply --backup-first
/opt/mangos/manager/bin/vmangos-manager update apply --backup-first --include-db
```

- `update check` prefers the VMANGOS core source tree under `<install_root>/source`; falls back to the current `VMaNGOS-Manager` checkout.
- `update inspect` performs a read-only DB assessment against `auth`, `world`, and `logs`.
- `update plan --include-db` adds migration assessment and fails closed when manual SQL review is needed.
- `update apply` is **non-atomic** and does not promise rollback.
- `update apply` requires `--backup-first` or explicit confirmation of a verified backup.
- `update apply` rejects dirty/divergent source trees.
- `update apply --include-db` only applies supported timestamped files under `sql/migrations`.

---

## 🔥 Common Workflows

**Dashboard:**

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

**Status:**

```bash
sudo /opt/mangos/manager/bin/vmangos-manager server status
sudo /opt/mangos/manager/bin/vmangos-manager server status --watch --interval 2
```

**Account creation:**

```bash
sudo VMANGOS_PASSWORD='ChangeMe7' /opt/mangos/manager/bin/vmangos-manager account create TESTUSER --password-env
```

**Backup with verification:**

```bash
sudo /opt/mangos/manager/bin/vmangos-manager backup now --verify
```

**Recent realm logs:**

```bash
sudo /opt/mangos/manager/bin/vmangos-manager logs recent --source all --window 15m --severity warning --limit 25
sudo /opt/mangos/manager/bin/vmangos-manager logs recent --source world --severity error --watch --interval 2
```

**Update check from a checkout:**

```bash
cd ~/source/VMaNGOS-Manager
./manager/bin/vmangos-manager update check
```
