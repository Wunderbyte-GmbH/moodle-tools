#!/usr/bin/env bash
# =============================================================================
# mirror.sh — Moodle Production → Test mirror
#
# Runs on PRODUCTION server.
# Reads DB/path config directly from Moodle's config.php.
# Dumps DB into moodledata/mirror/ so rsync carries it automatically.
# Executes post-import steps on test server via SSH.
#
# Usage:
#   ./mirror.sh                   # full mirror
#   ./mirror.sh --dry-run         # rsync dry-run, no DB import, no remote exec
#   ./mirror.sh --files-only      # skip DB dump/import, sync moodledata only
#   ./mirror.sh --db-only         # skip moodledata rsync, do DB only
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# SECTION 1: CONFIGURATION
# =============================================================================
# Values are first read automatically from Moodle's config.php.
# Set any variable below to override what was read from config.php.
# Leave a variable empty ("") to use the auto-detected value.
# =============================================================================

# --- Production Moodle root (where config.php lives) -------------------------
PROD_MOODLE_ROOT="/var/www/moodle"
PROD_PHP_CLI="php"

# --- Overrides: Production DB ------------------------------------------------
# Auto-detected from config.php. Override only if needed.
OVERRIDE_PROD_DB_TYPE=""       # pgsql | mariadb
OVERRIDE_PROD_DB_HOST=""
OVERRIDE_PROD_DB_PORT=""
OVERRIDE_PROD_DB_NAME=""
OVERRIDE_PROD_DB_USER=""
OVERRIDE_PROD_DB_PASS=""

# --- Overrides: Production moodledata path -----------------------------------
# Auto-detected from config.php ($CFG->dataroot). Override if needed.
OVERRIDE_PROD_MOODLEDATA=""

# --- Overrides: Production wwwroot -------------------------------------------
# Auto-detected from config.php ($CFG->wwwroot). Override if needed.
OVERRIDE_PROD_WWWROOT=""

# --- Test server connection ---------------------------------------------------
TEST_HOST="test.example.com"
TEST_SSH_USER="mirrordeploy"
TEST_SSH_PORT="22"
TEST_SSH_HOST_ALIAS=""

SSH_EXTRA_OPTS=(
    # "-A"
)

# --- Test server paths -------------------------------------------------------
TEST_MOODLE_ROOT="/usr/home/wundez/public_html/kswdev.wunderbyte.at/moodle"
TEST_MOODLEDATA="/usr/home/wundez/public_html/kswdev.wunderbyte.at/moodledata"
TEST_PHP_CLI="php"

# --- Test DB -----------------------------------------------------------------
TEST_DB_TYPE="pgsql"           # pgsql | mariadb
TEST_DB_HOST="localhost"
TEST_DB_PORT="5432"
TEST_DB_NAME="moodle_test"
TEST_DB_USER="moodle_test"
TEST_DB_PASS="CHANGE_ME"

# --- Dump location (relative to moodledata root) -----------------------------
# Dump is written here, then picked up by rsync automatically.
DUMP_SUBDIR="mirror"

LOG_FILE="/var/log/moodle-mirror/mirror.log"
LOG_MAX_BYTES=10485760 # rotate at 10 MB

# --- Lock file ---------------------------------------------------------------
LOCK_FILE="/tmp/moodle_mirror.lock"
# --- How many dump files to keep in moodledata/mirror/ -----------------------
KEEP_DUMPS=3

# --- Rsync exclusions (relative to moodledata root) --------------------------
# The DUMP_SUBDIR is always included (not excluded).
RSYNC_EXCLUDES=(
    "cache/"
    "localcache/"
    "temp/"
    "sessions/"
    "trashdir/"
    "lock/"
    "filedir/antivirus_quarantine/"
)

# --- Notify on failure (requires sendmail/mail on production) ----------------
NOTIFY_EMAIL="admin@example.com"
NOTIFY_ON_FAILURE=true

# =============================================================================
# END OF CONFIGURATION — do not edit below unless you know what you are doing
# =============================================================================


