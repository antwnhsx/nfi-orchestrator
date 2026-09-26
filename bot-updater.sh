#!/usr/bin/env bash
# ==============================================================================
# Script:       bot-updater.sh
# Repository:   antwnhsx/nfi-orchestrator
# Description:  A lightweight, low-write remote orchestration and backup script for Freqtrade + NFI trading bots running via Docker Compose over SSH. Includes safety checks, offsite streaming backups, and automatic recovery.
#
# Usage:        ./bot-updater.sh [options] [arguments]
# Options:      -h, --help            Show this help message and exit
#               -t, --target <name>   Section target name in configuration file (Required)
#               -c, --config <path>   Path to configuration file (Default: ./updater.conf)
#               -d, --dry-run         Simulate steps without making changes
#               -v, --verbose         Enable verbose log output to stdout
#               -q, --quiet           Suppress non-error output to stdout
#
# Environment Variables:
#               DEBUG         Set to 1 to enable debug mode
# ==============================================================================

set -euo pipefail

# --- Defaults ---
CONFIG_FILE="./updater.conf"
DRY_RUN=false
VERBOSITY="normal" # quiet, normal, verbose
TARGET_SECTION=""
CONTAINER_STOPPED=false
MIN_FREE_DISK_KB=512000 # 500 MB minimum requirement

# --- Usage Help ---
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] -t <target_profile>

Options:
  -t, --target <name>   Section target name in configuration file (Required)
  -c, --config <path>   Path to configuration file (Default: ./updater.conf)
  -d, --dry-run         Simulate steps without making changes
  -v, --verbose         Enable verbose log output to stdout
  -q, --quiet           Suppress non-error output to stdout
  -h, --help            Show this help menu
EOF
  exit 1
}

# --- Command Line Argument Parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target) TARGET_SECTION="$2"; shift 2 ;;
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    -d|--dry-run) DRY_RUN=true; shift ;;
    -v|--verbose) VERBOSITY="verbose"; shift ;;
    -q|--quiet) VERBOSITY="quiet"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown parameter: $1"; usage ;;
  esac
done

if [[ -z "$TARGET_SECTION" ]]; then
  echo "Error: Target profile (-t|--target) is required." >&2
  usage
fi

# --- Logging Engine ---
log() {
  local level="$1"
  shift
  local msg="$*"
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")

  if [[ -n "${LOG_FILE:-}" ]]; then
    # Safely expand ~ or environment variables if present in path string
    eval local log_path="$LOG_FILE"
    mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
    echo "[$timestamp] [$level] $msg" >> "$log_path"
  fi

  case "$VERBOSITY" in
    quiet)   [[ "$level" == "ERROR" ]] && echo "[$level] $msg" >&2 ;;
    normal)  [[ "$level" != "DEBUG" ]] && echo "[$level] $msg" ;;
    verbose) echo "[$timestamp] [$level] $msg" ;;
  esac
}

# --- Command Execution Helper ---
# Captures raw command outputs (like git pull / docker compose) and appends to log
exec_logged() {
  if [[ -n "${LOG_FILE:-}" ]]; then
    eval local log_path="$LOG_FILE"
    "$@" 2>&1 | tee -a "$log_path"
  else
    "$@"
  fi
}

# --- INI Section Parser ---
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

parse_config "$CONFIG_FILE" "$TARGET_SECTION"

# --- Validate Configuration Settings ---
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

SSH_CMD="ssh -p $SSH_PORT"
if [[ -n "$SSH_KEY_FILE" ]]; then
  SSH_CMD="$SSH_CMD -i $SSH_KEY_FILE"
fi
SSH_CONN="$SSH_CMD $SSH_USER@$SSH_HOST"

# --- Safe Execution / Recovery Hook ---
cleanup() {
  if [[ "$CONTAINER_STOPPED" == "true" ]]; then
    log "WARN" "Script interrupted or failed! Attempting remote container recovery..."
    $SSH_CONN "cd '$REMOTE_BOT_DIR' && ${REMOTE_COMPOSE_CMD:-docker compose} up -d" || log "ERROR" "Failed to restart remote container!"
  fi
}
trap cleanup EXIT

