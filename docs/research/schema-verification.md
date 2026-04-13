# Phase 2: Pre-coding Research Findings

**Issue:** GitHub Issue #6 - Pre-coding Research: Schema Verification & Testing  
**Date:** 2026-04-12  
**Status:** ✅ COMPLETE

---

## Executive Summary

All pre-coding research tasks have been completed successfully. The VMANGOS schema has been verified, all proposed implementation patterns have been validated, and the ENG_PLAN.md has been updated with confirmed findings.

**Schema Commit for Release A:** `e7de79f3beb1eeed7fcdcf2f4d9c057d3db6f149`

---

## 1. VMANGOS Schema Version ✅

### Confirmed Details
| Field | Value |
|-------|-------|
| **Repository** | https://github.com/vmangos/core |
| **Branch** | development |
| **Commit Hash** | `e7de79f3beb1eeed7fcdcf2f4d9c057d3db6f149` |
| **Short Hash** | `e7de79f3b` |
| **Commit Date** | 2026-04-12 11:26:33 +0100 |
| **Commit Message** | "Pool Un'Goro Blindweed (#3360)" |

### Verification Command
```bash
cd /opt/mangos/source && git log --oneline -1
```

**Status:** ✅ Confirmed and documented in ENG_PLAN.md

---

## 2. Online Player Query Testing ✅

### Schema Discovery

The ENG_PLAN.md referenced `auth.account.active_realm_id` which **does not exist** in the current schema. The correct column is `auth.account.current_realm`.

### Working Queries

All three queries execute successfully and return integers (including 0):

| # | Query | Table.Column | Type | Status |
|---|-------|--------------|------|--------|
| 1 | `SELECT COUNT(*) FROM auth.account WHERE online = 1;` | auth.account.online | tinyint(4) | ✅ Works |
| 2 | `SELECT COUNT(*) FROM auth.account WHERE current_realm != 0;` | auth.account.current_realm | tinyint(3) unsigned | ✅ Works |
| 3 | `SELECT COUNT(*) FROM characters.characters WHERE online = 1;` | characters.characters.online | tinyint(3) unsigned | ✅ Works |

### Recommended Implementation (per ENG_PLAN pattern)

```bash
get_online_player_count() {
    local cred_file="$1"
    
    # Try method 1: auth.account.online
    local count=$(mysql --defaults-file="$cred_file" -N -B \
        -e "SELECT COUNT(*) FROM auth.account WHERE online = 1;" 2>/dev/null)
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
        return 0
    fi
    
    # Try method 2: characters.characters.online
    count=$(mysql --defaults-file="$cred_file" -N -B \
        -e "SELECT COUNT(*) FROM characters.characters WHERE online = 1;" 2>/dev/null)
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
        return 0
    fi
    
    # Fallback
    echo "unknown"
    return 1
}
```

### Character Names Query (for detailed listing)

```sql
SELECT c.name, a.username, c.level, c.race, c.class
FROM characters.characters c
JOIN auth.account a ON c.account = a.id
WHERE c.online = 1;
```

**Status:** ✅ Tested and documented

---

## 3. Database Privilege Model ✅

### Test User Created

```sql
CREATE USER 'vmangos_mgr'@'localhost' IDENTIFIED BY 'test_password';
```

### Granted Privileges

| Database | SELECT | INSERT | UPDATE | DELETE | LOCK TABLES |
|----------|--------|--------|--------|--------|-------------|
| auth | ✅ | ✅ | ✅ | ✅ | ✅ |
| characters | ✅ | ✅ | ✅ | ✅ | ✅ |
| world | ✅ | ❌ | ❌ | ❌ | ✅ |
| logs | ✅ | ❌ | ❌ | ❌ | ✅ |

### SQL Commands Executed

```sql
-- Application operations
GRANT SELECT, INSERT, UPDATE, DELETE ON auth.* TO 'vmangos_mgr'@'localhost';
GRANT SELECT, INSERT, UPDATE, DELETE ON characters.* TO 'vmangos_mgr'@'localhost';

-- Backup operations (needs SELECT on all DBs)
GRANT SELECT, LOCK TABLES ON auth.* TO 'vmangos_mgr'@'localhost';
GRANT SELECT, LOCK TABLES ON characters.* TO 'vmangos_mgr'@'localhost';
GRANT SELECT, LOCK TABLES ON world.* TO 'vmangos_mgr'@'localhost';
GRANT SELECT, LOCK TABLES ON logs.* TO 'vmangos_mgr'@'localhost';

FLUSH PRIVILEGES;
```

### Test Results

| Test | Expected | Result |
|------|----------|--------|
| SELECT on auth.account | Success | ✅ PASS |
| SELECT on characters.characters | Success | ✅ PASS |
| SELECT on world.item_template | Success | ✅ PASS |
| SELECT on logs.logs_characters | Success | ✅ PASS |
| INSERT on auth.account | Success | ✅ PASS |
| UPDATE on auth.account | Success | ✅ PASS |
| DELETE on auth.account | Success | ✅ PASS |
| DROP TABLE auth.account | Denied | ✅ PASS (ERROR 1142) |

**Status:** ✅ Privilege model validated and working

---

## 4. JSON Helper Testing ✅

### Test Script Location
`/tmp/test_json.sh`

### Functions Tested

#### json_escape()
Escapes backslashes, quotes, and control characters:
- `\` → `\\`
- `"` → `\"`
- Tab → `\t`
- Newline → `\n`
- Carriage return → `\r`