# =============================================================================
# SECTION 2: ARGUMENT PARSING
# =============================================================================
DRY_RUN=false
FILES_ONLY=false
DB_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --files-only) FILES_ONLY=true ;;
        --db-only)    DB_ONLY=true ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--dry-run] [--files-only] [--db-only]"
            exit 1
            ;;
    esac
done

# =============================================================================
# SECTION 3: LOGGING
# =============================================================================
mkdir -p "$(dirname "$LOG_FILE")"

# Rotate log if too large
if [[ -f "$LOG_FILE" ]] && \
   [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $LOG_MAX_BYTES ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.1"
fi

log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${ts}] [$$] [${level}] $*" | tee -a "$LOG_FILE"
}

info()    { log "INFO " "$@"; }
warn()    { log "WARN " "$@"; }
error()   { log "ERROR" "$@"; }
section() { info "=== $* ==="; }

die() {
    error "$@"
    send_failure_notification "$*"
    cleanup
    exit 1
}

# =============================================================================
# SECTION 4: NOTIFICATIONS
# =============================================================================
send_failure_notification() {
    [[ "${NOTIFY_ON_FAILURE}" == "true" ]] || return 0
    [[ -n "${NOTIFY_EMAIL:-}" ]] || return 0

    local msg="$1"
    printf 'Subject: [Moodle Mirror] FAILED on %s\n\n%s\n\nLog: %s\n' \
        "$(hostname)" "$msg" "$LOG_FILE" \
        | sendmail "$NOTIFY_EMAIL" 2>/dev/null || true
}

# =============================================================================
# SECTION 5: LOCK
# =============================================================================
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        if [[ "$pid" != "unknown" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Mirror already running (PID: ${pid})."
        fi
        warn "Stale lock file (PID: ${pid} is dead). Removing."
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    info "Lock acquired (PID: $$)"
}

release_lock() {
    rm -f "$LOCK_FILE"
    info "Lock released"
}

# =============================================================================
# SECTION 6: CLEANUP + TRAPS
# =============================================================================
TEMP_DIR=""   # set after we know PROD_MOODLEDATA

setup_temp() {
    TEMP_DIR="${PROD_MOODLEDATA}/${DUMP_SUBDIR}"
    mkdir -p "$TEMP_DIR"
    info "Working directory: $TEMP_DIR"
}

cleanup() {
    # Remove only the in-progress temp files, not the whole subdir
    # (we keep completed dump files for KEEP_DUMPS rotation)
    if [[ -n "${DUMP_LOCAL_PATH:-}" ]] && [[ -f "${DUMP_LOCAL_PATH}.inprogress" ]]; then
        rm -f "${DUMP_LOCAL_PATH}.inprogress"
    fi
    release_lock
}

trap 'error "Unexpected error at line ${LINENO}."; \
      send_failure_notification "Unexpected error at line ${LINENO}"; \
      cleanup; exit 1' ERR
trap 'warn "Signal received. Cleaning up."; cleanup; exit 130' INT TERM

# =============================================================================
# SECTION 7: READ CONFIG FROM MOODLE config.php
# =============================================================================
# Extracts a single $CFG property from config.php using PHP CLI.
# Returns empty string on failure — caller decides if that is fatal.
extract_cfg() {
    local property="$1"
    "$PROD_PHP_CLI" \
        -d error_reporting=0 \
        -r "
            define('CLI_SCRIPT', true);
            require('${PROD_MOODLE_ROOT}/config.php');
            echo \$CFG->${property} ?? '';
        " 2>/dev/null || true
}

# Maps Moodle's $CFG->dbtype string to our internal token (pgsql / mariadb).
normalise_db_type() {
    local raw="$1"
    case "${raw,,}" in     # lowercase
        pgsql|postgres|postgresql) echo "pgsql" ;;
        mariadb|mysqli|mysql)      echo "mariadb" ;;
        *)
            warn "Unknown dbtype '${raw}' from config.php — defaulting to pgsql"
            echo "pgsql"
            ;;
    esac
}

