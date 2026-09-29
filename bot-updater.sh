#!/usr/bin/env bash
# ==============================================================================
# Script:       bot-updater.sh
# Repository:   antwnhsx/nfi-orchestrator
# Description:  A lightweight, low-write remote orchestration and backup script
#               for Freqtrade + NFI trading bots running via Docker Compose over
#               SSH. Includes safety checks, offsite streaming backups, and
#               automatic recovery.
#
# Usage:        ./bot-updater.sh [options] [arguments]
# Options:      -h, --help            Show this help message and exit
#               -t, --target <name>   Section target name in configuration file (Required)
#               -c, --config <path>   Path to configuration file (Default: ./updater.conf)
#               -d, --dry-run         Simulate steps without making changes
#               -v, --verbose         Enable verbose log output to stdout
#               -q, --quiet           Suppress non-error output to stdout
#               -D, --debug           Enable debug-level output (also via DEBUG=1)
# ==============================================================================

set -euo pipefail

# ==============================================================================
# 1. GLOBALS & DEFAULTS
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/updater.conf"
DRY_RUN=false
VERBOSITY="normal"     # quiet, normal, verbose
DEBUG_MODE=false

# Auto-enable debug mode if DEBUG environment variable is set to 1
if [[ "${DEBUG:-0}" == "1" ]]; then
    DEBUG_MODE=true
    VERBOSITY="verbose"
fi

TARGET_SECTION=""
CONTAINER_STOPPED=false
readonly MIN_FREE_DISK_KB=512000   # 500 MB minimum requirement

# Runtime variables
SSH_CONN=""
REMOTE_COMPOSE_CMD=""
TARGET_BACKUP_DIR=""

# ==============================================================================
# 2. CLI PARSING
# ==============================================================================

