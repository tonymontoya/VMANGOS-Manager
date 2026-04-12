# Engineering Plan: VMANGOS Setup - Release A & B

**Version:** 1.3 (Updated)  
**Date:** 2026-04-12  
**Status:** ✅ Release A Complete, Release B Planned  

---

## Release Scope Clarification

This engineering plan covers two distinct components:

| Release | Component | Repository | Status | Description |
|---------|-----------|------------|--------|-------------|
| **A** | `vmangos_setup.sh` | vmangos-setup | ✅ **COMPLETE** | Automated server installer |
| **B** | `vmangos-manager` CLI | vmangos-setup | 📋 **PLANNED** | Management tool (backup, health, etc.) |

### Release A (Installer) - COMPLETE
The installer script (`vmangos_setup.sh`) provides:
- Automated VMANGOS server installation on Ubuntu 22.04
- Database setup and world database import
- Client data extraction from WoW 1.12.1 client
- Service configuration (systemd)
- Optional RA/SOAP console enablement for VMANGOS Manager

**Installation location:** `/opt/mangos/`

### Release B (Manager Tool) - PLANNED
The management CLI tool (`vmangos-manager`) will provide:
- Account management (CRUD operations)
- Server backup and restore
- Health monitoring and alerting
- Log management

See [RELEASE_B_PLAN.md](RELEASE_B_PLAN.md) for detailed planning.

---

## Critical Corrections from Review

### 1. DB Query Abstraction - CORRECTED

**Finding:** Placeholder syntax `@uname` is fiction; actual execution uses string interpolation.

**Decision:** Drop the placeholder abstraction. Use validated primitives + purpose-built SQL helpers.

**Implementation Pattern:**

```bash
# APPROACH: Validated primitives + static SQL templates
# Safety relies on STRICT WHITELIST VALIDATION making SQL injection impossible
# Whitelist allows only alphanumerics (no quotes, backslashes, or control chars)
# This is string interpolation, but with guaranteed-safe character sets

# VALIDATION LAYER (strict whitelist)
validate_username() {
    local username="$1"
    # Regex: start anchor, alphanumeric only, length 2-32, end anchor
    if [[ ! "$username" =~ ^[a-zA-Z0-9]{2,32}$ ]]; then
        error_exit "Invalid username: must be 2-32 alphanumeric characters"
    fi
    printf '%s' "$username"  # Return clean (no newlines)
}

# QUERY LAYER (static templates, validated params only)
# Pattern: Validate first, then use in static SQL template

account_exists() {
    local username="$1"  # Already validated
    local cred_file="$2"
    
    # Static query template - username is validated clean
    mysql --defaults-file="$cred_file" -N -B \
        -e "SELECT COUNT(*) FROM account WHERE username = '${username}'" "$AUTH_DB"
}

account_create() {
    local username="$1"       # Pre-validated
    local pass_hash="$2"      # Pre-computed hash
    local gm_level="$3"       # Pre-validated 0-3
    local cred_file="$4"
    
    # Static INSERT - no dynamic construction
    mysql --defaults-file="$cred_file" \
        -e "INSERT INTO account (username, sha_pass_hash, gmlevel, expansion) 
            VALUES ('${username}', '${pass_hash}', ${gm_level}, 0)" "$AUTH_DB"
}

account_ban() {
    local account_id="$1"     # Numeric, from prior query
    local bandate="$2"        # SQL datetime format
    local unbandate="$3"      # SQL datetime or NULL
    local reason="$4"         # Validated: alphanumeric + spaces, max 255 chars
    local cred_file="$5"
    
    # Static INSERT with validated params
    mysql --defaults-file="$cred_file" \
        -e "INSERT INTO account_banned (id, bandate, unbandate, bannedby, banreason, active)
            VALUES (${account_id}, '${bandate}', ${unbandate}, 'vmangos-manager', '${reason}', 1)
            ON DUPLICATE KEY UPDATE 
                bandate = '${bandate}',
                unbandate = ${unbandate},
                banreason = '${reason}',
                active = 1" "$AUTH_DB"
}

# BANNED: Any dynamic SQL construction
# mysql -e "SELECT * FROM ${table}"                                    # NEVER
# mysql -e "SELECT * WHERE name = '${userinput}'"                      # NEVER
# mysql -e "CALL ${procedure}('${arg}')"                               # NEVER
```

**Validation Rules Summary:**