load_moodle_config() {
    section "Reading Moodle config.php"

    local config_php="${PROD_MOODLE_ROOT}/config.php"
    [[ -f "$config_php" ]] || die "config.php not found at: ${config_php}"

    local raw_dbtype
    raw_dbtype=$(extract_cfg "dbtype")
    [[ -n "$raw_dbtype" ]] || die "Could not read \$CFG->dbtype from config.php"
    PROD_DB_TYPE=$(normalise_db_type "$raw_dbtype")

    PROD_DB_HOST=$(extract_cfg "dbhost")
    [[ -n "$PROD_DB_HOST" ]] || die "Could not read \$CFG->dbhost from config.php"

    PROD_DB_PORT=$(
        "$PROD_PHP_CLI" -d error_reporting=0 -r "
            define('CLI_SCRIPT', true);
            require('${PROD_MOODLE_ROOT}/config.php');
            if (!empty(\$CFG->dboptions['dbport'])) {
                echo \$CFG->dboptions['dbport'];
                return;
            }
            if (strpos(\$CFG->dbhost, ':') !== false) {
                [, \$port] = explode(':', \$CFG->dbhost, 2);
                echo \$port;
                return;
            }
            echo (\$CFG->dbtype === 'pgsql') ? '5432' : '3306';
        " 2>/dev/null || true
    )
    PROD_DB_HOST="${PROD_DB_HOST%%:*}"

    PROD_DB_NAME=$(extract_cfg "dbname")
    [[ -n "$PROD_DB_NAME" ]] || die "Could not read \$CFG->dbname from config.php"

    PROD_DB_USER=$(extract_cfg "dbuser")
    [[ -n "$PROD_DB_USER" ]] || die "Could not read \$CFG->dbuser from config.php"

    PROD_DB_PASS=$(extract_cfg "dbpass")

    PROD_MOODLEDATA=$(extract_cfg "dataroot")
    [[ -n "$PROD_MOODLEDATA" ]] || die "Could not read \$CFG->dataroot from config.php"

    PROD_WWWROOT=$(extract_cfg "wwwroot")
    [[ -n "$PROD_WWWROOT" ]] || die "Could not read \$CFG->wwwroot from config.php"

    info "DB type    : $PROD_DB_TYPE"
    info "DB host    : $PROD_DB_HOST:$PROD_DB_PORT"
    info "DB name    : $PROD_DB_NAME"
    info "DB user    : $PROD_DB_USER"
    info "moodledata : $PROD_MOODLEDATA"
    info "wwwroot    : $PROD_WWWROOT"
}

apply_overrides() {
    section "Applying configuration overrides"

    local any=false

    _override() {
        local var="$1" override="$2"
        if [[ -n "$override" ]]; then
            info "Override: ${var} = ${override}"
            printf -v "$var" '%s' "$override"
            any=true
        fi
    }

    _override PROD_DB_TYPE       "$OVERRIDE_PROD_DB_TYPE"
    _override PROD_DB_HOST       "$OVERRIDE_PROD_DB_HOST"
    _override PROD_DB_PORT       "$OVERRIDE_PROD_DB_PORT"
    _override PROD_DB_NAME       "$OVERRIDE_PROD_DB_NAME"
    _override PROD_DB_USER       "$OVERRIDE_PROD_DB_USER"
    _override PROD_DB_PASS       "$OVERRIDE_PROD_DB_PASS"
    _override PROD_MOODLEDATA    "$OVERRIDE_PROD_MOODLEDATA"
    _override PROD_WWWROOT       "$OVERRIDE_PROD_WWWROOT"

    [[ "$any" == "true" ]] || info "No overrides applied"
}

