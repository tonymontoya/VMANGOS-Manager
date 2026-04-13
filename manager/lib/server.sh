#!/usr/bin/env bash
# shellcheck source=lib/common.sh
# shellcheck source=lib/config.sh
#
# Server control module for VMANGOS Manager
# Start, stop, restart, and status of auth and world services
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ============================================================================
# CONFIGURATION (Loaded from config file, not hardcoded)
# ============================================================================

SERVER_CONFIG_LOADED=""
AUTH_SERVICE=""
WORLD_SERVICE=""
INSTALL_ROOT=""
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""
AUTH_DB=""

# ============================================================================
# CONFIG LOADING
# ============================================================================

server_load_config() {
    [[ "$SERVER_CONFIG_LOADED" == "1" ]] && return 0
    
    config_load "$CONFIG_FILE" || {
        log_error "Failed to load configuration"
        return 1
    }
    
    AUTH_SERVICE="${CONFIG_SERVER_AUTH_SERVICE:-auth}"
    WORLD_SERVICE="${CONFIG_SERVER_WORLD_SERVICE:-world}"
    INSTALL_ROOT="${CONFIG_SERVER_INSTALL_ROOT:-/opt/mangos}"
    DB_HOST="${CONFIG_DATABASE_HOST:-127.0.0.1}"
    DB_PORT="${CONFIG_DATABASE_PORT:-3306}"
    DB_USER="${CONFIG_DATABASE_USER:-mangos}"
    DB_PASS="${CONFIG_DATABASE_PASSWORD:-}"
    AUTH_DB="${CONFIG_DATABASE_AUTH_DB:-auth}"
    
    SERVER_CONFIG_LOADED="1"
    log_debug "Server configuration loaded"
}

# ============================================================================
# DATABASE UTILITIES (Config-driven credentials)
# ============================================================================

db_check_connection() {
    if [[ -n "$DB_PASS" ]]; then
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -e "SELECT 1" "$AUTH_DB" >/dev/null 2>&1
    else
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -e "SELECT 1" "$AUTH_DB" >/dev/null 2>&1
    fi
}

get_online_player_count() {
    local count
    if [[ -n "$DB_PASS" ]]; then
        count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -N -B -e "SELECT COUNT(*) FROM $AUTH_DB.account WHERE online = 1" 2>/dev/null || echo 0)
    else
        count=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -N -B -e "SELECT COUNT(*) FROM $AUTH_DB.account WHERE online = 1" 2>/dev/null || echo 0)
    fi
    
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi
}

# ============================================================================
# PRE-FLIGHT CHECKS (Config-driven paths)
# ============================================================================

preflight_check() {
    local error_count=0
    
    log_info "Running pre-flight checks..."
    
    server_load_config || return 1
    
    # Check database connectivity
    if ! db_check_connection; then
        log_error "Database connectivity check failed"
        error_count=$((error_count + 1))
    else
        log_info "✓ Database connectivity OK"
    fi
    
    # Check disk space (using config-driven install root)
    local available
    available=$(df "$INSTALL_ROOT" | awk 'NR==2 {print $4}')
    if [[ "$available" -lt 512000 ]]; then
        log_error "Insufficient disk space: ${available}KB available, need 500MB"
        error_count=$((error_count + 1))
    else
        log_info "✓ Disk space OK"
    fi
    
    # Check config files exist (config-driven paths)
    if [[ ! -f "$INSTALL_ROOT/run/etc/mangosd.conf" ]]; then
        log_error "mangosd.conf not found at $INSTALL_ROOT/run/etc/mangosd.conf"
        error_count=$((error_count + 1))
    fi
    
    if [[ ! -f "$INSTALL_ROOT/run/etc/realmd.conf" ]]; then
        log_error "realmd.conf not found at $INSTALL_ROOT/run/etc/realmd.conf"
        error_count=$((error_count + 1))
    fi
    
    return "$error_count"
}

# ============================================================================
# SERVER START
# ============================================================================

server_start() {
    local wait="${1:-false}"
    local timeout="${2:-60}"
    
    log_section "Starting VMANGOS Server"
    
    server_load_config || error_exit "Failed to load configuration" "$E_CONFIG_ERROR"
    
    if ! preflight_check; then
        error_exit "Pre-flight checks failed" "$E_SERVICE_ERROR"
    fi
    
    # Start auth service first
    log_info "Starting auth service..."
    if service_active "$AUTH_SERVICE"; then
        log_info "Auth service already running"
    else
        if ! service_start "$AUTH_SERVICE"; then
            error_exit "Failed to start auth service" "$E_SERVICE_ERROR"
        fi
        
        if [[ "$wait" == "true" ]]; then
            log_info "Waiting for auth service to be ready..."
            local count=0
            while ! service_active "$AUTH_SERVICE" && [[ $count -lt 10 ]]; do
                sleep 1
                count=$((count + 1))
            done
            
            if ! service_active "$AUTH_SERVICE"; then
                error_exit "Auth service failed to start within 10s" "$E_SERVICE_ERROR"
            fi
        fi
    fi
    
    # Start world service
    log_info "Starting world service..."
    if service_active "$WORLD_SERVICE"; then
        log_info "World service already running"
    else
        if ! service_start "$WORLD_SERVICE"; then
            error_exit "Failed to start world service" "$E_SERVICE_ERROR"
        fi
        
        if [[ "$wait" == "true" ]]; then
            log_info "Waiting for world service to initialize..."
            local count=0
            while [[ $count -lt $timeout ]]; do
                sleep 1
                count=$((count + 1))
                
                if service_active "$WORLD_SERVICE"; then
                    sleep 2
                    if service_active "$WORLD_SERVICE"; then
                        log_info "World service is running"
                        break
                    fi
                fi
            done
            
            if ! service_active "$WORLD_SERVICE"; then
                error_exit "World service failed to start within ${timeout}s" "$E_SERVICE_ERROR"
            fi
        fi
    fi
    
    log_info "✓ Server started successfully"
}

