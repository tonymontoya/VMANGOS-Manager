# Issue #9: Log Rotation - Enhanced Implementation Plan

**Status:** 📋 Enhanced Plan Ready for Implementation  
**Estimated Effort:** 4-6 hours (was 1 hour)  
**Priority:** High  
**World-Class Goal:** Enterprise-grade log management with security, observability, and reliability

---

## Executive Summary

This enhanced plan transforms basic log rotation into a comprehensive, world-class log management system. Incorporates industry best practices from enterprise Linux environments, security hardening, and operational observability.

---

## Research Foundation

### Industry Best Practices Analyzed

| Source | Key Insight | Implementation |
|--------|-------------|----------------|
| fivenines.io | Permission management with `su` directive | Use `su mangos mangos` for proper ownership |
| last9.io | Security logging & integrity checks | AIDE integration, remote logging patterns |
| wafaicloud.com | Retention policies & compliance | Configurable retention, audit trails |
| datadoghq.com | `copytruncate` vs `create` modes | Use `copytruncate` for applications that can't reopen logs |
| teckneed.com | Testing workflows | Multi-stage validation before deployment |

### Game Server Specific Considerations

VMANGOS (like other game servers) has unique logging characteristics:
- **High-frequency writes:** Chat, movement, combat logs
- **Multiple log types:** 13 distinct log files
- **Service continuity:** Can't stop/restart for log rotation
- **Debug value:** Logs are critical for diagnosing player issues

---

## Enhanced Requirements

### 1. Core Logrotate Configuration

#### File: `/etc/logrotate.d/vmangos`

```apache
# VMANGOS Game Server Log Rotation
# Enhanced configuration with security and reliability features

/opt/mangos/logs/mangosd/*.log
/opt/mangos/logs/realmd/*.log
/opt/mangos/logs/honor/*.log {
    # Rotation schedule
    daily
    
    # Retention policy
    rotate 30
    
    # Compression strategy
    compress
    delaycompress
    compresscmd /bin/gzip
    compressext .gz
    compressoptions -6  # Balance speed vs compression
    
    # File creation strategy
    create 0640 mangos mangos
    
    # Use copytruncate for applications that can't reopen logs
    # VMANGOS may not handle SIGHUP properly for all log types
    copytruncate
    
    # Handle missing/empty files gracefully
    missingok
    notifempty
    
    # Prevent race conditions
    sharedscripts
    
    # Privilege management for logrotate operations
    su mangos mangos
    
    # Post-rotation: Signal services and notify monitoring
    postrotate
        # Attempt to signal services to reopen logs
        /bin/kill -HUP $(/usr/bin/pgrep -x mangosd) 2>/dev/null || true
        /bin/kill -HUP $(/usr/bin/pgrep -x realmd) 2>/dev/null || true
        
        # Log rotation event to system log
        /usr/bin/logger -t vmangos-logrotate "Log rotation completed for $(date +%Y-%m-%d)"
        
        # Optional: Notify monitoring system
        /opt/mangos/manager/bin/vmangos-manager logs rotated --quiet 2>/dev/null || true
    endscript
    
    # Pre-rotation: Check disk space
    prerotate
        # Ensure at least 500MB free before rotation
        AVAILABLE=$(/bin/df /opt/mangos/logs | /usr/bin/awk 'NR==2 {print $4}')
        if [ "$AVAILABLE" -lt 512000 ]; then  # 500MB in KB
            /usr/bin/logger -t vmangos-logrotate "ERROR: Insufficient disk space for log rotation"
            exit 1
        fi
    endscript
    
    # Date-based naming for easier identification
    dateext
    dateformat -%Y%m%d-%s
    
    # Max size trigger (rotate early if log exceeds 100MB)
    maxsize 100M
    
    # Min size threshold (don't rotate if less than 1MB)
    minsize 1M
}

# Special handling for security-sensitive logs
/opt/mangos/logs/mangosd/gm_critical.log
/opt/mangos/logs/mangosd/Anticheat.log {
    daily
    rotate 90  # Keep 90 days for compliance
    compress
    delaycompress
    
    # Stricter permissions for sensitive logs
    create 0600 mangos mangos
    
    copytruncate
    missingok
    notifempty
    
    su mangos mangos
    
    # Don't apply maxsize to these (compliance requirement)
    # But do ensure they rotate daily regardless
}
```

### 2. CLI Integration

#### Commands

```bash
# Status: Show log rotation statistics
vmangos-manager logs status [--format json]

# Manual rotation: Trigger rotation immediately
vmangos-manager logs rotate [--force]

# Configuration test: Validate logrotate config
vmangos-manager logs test-config

# Disk check: Verify sufficient space for next rotation
vmangos-manager logs check-disk

# Audit: Show rotation history
vmangos-manager logs audit [--days 7]
```