# =============================================================================
# SECTION 8: PREFLIGHT
# =============================================================================
preflight() {
    section "Preflight checks"

    [[ -d "$PROD_MOODLEDATA" ]] || die "Production moodledata not found: $PROD_MOODLEDATA"

    command -v ssh &>/dev/null   || die "ssh not installed"
    command -v rsync &>/dev/null || die "rsync not installed"

    if [[ "$FILES_ONLY" != "true" ]]; then
        case "$PROD_DB_TYPE" in
            pgsql)   command -v pg_dump   &>/dev/null || die "pg_dump not found" ;;
            mariadb) command -v mysqldump &>/dev/null || die "mysqldump not found" ;;
        esac
    fi

    info "Testing SSH to test server..."
    remote_exec "echo 'SSH OK'" \
        || die "Cannot SSH to test server. Ensure the production server user can SSH non-interactively."

    remote_exec "[[ -f '${TEST_MOODLE_ROOT}/config.php' ]]" \
        || die "Test config.php not found remotely: ${TEST_MOODLE_ROOT}/config.php"

    remote_exec "[[ -d '${TEST_MOODLEDATA}' ]]" \
        || die "Test moodledata not found remotely: ${TEST_MOODLEDATA}"

    remote_exec "command -v ${TEST_PHP_CLI} >/dev/null" \
        || die "PHP CLI not found on test server: ${TEST_PHP_CLI}"

    case "$TEST_DB_TYPE" in
        pgsql)
            remote_exec "command -v psql >/dev/null" \
                || die "psql not found on test server"
            ;;
        mariadb|mysql)
            remote_exec "command -v mysql >/dev/null" \
                || die "mysql client not found on test server"
            ;;
    esac

    info "Preflight OK"
}

# =============================================================================
# SECTION 9: SSH HELPERS
# =============================================================================
ssh_target() {
    if [[ -n "$TEST_SSH_HOST_ALIAS" ]]; then
        printf '%s' "$TEST_SSH_HOST_ALIAS"
    else
        printf '%s@%s' "$TEST_SSH_USER" "$TEST_HOST"
    fi
}

ssh_base() {
    local target
    target="$(ssh_target)"

    ssh \
        -p "$TEST_SSH_PORT" \
        -o StrictHostKeyChecking=accept-new \
        -o BatchMode=yes \
        -o ConnectTimeout=30 \
        "${SSH_EXTRA_OPTS[@]}" \
        "$target" \
        "$@"
}

remote_exec() {
    ssh_base "$@" 2>&1 | tee -a "$LOG_FILE"
}

# =============================================================================
# SECTION 10: DUMP PRODUCTION DATABASE
#   Writes into moodledata/mirror/ — rsync will carry it to test automatically
# =============================================================================
dump_prod_db() {
    section "Dumping production database"

    local ts
    ts=$(date '+%Y%m%d_%H%M%S')

    case "$PROD_DB_TYPE" in
        pgsql)
            DUMP_LOCAL_PATH="${TEMP_DIR}/db_${ts}.sql.gz"
            local temp_sql="${TEMP_DIR}/db_${ts}.sql"
            info "Dumping (pg_dump plain SQL + COPY + gzip) -> $DUMP_LOCAL_PATH"

            export PGPASSWORD="$PROD_DB_PASS"
            export LC_ALL="en_US.UTF-8"
            export LANG="en_US.UTF-8"

            pg_dump \
                -h "$PROD_DB_HOST" \
                -p "$PROD_DB_PORT" \
                -U "$PROD_DB_USER" \
                -d "$PROD_DB_NAME" \
                --no-owner \
                --no-acl \
                --clean \
                --if-exists \
                > "$temp_sql" 2>>"$LOG_FILE"

            gzip -1 < "$temp_sql" > "${DUMP_LOCAL_PATH}.inprogress"
            rm -f "$temp_sql"
            unset PGPASSWORD
            ;;

        mariadb|mysql)
            DUMP_LOCAL_PATH="${TEMP_DIR}/db_${ts}.sql.gz"
            info "Dumping (mysqldump + gzip) -> $DUMP_LOCAL_PATH"

            mysqldump \
                -h "$PROD_DB_HOST" \
                -P "$PROD_DB_PORT" \
                -u "$PROD_DB_USER" \
                -p"$PROD_DB_PASS" \
                --single-transaction \
                --quick \
                --no-tablespaces \
                --default-character-set=utf8mb4 \
                --routines \
                --triggers \
                --events \
                "$PROD_DB_NAME" \
                2>>"$LOG_FILE" \
                | gzip -1 > "${DUMP_LOCAL_PATH}.inprogress"
            ;;
    esac

    # Atomic rename — only a complete dump is visible to rsync
    mv "${DUMP_LOCAL_PATH}.inprogress" "$DUMP_LOCAL_PATH"

    local size
    size=$(du -sh "$DUMP_LOCAL_PATH" | cut -f1)
    info "Dump complete: $(basename "$DUMP_LOCAL_PATH") (${size})"

    # Rotate old dumps — keep KEEP_DUMPS most recent
    # shellcheck disable=SC2012
    ls -t "${TEMP_DIR}"/db_* 2>/dev/null \
        | tail -n +"$((KEEP_DUMPS + 1))" \
        | xargs -r rm --
    info "Dump rotation done (keeping ${KEEP_DUMPS})"
}