#### json_output()
Generates valid JSON with schema:
```json
{
  "success": true|false,
  "timestamp": "ISO-8601 datetime",
  "data": object|null,
  "error": {
    "code": "ERROR_CODE",
    "message": "Human readable",
    "suggestion": "How to fix"
  }|null
}
```

### Test Results

| Test | Input | Expected | Result |
|------|-------|----------|--------|
| Escape quotes | `"test"` | `\"test\"` | ✅ Valid JSON |
| Escape newlines | `line1\nline2` | `line1\\nline2` | ✅ Valid JSON |
| Escape backslashes | `path\\to\\file` | `path\\\\to\\\\file` | ✅ Valid JSON |
| json_output success | - | Valid JSON object | ✅ PASS |
| json_output error | Special chars | Valid JSON with escapes | ✅ PASS |

**Status:** ✅ JSON helper produces valid JSON

---

## 5. Password File Permission Testing ✅

### Test Script Location
`/tmp/test_pass.sh`

### Function Tested
`get_password_from_file()` from ENG_PLAN.md

### Security Checks (in order)
1. File exists check
2. Ownership check (must be root or current user)
3. Permission check (must be mode 600)
4. Only then read file

### Test Results

| Test | Setup | Expected | Result |
|------|-------|----------|--------|
| Mode 600 | `chmod 600 file` | Accept | ✅ PASS |
| Mode 644 | `chmod 644 file` | Reject | ✅ PASS |
| Wrong owner | `chown nobody file` | Reject | ✅ PASS |
| Non-existent | Missing file | Error gracefully | ✅ PASS |
| Short password | 5 chars | Reject (< 6) | ✅ PASS |

**Status:** ✅ Permission checking works correctly

---

## 6. Systemd Timer Validation ✅

### Daily Schedule Test
- **Format:** `*-*-* 02:00:00`
- **Command:** `OnCalendar=*-*-* 02:00:00`
- **Status:** ✅ Valid, timer loads successfully

### Weekly Schedule Test
- **Format:** `Sun *-*-* 04:00:00`
- **Command:** `OnCalendar=Sun *-*-* 04:00:00`
- **Status:** ✅ Valid, timer loads successfully

### Implementation Pattern

```bash
backup_schedule() {
    local schedule="$1"
    
    if [[ "$schedule" =~ ^([0-9]{2}):([0-9]{2})$ ]]; then
        local oncalendar="*-*-* ${schedule}:00"
    elif [[ "$schedule" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)[[:space:]]+([0-9]{2}):([0-9]{2})$ ]]; then
        local day="${BASH_REMATCH[1]}"
        local time="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
        local oncalendar="${day} *-*-* ${time}:00"
    else
        error_exit "Invalid schedule. Use HH:MM for daily or 'Day HH:MM' for weekly"
    fi
    
    # Create timer file...
}
```

**Status:** ✅ Both daily and weekly schedules validated on Ubuntu 22.04

---

## ENG_PLAN.md Updates

### Changes Made

1. **Line 125:** Updated schema version from placeholder to confirmed commit
   - Before: `commit TBD - research required`
   - After: `commit e7de79f3beb1eeed7fcdcf2f4d9c057d3db6f149`

2. **Line 536:** Marked pre-coding checklist items complete with details

3. **Line 561:** Added schema commit to Final Decision Points section

4. **Online Query Correction:** Changed `active_realm_id` to `current_realm` in query examples

### Updated Checklist

- [x] VMANGOS schema version confirmed (1.12 development branch) - Commit: `e7de79f3beb1eeed7fcdcf2f4d9c057d3db6f149`
- [x] Online player query tested on actual database - Both auth.account.online and characters.characters.online work
- [x] DB privilege model tested with actual GRANT statements - vmangos_mgr user validated
- [x] JSON helper tested with edge cases (quotes, newlines, backslashes) - Produces valid JSON
- [x] Password file permission checks tested - Mode 600 required, proper ownership enforced
- [x] Systemd timer schedules validated on Ubuntu 22.04 - Daily and weekly formats confirmed

---

## Discrepancies Found

### 1. active_realm_id Column
**ENG_PLAN Reference:** `auth.account.active_realm_id`  
**Actual Schema:** `auth.account.current_realm` (tinyint(3) unsigned)

**Impact:** Online player query needs to use `current_realm` instead of `active_realm_id`.

**Resolution:** Updated ENG_PLAN.md to reference correct column.

---

## Artifacts Created

| File | Location | Description |
|------|----------|-------------|
| Test JSON Script | `/tmp/test_json.sh` | Validates json_escape() and json_output() |
| Test Password Script | `/tmp/test_pass.sh` | Validates get_password_from_file() security |
| Research Findings | `/home/tony/dev-plans/vmangos-setup/PHASE2_RESEARCH_FINDINGS.md` | This document |

---

## Action Items

- [x] Document findings on GitHub Issue #6 (comment added)
- [x] Update ENG_PLAN.md with confirmed schema commit hash
- [x] Close GitHub Issue #6

---

## Sign-off

**Phase 2 Status:** ✅ COMPLETE

All pre-coding research tasks have been completed successfully. The VMANGOS schema has been verified against the actual installation at `/opt/mangos/source/`, and all proposed implementation patterns have been validated on the target Ubuntu 22.04 system.

**Ready for Phase 3:** Foundation development (GitHub Issue #7)

---

*Generated: 2026-04-12*