usage() {
cat <<EOF
Usage: $(basename "$0") [OPTIONS] -t <target_profile>

Options:
  -t, --target <name>   Section target name in configuration file (Required)
  -c, --config <path>   Path to configuration file (Default: ./updater.conf)
  -d, --dry-run         Simulate steps without making changes
  -v, --verbose         Enable verbose log output to stdout
  -q, --quiet           Suppress non-error output to stdout
  -D, --debug           Enable debug output
  -h, --help            Show this help menu
EOF
exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target) 
                [[ $# -lt 2 ]] && { echo "Error: Missing value for $1" >&2; usage; }
                TARGET_SECTION="$2"; shift 2 ;;
            -c|--config) 
                [[ $# -lt 2 ]] && { echo "Error: Missing value for $1" >&2; usage; }
                CONFIG_FILE="$2"; shift 2 ;;
            -d|--dry-run) DRY_RUN=true; shift ;;
            -v|--verbose) VERBOSITY="verbose"; shift ;;
            -q|--quiet) VERBOSITY="quiet"; shift ;;
            -D|--debug) DEBUG_MODE=true; VERBOSITY="verbose"; shift ;;
            -h|--help) usage ;;
            *) echo "Unknown parameter: $1" >&2; usage ;;
        esac
    done

    # Enable execution tracing strictly when debug mode is enabled
    if [[ "$DEBUG_MODE" == "true" ]]; then
        set -vx
    fi

    if [[ -z "$TARGET_SECTION" ]]; then
        echo "Error: Target profile (-t|--target) is required." >&2
        usage
    fi

    if [[ ! "$TARGET_SECTION" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]; then
        echo "Error: Invalid target name '$TARGET_SECTION'." >&2
        exit 1
    fi

    if [[ ! "${CONFIG_FILE}" == /* ]]; then
        CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
    fi
}

# ==============================================================================
# 3. LOGGING ENGINE
# ==============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # File Logging
    if [[ -n "${LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
    fi

    # Console Output Routing
    case "$level" in
        DEBUG)
            [[ "$DEBUG_MODE" == "true" ]] && echo "[$timestamp] [DEBUG] $msg"
            ;;
        INFO)
            [[ "$VERBOSITY" != "quiet" ]] && echo "[$timestamp] [INFO] $msg"
            ;;
        WARN)
            if [[ "$VERBOSITY" != "quiet" ]]; then
                echo "[$timestamp] [WARN] $msg"
            else
                echo "[$timestamp] [WARN] $msg" >&2
            fi
            ;;
        ERROR)
            echo "[$timestamp] [ERROR] $msg" >&2
            # Automatically dispatch critical errors to Telegram
            notify_telegram "🚨 [ERROR] $msg"
            ;;
    esac
}

# Captures command outputs and mirrors to log file if configured
exec_logged() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        "$@"
    fi
}

# ==============================================================================
# 4. CONFIG LOADING & VALIDATION
# ==============================================================================

check_for_lock() {
    local lock_dir="${XDG_RUNTIME_DIR:-$HOME/.cache/bot-updater}"
    mkdir -p -m 700 "$lock_dir"
    LOCK_FILE="${lock_dir}/bot-updater-${TARGET_SECTION}.lock"
    exec 200>"$LOCK_FILE"

    if ! flock -n 200; then
        log "ERROR" "Another bot-updater run for target '$TARGET_SECTION' is already in progress."
        exit 1
    fi
}

parse_config() {
    local file="$1"
    local section="$2"

    if [[ ! -f "$file" ]]; then
        log "ERROR" "Config file '$file' not found."
        exit 1
    fi

    if ! grep -q "^\\[$section\\]" "$file"; then
        log "ERROR" "Section [$section] not found in config file."
        exit 1
    fi

    local in_section=0
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^[#\;] ]] && continue

        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=1
            else
                in_section=0
            fi
            continue
        fi

        if (( in_section )) && [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"
            value="${value//\$HOME/$HOME}"
            value="${value/#\~/$HOME}"

            declare -g "$key=$value"
        fi
    done < "$file"
}

validate_config() {
    log "DEBUG" "Loaded config section [$TARGET_SECTION] from $CONFIG_FILE"

    : "${ENABLED:="true"}"
    if [[ "$ENABLED" != "true" ]]; then
        log "INFO" "Target [$TARGET_SECTION] is currently disabled. Exiting."
        exit 0
    fi

    : "${SSH_USER:?Config SSH_USER missing}"
    : "${SSH_HOST:?Config SSH_HOST missing}"
    : "${REMOTE_BOT_DIR:?Config REMOTE_BOT_DIR missing}"
    : "${SSH_PORT:="22"}"
    : "${SSH_KEY_FILE:=""}"
    : "${BACKUP_BASE_DIR:="$HOME/bot-updater/backups"}"
    : "${EXCLUDE_PATTERNS:=""}"
    : "${RETENTION_DAYS:=0}"
    : "${FORCE_UPDATE:="false"}"

    log "DEBUG" "Config settings: SSH_HOST=$SSH_HOST SSH_PORT=$SSH_PORT REMOTE_BOT_DIR=$REMOTE_BOT_DIR BACKUP_BASE_DIR=$BACKUP_BASE_DIR RETENTION_DAYS=$RETENTION_DAYS FORCE_UPDATE=$FORCE_UPDATE"
}

# ==============================================================================
# 5. SSH / REMOTE EXECUTION HELPERS
# ==============================================================================

init_ssh() {
    local ssh_cmd="ssh -p $SSH_PORT -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
    if [[ -n "$SSH_KEY_FILE" ]]; then
        ssh_cmd="$ssh_cmd -i $SSH_KEY_FILE"
    fi
    SSH_CONN="$ssh_cmd $SSH_USER@$SSH_HOST"
}

# ==============================================================================
# 6. NOTIFICATION HELPERS
# ==============================================================================

notify_telegram() {
    local msg="$1"
    
    # Skip if credentials are missing
    [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0

    # Non-blocking async dispatch with background execution to avoid slowing workflow
    (
        curl -s -m 5 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${msg}" > /dev/null 2>&1
    ) &
}

# High-level wrapper for unified dispatch
notify() {
    local level="$1"
    shift
    local msg="$*"

    # First record to standard local log engine
    log "$level" "$msg"

    # Route specific event levels to Telegram
    case "$level" in
        WARN|ERROR)
            notify_telegram "[$level] [$TARGET_SECTION] $msg"
            ;;
        EVENT)
            notify_telegram "[$TARGET_SECTION] $msg"
            ;;
    esac
}

# ==============================================================================
# 7. SAFETY / RECOVERY
# ==============================================================================

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        notify_telegram "❌ Script failed unexpectedly with exit code $exit_code for target: $TARGET_SECTION"
    fi

    if [[ "$CONTAINER_STOPPED" == "true" ]]; then
        log "WARN" "Script interrupted or failed! Attempting remote container recovery..."
        if $SSH_CONN "cd '$REMOTE_BOT_DIR' && ${REMOTE_COMPOSE_CMD:-docker compose} up -d"; then
            notify_telegram "🔄 Recovery successful: Container restarted on $TARGET_SECTION"
        else
            notify_telegram "🔥 RECOVERY FAILED: Container is offline on $TARGET_SECTION!"
        fi
    fi
}

install_trap() {
    trap cleanup EXIT
}

# ==============================================================================
# 8. WORKFLOW STEPS
# ==============================================================================

step_check_connectivity() {
    log "DEBUG" "Checking SSH connectivity..."
    if ! $SSH_CONN "exit" 2>/dev/null; then
        log "ERROR" "Could not connect to remote host $SSH_HOST via SSH."
        exit 1
    fi
}

step_detect_compose() {
    REMOTE_COMPOSE_CMD=$($SSH_CONN "if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then echo 'docker compose'; elif command -v docker-compose >/dev/null 2>&1; then echo 'docker-compose'; fi")

    if [[ -z "$REMOTE_COMPOSE_CMD" ]]; then
        log "ERROR" "Neither 'docker compose' nor 'docker-compose' is installed on remote host."
        exit 1
    fi
    log "DEBUG" "Using remote compose command: '$REMOTE_COMPOSE_CMD'"
}

step_check_git_updates() {
    log "INFO" "Checking remote repository for git updates..."
    local is_behind
    is_behind=$($SSH_CONN "cd '$REMOTE_BOT_DIR' && git fetch origin >/dev/null 2>&1 && LOCAL=\$(git rev-parse HEAD) && REMOTE=\$(git rev-parse @{u}) && [ \$LOCAL != \$REMOTE ] && echo 'yes' || echo 'no'")
    log "DEBUG" "IS_BEHIND=$is_behind"

    if [[ "$is_behind" == "no" ]]; then
        log "INFO" "Remote repository is up-to-date with upstream branch. No updates required."
        notify_telegram "Remote repository is up-to-date with upstream branch. No updates required for: $TARGET_SECTION"
        exit 0
    fi
    log "INFO" "New commits detected on upstream git repository."
}

step_safety_check_open_trades() {
    [[ -z "${API_ENDPOINT:-}" ]] && return 0

    log "INFO" "Executing safety check via API..."
    local api_url="http://${API_HOST}:${API_PORT}${API_ENDPOINT}"
    local open_trades
    open_trades=$(curl -s --max-time 10 "$api_url" | grep -o '"count": *[0-9]*' | grep -o '[0-9]*' || echo "0")
    log "DEBUG" "API_URL=$api_url OPEN_TRADES=$open_trades"

    if [[ "$open_trades" =~ ^[0-9]+$ ]] && [[ "$open_trades" -gt 0 ]]; then
        if [[ "$FORCE_UPDATE" == "true" ]]; then
            log "WARN" "$open_trades active position(s) detected, but FORCE_UPDATE=true, continuing anyway."
            notify_telegram "⚠️ Continuing update for $TARGET_SECTION despite $open_trades active position(s) (FORCE_UPDATE enabled)."
        else
            log "WARN" "Safety check failed: $open_trades active positions detected! Aborting update."
            notify_telegram "⚠️ Update aborted for $TARGET_SECTION: $open_trades active positions."
            exit 0
        fi
    else
        log "INFO" "Safety check passed. 0 active positions."
    fi
}

step_check_disk_space() {
    TARGET_BACKUP_DIR="${BACKUP_BASE_DIR}/${TARGET_SECTION}"
    mkdir -p "$TARGET_BACKUP_DIR"
    local free_disk_kb
    free_disk_kb=$(df -k "$TARGET_BACKUP_DIR" | awk 'NR==2 {print $4}')
    log "DEBUG" "TARGET_BACKUP_DIR=$TARGET_BACKUP_DIR FREE_DISK_KB=$free_disk_kb MIN_FREE_DISK_KB=$MIN_FREE_DISK_KB"

    if [[ "$free_disk_kb" -lt "$MIN_FREE_DISK_KB" ]]; then
        log "ERROR" "Insufficient local storage space! Required: ${MIN_FREE_DISK_KB}KB, Free: ${free_disk_kb}KB"
        exit 1
    fi
}

step_stop_container() {
    log "INFO" "Stopping remote docker container..."
    $SSH_CONN "cd '$REMOTE_BOT_DIR' && $REMOTE_COMPOSE_CMD down"
    CONTAINER_STOPPED=true
}

step_backup() {
    local backup_filename="${TARGET_SECTION}_$(date +%Y%m%d_%H%M%S).tar.gz"
    local local_backup_path="${TARGET_BACKUP_DIR}/${backup_filename}"

    log "INFO" "Streaming remote backup to $local_backup_path..."

    local exclude_opts=()
    for pattern in $EXCLUDE_PATTERNS; do
        exclude_opts+=(--exclude="$pattern")
    done

    $SSH_CONN "cd '$REMOTE_BOT_DIR' && tar ${exclude_opts[*]:-} -czf - ." > "$local_backup_path"
    log "INFO" "Backup streamed successfully."
    log "DEBUG" "Backup file size: $(du -k "$local_backup_path" 2>/dev/null | awk '{print $1}')KB"
}

step_apply_updates() {
    log "INFO" "Applying git updates on remote host..."
    exec_logged $SSH_CONN "cd '$REMOTE_BOT_DIR' && git pull"
}

step_restart_container() {
    log "INFO" "Restarting remote docker container..."
    $SSH_CONN "cd '$REMOTE_BOT_DIR' && $REMOTE_COMPOSE_CMD up -d"
    CONTAINER_STOPPED=false
}

step_retention_cleanup() {
    [[ "$RETENTION_DAYS" -le 0 ]] && return 0

    log "INFO" "Cleaning up local backups older than $RETENTION_DAYS days..."
    find "$TARGET_BACKUP_DIR" -name "*.tar.gz" -type f -mtime +"$RETENTION_DAYS" -delete
    notify_telegram "Cleared old backups for: $TARGET_SECTION"
}

# ==============================================================================
# 9. MAIN
# ==============================================================================

main() {
    parse_args "$@"

    check_for_lock

    parse_config "$CONFIG_FILE" "$TARGET_SECTION"
    validate_config

    init_ssh
    install_trap

    log "INFO" "=== Starting bot-updater for [$TARGET_SECTION] ==="
    notify_telegram "Starting bot-updater for: $TARGET_SECTION"

    step_check_connectivity
    step_detect_compose
    step_check_git_updates
    step_safety_check_open_trades
    step_check_disk_space

    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "[DRY-RUN] Pre-flight checks passed. Would stop container, stream backup local, update git repository, and restart container."
        exit 0
    fi

    step_stop_container
    step_backup
    step_apply_updates
    step_restart_container
    step_retention_cleanup

    log "INFO" "=== Update completed successfully for [$TARGET_SECTION] ==="
    notify_telegram "✅ Successfully updated bot instance: $TARGET_SECTION"
}

main "$@"