# =============================================================================
# SECTION 11: SYNC MOODLEDATA (includes dump in mirror/ subdir)
# =============================================================================
sync_moodledata() {
    section "Syncing moodledata to test server"

    local exclude_args=()
    for excl in "${RSYNC_EXCLUDES[@]}"; do
        exclude_args+=("--exclude=${excl}")
    done
    exclude_args+=("--include=${DUMP_SUBDIR}/")

    local dry_flag=()
    [[ "$DRY_RUN" == "true" ]] && dry_flag=("--dry-run")

    local rsync_ssh="ssh -p ${TEST_SSH_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    if [[ ${#SSH_EXTRA_OPTS[@]} -gt 0 ]]; then
        rsync_ssh+=" $(printf '%q ' "${SSH_EXTRA_OPTS[@]}")"
    fi

    rsync \
        --archive \
        --compress \
        --delete \
        --delete-excluded \
        --human-readable \
        --stats \
        --rsh="$rsync_ssh" \
        "${dry_flag[@]}" \
        "${exclude_args[@]}" \
        "${PROD_MOODLEDATA}/" \
        "$(ssh_target):${TEST_MOODLEDATA}/" \
        2>&1 | tee -a "$LOG_FILE"

    info "moodledata rsync complete"
}

sync_dump_only() {
    section "Syncing DB dump only to test server"

    rsync \
        --archive \
        --compress \
        --human-readable \
        --rsh="ssh -p ${TEST_SSH_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes" \
        "$DUMP_LOCAL_PATH" \
        "$(ssh_target):${TEST_MOODLEDATA}/${DUMP_SUBDIR}/" \
        2>&1 | tee -a "$LOG_FILE"

    info "DB dump rsync complete"
}

