# Issue #21: Maintenance Scheduler - Enhanced Implementation Plan

**Status:** 📋 Enhanced Plan Ready  
**Estimated Effort:** 8-10 hours (was 6-8 hours)  
**Priority:** Medium  
**World-Class Goal:** Zero-disruption maintenance with player communication

---

## Executive Summary

Automated scheduling for recurring VMANGOS maintenance tasks with player-friendly announcements, configurable warning intervals, and conflict detection. Ensures maintenance happens at optimal times with minimal player disruption.

---

## Research Foundation

### MMORPG Maintenance Patterns
- Advance warning is critical (players plan activities)
- Typical warning intervals: 30min, 15min, 5min, 1min
- Honor distribution typically daily at fixed time
- Scheduled restarts during low-population periods

### systemd Timer Best Practices
- Use `OnCalendar` for absolute times
- Use `OnUnitActiveSec` for intervals
- Support both one-time and recurring schedules
- Persist missed executions with `Persistent=true`

---

## Enhanced Requirements

### 1. Command Interface

```bash
# Schedule honor distribution
vmangos-manager schedule honor \
    --time 06:00 \
    [--daily | --weekly <day>] \
    [--timezone UTC]

# Schedule server restart
vmangos-manager schedule restart \
    --time 04:00 \
    [--daily | --weekly Sun] \
    [--announce "Weekly maintenance"] \
    [--warnings 30,15,5,1]

# List all scheduled jobs
vmangos-manager schedule list [--format json]

# Cancel a scheduled job
vmangos-manager schedule cancel <job-id>

# Preview what would happen
vmangos-manager schedule simulate <job-id>
```

### 2. Database Schema

```sql
CREATE TABLE vmangos_mgr.scheduled_jobs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    job_type ENUM('honor', 'restart', 'backup', 'custom') NOT NULL,
    schedule_type ENUM('once', 'daily', 'weekly') NOT NULL,
    schedule_time TIME NOT NULL,
    schedule_day VARCHAR(10),  -- For weekly: Mon, Tue, etc.
    timezone VARCHAR(50) DEFAULT 'UTC',
    enabled BOOLEAN DEFAULT TRUE,
    last_run TIMESTAMP NULL,
    next_run TIMESTAMP NULL,
    run_count INT DEFAULT 0,
    fail_count INT DEFAULT 0,
    announce_message TEXT,
    warning_minutes VARCHAR(50),  -- Comma-separated: "30,15,5,1"
    status ENUM('active', 'paused', 'completed', 'failed') DEFAULT 'active',
    INDEX idx_next_run (next_run),
    INDEX idx_enabled (enabled, status)
);

CREATE TABLE vmangos_mgr.schedule_history (
    id INT AUTO_INCREMENT PRIMARY KEY,
    job_id INT NOT NULL,
    executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status ENUM('success', 'failed', 'cancelled') NOT NULL,
    player_count_at_start INT,
    duration_seconds INT,
    error_message TEXT,
    FOREIGN KEY (job_id) REFERENCES scheduled_jobs(id)
);
```

### 3. Honor Distribution Job

```bash
schedule_honor() {
    local time="$1"
    local schedule="$2"  # daily or weekly
    
    # Create systemd timer
    cat > /etc/systemd/system/vmangos-honor.timer <<EOF
[Unit]
Description=VMANGOS Honor Distribution Timer

[Timer]
OnCalendar=*-*-* $time:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/vmangos-honor.service <<EOF
[Unit]
Description=VMANGOS Honor Distribution
After=mysql.service

[Service]
Type=oneshot
ExecStart=/opt/mangos/manager/bin/vmangos-manager schedule run-honor
User=mangos
EOF

    systemctl daemon-reload
    systemctl enable vmangos-honor.timer
    systemctl start vmangos-honor.timer
}

# Honor distribution logic
run_honor_distribution() {
    log_info "Starting honor distribution..."
    
    # Record player count before
    local player_count=$(get_online_player_count)
    
    # Execute honor update via console
    echo "honor update" | send_to_mangosd_console
    
    # Log to database
    insert_schedule_history "honor" "success" "$player_count"
    
    # Announce completion
    announce_in_game "Honor has been distributed for today!"
}
```

### 4. Restart Job with Announcements