# ============================================================================
# SERVER STOP
# ============================================================================

server_stop() {
    local graceful="${1:-true}"
    local force="${2:-false}"
    
    log_section "Stopping VMANGOS Server"
    
    server_load_config || error_exit "Failed to load configuration" "$E_CONFIG_ERROR"
    
    if [[ "$force" == "true" ]]; then
        graceful="false"
    fi
    
    # Stop world service first
    if service_active "$WORLD_SERVICE"; then
        log_info "Stopping world service..."
        
        if [[ "$graceful" == "true" ]]; then
            if ! systemctl stop "$WORLD_SERVICE"; then
                log_warn "Graceful stop failed, forcing..."
                systemctl kill -s SIGTERM "$WORLD_SERVICE" 2>/dev/null || true
                sleep 5
            fi
        else
            systemctl stop "$WORLD_SERVICE" || true
        fi
        
        if service_active "$WORLD_SERVICE" && [[ "$force" == "true" ]]; then
            log_warn "Force killing world service..."
            systemctl kill -s SIGKILL "$WORLD_SERVICE" 2>/dev/null || true
            sleep 2
        fi
    else
        log_info "World service not running"
    fi
    
    # Stop auth service
    if service_active "$AUTH_SERVICE"; then
        log_info "Stopping auth service..."
        systemctl stop "$AUTH_SERVICE" || true
    else
        log_info "Auth service not running"
    fi
    
    log_info "✓ Server stopped"
}

# ============================================================================
# SERVER RESTART
# ============================================================================

server_restart() {
    log_section "Restarting VMANGOS Server"
    
    server_stop true false
    sleep 2
    server_start true 60
}

# ============================================================================
# SERVER STATUS (TEXT)
# ============================================================================

server_status_text() {
    log_section "VMANGOS Server Status"
    
    server_load_config || {
        log_error "Failed to load configuration"
        return 1
    }
    
    local auth_status world_status auth_pid world_pid
    
    if service_active "$AUTH_SERVICE"; then
        auth_status="running"
        auth_pid=$(systemctl show -p MainPID "$AUTH_SERVICE" | cut -d= -f2)
    else
        auth_status="stopped"
        auth_pid="N/A"
    fi
    
    if service_active "$WORLD_SERVICE"; then
        world_status="running"
        world_pid=$(systemctl show -p MainPID "$WORLD_SERVICE" | cut -d= -f2)
    else
        world_status="stopped"
        world_pid="N/A"
    fi
    
    echo ""
    echo "Services:"
    echo "  Auth Server:  $auth_status (PID: $auth_pid)"
    echo "  World Server: $world_status (PID: $world_pid)"
    echo ""
    
    if [[ "$world_status" == "running" ]]; then
        local mem_usage cpu_usage
        mem_usage=$(ps -p "$world_pid" -o rss= 2>/dev/null | awk '{print $1/1024 " MB"}')
        cpu_usage=$(ps -p "$world_pid" -o %cpu= 2>/dev/null || echo "N/A")
        echo "Resource Usage (World):"
        echo "  Memory: $mem_usage"
        echo "  CPU:    $cpu_usage%"
        echo ""
        
        local player_count
        player_count=$(get_online_player_count)
        echo "Players Online: $player_count"
        echo ""
    fi
}

# ============================================================================
# SERVER STATUS (JSON)
# ============================================================================

server_status_json() {
    server_load_config || {
        json_output false "null" "CONFIG_ERROR" "Failed to load configuration" "Check config file exists and is readable"
        return 1
    }
    
    local auth_status="stopped"
    local world_status="stopped"
    local auth_pid=0
    local world_pid=0
    local world_mem=0
    local online_players=0
    
    if service_active "$AUTH_SERVICE"; then
        auth_status="running"
        auth_pid=$(systemctl show -p MainPID "$AUTH_SERVICE" | cut -d= -f2)
    fi
    
    if service_active "$WORLD_SERVICE"; then
        world_status="running"
        world_pid=$(systemctl show -p MainPID "$WORLD_SERVICE" | cut -d= -f2)
        world_mem=$(ps -p "$world_pid" -o rss= 2>/dev/null || echo 0)
        world_mem=$((world_mem / 1024))
        online_players=$(get_online_player_count)
    fi
    
    local data
    data=$(cat <<EOF
{
  "services": {
    "auth": {
      "status": "$auth_status",
      "running": $( [[ "$auth_status" == "running" ]] && echo true || echo false ),
      "pid": $auth_pid
    },
    "world": {
      "status": "$world_status",
      "running": $( [[ "$world_status" == "running" ]] && echo true || echo false ),
      "pid": $world_pid,
      "memory_mb": $world_mem,
      "players_online": $online_players
    }
  }
}
EOF
)
    
    json_output true "$data"
}

# ============================================================================
# UTILITY
# ============================================================================

log_section() {
    echo ""
    log_info "========================================"
    log_info "$1"
    log_info "========================================"
}