# =============================================================================
# SECTION 12: POST-IMPORT (executed on test server via SSH heredoc)
#   All logic is sent inline — no separate file to maintain or transfer.
# =============================================================================
run_post_import() {
    section "Running post-import steps on test server"

    # The dump landed at the same relative path under TEST_MOODLEDATA
    local remote_dump="${TEST_MOODLEDATA}/${DUMP_SUBDIR}/$(basename "$DUMP_LOCAL_PATH")"
    info "Remote dump path: $remote_dump"

    ssh_base \
        "TEST_MOODLE_ROOT=$(printf '%q' "$TEST_MOODLE_ROOT") \
         TEST_MOODLEDATA=$(printf '%q' "$TEST_MOODLEDATA") \
         TEST_PHP_CLI=$(printf '%q' "$TEST_PHP_CLI") \
         TEST_DB_TYPE=$(printf '%q' "$TEST_DB_TYPE") \
         TEST_DB_HOST=$(printf '%q' "$TEST_DB_HOST") \
         TEST_DB_PORT=$(printf '%q' "$TEST_DB_PORT") \
         TEST_DB_NAME=$(printf '%q' "$TEST_DB_NAME") \
         TEST_DB_USER=$(printf '%q' "$TEST_DB_USER") \
         TEST_DB_PASS=$(printf '%q' "$TEST_DB_PASS") \
         PROD_WWWROOT=$(printf '%q' "$PROD_WWWROOT") \
         DUMP_PATH=$(printf '%q' "$remote_dump") \
         bash -s" <<'ENDSSH' 2>&1 | tee -a "$LOG_FILE"
set -euo pipefail

LOG="/tmp/moodle_mirror_postimport_$$.log"

log_r() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [REMOTE] $*" | tee -a "$LOG"; }
warn_r() { log_r "WARN $*"; }

log_r "=== Post-import start ==="

CONFIG="${TEST_MOODLE_ROOT}/config.php"
CONFIG_BK="/tmp/moodle_config_protected_$$.php"

[[ -f "$CONFIG" ]] || { log_r "ERROR: config.php missing at $CONFIG"; exit 1; }
cp -p "$CONFIG" "$CONFIG_BK"
log_r "config.php protected -> $CONFIG_BK"

restore_config() {
    cp -p "$CONFIG_BK" "$CONFIG"
    rm -f "$CONFIG_BK"
    log_r "config.php restored"
}
trap restore_config EXIT

log_r "Enabling maintenance mode..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/maintenance.php" \
    --enable 2>&1 | tee -a "$LOG" \
    || warn_r "Could not enable maintenance mode"

log_r "Importing database: $DUMP_PATH"
[[ -f "$DUMP_PATH" ]] || { log_r "ERROR: dump not found at $DUMP_PATH"; exit 1; }

case "$TEST_DB_TYPE" in
    pgsql)
        export PGPASSWORD="$TEST_DB_PASS"

        log_r "Resetting PostgreSQL public schema on test database..."
        psql \
            -h "$TEST_DB_HOST" \
            -p "$TEST_DB_PORT" \
            -U "$TEST_DB_USER" \
            -d "$TEST_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "DROP SCHEMA IF EXISTS public CASCADE;" \
            >>"$LOG" 2>&1

        psql \
            -h "$TEST_DB_HOST" \
            -p "$TEST_DB_PORT" \
            -U "$TEST_DB_USER" \
            -d "$TEST_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "CREATE SCHEMA public AUTHORIZATION \"$TEST_DB_USER\";" \
            >>"$LOG" 2>&1

        psql \
            -h "$TEST_DB_HOST" \
            -p "$TEST_DB_PORT" \
            -U "$TEST_DB_USER" \
            -d "$TEST_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "GRANT ALL ON SCHEMA public TO \"$TEST_DB_USER\";" \
            >>"$LOG" 2>&1 || true

        psql \
            -h "$TEST_DB_HOST" \
            -p "$TEST_DB_PORT" \
            -U "$TEST_DB_USER" \
            -d "$TEST_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "GRANT ALL ON SCHEMA public TO public;" \
            >>"$LOG" 2>&1 || true

        log_r "Restoring PostgreSQL plain SQL dump into existing database..."
        gzip -dc "$DUMP_PATH" \
            | psql \
                -h "$TEST_DB_HOST" \
                -p "$TEST_DB_PORT" \
                -U "$TEST_DB_USER" \
                -d "$TEST_DB_NAME" \
                -q \
                -v ON_ERROR_STOP=1 \
                > /dev/null \
                2>>"$LOG"
        ;;

    mariadb|mysql)
        export MYSQL_PWD="$TEST_DB_PASS"

        log_r "Dropping existing views in MariaDB test database..."
        mysql \
            -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
            -Nse "
SET SESSION group_concat_max_len = 1000000;
SELECT IFNULL(
  CONCAT(
    'DROP VIEW IF EXISTS ',
    GROUP_CONCAT(CONCAT('\`', table_name, '\`') SEPARATOR ','),
    ';'
  ),
  'SELECT 1;'
)
FROM information_schema.views
WHERE table_schema = '$TEST_DB_NAME';
" "$TEST_DB_NAME" \
            | mysql \
                -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
                "$TEST_DB_NAME" \
            2>&1 | tee -a "$LOG" || true

        log_r "Dropping existing tables in MariaDB test database..."
        mysql \
            -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
            -Nse "
SET SESSION group_concat_max_len = 1000000;
SET FOREIGN_KEY_CHECKS=0;
SELECT IFNULL(
  CONCAT(
    'DROP TABLE IF EXISTS ',
    GROUP_CONCAT(CONCAT('\`', table_name, '\`') SEPARATOR ','),
    ';'
  ),
  'SELECT 1;'
)
FROM information_schema.tables
WHERE table_schema = '$TEST_DB_NAME'
  AND table_type = 'BASE TABLE';