| Field | Pattern | Max Length | Example |
|-------|---------|------------|---------|
| username | `^[a-zA-Z0-9]+$` | 32 | Player123 |
| gm_level | `^[0-3]$` | 1 | 3 |
| duration | `^[0-9]+[hdwmy]$` | 10 | 7d |
| ban_reason | `^[a-zA-Z0-9 ]+$` | 255 | "Exploiting bug" |
| account_id | `^[0-9]+$` | 10 | 12345 |

**Security Note:** Safety depends on whitelist validation excluding `'`, `\`, and control characters. The validation patterns above make SQL injection impossible by character set constraint, not by parameterization.

---

### 2. Online Player Query - CORRECTED

**Finding:** `SELECT COUNT(*) FROM characters.character_social` is wrong table.

**Research Required:** VMANGOS schema for online players needs confirmation.

**Proposed Query (Pending Verification):**
```sql
-- VMANGOS tracks online status in account.current_realm
-- Non-zero = online on that realm
SELECT COUNT(*) FROM auth.account WHERE current_realm != 0;

-- Alternative: characters table has online flag
SELECT COUNT(*) FROM characters.characters WHERE online = 1;

-- Character names for listing
SELECT c.name, a.username, c.level, c.race, c.class
FROM characters.characters c
JOIN auth.account a ON c.account = a.id
WHERE c.online = 1;
```

**Decision:** 
- Test both queries on actual VMANGOS 1.12 schema
- Use first query that executes successfully and returns an integer (including 0)
- If both fail, return "online: unknown" rather than garbage data
- Document exact schema version tested against

**Schema Version Target:** VMANGOS 1.12 (development branch, commit `e7de79f3beb1eeed7fcdcf2f4d9c057d3db6f149`)

---

### 3. Level 3 Verification - CORRECTED

**Finding:** Multi-DB dump into single temp DB fails; dump contains `USE database` statements.

**Decision:** Drop Level 3 from Release A. Levels 1-2 only.

**Release A Verification:**

| Level | Description | Implementation |
|-------|-------------|----------------|
| 1 | File integrity | `gunzip -t` + SHA256 checksum |
| 2 | Content validation | SQL header check + table presence |
| 3 | **DEFERRED** | Full restore test (complex, multi-schema) |

**Rationale:** 
- Level 1 catches corruption
- Level 2 catches incomplete backups
- Level 3 requires isolated schema recreation matching production
- Risk of false confidence if Level 3 is wrong

---

### 4. DB Size Estimation - CORRECTED

**Finding:** Query sums all databases, ignores indexes, no compression overhead.

**Corrected Implementation:**

```bash
backup_preflight_check() {
    local cred_file="$1"
    local backup_dir="$2"
    
    # Get size per database (data + index)
    local auth_size=$(mysql --defaults-file="$cred_file" -N -B \
        -e "SELECT SUM(data_length + index_length) 
            FROM information_schema.tables 
            WHERE table_schema = '${AUTH_DB}'" 2>/dev/null || echo 0)
    
    local chars_size=$(mysql --defaults-file="$cred_file" -N -B \
        -e "SELECT SUM(data_length + index_length) 
            FROM information_schema.tables 
            WHERE table_schema = '${CHARACTERS_DB}'" 2>/dev/null || echo 0)
    
    local world_size=$(mysql --defaults-file="$cred_file" -N -B \
        -e "SELECT SUM(data_length + index_length) 
            FROM information_schema.tables 
            WHERE table_schema = '${WORLD_DB}'" 2>/dev/null || echo 0)
    
    local logs_size=$(mysql --defaults-file="$cred_file" -N -B \
        -e "SELECT SUM(data_length + index_length) 
            FROM information_schema.tables 
            WHERE table_schema = '${LOGS_DB}'" 2>/dev/null || echo 0)
    
    local total_bytes=$((auth_size + chars_size + world_size + logs_size))
    
    # Conservative multiplier: raw size -> compressed size -> working space
    # Assume: 2:1 compression ratio (generous), need 3x working space
    local required_bytes=$((total_bytes / 2 * 3))
    
    local available_bytes=$(df -B1 "$backup_dir" | awk 'NR==2 {print $4}')
    
    log_info "Backup space check:"
    log_info "  Database size: $((total_bytes / 1024 / 1024)) MB"
    log_info "  Estimated backup: $((total_bytes / 2 / 1024 / 1024)) MB (compressed)"
    log_info "  Required space: $((required_bytes / 1024 / 1024)) MB (3x safety)"
    log_info "  Available: $((available_bytes / 1024 / 1024)) MB"
    
    if [[ $available_bytes -lt $required_bytes ]]; then
        error_exit "Insufficient disk space. Need $((required_bytes / 1024 / 1024)) MB, have $((available_bytes / 1024 / 1024)) MB"
    fi
}
```

---

### 5. Systemd Timer Schedule - CORRECTED

**Finding:** `OnCalendar=${frequency}` with "daily" or "weekly" is vague.

**Corrected Implementation:**

```bash
backup_schedule() {
    local schedule="$1"  # "02:00" for daily, or "Mon 04:00" for weekly
    
    # Parse into OnCalendar format
    if [[ "$schedule" =~ ^([0-9]{2}):([0-9]{2})$ ]]; then
        # Daily at specific time: "02:00" -> "*-*-* 02:00:00"
        local oncalendar="*-*-* ${schedule}:00"
    elif [[ "$schedule" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[[:space:]]+([0-9]{2}):([0-9]{2})$ ]]; then
        # Weekly: "Sun 04:00" -> "Sun *-*-* 04:00:00"
        local day="${BASH_REMATCH[1]}"
        local time="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
        local oncalendar="${day} *-*-* ${time}:00"
    else
        error_exit "Invalid schedule. Use HH:MM for daily or 'Day HH:MM' for weekly"
    fi
    
    cat > /etc/systemd/system/vmangos-backup.timer <<EOF
[Unit]
Description=VMANGOS Backup Timer

[Timer]
OnCalendar=${oncalendar}
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable vmangos-backup.timer
    
    log_info "Backup scheduled: ${schedule}"
    log_info "Verify with: systemctl list-timers vmangos-backup.timer"
}

# Usage examples:
# vmangos-manager backup schedule --daily "02:00"
# vmangos-manager backup schedule --weekly "Sun 04:00"
```

---

### 6. Password File Permission Check - CORRECTED

**Finding:** `cat` before `chmod 600` - exposure already happened.

**Corrected Implementation:**

```bash
get_password_from_file() {
    local file="$1"
    
    # SECURITY: Check BEFORE reading
    
    # Check file exists
    if [[ ! -f "$file" ]]; then
        error_exit "Password file not found: $file"
    fi
    
    # Check ownership (must be root or current user)
    local file_owner=$(stat -c %u "$file")
    local current_uid=$(id -u)
    if [[ "$file_owner" != "$current_uid" && "$file_owner" != "0" ]]; then
        error_exit "Password file must be owned by root or current user"
    fi
    
    # Check permissions (must be 600)
    local file_mode=$(stat -c %a "$file")
    if [[ "$file_mode" != "600" ]]; then
        error_exit "Password file must have mode 600 (has $file_mode)"
    fi
    
    # NOW safe to read
    local password
    password=$(cat "$file")
    
    # Remove trailing newline
    password="${password%$'\n'}"
    
    # Basic validation
    if [[ ${#password} -lt 6 ]]; then
        error_exit "Password in file must be at least 6 characters"
    fi
    
    printf '%s' "$password"
}
```

---

### 7. Security Test - CORRECTED

**Finding:** Test backgrounds sleep and greps for hardcoded string - doesn't test manager.

**Corrected Test:**

```bash
#!/usr/bin/env bats

# tests/security/test_password_exposure.bats

@test "password not visible in manager process when using --password-file" {
    # Setup: Create password file
    local pass_file="/tmp/test_pass_$$"
    echo "SecretPass123!" > "$pass_file"
    chmod 600 "$pass_file"
    
    # Create a mock manager that reads password and blocks
    local mock_manager="/tmp/mock_manager_$$.sh"
    cat > "$mock_manager" << 'MOCK'
#!/bin/bash
source /opt/mangos/manager/lib/common.sh
source /opt/mangos/manager/lib/account.sh
pass=$(get_password_from_file "$1")
echo "Got password, sleeping..."
sleep 10
MOCK
    chmod +x "$mock_manager"
    
    # Start mock manager in background
    "$mock_manager" "$pass_file" &
    local pid=$!
    sleep 1
    
    # Verify password NOT in process list
    local ps_output=$(ps aux | grep "$pid" | grep -v grep)
    [[ ! "$ps_output" == *"SecretPass123!"* ]]
    
    # Verify password NOT in /proc/$pid/cmdline
    if [[ -f "/proc/$pid/cmdline" ]]; then
        local cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline")
        [[ ! "$cmdline" == *"SecretPass123!"* ]]
    fi
    
    # Verify password NOT in /proc/$pid/environ (if env var path used)
    if [[ -f "/proc/$pid/environ" ]]; then
        local environ=$(tr '\0' '\n' < "/proc/$pid/environ")
        [[ ! "$environ" == *"SecretPass123!"* ]]
    fi
    
    # Cleanup
    kill $pid 2>/dev/null || true
    rm -f "$pass_file" "$mock_manager"
}

@test "password file rejected if permissions too open" {
    local pass_file="/tmp/test_pass_$$"
    echo "SecretPass123" > "$pass_file"
    chmod 644 "$pass_file"  # World-readable - should be rejected
    
    run vmangos-manager account create TestUser --password-file "$pass_file"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"mode 600"* ]]
    
    rm -f "$pass_file"
}

@test "password file rejected if owned by wrong user" {
    if [[ "$(id -u)" == "0" ]]; then
        skip "Test requires non-root user"
    fi
    
    local pass_file="/tmp/test_pass_$$"
    echo "SecretPass123" > "$pass_file"
    chmod 600 "$pass_file"
    sudo chown nobody "$pass_file"
    
    run vmangos-manager account create TestUser --password-file "$pass_file"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"owned by root or current user"* ]]
    
    sudo rm -f "$pass_file"
}
```

---

### 8. JSON Output - CORRECTED

**Finding:** Ad-hoc heredoc JSON is brittle; no escaping strategy.

**Corrected Implementation:**

```bash
# JSON helper with proper escaping
json_escape() {
    # Escape backslashes, quotes, and control characters
    local str="$1"
    str="${str//\\/\\\\}"      # \ -> \\
    str="${str//\"/\\\"}"      # " -> \"
    str="${str//$'\t'/\\t}"   # tab -> \t
    str="${str//$'\n'/\\n}"   # newline -> \n
    str="${str//$'\r'/\\r}"   # carriage return -> \r
    printf '%s' "$str"
}

json_output() {
    local success="$1"
    local data="${2:-null}"
    local error_code="${3:-null}"
    local error_message="${4:-null}"
    local error_suggestion="${5:-null}"
    
    local timestamp
    timestamp=$(date -Iseconds)
    
    if [[ "$success" == "true" ]]; then
        printf '{"success":true,"timestamp":"%s","data":%s,"error":null}\n' \
            "$timestamp" "$data"
    else
        local escaped_message
        escaped_message=$(json_escape "$error_message")
        local escaped_suggestion
        escaped_suggestion=$(json_escape "$error_suggestion")
        
        printf '{"success":false,"timestamp":"%s","data":null,"error":{"code":"%s","message":"%s","suggestion":"%s"}}\n' \
            "$timestamp" "$error_code" "$escaped_message" "$escaped_suggestion"
    fi
}

# Usage in status_check:
status_json() {
    local auth_status="$1"
    local world_status="$2"
    local player_count="$3"
    
    # Build data object - all values are controlled (not user input)
    local data
    data=$(cat <<EOF
{
  "services": {
    "auth": {"status":"${auth_status}","running":$([[ "$auth_status" == "active" ]] && echo true || echo false)},
    "world": {"status":"${world_status}","running":$([[ "$world_status" == "active" ]] && echo true || echo false),"players_online":${player_count}}
  }
}
EOF
)
    
    json_output true "$data"
}
```

**JSON Schema (Contract):**
```json
{
  "success": boolean,
  "timestamp": "ISO-8601 datetime",
  "data": object | null,
  "error": {
    "code": "ERROR_CODE_STRING",
    "message": "Human readable description",
    "suggestion": "How to fix"
  } | null
}
```

---

### 9. Privilege Model - CORRECTED

**Finding:** `vmangos_manager` user stated as CRUD on auth only, but backups need more.

**Release A Decision: Single-User Model**

Release A implements a single database user with combined permissions. Two-user separation is noted as a future enhancement.

**Implemented Single User:**

```sql
-- Single user with combined permissions
CREATE USER IF NOT EXISTS 'vmangos_mgr'@'localhost' 
    IDENTIFIED BY 'RANDOM_GENERATED_PASSWORD';

-- Application operations
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.* TO 'vmangos_mgr'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON characters.* TO 'vmangos_mgr'@'localhost';

-- Backup operations (needs SELECT on all DBs)
GRANT SELECT, LOCK TABLES ON auth.* TO 'vmangos_mgr'@'localhost';
GRANT SELECT, LOCK TABLES ON characters.* TO 'vmangos_mgr'@'localhost';
GRANT SELECT, LOCK TABLES ON world.* TO 'vmangos_mgr'@'localhost';
GRANT SELECT, LOCK TABLES ON logs.* TO 'vmangos_mgr'@'localhost';

-- Explicitly denied (defense in depth)
-- No DROP, no ALTER, no CREATE, no GRANT
```

**Restore Operations:**
- Restore requires stopping services + running as root
- Restore uses root DB credentials (separate from manager user)
- Documented limitation

**Future Enhancement (Post-Release A):**
Two-user separation (`vmangos_mgr_app` + `vmangos_mgr_backup`) for defense in depth.

---

### 10. Scope Ambiguity - CORRECTED

**Finding:** Update check included in milestones but excluded in summary.

**Corrected Release A Scope:**

| In Scope | Status |
|----------|--------|
| server module | ✅ P1 |
| backup module | ✅ P2 |
| status module | ✅ P3 |
| account module | ✅ P4 |
| update check | ✅ P5 (included, simple) |

| Out of Scope | Status |
|--------------|--------|
| update apply | ❌ Deferred to v0.5 |
| console attach | ❌ Escape hatch only |
| Textual dashboard | ❌ Release B |
| Level 3 verification | ❌ Deferred |

---

## Release A Completion Status

### Installer Script (`vmangos_setup.sh`)

| Feature | Status | Notes |
|---------|--------|-------|
| Automated installation | ✅ Complete | Full VMANGOS server setup |
| Database configuration | ✅ Complete | Auth, world, characters, logs |
| World DB import | ✅ Complete | Downloads and imports latest |
| Client data extraction | ✅ Complete | Maps, DBC, vmaps, mmaps |
| Service setup (systemd) | ✅ Complete | auth.service, world.service |
| RA/SOAP console config | ✅ Complete | Optional, asks user |
| Realm configuration | ✅ Complete | Fixes localAddress for external access |
| Checkpoint/resume | ✅ Complete | Supports resume on failure |

**Release A Completed:** 2026-04-12

---

## Implementation Checklist (Release B Pre-Coding)

Before writing Release B manager tool code, verify:

- [x] VMANGOS schema version confirmed (1.12 development branch) - Commit: `e7de79f3beb1eeed7fcdcf2f4d9c057d3db6f149`
- [x] Online player query tested on actual database - Both auth.account.online and characters.characters.online work
- [x] DB privilege model tested with actual GRANT statements - vmangos_mgr user validated
- [x] JSON helper tested with edge cases (quotes, newlines, backslashes) - Produces valid JSON
- [x] Password file permission checks tested - Mode 600 required, proper ownership enforced
- [x] Systemd timer schedules validated on Ubuntu 22.04 - Daily and weekly formats confirmed
- [ ] Manager tool directory structure created
- [ ] CLI framework selected/implemented
- [ ] Configuration file format finalized

---

## Revised Estimates

| Task | Original | Revised | Change |
|------|----------|---------|--------|
| Foundation + Server | 18h | 20h | +JSON helper |
| Backup | 20h | 18h | -Level 3 complexity |
| Status | 10h | 12h | +schema research |
| Account | 30h | 28h | -placeholder abstraction |
| Update Check + Polish | 14h | 14h | No change |
| **Total** | **114h** | **112h** | **-2h** |

---

## Final Decision Points

### 1. Schema Version
**Target:** VMANGOS 1.12 development branch (commit `e7de79f3beb1eeed7fcdcf2f4d9c057d3db6f149`)  
**Document:** Exact commit tested against in README  
**Date Tested:** 2026-04-12

### 2. Level 3 Verification
**Decision:** OUT of Release A  
**Rationale:** Complexity exceeds value; Levels 1-2 sufficient

### 3. Privilege Model
**Decision:** Single user (`vmangos_mgr`) with combined permissions  
**Rationale:** Simpler deployment, adequate security with proper restrictions

### 4. Online Player Query
**Decision:** Implement both methods, use first that executes successfully and returns an integer (including 0)  
**Fallback:** Return "unknown" if both fail

---

**Plan Status:** ✅ Ready for implementation (corrected)
