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
#
# Environment Variables:
#               DEBUG         Set to 1 to enable debug mode
#
# Structure:    This script is organized into clearly separated sections so
#               new functionality can be added without touching unrelated
#               code:
#                 1. Globals & Defaults
#                 2. CLI Parsing
#                 3. Logging Engine
#                 4. Config Loading & Validation
#                 5. SSH / Remote Execution Helpers
#                 6. Notification Helpers
#                 7. Safety / Recovery (trap + cleanup)
#                 8. Workflow Steps (one function per numbered step)
#                 9. main() — orchestrates the steps in order
#
#               To add a new step: write a `step_xxx()` function in section 8
#               and call it from `main()` in section 9. Keep each step
#               self-contained and idempotent where possible.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# 1. GLOBALS & DEFAULTS
# ==============================================================================

CONFIG_FILE="./updater.conf"
DRY_RUN=false
VERBOSITY="normal"     # quiet, normal, verbose
DEBUG_MODE=false
[[ "${DEBUG:-0}" == "1" ]] && DEBUG_MODE=true
TARGET_SECTION=""
CONTAINER_STOPPED=false
readonly MIN_FREE_DISK_KB=512000   # 500 MB minimum requirement

# Populated later
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
  -D, --debug           Enable debug-level output (also via DEBUG=1)
  -h, --help            Show this help menu
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target) TARGET_SECTION="$2"; shift 2 ;;
            -c|--config) CONFIG_FILE="$2"; shift 2 ;;
            -d|--dry-run) DRY_RUN=true; shift ;;
            -v|--verbose) VERBOSITY="verbose"; shift ;;
            -q|--quiet) VERBOSITY="quiet"; shift ;;
            -D|--debug) DEBUG_MODE=true; shift ;;
            -h|--help) usage ;;
            *) echo "Unknown parameter: $1"; usage ;;
        esac
    done

    if [[ -z "$TARGET_SECTION" ]]; then
        echo "Error: Target profile (-t|--target) is required." >&2
        usage
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

    if [[ -n "${LOG_FILE:-}" ]]; then
        # SECURITY NOTE: `eval` here expands `~`/env vars embedded in LOG_FILE.
        # Preserved from the original for behavioral parity; if LOG_FILE ever
        # becomes user-influenced (vs. trusted config), replace with a safe
        # tilde/env expansion instead of eval.
        eval local log_path="$LOG_FILE"
        mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
        echo "[$timestamp] [$level] $msg" >> "$log_path"
    fi

    case "$VERBOSITY" in
        quiet)   [[ "$level" == "ERROR" ]] && echo "[$level] $msg" >&2 ;;
        normal)  [[ "$level" != "DEBUG" || "$DEBUG_MODE" == "true" ]] && echo "[$timestamp] [$level] $msg" ;;
        verbose) echo "[$timestamp] [$level] $msg" ;;
    esac
    return 0
}

# Captures raw command outputs (like git pull / docker compose) and appends to log.
exec_logged() {
    if [[ -n "${LOG_FILE:-}" ]]; then
        eval local log_path="$LOG_FILE"
        "$@" 2>&1 | tee -a "$log_path"
    else
        "$@"
    fi
}

# ==============================================================================
# 4. CONFIG LOADING & VALIDATION
# ==============================================================================

# Prevent overlapping runs for the same target.
check_for_lock() {
    LOCK_FILE="/tmp/bot-updater-${TARGET_SECTION}.lock"
    exec 200>"$LOCK_FILE"

    if ! flock -n 200; then
      echo "Error: another bot-updater run for target '$TARGET_SECTION' is already in progress." >&2
      exit 1
    fi
}

# Parses a single INI-style section out of $file into the current shell's
# environment via `eval`. SECURITY NOTE: as with log(), this trusts
# the contents of the config file.
parse_config() {
    local file="$1"
    local section="$2"

    if [[ ! -f "$file" ]]; then
        echo "Error: Config file '$file' not found." >&2
        exit 1
    fi

    eval "$(awk -F '=' -v target="[$section]" '
        BEGIN { in_target=0 }
        /^\[/ { in_target = ($0 == target) }
        in_target && /^[^#;]/ && /=/ {
          gsub(/[ \t]+$/, "", $1); gsub(/^[ \t]+/, "", $1);
          gsub(/[ \t]+$/, "", $2); gsub(/^[ \t]+/, "", $2);
          print $1 "=" $2
        }
      ' "$file")"
}

# Sets defaults for optional keys and hard-fails on missing required keys.
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

    log "DEBUG" "Config: SSH_HOST=$SSH_HOST SSH_PORT=$SSH_PORT REMOTE_BOT_DIR=$REMOTE_BOT_DIR BACKUP_BASE_DIR=$BACKUP_BASE_DIR RETENTION_DAYS=$RETENTION_DAYS FORCE_UPDATE=$FORCE_UPDATE"
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

send_telegram() {
    local msg="$1"
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=${msg}" > /dev/null || true
    fi
}

# ==============================================================================
# 7. SAFETY / RECOVERY
# ==============================================================================

cleanup() {
    # if [[ -n "${LOCK_FILE:-}" ]]; then
    #     flock -u 200 2>/dev/null || true
    #     rm -f "$LOCK_FILE" 2>/dev/null || true
    # fi

    if [[ "$CONTAINER_STOPPED" == "true" ]]; then
        log "WARN" "Script interrupted or failed! Attempting remote container recovery..."
        $SSH_CONN "cd '$REMOTE_BOT_DIR' && ${REMOTE_COMPOSE_CMD:-docker compose} up -d" \
            || log "ERROR" "Failed to restart remote container!"
    fi
}

install_trap() {
    trap '[[ $? -ne 0 ]] && cleanup' EXIT
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

# Returns via exit code semantics through a global for simplicity: sets
# IS_BEHIND=yes/no. Exits 0 early if already up to date.
step_check_git_updates() {
    log "INFO" "Checking remote repository for git updates..."
    IS_BEHIND=$($SSH_CONN "cd '$REMOTE_BOT_DIR' && git fetch origin >/dev/null 2>&1 && LOCAL=\$(git rev-parse HEAD) && REMOTE=\$(git rev-parse @{u}) && [ \$LOCAL != \$REMOTE ] && echo 'yes' || echo 'no'")
    log "DEBUG" "IS_BEHIND=$IS_BEHIND"

    if [[ "$IS_BEHIND" == "no" ]]; then
        log "INFO" "Remote repository is up-to-date with upstream branch. No updates required."
        send_telegram "Remote repository is up-to-date with upstream branch. No updates required for: $TARGET_SECTION"
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
            send_telegram "⚠️ Continuing update for $TARGET_SECTION despite $open_trades active position(s) (FORCE_UPDATE enabled)."
        else
            log "WARN" "Safety check failed: $open_trades active positions detected! Aborting update."
            send_telegram "⚠️ Update aborted for $TARGET_SECTION: $open_trades active positions."
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

    local exclude_args=""
    for pattern in $EXCLUDE_PATTERNS; do
        exclude_args="$exclude_args --exclude='$pattern'"
    done
    log "DEBUG" "EXCLUDE_ARGS=$exclude_args"

    $SSH_CONN "cd '$REMOTE_BOT_DIR' && tar $exclude_args -czf - ." > "$local_backup_path"
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
    send_telegram "Cleared old backups for: $TARGET_SECTION"
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
    send_telegram "Starting bot-updater for: $TARGET_SECTION"

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
    send_telegram "✅ Successfully updated bot instance: $TARGET_SECTION"
}

main "$@"