" "$TEST_DB_NAME" \
            | mysql \
                -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
                "$TEST_DB_NAME" \
            2>&1 | tee -a "$LOG"

        log_r "Restoring MariaDB dump into existing database..."
        gzip -dc "$DUMP_PATH" \
            | mysql \
                -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
                "$TEST_DB_NAME" \
            2>&1 | tee -a "$LOG"

        unset MYSQL_PWD
        ;;
esac

log_r "Database import complete"

restore_config
trap - EXIT

log_r "Reading test wwwroot and dataroot from test config.php..."

get_cfg() {
    "$TEST_PHP_CLI" -d error_reporting=0 -r "
        define('CLI_SCRIPT', true);
        require('${TEST_MOODLE_ROOT}/config.php');
        echo \$CFG->$1 ?? '';
    " 2>/dev/null
}

TEST_WWWROOT=$(get_cfg wwwroot)
TEST_DATAROOT=$(get_cfg dataroot)

log_r "Test wwwroot : $TEST_WWWROOT"
log_r "Test dataroot: $TEST_DATAROOT"

log_r "Running wwwroot search/replace in DB..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/replace.php" \
    --search="$PROD_WWWROOT" \
    --replace="$TEST_WWWROOT" \
    --non-interactive \
    2>&1 | tee -a "$LOG" || warn_r "replace.php returned non-zero"

set_cfg() {
    "$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/cfg.php" \
        --name="$1" --set="$2" \
        2>&1 | tee -a "$LOG" \
        || warn_r "Could not set cfg $1"
}

set_cfg wwwroot     "$TEST_WWWROOT"
set_cfg dataroot    "$TEST_DATAROOT"
set_cfg noemailever 1

log_r "Sanitisation complete"

log_r "Purging caches..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/purge_caches.php" \
    2>&1 | tee -a "$LOG" || warn_r "Cache purge failed"

log_r "Running upgrade check..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/upgrade.php" \
    --non-interactive \
    2>&1 | tee -a "$LOG" || warn_r "upgrade.php returned non-zero"

log_r "Disabling maintenance mode..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/maintenance.php" \
    --disable 2>&1 | tee -a "$LOG" \
    || warn_r "Could not disable maintenance mode"

log_r "=== Post-import complete ==="
ENDSSH

    info "Post-import finished"
}

# =============================================================================
# SECTION 13: SUMMARY
# =============================================================================
print_summary() {
    local end duration mins secs
    end=$(date +%s)
    duration=$((end - SCRIPT_START))
    mins=$((duration / 60))
    secs=$((duration % 60))

    section "Summary"
    info "Finished at  : $(date)"
    info "Duration     : ${mins}m ${secs}s"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "Files synced : preview only"
        info "DB synced    : skipped"
        info "*** DRY RUN — no changes were applied ***"
    else
        info "Files synced : $( [[ "$DB_ONLY"    == "true" ]] && echo "skipped" || echo "yes")"
        info "DB synced    : $( [[ "$FILES_ONLY" == "true" ]] && echo "skipped" || echo "yes")"
    fi

    info "Log          : $LOG_FILE"
}

# =============================================================================
# SECTION 14: MAIN
# =============================================================================
SCRIPT_START=$(date +%s)

main() {
    section "Moodle Mirror: Production → Test ($(date))"
    [[ "$DRY_RUN"    == "true" ]] && info "*** DRY RUN MODE ***"
    [[ "$FILES_ONLY" == "true" ]] && info "*** FILES ONLY ***"
    [[ "$DB_ONLY"    == "true" ]] && info "*** DB ONLY ***"

    acquire_lock
    # Always read Moodle config.php first, then apply overrides
    load_moodle_config
    apply_overrides
    # Now we know PROD_MOODLEDATA — set up working dir inside it
    setup_temp
    preflight

    # DB dump goes first — lands in moodledata/mirror/ before rsync runs
    if [[ "$FILES_ONLY" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        dump_prod_db
    fi

    # rsync carries moodledata/ including the fresh dump
    if [[ "$DB_ONLY" != "true" ]]; then
        sync_moodledata
    fi

    # Trigger import + sanitise on test server
    if [[ "$DB_ONLY" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        sync_dump_only
    fi

    if [[ "$FILES_ONLY" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        run_post_import
    fi

    print_summary
    cleanup
}

main "$@"
