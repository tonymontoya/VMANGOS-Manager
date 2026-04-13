#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Log rotation module for VMANGOS Manager
# Generates and validates logrotate configuration for VMANGOS logs
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

LOGS_CONFIG_LOADED=""
LOGS_INSTALL_ROOT=""
LOGS_ROOT=""
LOGS_ROTATE_CONFIG_PATH="${VMANGOS_LOGROTATE_CONFIG_PATH:-/etc/logrotate.d/vmangos}"
LOGS_ROTATE_STATE_PATH="${VMANGOS_LOGROTATE_STATE_PATH:-}"
LOGS_ROTATE_OWNER_USER="${VMANGOS_LOGROTATE_OWNER_USER:-mangos}"
LOGS_ROTATE_OWNER_GROUP="${VMANGOS_LOGROTATE_OWNER_GROUP:-mangos}"
LOGS_MIN_FREE_KB="${VMANGOS_LOGROTATE_MIN_FREE_KB:-512000}"
LOGS_RETENTION_DAYS="${VMANGOS_LOGROTATE_RETENTION_DAYS:-30}"
LOGS_SENSITIVE_RETENTION_DAYS="${VMANGOS_LOGROTATE_SENSITIVE_RETENTION_DAYS:-90}"
LOGS_MAX_SIZE="${VMANGOS_LOGROTATE_MAX_SIZE:-100M}"
LOGS_MIN_SIZE="${VMANGOS_LOGROTATE_MIN_SIZE:-1M}"

logs_load_config() {
    [[ "$LOGS_CONFIG_LOADED" == "1" ]] && return 0

    config_load "$CONFIG_FILE" || {
        log_error "Failed to load configuration"
        return 1
    }

    LOGS_INSTALL_ROOT="${CONFIG_SERVER_INSTALL_ROOT:-/opt/mangos}"
    LOGS_ROOT="${LOGS_INSTALL_ROOT}/logs"
    LOGS_CONFIG_LOADED="1"
    return 0
}

logs_logrotate_bin() {
    if [[ -n "${LOGROTATE_BIN:-}" ]]; then
        printf '%s\n' "$LOGROTATE_BIN"
        return 0
    fi

    command -v logrotate 2>/dev/null || printf '%s\n' /usr/sbin/logrotate
}

logs_df_target() {
    if [[ -d "$LOGS_ROOT" ]]; then
        printf '%s\n' "$LOGS_ROOT"
    elif [[ -d "$LOGS_INSTALL_ROOT" ]]; then
        printf '%s\n' "$LOGS_INSTALL_ROOT"
    else
        printf '%s\n' "$(dirname "$LOGS_ROOT")"
    fi
}

logs_collect_disk_stats() {
    local target disk_data
    target=$(logs_df_target)
    disk_data=$(df -Pk "$target" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); print $2 "|" $3 "|" $4 "|" $5}' || true)

    if [[ -n "$disk_data" ]]; then
        printf '%s\n' "$disk_data"
    else
        printf '0|0|0|0\n'
    fi
}

logs_check_disk_space() {
    local disk_data available_kb
    disk_data=$(logs_collect_disk_stats)
    available_kb="${disk_data#*|}"
    available_kb="${available_kb#*|}"
    available_kb="${available_kb%%|*}"
    [[ "$available_kb" =~ ^[0-9]+$ ]] || available_kb=0
    [[ "$LOGS_MIN_FREE_KB" =~ ^[0-9]+$ ]] || LOGS_MIN_FREE_KB=512000
    [[ "$available_kb" -ge "$LOGS_MIN_FREE_KB" ]]
}

logs_sensitive_paths() {
    cat <<EOF
$LOGS_ROOT/mangosd/gm_critical.log
$LOGS_ROOT/mangosd/Anticheat.log
EOF
}

