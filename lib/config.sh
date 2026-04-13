#!/usr/bin/env bash
#
# Configuration module for VMANGOS Manager
# INI parsing, validation, and management
#

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ============================================================================
# GLOBALS
# ============================================================================

CONFIG_FILE="${MANAGER_CONFIG:-/opt/mangos/manager/config/manager.conf}"
CONFIG_PASSWORD_FILE=""

# Loaded config values (prefixed to avoid namespace collision)
CONFIG_DATABASE_HOST=""
CONFIG_DATABASE_PORT=""
CONFIG_DATABASE_USER=""
CONFIG_DATABASE_PASSWORD=""
CONFIG_DATABASE_AUTH_DB=""
CONFIG_DATABASE_CHARACTERS_DB=""
CONFIG_DATABASE_WORLD_DB=""

CONFIG_SERVER_AUTH_SERVICE=""
CONFIG_SERVER_WORLD_SERVICE=""
CONFIG_SERVER_INSTALL_ROOT=""
CONFIG_SERVER_DATA_DIR=""

CONFIG_BACKUP_ENABLED=""
CONFIG_BACKUP_RETENTION_DAYS=""

# ============================================================================
# INI PARSING
# ============================================================================

ini_read() {
    local file="$1"
    local section="$2"
    local key="$3"
    local default="${4:-}"
    
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return 1
    fi
    
    local value
    value=$(awk -F'=' -v sec="$section" -v k="$key" '
        /^\[/ { in_section = ($0 ~ "^\\[" sec "\\]") }
        in_section && $1 ~ "^" k "$" {
            gsub(/^[ \t]+|[ \t]+$/, "", $2)
            print $2
            exit
        }
    ' "$file")
    
    if [[ -z "$value" ]]; then
        value="$default"
    fi
    
    echo "$value"
}

# ============================================================================
# CONFIG LOADING
# ============================================================================

config_load() {
    local config_file="${1:-$CONFIG_FILE}"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi
    
    # Check permissions - should be 600
    local perms
    perms=$(stat -c "%a" "$config_file" 2>/dev/null || echo "644")
    if [[ "$perms" != "600" ]]; then
        log_warn "Config file permissions are $perms, should be 600"
    fi
    
    # Load database section
    CONFIG_DATABASE_HOST=$(ini_read "$config_file" "database" "host" "127.0.0.1")
    CONFIG_DATABASE_PORT=$(ini_read "$config_file" "database" "port" "3306")
    CONFIG_DATABASE_USER=$(ini_read "$config_file" "database" "user" "mangos")
    
    # Load password from file (more secure)
    CONFIG_PASSWORD_FILE=$(ini_read "$config_file" "database" "password_file" "")
    if [[ -f "${CONFIG_PASSWORD_FILE:-}" ]]; then
        CONFIG_DATABASE_PASSWORD=$(cat "$CONFIG_PASSWORD_FILE" 2>/dev/null || true)
    else
        CONFIG_DATABASE_PASSWORD=$(ini_read "$config_file" "database" "password" "")
    fi
    
    CONFIG_DATABASE_AUTH_DB=$(ini_read "$config_file" "database" "auth_db" "auth")
    CONFIG_DATABASE_CHARACTERS_DB=$(ini_read "$config_file" "database" "characters_db" "characters")
    CONFIG_DATABASE_WORLD_DB=$(ini_read "$config_file" "database" "world_db" "mangos")
    
    # Load server section
    CONFIG_SERVER_AUTH_SERVICE=$(ini_read "$config_file" "server" "auth_service" "auth")
    CONFIG_SERVER_WORLD_SERVICE=$(ini_read "$config_file" "server" "world_service" "world")
    CONFIG_SERVER_INSTALL_ROOT=$(ini_read "$config_file" "server" "install_root" "/opt/mangos")
    CONFIG_SERVER_DATA_DIR=$(ini_read "$config_file" "server" "data_dir" "/opt/mangos/data")
    
    # Load backup section
    CONFIG_BACKUP_ENABLED=$(ini_read "$config_file" "backup" "enabled" "true")
    CONFIG_BACKUP_RETENTION_DAYS=$(ini_read "$config_file" "backup" "retention_days" "30")
    
    log_debug "Configuration loaded from $config_file"
    return 0
}

# ============================================================================
# CONFIG CREATION
# ============================================================================

config_create() {
    local config_path="${1:-$CONFIG_FILE}"
    local password_file="${2:-}"
    
    log_info "Creating configuration at $config_path"
    
    # Create directory
    local config_dir
    config_dir=$(dirname "$config_path")
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir" || {
            log_error "Failed to create config directory: $config_dir"
            return 1
        }
    fi
    
    # Determine password file location
    if [[ -z "$password_file" ]]; then
        password_file="$config_dir/.dbpass"
    fi
    
    cat > "$config_path" << EOF
# VMANGOS Manager Configuration
# Auto-generated on $(date -Iseconds)
# NOTE: This file contains sensitive configuration. Mode: 600

[database]
host = 10.0.1.6
port = 3306
user = vmangos_mgr
; Password can be stored in a separate file (recommended) or inline
password_file = $password_file
; If password_file doesn't exist, falls back to inline password:
password = 

; Database names
auth_db = auth
characters_db = characters
world_db = mangos

[server]
; systemd service names
auth_service = auth
world_service = world

; Installation paths
install_root = /opt/mangos
data_dir = /opt/mangos/data

; Authentication and World server ports
auth_port = 3724
world_port = 8085

[backup]
enabled = true
backup_dir = /opt/mangos/backups
retention_days = 30

[logging]
log_file = /var/log/vmangos-manager.log
log_level = info
EOF

    # CRITICAL FIX: Set mode 600 for security (credential material)
    chmod 600 "$config_path"
    
    # Create password file with proper permissions if it doesn't exist
    if [[ ! -f "$password_file" ]]; then
        touch "$password_file"
        chmod 600 "$password_file"
        log_info "Created password file: $password_file (mode 600)"
    fi
    
    log_info "Configuration created at $config_path (mode 600)"
    log_info "IMPORTANT: Edit $password_file and add the database password"
}

# ============================================================================
# CONFIG VALIDATION
# ============================================================================

config_validate() {
    local config_file="${1:-$CONFIG_FILE}"
    local output_format="${2:-text}"
    
    local errors=()
    local warnings=()
    
    if [[ ! -f "$config_file" ]]; then
        errors+=("Config file not found: $config_file")
        if [[ "$output_format" == "json" ]]; then
            json_output false "null" "CONFIG_NOT_FOUND" "$config_file" "Run 'vmangos-manager config create'"
        else
            log_error "Config file not found: $config_file"
            log_info "Run: vmangos-manager config create"
        fi
        return 1
    fi
    
    # Check permissions
    local perms
    perms=$(stat -c "%a" "$config_file" 2>/dev/null || echo "unknown")
    if [[ "$perms" != "600" ]]; then
        warnings+=("Config file permissions are $perms (should be 600)")
    fi
    
    # Required fields
    local required_fields=(
        "database:host"
        "database:port"
        "database:user"
        "database:password_file"
        "server:auth_service"
        "server:world_service"
        "server:install_root"
    )
    
    for field in "${required_fields[@]}"; do
        local section key value
        section="${field%%:*}"
        key="${field##*:}"
        value=$(ini_read "$config_file" "$section" "$key")
        
        if [[ -z "$value" ]]; then
            errors+=("Missing required field: [$section] $key")
        fi
    done
    
    # Check password file exists
    local password_file
    password_file=$(ini_read "$config_file" "database" "password_file")
    if [[ -n "$password_file" && ! -f "$password_file" ]]; then
        warnings+=("Password file does not exist: $password_file")
    elif [[ -n "$password_file" && -f "$password_file" ]]; then
        local pass_perms
        pass_perms=$(stat -c "%a" "$password_file" 2>/dev/null || echo "unknown")
        if [[ "$pass_perms" != "600" ]]; then
            warnings+=("Password file permissions are $pass_perms (should be 600)")
        fi
    fi
    
    # Check install_root exists
    local install_root
    install_root=$(ini_read "$config_file" "server" "install_root")
    if [[ -n "$install_root" && ! -d "$install_root" ]]; then
        warnings+=("Install root directory does not exist: $install_root")
    fi
    
    # Output results
    if [[ "$output_format" == "json" ]]; then
        local data="{\"valid\": $( [[ ${#errors[@]} -eq 0 ]] && echo true || echo false ), \"errors\": [], \"warnings\": []}"
        json_output "$([[ ${#errors[@]} -eq 0 ]] && echo true || echo false)" "$data"
    else
        echo ""
        echo "Config File: $config_file"
        echo "Permissions: $perms"
        echo ""
        
        if [[ ${#errors[@]} -eq 0 && ${#warnings[@]} -eq 0 ]]; then
            echo "✓ Configuration is valid"
            return 0
        fi
        
        if [[ ${#errors[@]} -gt 0 ]]; then
            echo "Errors:"
            for err in "${errors[@]}"; do
                echo "  ✗ $err"
            done
            echo ""
        fi
        
        if [[ ${#warnings[@]} -gt 0 ]]; then
            echo "Warnings:"
            for warn in "${warnings[@]}"; do
                echo "  ⚠ $warn"
            done
        fi
        
        return $([[ ${#errors[@]} -eq 0 ]] && echo 0 || echo 1)
    fi
}

# ============================================================================
# CONFIG SHOW
# ============================================================================

config_show() {
    local config_file="${1:-$CONFIG_FILE}"
    local output_format="${2:-text}"
    
    if [[ ! -f "$config_file" ]]; then
        if [[ "$output_format" == "json" ]]; then
            json_output false "null" "CONFIG_NOT_FOUND" "Configuration file not found: $config_file" "Run 'config create' first"
        else
            log_error "Configuration file not found: $config_file"
            log_info "Run: vmangos-manager config create"
        fi
        return 1
    fi
    
    if [[ "$output_format" == "json" ]]; then
        json_output true "{\"config_file\": \"$config_file\", \"content\": \"$(json_escape "$(cat "$config_file")")\"}"
    else
        echo "=== Configuration File: $config_file ==="
        echo ""
        cat "$config_file"
    fi
}