```bash
schedule_restart() {
    local time="$1"
    local warnings="${2:-30,15,5,1}"
    local message="${3:-Server restart scheduled}"
    
    # Pre-calculate warning times
    IFS=',' read -ra WARNING_ARRAY <<< "$warnings"
    
    # Main restart timer
    create_systemd_timer "restart" "$time"
    
    # Warning timers (created dynamically)
    for warning_min in "${WARNING_ARRAY[@]}"; do
        local warning_time=$(calculate_warning_time "$time" "$warning_min")
        create_warning_timer "$warning_min" "$warning_time" "$message"
    done
}

# Warning announcement
send_restart_warning() {
    local minutes="$1"
    local message="$2"
    
    local player_count=$(get_online_player_count)
    
    if [ "$player_count" -gt 0 ]; then
        if [ "$minutes" -eq 1 ]; then
            announce_in_game "⚠️ $message in 1 minute! Please save your progress!"
        else
            announce_in_game "⚠️ $message in $minutes minutes."
        fi
        
        log_info "Restart warning sent: $minutes minutes ($player_count players online)"
    fi
}

# Execute restart
execute_restart() {
    log_info "Executing scheduled restart..."
    
    # Final warning
    announce_in_game "🔴 Server is restarting NOW!"
    sleep 5
    
    # Use server control module
    vmangos-manager server restart --announce
    
    # Log completion
    insert_schedule_history "restart" "success"
}
```

### 5. Schedule Listing (JSON)

```json
{
  "schedules": [
    {
      "id": 1,
      "type": "honor",
      "schedule": "daily at 06:00 UTC",
      "next_run": "2026-04-13T06:00:00Z",
      "status": "active",
      "last_run": "2026-04-12T06:00:00Z",
      "run_count": 45,
      "service": "vmangos-honor.timer"
    },
    {
      "id": 2,
      "type": "restart",
      "schedule": "weekly Sun at 04:00 UTC",
      "next_run": "2026-04-13T04:00:00Z",
      "status": "active",
      "announcement": "Weekly maintenance",
      "warnings": [30, 15, 5, 1],
      "service": "vmangos-restart.timer"
    }
  ]
}
```

### 6. Conflict Detection

```bash
check_schedule_conflicts() {
    local new_time="$1"
    local new_type="$2"
    
    # Check for overlapping jobs
    local conflicts=$(mysql -e "
        SELECT id, job_type, schedule_time 
        FROM vmangos_mgr.scheduled_jobs 
        WHERE enabled = 1 
        AND ABS(TIME_TO_SEC(schedule_time) - TIME_TO_SEC('$new_time')) < 1800
    ")
    
    if [ -n "$conflicts" ]; then
        warn "Schedule conflicts detected:"
        echo "$conflicts"
        read -p "Continue anyway? [y/N] " confirm
        [[ "$confirm" =~ [Yy] ]] || return 1
    fi
    
    return 0
}
```

### 7. Timezone Support

```bash
# Convert to system timezone
convert_timezone() {
    local time="$1"
    local from_tz="$2"
    local to_tz="${3:-$(date +%Z)}"
    
    TZ="$from_tz" date -d "$time" +"%H:%M" -TZ="$to_tz"
}

# Display in local time
show_schedule_local() {
    local utc_time="$1"
    local local_time=$(date -d "$utc_time UTC" +"%H:%M %Z")
    echo "Scheduled: $utc_time UTC ($local_time)"
}
```

### 8. Testing

```bash
# Unit tests
@test "honor schedule creates systemd timer" { }
@test "restart schedule creates warning timers" { }
@test "conflict detection finds overlapping times" { }
@test "cancel removes systemd timer" { }
@test "timezone conversion works" { }

# Integration tests
@test "honor distribution runs at scheduled time" { }
@test "restart warnings fire in correct order" { }
@test "schedule persists across reboots" { }
```

---

## Implementation

### Phase 1: Core Scheduling (4 hours)
1. Database schema
2. Honor distribution job
3. Restart job
4. systemd timer generation

### Phase 2: Announcements (2 hours)
1. Warning timer system
2. In-game announcements
3. Message templates

### Phase 3: Polish (2 hours)
1. Conflict detection
2. Timezone support
3. Testing
4. Documentation

---

## Success Criteria

- [ ] Honor distribution scheduled and runs
- [ ] Restart with warnings works
- [ ] 30/15/5/1 minute warnings fire
- [ ] Schedule list shows next run times
- [ ] Cancel removes timer
- [ ] Timezone conversion works
- [ ] Conflict detection warns user
- [ ] History tracked in database

---

**Document Version:** 1.0  
**Last Updated:** 2026-04-12