# --- Helper Functions ---
send_telegram() {
  local msg="$1"
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && [[ -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=${msg}" > /dev/null || true
  fi
}

# --- Core Workflow ---
log "INFO" "=== Starting bot-updater for [$TARGET_SECTION] ==="
send_telegram "Starting bot-updater for: $TARGET_SECTION"

# 1. Connectivity Check
log "DEBUG" "Checking SSH connectivity..."
if ! $SSH_CONN "exit" 2>/dev/null; then
  log "ERROR" "Could not connect to remote host $SSH_HOST via SSH."
  exit 1
fi

# 2. Remote Docker Compose Detection
REMOTE_COMPOSE_CMD=$($SSH_CONN "if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then echo 'docker compose'; elif command -v docker-compose >/dev/null 2>&1; then echo 'docker-compose'; fi")

if [[ -z "$REMOTE_COMPOSE_CMD" ]]; then
  log "ERROR" "Neither 'docker compose' nor 'docker-compose' is installed on remote host."
  exit 1
fi
log "DEBUG" "Using remote compose command: '$REMOTE_COMPOSE_CMD'"

# 3. Check Remote Git Updates via Commit Revision Hashes
log "INFO" "Checking remote repository for git updates..."
IS_BEHIND=$($SSH_CONN "cd '$REMOTE_BOT_DIR' && git fetch origin >/dev/null 2>&1 && LOCAL=\$(git rev-parse HEAD) && REMOTE=\$(git rev-parse @{u}) && [ \$LOCAL != \$REMOTE ] && echo 'yes' || echo 'no'")

if [[ "$IS_BEHIND" == "no" ]]; then
  log "INFO" "Remote repository is up-to-date with upstream branch. No updates required."
  exit 0
fi
log "INFO" "New commits detected on upstream git repository."

# 4. Check Safety API (if defined)
if [[ -n "${API_ENDPOINT:-}" ]]; then
  log "INFO" "Executing safety check via API..."
  API_URL="http://${API_HOST}:${API_PORT}${API_ENDPOINT}"
  OPEN_TRADES=$(curl -s --max-time 10 "$API_URL" | grep -o '"count": *[0-9]*' | grep -o '[0-9]*' || echo "0")

  if [[ "$OPEN_TRADES" -gt 0 ]]; then
    log "WARN" "Safety check failed: $OPEN_TRADES active positions detected! Aborting update."
    send_telegram "⚠️ Update aborted for $TARGET_SECTION: $OPEN_TRADES active positions."
    exit 0
  fi
  log "INFO" "Safety check passed. 0 active positions."
fi

# 5. Local Storage Space Check
TARGET_BACKUP_DIR="${BACKUP_BASE_DIR}/${TARGET_SECTION}"
mkdir -p "$TARGET_BACKUP_DIR"
FREE_DISK_KB=$(df -k "$TARGET_BACKUP_DIR" | awk 'NR==2 {print $4}')

if [[ "$FREE_DISK_KB" -lt "$MIN_FREE_DISK_KB" ]]; then
  log "ERROR" "Insufficient local storage space! Required: ${MIN_FREE_DISK_KB}KB, Free: ${FREE_DISK_KB}KB"
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "INFO" "[DRY-RUN] Pre-flight checks passed. Would stop container, stream backup local, update git repository, and restart container."
  exit 0
fi

# 6. Stop Container
log "INFO" "Stopping remote docker container..."
$SSH_CONN "cd '$REMOTE_BOT_DIR' && $REMOTE_COMPOSE_CMD down"
CONTAINER_STOPPED=true

# 7. Backup Remote Directory
BACKUP_FILENAME="${TARGET_SECTION}_$(date +%Y%m%d_%H%M%S).tar.gz"
LOCAL_BACKUP_PATH="${TARGET_BACKUP_DIR}/${BACKUP_FILENAME}"

log "INFO" "Streaming remote backup to $LOCAL_BACKUP_PATH..."

EXCLUDE_ARGS=""
for pattern in $EXCLUDE_PATTERNS; do
  EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude='$pattern'"
done

$SSH_CONN "cd '$REMOTE_BOT_DIR' && tar $EXCLUDE_ARGS -czf - ." > "$LOCAL_BACKUP_PATH"
log "INFO" "Backup streamed successfully."

# 8. Apply Updates
log "INFO" "Applying git updates on remote host..."
exec_logged $SSH_CONN "cd '$REMOTE_BOT_DIR' && git pull"

# 9. Restart Container
log "INFO" "Restarting remote docker container..."
$SSH_CONN "cd '$REMOTE_BOT_DIR' && $REMOTE_COMPOSE_CMD up -d"
CONTAINER_STOPPED=false

# 10. Local Retention Cleanup
if [[ "$RETENTION_DAYS" -gt 0 ]]; then
  log "INFO" "Cleaning up local backups older than $RETENTION_DAYS days..."
  find "$TARGET_BACKUP_DIR" -name "*.tar.gz" -type f -mtime +"$RETENTION_DAYS" -delete
fi

log "INFO" "=== Update completed successfully for [$TARGET_SECTION] ==="
send_telegram "✅ Successfully updated bot instance: $TARGET_SECTION"