#### Status Output (JSON)

```json
{
  "status": "healthy",
  "timestamp": "2026-04-12T15:30:00Z",
  "config": {
    "file": "/etc/logrotate.d/vmangos",
    "valid": true,
    "last_modified": "2026-04-12T10:00:00Z"
  },
  "logs": {
    "total_log_files": 13,
    "total_size_bytes": 15728640,
    "rotated_files_count": 45,
    "compressed_size_bytes": 3145728
  },
  "disk": {
    "path": "/opt/mangos/logs",
    "total_bytes": 107374182400,
    "used_bytes": 21474836480,
    "free_bytes": 85899345920,
    "usage_percent": 20
  },
  "last_rotation": {
    "timestamp": "2026-04-12T03:00:00Z",
    "status": "success",
    "files_rotated": 13,
    "duration_seconds": 2.3
  },
  "next_rotation": {
    "scheduled": "2026-04-13T03:00:00Z",
    "estimated_disk_needed_bytes": 5242880
  }
}
```

### 3. Security Hardening

#### File Permissions Strategy

| Log Type | Permission | Rationale |
|----------|------------|-----------|
| General logs | 0640 | Owner read/write, group read |
| GM critical logs | 0600 | Owner only, contains sensitive actions |
| Anticheat logs | 0600 | Owner only, potential exploit info |
| Backup configs | 0644 | Readable for audit, writable by root only |

#### Log Integrity Verification

```bash
# Generate checksums for log files
vmangos-manager logs verify --generate

# Verify log integrity
vmangos-manager logs verify --check
```

**Implementation:**
- Store SHA256 checksums in `/opt/mangos/logs/.checksums/`
- Verify on rotation to detect tampering
- Alert if integrity check fails

### 4. Monitoring & Alerting

#### Health Check Integration

The log rotation system integrates with Issue #10 (Health Monitoring):

| Alert Condition | Severity | Action |
|-----------------|----------|--------|
| Rotation failed | CRITICAL | Notify admin, prevent disk fill |
| Disk usage > 80% | WARNING | Early warning before rotation |
| Disk usage > 95% | CRITICAL | Urgent action required |
| Log file > 500MB | WARNING | Unusual growth pattern |
| Integrity check failed | CRITICAL | Potential security issue |
| Rotation duration > 60s | WARNING | Performance degradation |

#### Log Rotation Metrics

Track in `vmangos_mgr.log_rotation_stats`:

```sql
CREATE TABLE vmangos_mgr.log_rotation_stats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    rotated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    files_rotated INT NOT NULL,
    bytes_before BIGINT NOT NULL,
    bytes_after BIGINT NOT NULL,
    compression_ratio DECIMAL(4,2),
    duration_seconds DECIMAL(6,2),
    status ENUM('success', 'failed', 'skipped') NOT NULL,
    error_message TEXT,
    INDEX idx_rotated_at (rotated_at),
    INDEX idx_status (status)
);
```

### 5. Testing Strategy

#### Pre-Deployment Testing

```bash
# 1. Configuration syntax test
sudo logrotate -d /etc/logrotate.d/vmangos

# 2. Create test log files
touch /opt/mangos/logs/mangosd/test{1..5}.log

# 3. Force rotation test
sudo logrotate -vf /etc/logrotate.d/vmangos

# 4. Verify rotated files
ls -la /opt/mangos/logs/mangosd/*.gz

# 5. Verify new logs created
ls -la /opt/mangos/logs/mangosd/*.log

# 6. Test service continuity
systemctl status world

# 7. Verify application still logging
tail -f /opt/mangos/logs/mangosd/Server.log
```

#### Unit Tests

```bash
#!/usr/bin/env bats
# tests/unit/test_log_rotation.sh

@test "logrotate configuration is valid" {
    run logrotate -d /etc/logrotate.d/vmangos
    [ "$status" -eq 0 ]
}

@test "log directory has correct permissions" {
    [ "$(stat -c %U /opt/mangos/logs)" = "mangos" ]
    [ "$(stat -c %G /opt/mangos/logs)" = "mangos" ]
}

@test "rotation creates compressed files" {
    # Create test log
    echo "test" > /opt/mangos/logs/mangosd/test_rotation.log
    
    # Force rotation
    logrotate -f /etc/logrotate.d/vmangos
    
    # Verify compressed file exists
    [ -f /opt/mangos/logs/mangosd/test_rotation.log*.gz ]
}

@test "status command returns valid JSON" {
    run vmangos-manager logs status --format json
    [ "$status" -eq 0 ]
    echo "$output" | jq . > /dev/null
}

@test "disk check prevents rotation when low space" {
    # Mock low disk scenario
    # ... implementation
}
```

### 6. Error Handling

