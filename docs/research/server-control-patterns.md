# Issue #20: Server Control - Enhanced Implementation Plan

**Status:** 📋 Enhanced Plan Ready  
**Estimated Effort:** 6-8 hours (was 4-6 hours)  
**Priority:** High  
**World-Class Goal:** Production-grade service management with safety interlocks

---

## Executive Summary

Server Control provides safe, observable management of VMANGOS services with emphasis on data integrity, player experience, and operational safety. Implements graceful shutdowns, health verification, and crash recovery.

---

## Research Foundation

### systemd Best Practices
- Use `systemctl` for service state management
- Implement graceful timeouts (not SIGKILL)
- Handle dependency chains properly
- Verify service health post-start

### Game Server Specifics
- Players expect advance warning before restarts
- Database connections must drain properly
- Logout handlers need time to save character state
- Crash loops indicate configuration issues

---

## Enhanced Requirements

### 1. Service Commands

```bash
# Start services with health verification
vmangos-manager server start [--wait] [--timeout 60]

# Graceful stop with player warning
vmangos-manager server stop [--graceful] [--force] [--announce "MESSAGE"]

# Safe restart with pre/post checks
vmangos-manager server restart [--announce] [--quick]

# Comprehensive status
vmangos-manager server status [--format json] [--watch]

# Console access
vmangos-manager server console [--attach] [--command "CMD"]
```

### 2. Start Sequence with Verification

```bash
server_start() {
    # 1. Pre-flight checks
    check_database_connection || error_exit "Database unreachable"
    check_disk_space || error_exit "Insufficient disk space"
    check_config_files || error_exit "Configuration errors detected"
    
    # 2. Start auth service
    systemctl start auth
    wait_for_service auth --timeout 10 || error_exit "Auth failed to start"
    verify_auth_health || warn "Auth started but health check failed"
    
    # 3. Start world service
    systemctl start world
    wait_for_service world --timeout 60 || error_exit "World failed to start"
    verify_world_health || warn "World started but health check failed"
    
    # 4. Post-start verification
    check_port 3724 || error_exit "Auth port not listening"
    check_port 8085 || error_exit "World port not listening"
    verify_database_connection || error_exit "Services not connecting to DB"
    
    log_info "Server started successfully"
}
```

### 3. Graceful Stop Sequence

```bash
server_stop() {
    local graceful="${1:-true}"
    local timeout="${2:-30}"
    
    if [ "$graceful" = true ]; then
        # 1. Announce to players (if world is running)
        if service_active world; then
            announce_in_game "Server shutting down in ${timeout}s..."
            sleep 5
        fi
        
        # 2. Stop world first (allows auth to handle disconnects)
        systemctl stop world
        wait_for_stop world --timeout "$timeout" || {
            warn "World did not stop gracefully, forcing..."
            systemctl kill -s SIGTERM world
            sleep 5
            systemctl kill -s SIGKILL world 2>/dev/null || true
        }
        
        # 3. Stop auth
        systemctl stop auth
        wait_for_stop auth --timeout 10 || {
            systemctl kill -s SIGKILL auth 2>/dev/null || true
        }
    else
        # Force stop both
        systemctl stop auth world
    fi
    
    verify_stopped || error_exit "Services still running after stop"
}
```

### 4. Status Command (JSON Output)

```json
{
  "timestamp": "2026-04-12T15:30:00Z",
  "services": {
    "auth": {
      "active": true,
      "state": "running",
      "pid": 1234,
      "uptime": "2d 4h 32m",
      "memory_mb": 45.2,
      "cpu_percent": 2.1,
      "health": "healthy"
    },
    "world": {
      "active": true,
      "state": "running",
      "pid": 1235,
      "uptime": "2d 4h 30m",
      "memory_mb": 890.5,
      "cpu_percent": 15.3,
      "health": "healthy",
      "online_players": 47
    }
  },
  "resources": {
    "disk_usage_percent": 45,
    "load_average": [0.5, 0.3, 0.2]
  },
  "restart_count_1h": {
    "auth": 0,
    "world": 0
  }
}
```

### 5. Safety Interlocks

| Condition | Action | Rationale |
|-----------|--------|-----------|
| Database unreachable | Prevent start | Avoid crash loops |
| Disk > 95% full | Warn but allow start | Emergency access |
| Recent crash (< 5 min) | Delay start | Prevent crash loops |
| Config syntax error | Block start | Catch errors early |
| Player count > 0 on stop | Require --force | Prevent accidental disruption |

### 6. Console Access

```bash
# Interactive console
vmangos-manager server console --attach
> account create PlayerOne
> server info
> exit

# One-shot command
vmangos-manager server console --command "account list"

# Non-interactive (for scripts)
vmangos-manager server console --command "account create testuser" --password-file /tmp/pass
```

### 7. Watch Mode

```bash
# Live status updates
vmangos-manager server status --watch --interval 5

# Shows:
# Every 5.0s: Server Status
# Auth:  🟢 Running (PID: 1234) - 45MB RAM
# World: 🟢 Running (PID: 1235) - 890MB RAM, 47 players
```

### 8. Error Handling & Recovery

```bash
# Detect and report crash loops
detect_crash_loop() {
    local restarts=$(journalctl -u world --since "1 hour ago" | grep -c "Started VMANGOS World Server")
    if [ "$restarts" -gt 10 ]; then
        error_exit "Crash loop detected ($restarts restarts in 1 hour). Check logs: journalctl -u world -n 100"
    fi
}

# Automatic recovery attempt
auto_recover() {
    if service_failed world; then
        log_warn "World service failed, attempting recovery..."
        
        # Check common issues
        if ! database_reachable; then
            error_exit "Database unreachable - cannot auto-recover"
        fi
        
        # Try restart
        systemctl restart world
        sleep 10
        
        if service_active world; then
            log_info "Auto-recovery successful"
        else
            error_exit "Auto-recovery failed - manual intervention required"
        fi
    fi
}
```

### 9. Testing Requirements

```bash
# Unit tests
@test "start succeeds when database is reachable" { }
@test "start fails when database is unreachable" { }
@test "graceful stop waits for players to disconnect" { }
@test "force stop terminates immediately" { }
@test "status returns valid JSON" { }
@test "restart maintains player sessions" { }
@test "crash loop detection works" { }

# Integration tests
@test "full start -> stop -> start cycle" { }
@test "graceful shutdown saves player data" { }
@test "console command execution" { }
```

---

## Implementation

### Phase 1: Core Commands (3 hours)
1. server start with pre-flight checks
2. server stop (graceful and force)
3. server status with JSON output
4. Error handling framework

### Phase 2: Safety Features (2 hours)
1. Crash loop detection
2. Player count awareness
3. In-game announcements
4. Auto-recovery

### Phase 3: Console & Polish (2 hours)
1. Console attach/command
2. Watch mode
3. Testing suite
4. Documentation

---

## Success Criteria

- [ ] Start with pre-flight checks
- [ ] Graceful stop with timeout
- [ ] Force stop works reliably
- [ ] JSON status output
- [ ] Crash loop detection
- [ ] Console access works
- [ ] Watch mode updates
- [ ] Unit tests pass
- [ ] No data loss on restart

---

**Document Version:** 1.0  
**Last Updated:** 2026-04-12
