#!/usr/bin/env bash
# ==============================================================================
# Script:       bot-updater.sh
# Repository:   antwnhsx/nfi-orchestrator
# Description:  A lightweight, low-write remote orchestration and backup script
#               for Freqtrade + NFI trading bots running via Compose over SSH.
#               Includes safety checks, offsite streaming backups, and
#               automatic recovery.
#
# Usage:        ./bot-updater.sh [options] -t <target>
# Options:      -h, --help            Show this help message and exit
#               -t, --target <name>   Section target name in configuration file (Required)
#               -c, --config <path>   Path to configuration file (Default: <script dir>/updater.conf)
#               -d, --dry-run         Simulate steps without making changes
#               -v, --verbose         Enable verbose log output to stdout
#               -q, --quiet           Suppress non-error output to stdout
#               -D, --debug           Enable debug-level output (also via DEBUG=1)
#
# Config keys (per [section]):
#   Required: SSH_USER SSH_HOST REMOTE_BOT_DIR
#   Optional: ENABLED SSH_PORT SSH_KEY_FILE
#             API_HOST API_PORT API_ENDPOINT (empty => skip safety check)
#             API_VIA_SSH (default true: query the API from the bot host)
#             FT_USERNAME FT_PASSWORD FORCE_UPDATE
#             BACKUP_BASE_DIR EXCLUDE_PATTERNS RETENTION_DAYS
#             COMPOSE_CMD (override auto-detection) UP_ARGS (e.g. "--build")
#             LOG_FILE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
# ==============================================================================

set -euo pipefail
umask 077   # backups contain API keys / exchange secrets

# ==============================================================================
# 1. GLOBALS & DEFAULTS
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/updater.conf"
DRY_RUN=false
VERBOSITY="verbose"
DEBUG_MODE=false

if [[ "${DEBUG:-0}" == "1" ]]; then
    DEBUG_MODE=true
    VERBOSITY="verbose"
fi

TARGET_SECTION=""
CONTAINER_STOPPED=false
ERROR_REPORTED=false
readonly MIN_FREE_DISK_KB=512000   # 500 MB minimum requirement

# Settings that may come from the environment or the config file
LOG_FILE="${LOG_FILE:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Only these keys may be set from the config file (protects script internals)
readonly ALLOWED_KEYS=" ENABLED SSH_USER SSH_HOST SSH_PORT SSH_KEY_FILE REMOTE_BOT_DIR \
API_HOST API_PORT API_ENDPOINT API_VIA_SSH FT_USERNAME FT_PASSWORD BACKUP_BASE_DIR \
EXCLUDE_PATTERNS RETENTION_DAYS FORCE_UPDATE COMPOSE_CMD UP_ARGS LOG_FILE \
TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID "

# Runtime variables
SSH_CMD=()
REMOTE_COMPOSE_CMD=""
TARGET_BACKUP_DIR=""

# ==============================================================================
# 2. CLI PARSING
# ==============================================================================

usage_text() {
cat <<EOF
Usage: $(basename "$0") [OPTIONS] -t <target_profile>

Options:
  -t, --target <name>   Section target name in configuration file (Required)
  -c, --config <path>   Path to configuration file (Default: <script dir>/updater.conf)
  -d, --dry-run         Simulate steps without making changes
  -v, --verbose         Enable verbose log output to stdout
  -q, --quiet           Suppress non-error output to stdout
  -D, --debug           Enable debug output (also via DEBUG=1)
  -h, --help            Show this help menu
EOF
}