#### Rotation Failure Scenarios

| Scenario | Detection | Response |
|----------|-----------|----------|
| Disk full | Pre-rotation check | Skip rotation, alert admin |
| Permission denied | Post-rotation check | Log error, attempt fix |
| Service not responding | SIGHUP timeout | Log warning, continue |
| Corrupt log file | Integrity check | Quarantine file, alert |
| Config syntax error | Test on install | Prevent installation |

#### Recovery Procedures

```bash
# Manual recovery commands

# 1. Fix permissions
sudo chown -R mangos:mangos /opt/mangos/logs
sudo chmod -R u+rw /opt/mangos/logs

# 2. Force rotation after fix
sudo logrotate -f /etc/logrotate.d/vmangos

# 3. Clear old logs manually (emergency)
sudo find /opt/mangos/logs -name "*.gz" -mtime +30 -delete

# 4. Reset logrotate status
sudo rm /var/lib/logrotate/status
```

### 7. Configuration Management

#### Default Configuration

```ini
# /opt/mangos/manager/config/logrotate.conf

[logrotate]
enabled = true
config_path = /etc/logrotate.d/vmangos

[rotation]
schedule = daily
retention_days = 30
compress = true
compress_level = 6
max_size_mb = 100
min_size_mb = 1

[security]
sensitive_logs_permission = 0600
general_logs_permission = 0640
verify_integrity = true

[monitoring]
alert_on_failure = true
alert_on_high_disk = 80
track_metrics = true

[retention]
# Different retention for different log types
general_logs_days = 30
security_logs_days = 90
debug_logs_days = 7
```

#### Runtime Configuration Updates

```bash
# Update configuration
vmangos-manager logs config set retention.general_logs_days 60
vmangos-manager logs config set rotation.max_size_mb 200

# Apply changes
vmangos-manager logs config apply --test
vmangos-manager logs config apply --force
```

---

## Implementation Phases

### Phase 1: Core Infrastructure (2 hours)

1. **Create logrotate configuration**
   - File: `/etc/logrotate.d/vmangos`
   - Include all 13 log types
   - Set up proper permissions

2. **Create configuration file**
   - Path: `/opt/mangos/manager/config/logrotate.conf`
   - Default settings

3. **Basic CLI commands**
   - `logs status`
   - `logs rotate`
   - `logs test-config`

### Phase 2: Security & Reliability (1.5 hours)

1. **Implement security hardening**
   - Separate permissions for sensitive logs
   - Integrity verification
   - SELinux compatibility checks

2. **Add error handling**
   - Disk space checks
   - Rotation failure recovery
   - Service continuity verification

3. **Testing suite**
   - Unit tests
   - Integration tests
   - Pre-deployment validation

### Phase 3: Observability (1.5 hours)

1. **Metrics collection**
   - Database schema
   - Rotation statistics
   - Disk usage tracking

2. **Health check integration**
   - Alert conditions
   - Status reporting
   - Historical data

3. **CLI enhancements**
   - JSON output
   - Audit command
   - Disk prediction

---

## Success Criteria

- [ ] Log rotation works automatically (daily)
- [ ] All 13 log file types are rotated
- [ ] Compression reduces size by 50%+ 
- [ ] No service interruption during rotation
- [ ] Disk space alerts trigger correctly
- [ ] Rotation failures are detected and alerted
- [ ] Sensitive logs have restricted permissions (0600)
- [ ] Metrics are tracked in database
- [ ] Status command provides actionable information
- [ ] Unit tests pass (>90% coverage)
- [ ] Manual rotation works on demand
- [ ] Configuration is valid and tested

---

## Dependencies

- **Release A:** VMANGOS server installed and running
- **Issue #10:** Health monitoring for alert integration (optional)
- **System:** logrotate package installed (standard on Ubuntu)

---

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| Service crash during SIGHUP | High | Use `copytruncate` mode |
| Disk fills before rotation | High | Pre-rotation disk check |
| Permission issues | Medium | `su` directive, proper ownership |
| Log loss during rotation | Medium | Atomic rotation with `copytruncate` |
| SELinux blocking | Low | Context-aware configuration |

---

## References

1. [Logrotate: The Complete Guide](https://fivenines.io/blog/logrotate-the-complete-guide/)
2. [Linux Security Logs Best Practices](https://last9.io/blog/linux-security-logs/)
3. [Logrotate Best Practices - Datadog](https://www.datadoghq.com/blog/log-file-control-with-logrotate/)
4. [Effective Log Rotation Strategies - WafaiCloud](https://wafaicloud.com/blog/effective-log-rotation-strategies-for-enhancing-linux-security/)

---

**Document Version:** 1.0  
**Last Updated:** 2026-04-12  
**Status:** Ready for Implementation