logs_general_paths() {
    cat <<EOF
$LOGS_ROOT/mangosd/Bg.log
$LOGS_ROOT/mangosd/Char.log
$LOGS_ROOT/mangosd/Chat.log
$LOGS_ROOT/mangosd/DBErrors.log
$LOGS_ROOT/mangosd/LevelUp.log
$LOGS_ROOT/mangosd/Loot.log
$LOGS_ROOT/mangosd/Movement.log
$LOGS_ROOT/mangosd/Network.log
$LOGS_ROOT/mangosd/Perf.log
$LOGS_ROOT/mangosd/Ra.log
$LOGS_ROOT/mangosd/Scripts.log
$LOGS_ROOT/mangosd/Server.log
$LOGS_ROOT/mangosd/Trades.log
$LOGS_ROOT/realmd/*.log
$LOGS_ROOT/honor/*.log
EOF
}

logs_find_active_files() {
    [[ -d "$LOGS_ROOT" ]] || return 0
    find "$LOGS_ROOT" -type f -name '*.log' -print0 2>/dev/null
}

logs_find_rotated_files() {
    [[ -d "$LOGS_ROOT" ]] || return 0
    find "$LOGS_ROOT" -type f \( -name '*.log-*' -o -name '*.log.[0-9]*' -o -name '*.log.[0-9]*.gz' \) -print0 2>/dev/null
}

logs_find_sensitive_files() {
    local file
    while IFS= read -r file; do
        [[ -n "$file" && -f "$file" ]] && printf '%s\0' "$file"
    done < <(logs_sensitive_paths)
}

logs_collect_file_stats() {
    local mode="$1"
    local count=0
    local total_bytes=0
    local file size

    while IFS= read -r -d '' file; do
        count=$((count + 1))
        size=$(get_file_size_bytes "$file" 2>/dev/null || echo 0)
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        total_bytes=$((total_bytes + size))
    done < <(
        if [[ "$mode" == "active" ]]; then
            logs_find_active_files
        else
            logs_find_rotated_files
        fi
    )

    printf '%s|%s\n' "$count" "$total_bytes"
}

logs_sensitive_permissions_ok() {
    local file perms

    while IFS= read -r -d '' file; do
        perms=$(get_file_permissions "$file" 2>/dev/null || echo "")
        if [[ "$perms" != "600" ]]; then
            return 1
        fi
    done < <(logs_find_sensitive_files)

    return 0
}

logs_harden_sensitive_permissions() {
    local file changed=0

    while IFS= read -r -d '' file; do
        chmod 600 "$file" || {
            log_error "Failed to harden sensitive log permissions: $file"
            return 1
        }
        changed=$((changed + 1))
    done < <(logs_find_sensitive_files)

    log_debug "Sensitive log permission check applied to $changed files"
    return 0
}

logs_render_logrotate_config() {
    logs_load_config || return 1

    local general_paths sensitive_paths
    general_paths=$(logs_general_paths)
    sensitive_paths=$(logs_sensitive_paths)

    cat <<EOF
# Managed by VMANGOS Manager. Manual edits will be overwritten.
# copytruncate is intentional because VMANGOS keeps log file descriptors open
# and does not provide a consistent reopen mechanism across mangosd/realmd logs.

$general_paths {
    daily
    rotate $LOGS_RETENTION_DAYS
    compress
    delaycompress
    compressoptions -6
    copytruncate
    missingok
    notifempty
    sharedscripts
    su $LOGS_ROTATE_OWNER_USER $LOGS_ROTATE_OWNER_GROUP
    dateext
    dateformat -%Y%m%d-%s
    maxsize $LOGS_MAX_SIZE
    minsize $LOGS_MIN_SIZE
    prerotate
        AVAILABLE=\$(/bin/df -Pk "$LOGS_ROOT" | /usr/bin/awk 'NR==2 {print \$4}')
        if [ "\${AVAILABLE:-0}" -lt $LOGS_MIN_FREE_KB ]; then
            /usr/bin/logger -t vmangos-logrotate "ERROR: Insufficient disk space for log rotation"
            exit 1
        fi
    endscript
}

$sensitive_paths {
    daily
    rotate $LOGS_SENSITIVE_RETENTION_DAYS
    compress
    delaycompress
    copytruncate
    missingok
    notifempty
    su $LOGS_ROTATE_OWNER_USER $LOGS_ROTATE_OWNER_GROUP
    dateext
    dateformat -%Y%m%d-%s
}
EOF
}

logs_config_in_sync() {
    local temp_file
    temp_file=$(mktemp_secure vmangos-logrotate-XXXXXX)
    logs_render_logrotate_config > "$temp_file"

    [[ -f "$LOGS_ROTATE_CONFIG_PATH" ]] && cmp -s "$temp_file" "$LOGS_ROTATE_CONFIG_PATH"
}

logs_install_config() {
    logs_load_config || return 1

    local temp_file config_dir
    temp_file=$(mktemp_secure vmangos-logrotate-XXXXXX)
    logs_render_logrotate_config > "$temp_file"
    chmod 644 "$temp_file"

    config_dir=$(dirname "$LOGS_ROTATE_CONFIG_PATH")
    install -d "$config_dir" || {
        log_error "Failed to create config directory: $config_dir"
        return 1
    }

    if [[ -f "$LOGS_ROTATE_CONFIG_PATH" ]] && cmp -s "$temp_file" "$LOGS_ROTATE_CONFIG_PATH"; then
        log_debug "Logrotate config already current: $LOGS_ROTATE_CONFIG_PATH"
        return 0
    fi

    install -m 644 "$temp_file" "$LOGS_ROTATE_CONFIG_PATH" || {
        log_error "Failed to install logrotate config: $LOGS_ROTATE_CONFIG_PATH"
        return 1
    }

    log_info "Installed logrotate config: $LOGS_ROTATE_CONFIG_PATH"
}

logs_run_logrotate() {
    local mode="$1"
    local force="${2:-false}"
    local logrotate_bin
    local cmd=()

    logrotate_bin=$(logs_logrotate_bin)
    if [[ ! -x "$logrotate_bin" ]]; then
        log_error "logrotate not found: $logrotate_bin"
        return 1
    fi

    cmd+=("$logrotate_bin")
    [[ "$mode" == "debug" ]] && cmd+=("-d")
    [[ "$force" == "true" ]] && cmd+=("-f")
    [[ -n "$LOGS_ROTATE_STATE_PATH" ]] && cmd+=("-s" "$LOGS_ROTATE_STATE_PATH")
    cmd+=("$LOGS_ROTATE_CONFIG_PATH")

    "${cmd[@]}"
}

logs_collect_status() {
    logs_load_config || return 1

    LOGS_STATUS_TIMESTAMP=$(date -Iseconds)
    LOGS_STATUS_CONFIG_PRESENT="false"
    LOGS_STATUS_CONFIG_IN_SYNC="false"
    LOGS_STATUS_LOG_ROOT_PRESENT="false"
    LOGS_STATUS_DISK_OK="false"
    LOGS_STATUS_SENSITIVE_PERMISSIONS_OK="true"

    if [[ -f "$LOGS_ROTATE_CONFIG_PATH" ]]; then
        LOGS_STATUS_CONFIG_PRESENT="true"
        if logs_config_in_sync; then
            LOGS_STATUS_CONFIG_IN_SYNC="true"
        fi
    fi

    if [[ -d "$LOGS_ROOT" ]]; then
        LOGS_STATUS_LOG_ROOT_PRESENT="true"
    fi

    local active_stats rotated_stats disk_data
    active_stats=$(logs_collect_file_stats "active")
    rotated_stats=$(logs_collect_file_stats "rotated")
    disk_data=$(logs_collect_disk_stats)

    LOGS_STATUS_ACTIVE_FILE_COUNT="${active_stats%%|*}"
    LOGS_STATUS_ACTIVE_SIZE_BYTES="${active_stats##*|}"
    LOGS_STATUS_ROTATED_FILE_COUNT="${rotated_stats%%|*}"
    LOGS_STATUS_ROTATED_SIZE_BYTES="${rotated_stats##*|}"

    LOGS_STATUS_DISK_TOTAL_KB="${disk_data%%|*}"
    disk_data="${disk_data#*|}"
    LOGS_STATUS_DISK_USED_KB="${disk_data%%|*}"
    disk_data="${disk_data#*|}"
    LOGS_STATUS_DISK_AVAILABLE_KB="${disk_data%%|*}"
    LOGS_STATUS_DISK_USED_PERCENT="${disk_data##*|}"

    [[ "$LOGS_STATUS_ACTIVE_FILE_COUNT" =~ ^[0-9]+$ ]] || LOGS_STATUS_ACTIVE_FILE_COUNT=0
    [[ "$LOGS_STATUS_ACTIVE_SIZE_BYTES" =~ ^[0-9]+$ ]] || LOGS_STATUS_ACTIVE_SIZE_BYTES=0
    [[ "$LOGS_STATUS_ROTATED_FILE_COUNT" =~ ^[0-9]+$ ]] || LOGS_STATUS_ROTATED_FILE_COUNT=0
    [[ "$LOGS_STATUS_ROTATED_SIZE_BYTES" =~ ^[0-9]+$ ]] || LOGS_STATUS_ROTATED_SIZE_BYTES=0
    [[ "$LOGS_STATUS_DISK_TOTAL_KB" =~ ^[0-9]+$ ]] || LOGS_STATUS_DISK_TOTAL_KB=0
    [[ "$LOGS_STATUS_DISK_USED_KB" =~ ^[0-9]+$ ]] || LOGS_STATUS_DISK_USED_KB=0
    [[ "$LOGS_STATUS_DISK_AVAILABLE_KB" =~ ^[0-9]+$ ]] || LOGS_STATUS_DISK_AVAILABLE_KB=0
    [[ "$LOGS_STATUS_DISK_USED_PERCENT" =~ ^[0-9]+$ ]] || LOGS_STATUS_DISK_USED_PERCENT=0

    local sensitive_count=0
    local file
    while IFS= read -r -d '' file; do
        sensitive_count=$((sensitive_count + 1))
    done < <(logs_find_sensitive_files)
    LOGS_STATUS_SENSITIVE_FILE_COUNT="$sensitive_count"

    if logs_sensitive_permissions_ok; then
        LOGS_STATUS_SENSITIVE_PERMISSIONS_OK="true"
    else
        LOGS_STATUS_SENSITIVE_PERMISSIONS_OK="false"
    fi

    if logs_check_disk_space; then
        LOGS_STATUS_DISK_OK="true"
    fi

    LOGS_STATUS_HEALTH="healthy"
    if [[ "$LOGS_STATUS_CONFIG_PRESENT" != "true" || "$LOGS_STATUS_CONFIG_IN_SYNC" != "true" || "$LOGS_STATUS_DISK_OK" != "true" || "$LOGS_STATUS_SENSITIVE_PERMISSIONS_OK" != "true" ]]; then
        LOGS_STATUS_HEALTH="degraded"
    fi
    if [[ "$LOGS_STATUS_LOG_ROOT_PRESENT" != "true" ]]; then
        LOGS_STATUS_HEALTH="missing"
    fi
}

logs_status_text() {
    logs_collect_status || {
        log_error "Failed to load configuration"
        return 1
    }

    local disk_free_mb=$((LOGS_STATUS_DISK_AVAILABLE_KB / 1024))

    echo "VMANGOS Log Rotation Status"
    echo "Timestamp: $LOGS_STATUS_TIMESTAMP"
    echo "Log Root: $LOGS_ROOT"
    echo "Health: $LOGS_STATUS_HEALTH"
    echo ""
    echo "Config:"
    echo "  File:    $LOGS_ROTATE_CONFIG_PATH"
    echo "  Present: $LOGS_STATUS_CONFIG_PRESENT"
    echo "  In sync: $LOGS_STATUS_CONFIG_IN_SYNC"
    echo ""
    echo "Logs:"
    echo "  Active files:        $LOGS_STATUS_ACTIVE_FILE_COUNT"
    echo "  Active size bytes:   $LOGS_STATUS_ACTIVE_SIZE_BYTES"
    echo "  Rotated files:       $LOGS_STATUS_ROTATED_FILE_COUNT"
    echo "  Rotated size bytes:  $LOGS_STATUS_ROTATED_SIZE_BYTES"
    echo "  Sensitive files:     $LOGS_STATUS_SENSITIVE_FILE_COUNT"
    echo "  Sensitive perms OK:  $LOGS_STATUS_SENSITIVE_PERMISSIONS_OK"
    echo ""
    echo "Disk:"
    echo "  OK:        $LOGS_STATUS_DISK_OK"
    echo "  Free MB:   $disk_free_mb"
    echo "  Used %:    $LOGS_STATUS_DISK_USED_PERCENT"
    echo "  Threshold: $LOGS_MIN_FREE_KB KB"
}

logs_status_json() {
    logs_collect_status || {
        json_output false "null" "CONFIG_ERROR" "Failed to load configuration" "Check config file exists and is readable"
        return 1
    }

    local data
    data=$(cat <<EOF
{
  "status": "$(json_escape "$LOGS_STATUS_HEALTH")",
  "log_root": "$(json_escape "$LOGS_ROOT")",
  "config": {
    "path": "$(json_escape "$LOGS_ROTATE_CONFIG_PATH")",
    "present": $LOGS_STATUS_CONFIG_PRESENT,
    "in_sync": $LOGS_STATUS_CONFIG_IN_SYNC
  },
  "logs": {
    "active_files": $LOGS_STATUS_ACTIVE_FILE_COUNT,
    "active_size_bytes": $LOGS_STATUS_ACTIVE_SIZE_BYTES,
    "rotated_files": $LOGS_STATUS_ROTATED_FILE_COUNT,
    "rotated_size_bytes": $LOGS_STATUS_ROTATED_SIZE_BYTES,
    "sensitive_files": $LOGS_STATUS_SENSITIVE_FILE_COUNT,
    "sensitive_permissions_ok": $LOGS_STATUS_SENSITIVE_PERMISSIONS_OK
  },
  "disk": {
    "path": "$(json_escape "$(logs_df_target)")",
    "ok": $LOGS_STATUS_DISK_OK,
    "total_kb": $LOGS_STATUS_DISK_TOTAL_KB,
    "used_kb": $LOGS_STATUS_DISK_USED_KB,
    "available_kb": $LOGS_STATUS_DISK_AVAILABLE_KB,
    "used_percent": $LOGS_STATUS_DISK_USED_PERCENT,
    "required_free_kb": $LOGS_MIN_FREE_KB
  },
  "policy": {
    "copytruncate": true,
    "retention_days": $LOGS_RETENTION_DAYS,
    "sensitive_retention_days": $LOGS_SENSITIVE_RETENTION_DAYS,
    "max_size": "$(json_escape "$LOGS_MAX_SIZE")",
    "min_size": "$(json_escape "$LOGS_MIN_SIZE")"
  }
}
EOF
)

    json_output true "$data"
}

logs_test_config() {
    logs_install_config || return 1

    if ! logs_run_logrotate "debug" "false" >/dev/null; then
        if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
            json_output false "null" "LOGROTATE_INVALID" "logrotate validation failed" "Run with --verbose or inspect the generated config"
        else
            log_error "logrotate validation failed"
        fi
        return 1
    fi

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "{\"config_path\":\"$(json_escape "$LOGS_ROTATE_CONFIG_PATH")\",\"valid\":true}"
    else
        log_info "Logrotate configuration is valid: $LOGS_ROTATE_CONFIG_PATH"
    fi
}

logs_rotate() {
    local force="${1:-false}"

    logs_install_config || return 1

    if ! logs_check_disk_space; then
        if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
            json_output false "null" "INSUFFICIENT_DISK" "Insufficient disk space for log rotation" "Free at least ${LOGS_MIN_FREE_KB} KB under $LOGS_ROOT"
        else
            log_error "Insufficient disk space for log rotation"
        fi
        return 1
    fi

    logs_harden_sensitive_permissions || return 1

    if ! logs_run_logrotate "rotate" "$force" >/dev/null; then
        if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
            json_output false "null" "LOGROTATE_FAILED" "logrotate execution failed" "Inspect logrotate output and generated config"
        else
            log_error "logrotate execution failed"
        fi
        return 1
    fi

    if [[ "${OUTPUT_FORMAT:-text}" == "json" ]]; then
        json_output true "{\"config_path\":\"$(json_escape "$LOGS_ROTATE_CONFIG_PATH")\",\"force\":$force,\"disk_precheck_ok\":true}"
    else
        log_info "Log rotation completed using $LOGS_ROTATE_CONFIG_PATH"
    fi
}