usage() {
    local code="${1:-1}"
    if (( code == 0 )); then usage_text; else usage_text >&2; fi
    exit "$code"
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
            -q|--quiet)   VERBOSITY="quiet"; shift ;;
            -D|--debug)   DEBUG_MODE=true; VERBOSITY="verbose"; shift ;;
            -h|--help)    usage 0 ;;
            *) echo "Unknown parameter: $1" >&2; usage ;;
        esac
    done

    if [[ -z "$TARGET_SECTION" ]]; then
        echo "Error: Target profile (-t|--target) is required." >&2
        usage
    fi

    if [[ ! "$TARGET_SECTION" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]; then
        echo "Error: Invalid target name '$TARGET_SECTION'." >&2
        exit 1
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file '$CONFIG_FILE' not found." >&2
        exit 1
    fi

    if [[ "$CONFIG_FILE" != /* ]]; then
        CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
    fi
}

# ==============================================================================
# 3. LOGGING & NOTIFICATIONS
#    log()    -> local only (console + LOG_FILE). Never talks to Telegram.
#    notify() -> log() + Telegram. The ONLY path to Telegram for user-visible
#                events. Use die() for fatal errors.
# ==============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    if [[ -n "$LOG_FILE" ]]; then
        printf '[%s] [%s] %s\n' "$timestamp" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi

    case "$level" in
        DEBUG)
            if [[ "$DEBUG_MODE" == "true" ]]; then
                printf '[%s] [DEBUG] %s\n' "$timestamp" "$msg"
            fi
            ;;
        INFO|EVENT)
            if [[ "$VERBOSITY" != "quiet" ]]; then
                printf '[%s] [%s] %s\n' "$timestamp" "$level" "$msg"
            fi
            ;;
        WARN)
            if [[ "$VERBOSITY" != "quiet" ]]; then
                printf '[%s] [WARN] %s\n' "$timestamp" "$msg"
            else
                printf '[%s] [WARN] %s\n' "$timestamp" "$msg" >&2
            fi
            ;;
        ERROR)
            printf '[%s] [ERROR] %s\n' "$timestamp" "$msg" >&2
            ;;
    esac
}

notify_telegram() {
    local msg="$1"

    [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0

    if [[ "$DRY_RUN" == "true" ]]; then
        log DEBUG "[dry-run] would send Telegram: $msg"
        return 0
    fi

    # Background so a slow Telegram never stalls the workflow; cleanup() waits
    # for these. The token is passed via stdin (-K -), never in argv, and
    # tracing is disabled so it can't leak into -D output or the log.
    (
        { set +x; } 2>/dev/null
        printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" |
            curl -s -m 5 -K - \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=${msg}" >/dev/null 2>&1
    ) 200>&- &
}

notify() {
    local level="$1"
    shift
    log "$level" "$*"
    case "$level" in
        ERROR) ERROR_REPORTED=true; notify_telegram "🚨 [$TARGET_SECTION] $*" ;;
        WARN)  notify_telegram "⚠️ [$TARGET_SECTION] $*" ;;
        EVENT) notify_telegram "[$TARGET_SECTION] $*" ;;
    esac
}

die() {
    notify ERROR "$*"
    exit 1
}

# Runs a command, mirroring its output to LOG_FILE (respects --quiet)
exec_logged() {
    if [[ -n "$LOG_FILE" ]]; then
        if [[ "$VERBOSITY" == "quiet" ]]; then
            "$@" >>"$LOG_FILE" 2>&1
        else
            "$@" 2>&1 | tee -a "$LOG_FILE"
        fi
    elif [[ "$VERBOSITY" == "quiet" ]]; then
        "$@" >/dev/null
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
        die "Another bot-updater run for target '$TARGET_SECTION' is already in progress."
    fi
}

parse_config() {
    local file="$1"
    local section="$2"

    [[ -f "$file" ]] || die "Config file '$file' not found."

    local in_section=0 found=0
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        if [[ -z "$line" || "$line" =~ ^[#\;] ]]; then
            continue
        fi

        if [[ "$line" =~ ^\[(.*)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=1
                found=1
            else
                in_section=0
            fi
            continue
        fi

        if (( in_section )) && [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            if [[ "$ALLOWED_KEYS" != *" $key "* ]]; then
                echo "Warning: unknown config key '$key' ignored" >&2
                continue
            fi

            value="${value#\"}"; value="${value%\"}"
            value="${value#\'}"; value="${value%\'}"

            # Expand ~ / $HOME only for LOCAL paths (not REMOTE_BOT_DIR)
            case "$key" in
                SSH_KEY_FILE|BACKUP_BASE_DIR|LOG_FILE)
                    value="${value//\$HOME/$HOME}"
                    value="${value/#\~/$HOME}"
                    ;;
            esac

            declare -g "$key=$value"
        fi
    done < "$file"

    (( found )) || die "Section [$section] not found in config file."
}

validate_config() {
    log DEBUG "Loaded config section [$TARGET_SECTION] from $CONFIG_FILE"

    : "${ENABLED:="true"}"
    if [[ "$ENABLED" != "true" ]]; then
        log INFO "Target [$TARGET_SECTION] is currently disabled. Exiting."
        exit 0
    fi

    local v
    for v in SSH_USER SSH_HOST REMOTE_BOT_DIR; do
        [[ -n "${!v:-}" ]] || die "Config $v missing"
    done

    : "${SSH_PORT:="22"}"
    : "${SSH_KEY_FILE:=""}"
    : "${API_HOST:="127.0.0.1"}"
    : "${API_PORT:="8080"}"
    : "${API_ENDPOINT="/api/v1/count"}"   # no colon: explicit empty disables the check
    : "${API_VIA_SSH:="true"}"
    : "${FT_USERNAME:=""}"
    : "${FT_PASSWORD:=""}"
    : "${BACKUP_BASE_DIR:="$HOME/bot-updater/backups"}"
    : "${EXCLUDE_PATTERNS:=""}"
    : "${RETENTION_DAYS:=0}"
    : "${FORCE_UPDATE:="false"}"
    : "${COMPOSE_CMD:=""}"
    : "${UP_ARGS:=""}"

    [[ "$SSH_PORT" =~ ^[0-9]+$ ]]       || die "SSH_PORT must be an integer"
    [[ "$API_PORT" =~ ^[0-9]+$ ]]       || die "API_PORT must be an integer"
    [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "RETENTION_DAYS must be a non-negative integer"
    [[ "$FORCE_UPDATE" =~ ^(true|false)$ ]]  || die "FORCE_UPDATE must be true or false"
    [[ "$API_VIA_SSH" =~ ^(true|false)$ ]]   || die "API_VIA_SSH must be true or false"
    [[ "$REMOTE_BOT_DIR" != *"'"* ]]    || die "REMOTE_BOT_DIR must not contain a single quote"

    if [[ -n "$LOG_FILE" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    fi

    log DEBUG "Config settings: SSH_HOST=$SSH_HOST SSH_PORT=$SSH_PORT REMOTE_BOT_DIR=$REMOTE_BOT_DIR BACKUP_BASE_DIR=$BACKUP_BASE_DIR RETENTION_DAYS=$RETENTION_DAYS FORCE_UPDATE=$FORCE_UPDATE API_VIA_SSH=$API_VIA_SSH"
}

# ==============================================================================
# 5. SSH / REMOTE EXECUTION HELPERS
# ==============================================================================

init_ssh() {
    SSH_CMD=(ssh -p "$SSH_PORT"
             -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
             -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
    if [[ -n "$SSH_KEY_FILE" ]]; then
        SSH_CMD+=(-i "$SSH_KEY_FILE")
    fi
    SSH_CMD+=("${SSH_USER}@${SSH_HOST}")
}

# Emits a curl config (stdin for `curl -K -`) with the Freqtrade credentials so
# they never appear in argv. Must be used in a pipeline (runs in a subshell).
api_curl_config() {
    { set +x; } 2>/dev/null
    if [[ -n "${FT_USERNAME}${FT_PASSWORD}" ]]; then
        local u="${FT_USERNAME//\\/\\\\}" p="${FT_PASSWORD//\\/\\\\}"
        u="${u//\"/\\\"}"
        p="${p//\"/\\\"}"
        printf 'user = "%s:%s"\n' "$u" "$p"
    fi
}

# ==============================================================================
# 6. SAFETY / RECOVERY
# ==============================================================================

cleanup() {
    local exit_code=$?
    set +e
    trap - EXIT

    if [[ $exit_code -ne 0 && "$ERROR_REPORTED" != "true" ]]; then
        notify ERROR "Script failed unexpectedly (exit code $exit_code)"
    fi

    if [[ "$CONTAINER_STOPPED" == "true" && ${#SSH_CMD[@]} -gt 0 ]]; then
        log WARN "Script interrupted or failed! Attempting remote container recovery..."
        if "${SSH_CMD[@]}" "cd '$REMOTE_BOT_DIR' && ${REMOTE_COMPOSE_CMD:-docker compose} up -d"; then
            notify_telegram "🔄 Recovery successful: Container restarted on $TARGET_SECTION"
        else
            notify_telegram "🔥 RECOVERY FAILED: Container is offline on $TARGET_SECTION!"
        fi
    fi

    wait   # let background Telegram requests finish
    exit "$exit_code"
}

install_trap() {
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
}

# ==============================================================================
# 7. WORKFLOW STEPS
# ==============================================================================

step_check_connectivity() {
    log DEBUG "Checking SSH connectivity..."
    local err
    if ! err=$("${SSH_CMD[@]}" true 2>&1); then
        die "Could not connect to $SSH_HOST via SSH: ${err:-unknown error}"
    fi
}

step_detect_compose() {
    if [[ -n "$COMPOSE_CMD" ]]; then
        REMOTE_COMPOSE_CMD="$COMPOSE_CMD"
        log DEBUG "Using configured compose command: '$REMOTE_COMPOSE_CMD'"
        return 0
    fi

    if ! REMOTE_COMPOSE_CMD=$("${SSH_CMD[@]}" '
        if command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
            echo "podman compose"
        elif command -v podman-compose >/dev/null 2>&1; then
            echo "podman-compose"
        elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
            echo "docker compose"
        elif command -v docker-compose >/dev/null 2>&1; then
            echo "docker-compose"
        fi
    '); then
        die "Failed to query the remote host for a compose tool."
    fi

    [[ -n "$REMOTE_COMPOSE_CMD" ]] ||
        die "No valid compose tool found on remote host (checked: podman compose, podman-compose, docker compose, docker-compose). Set COMPOSE_CMD in the config to override."
    log DEBUG "Using remote compose command: '$REMOTE_COMPOSE_CMD'"
}

step_check_git_updates() {
    log INFO "Checking remote repository for git updates..."
    local behind
    if ! behind=$("${SSH_CMD[@]}" "cd '$REMOTE_BOT_DIR' && git fetch -q origin && git rev-list --count HEAD..@{u}"); then
        die "git fetch/rev-list failed on remote (network issue or no upstream configured?)"
    fi
    log DEBUG "COMMITS_BEHIND=$behind"

    if [[ ! "$behind" =~ ^[0-9]+$ ]]; then
        die "Unexpected output from git rev-list: '$behind'"
    fi

    if (( behind == 0 )); then
        log INFO "Remote repository is up-to-date with upstream branch. No updates required."
        exit 0
    fi
    log INFO "$behind new commit(s) detected on upstream git repository."
}

step_check_disk_space() {
    TARGET_BACKUP_DIR="${BACKUP_BASE_DIR}/${TARGET_SECTION}"

    # Probe the nearest existing ancestor so dry-run doesn't create directories
    local probe="$TARGET_BACKUP_DIR"
    while [[ ! -d "$probe" ]]; do probe="$(dirname "$probe")"; done

    local free_disk_kb
    free_disk_kb=$(df -Pk "$probe" | awk 'NR==2 {print $4}')
    log DEBUG "TARGET_BACKUP_DIR=$TARGET_BACKUP_DIR FREE_DISK_KB=$free_disk_kb MIN_FREE_DISK_KB=$MIN_FREE_DISK_KB"

    if (( free_disk_kb < MIN_FREE_DISK_KB )); then
        die "Insufficient local storage space! Required: ${MIN_FREE_DISK_KB}KB, Free: ${free_disk_kb}KB"
    fi

    # Informational: uncompressed size is an upper bound for the archive
    local remote_kb
    remote_kb=$("${SSH_CMD[@]}" "du -sk '$REMOTE_BOT_DIR' | cut -f1" 2>/dev/null || true)
    if [[ "$remote_kb" =~ ^[0-9]+$ ]]; then
        log DEBUG "Remote bot dir size: ${remote_kb}KB"
        if (( free_disk_kb < remote_kb )); then
            log WARN "Free space (${free_disk_kb}KB) is below the uncompressed remote size (${remote_kb}KB); backup may not fit."
        fi
    fi
}

step_safety_check_open_trades() {
    if [[ -z "$API_ENDPOINT" ]]; then
        log INFO "No API_ENDPOINT specified. Skipping safety check."
        return 0
    fi

    local api_url="http://${API_HOST}:${API_PORT}${API_ENDPOINT}"
    log INFO "Executing safety check via API ($api_url)$([[ "$API_VIA_SSH" == "true" ]] && echo " through SSH")..."

    local response
    if [[ "$API_VIA_SSH" == "true" ]]; then
        response=$(api_curl_config |
            "${SSH_CMD[@]}" "curl -s --fail --max-time 10 -K - '$api_url'" 2>/dev/null) || response=""
    else
        response=$(api_curl_config |
            curl -s --fail --max-time 10 -K - "$api_url" 2>/dev/null) || response=""
    fi
    [[ -n "$response" ]] ||
        die "Safety check: cannot reach/authenticate to Freqtrade API at $api_url (network error, wrong credentials, or bot offline)."

    # Response looks like: {"current":1,"max":6,"total_stake":53.5325}
    local open_trades
    open_trades=$(printf '%s' "$response" | sed -n 's/.*"current" *: *\([0-9][0-9]*\).*/\1/p' | head -n1)

    if [[ -z "$open_trades" ]]; then
        die "Safety check: failed to parse 'current' trade count from API response: $response"
    fi

    log DEBUG "API_URL=$api_url OPEN_TRADES=$open_trades"

    if (( open_trades > 0 )); then
        if [[ "$FORCE_UPDATE" == "true" ]]; then
            notify WARN "$open_trades active position(s) detected, but FORCE_UPDATE=true, continuing anyway."
        else
            log WARN "Safety check: $open_trades active position(s) open. Skipping update this run."
            exit 0
        fi
    else
        log INFO "Safety check passed. 0 active positions."
    fi
}

step_stop_container() {
    log INFO "Stopping remote container(s)..."
    CONTAINER_STOPPED=true   # set first: a half-failed `down` still needs recovery
    exec_logged "${SSH_CMD[@]}" "cd '$REMOTE_BOT_DIR' && $REMOTE_COMPOSE_CMD down"
}

step_backup() {
    mkdir -p "$TARGET_BACKUP_DIR"

    local stamp backup_filename dest part
    stamp=$(date +%Y%m%d_%H%M%S)
    backup_filename="${TARGET_SECTION}_${stamp}.tar.gz"
    dest="${TARGET_BACKUP_DIR}/${backup_filename}"
    part="${dest}.part"

    log INFO "Streaming remote backup to $dest..."

    # Build a safely-quoted exclude list for the REMOTE shell (no local globbing)
    local excludes="" pattern
    set -f
    for pattern in $EXCLUDE_PATTERNS; do
        excludes+=" --exclude=$(printf '%q' "$pattern")"
    done
    set +f

    if ! "${SSH_CMD[@]}" "cd '$REMOTE_BOT_DIR' && tar${excludes} -czf - ." > "$part"; then
        rm -f "$part"
        die "Backup stream failed; update aborted (container will be restarted)."
    fi
    if ! gzip -t "$part" 2>/dev/null; then
        rm -f "$part"
        die "Backup integrity check failed; update aborted (container will be restarted)."
    fi
    mv "$part" "$dest"

    log INFO "Backup streamed and verified."
    log DEBUG "Backup file size: $(du -k "$dest" 2>/dev/null | awk '{print $1}')KB"
}

step_apply_updates() {
    log INFO "Applying git updates on remote host..."
    exec_logged "${SSH_CMD[@]}" "cd '$REMOTE_BOT_DIR' && git pull --ff-only"
}

step_restart_container() {
    log INFO "Restarting remote container(s)..."
    exec_logged "${SSH_CMD[@]}" "cd '$REMOTE_BOT_DIR' && $REMOTE_COMPOSE_CMD up -d $UP_ARGS"
    CONTAINER_STOPPED=false
}

step_retention_cleanup() {
    (( RETENTION_DAYS > 0 )) || return 0

    log INFO "Cleaning up local backups older than $RETENTION_DAYS days..."
    local n
    n=$(find "$TARGET_BACKUP_DIR" -maxdepth 1 \( -name '*.tar.gz' -o -name '*.part' \) -type f \
            -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
    if (( n > 0 )); then
        log INFO "Removed $n old backup(s)"
    fi
}

# ==============================================================================
# 8. MAIN
# ==============================================================================

main() {
    parse_args "$@"
    install_trap

    check_for_lock

    parse_config "$CONFIG_FILE" "$TARGET_SECTION"
    validate_config

    # Trace only after config (and its secrets) is loaded; -x alone is enough.
    if [[ "$DEBUG_MODE" == "true" ]]; then
        PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
        set -x
    fi

    init_ssh

    log INFO "=== Starting bot-updater for [$TARGET_SECTION] ==="

    step_check_connectivity
    step_detect_compose
    step_check_git_updates
    step_check_disk_space
    step_safety_check_open_trades   # last check before stopping: smallest race window

    if [[ "$DRY_RUN" == "true" ]]; then
        log INFO "[DRY-RUN] Pre-flight checks passed. Would stop container, stream backup local, update git repository, and restart container."
        exit 0
    fi

    step_stop_container
    step_backup
    step_apply_updates
    step_restart_container
    step_retention_cleanup

    notify EVENT "✅ Successfully updated bot instance"
    log INFO "=== Update completed successfully for [$TARGET_SECTION] ==="
}

main "$@"