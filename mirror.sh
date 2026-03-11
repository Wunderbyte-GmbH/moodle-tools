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
#
# Optional:
#   MIRROR_CONFIG=/path/to/mirror.config ./mirror.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# SECTION 1: SCRIPT PATHS + EXTERNAL CONFIG
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/mirror.config"
CONFIG_FILE="${MIRROR_CONFIG:-$DEFAULT_CONFIG_FILE}"

# mirror.log always lives beside mirror.sh
LOG_FILE="${SCRIPT_DIR}/mirror.log"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    echo "Expected default location: ${DEFAULT_CONFIG_FILE}" >&2
    echo "Create mirror.config beside ${SCRIPT_NAME}, or run with:" >&2
    echo "  MIRROR_CONFIG=/path/to/mirror.config ./${SCRIPT_NAME}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# =============================================================================
# SECTION 2: CONFIG VALIDATION
# =============================================================================
require_config_var() {
    local varname="$1"
    if [[ -z "${!varname:-}" ]]; then
        echo "ERROR: Required config variable '$varname' is missing or empty in: $CONFIG_FILE" >&2
        exit 1
    fi
}

validate_config() {
    require_config_var "PROD_MOODLE_ROOT"
    require_config_var "PROD_PHP_CLI"

    require_config_var "TEST_HOST"
    require_config_var "TEST_SSH_USER"
    require_config_var "TEST_SSH_PORT"

    require_config_var "TEST_MOODLE_ROOT"
    require_config_var "TEST_MOODLEDATA"
    require_config_var "TEST_PHP_CLI"

    require_config_var "TEST_DB_TYPE"
    require_config_var "TEST_DB_HOST"
    require_config_var "TEST_DB_PORT"
    require_config_var "TEST_DB_NAME"
    require_config_var "TEST_DB_USER"
    require_config_var "TEST_DB_PASS"

    require_config_var "DUMP_SUBDIR"
    require_config_var "REPLACE_SHORTEN"
    require_config_var "LOG_MAX_BYTES"
    require_config_var "LOCK_FILE"
    require_config_var "KEEP_DUMPS"
    require_config_var "NOTIFY_ON_FAILURE"

    if ! declare -p SSH_EXTRA_OPTS >/dev/null 2>&1; then
        echo "ERROR: Required config variable 'SSH_EXTRA_OPTS' must be defined as an array in: $CONFIG_FILE" >&2
        exit 1
    fi

    if ! declare -p RSYNC_EXCLUDES >/dev/null 2>&1; then
        echo "ERROR: Required config variable 'RSYNC_EXCLUDES' must be defined as an array in: $CONFIG_FILE" >&2
        exit 1
    fi
}

validate_config


# =============================================================================
# SECTION 3: ARGUMENT PARSING
# =============================================================================
DRY_RUN=false
FILES_ONLY=false
DB_ONLY=false
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --files-only) FILES_ONLY=true ;;
        --db-only)    DB_ONLY=true ;;
        --force)      FORCE=true ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--dry-run] [--files-only] [--db-only] [--force]"
            echo ""
            echo "  --dry-run     rsync preview only, no DB import, no remote exec"
            echo "  --files-only  sync moodledata only, skip DB dump and import"
            echo "  --db-only     dump and import DB only, skip moodledata rsync"
            echo "  --force       skip compatibility check confirmation prompt"
            exit 1
            ;;
    esac
done


# =============================================================================
# SECTION 4: LOGGING
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
# SECTION 5: NOTIFICATIONS
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
# SECTION 6: LOCK
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
# SECTION 7: CLEANUP + TRAPS
# =============================================================================
TEMP_DIR=""   # set after we know PROD_MOODLEDATA

setup_temp() {
    TEMP_DIR="${PROD_MOODLEDATA}/${DUMP_SUBDIR}"
    mkdir -p "$TEMP_DIR"
    info "Working directory: $TEMP_DIR"
}

cleanup() {
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
# SECTION 8: READ CONFIG FROM MOODLE config.php
# =============================================================================
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

normalise_db_type() {
    local raw="$1"
    case "${raw,,}" in
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

    # Read production Moodle version + release from version.php
    PROD_MOODLE_VERSION=$(
        grep -E '^[[:space:]]*\$version[[:space:]]*=' "${PROD_MOODLE_ROOT}/version.php" \
            | head -n1 \
            | sed -nE 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*([0-9.]+);.*$/\1/p' \
            2>/dev/null || true
    )

    PROD_MOODLE_RELEASE=$(
        grep -E '^[[:space:]]*\$release[[:space:]]*=' "${PROD_MOODLE_ROOT}/version.php" \
            | head -n1 \
            | sed -nE "s/^[[:space:]]*\$release[[:space:]]*=[[:space:]]*'(.*)';.*$/\1/p" \
            2>/dev/null || true
    )

    info "DB type    : $PROD_DB_TYPE"
    info "DB host    : $PROD_DB_HOST:$PROD_DB_PORT"
    info "DB name    : $PROD_DB_NAME"
    info "DB user    : $PROD_DB_USER"
    info "moodledata : $PROD_MOODLEDATA"
    info "wwwroot    : $PROD_WWWROOT"
    info "Moodle ver : $PROD_MOODLE_VERSION (${PROD_MOODLE_RELEASE:-unknown})"
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
# SECTION 9: COMPATIBILITY CHECK
#
# Compares production vs test for:
#   - Moodle core version (downgrade detection)
#   - Plugin versions (missing or older on test)
#
# Uses version.php files on both sides for Moodle core.
# Uses the production DB for plugin versions (authoritative installed state).
# Uses the test DB for what is currently installed on test.
#
# If any problems are found:
#   - Lists all issues clearly
#   - If running interactively: asks for confirmation to continue
#   - If --force is set: logs a warning and continues automatically
#   - If running non-interactively without --force: aborts
# =============================================================================
normalise_version_number() {
    local v="$1"
    echo "${v%%.*}"
}

compatibility_check() {
    section "Compatibility check: Production vs Test"

    # Collect issues into an array so we can display them all at once.
    local issues=()

    # -------------------------------------------------------------------------
    # 1. Moodle core version
    # -------------------------------------------------------------------------
    info "Reading test Moodle core version..."

    local test_version test_release
    test_version=$(
        remote_exec_capture "grep -E '^[[:space:]]*\\\$version[[:space:]]*=' '${TEST_MOODLE_ROOT}/version.php' \
            | head -n1 \
            | sed -nE 's/^[[:space:]]*\\\$version[[:space:]]*=[[:space:]]*([0-9.]+);.*$/\1/p'"
    )

    test_release=$(
        remote_exec_capture "grep -E '^[[:space:]]*\\\$release[[:space:]]*=' '${TEST_MOODLE_ROOT}/version.php' \
            | head -n1 \
            | sed -nE \"s/^[[:space:]]*\\\$release[[:space:]]*=[[:space:]]*'(.*)';.*$/\\1/p\""
    )

    info "Production core : $PROD_MOODLE_VERSION (${PROD_MOODLE_RELEASE:-unknown})"
    info "Test core       : ${test_version:-unknown} (${test_release:-unknown})"

    local prod_core_num test_core_num
    prod_core_num=$(normalise_version_number "$PROD_MOODLE_VERSION")
    test_core_num=$(normalise_version_number "$test_version")

    if [[ -z "$test_version" ]]; then
        issues+=("Could not read test Moodle version from ${TEST_MOODLE_ROOT}/version.php")
    elif [[ -z "$prod_core_num" || -z "$test_core_num" ]]; then
        issues+=("Could not normalise Moodle core versions for comparison (prod='${PROD_MOODLE_VERSION}', test='${test_version}')")
    elif [[ "$prod_core_num" -lt "$test_core_num" ]]; then
        issues+=("CORE DOWNGRADE: Production ($PROD_MOODLE_VERSION / ${PROD_MOODLE_RELEASE:-unknown}) is OLDER than Test ($test_version / ${test_release:-unknown}). Importing would downgrade the test database schema.")
    elif [[ "$prod_core_num" -eq "$test_core_num" ]]; then
        info "Core version match: OK"
    else
        info "Core upgrade: Production ($PROD_MOODLE_VERSION) is newer than Test ($test_version) — upgrade.php will run after import."
    fi

    # -------------------------------------------------------------------------
    # 2. Plugin version comparison
    #
    # Strategy:
    #   - Dump plugin component + version from production DB (mdl_config_plugins)
    #   - Dump plugin component + version from test DB via SSH
    #   - Compare: flag any plugin that is missing on test or older on test
    #     than what production has installed.
    #
    # We intentionally do NOT flag plugins that exist on test but not on prod
    # (those are test-only plugins and are fine).
    # -------------------------------------------------------------------------
    info "Comparing plugin versions between production and test databases..."

    # Get production plugin versions from local DB.
    # mdl_config_plugins stores 'version' as a value for name='version' per plugin.
    local prod_plugins_raw
    prod_plugins_raw=$(get_prod_plugin_versions)

    # Get test plugin versions via SSH.
    local test_plugins_raw
    test_plugins_raw=$(get_test_plugin_versions)

    if [[ -z "$prod_plugins_raw" ]]; then
        issues+=("Could not read plugin versions from production database.")
    elif [[ -z "$test_plugins_raw" ]]; then
        issues+=("Could not read plugin versions from test database.")
    else
        # Build associative arrays: component -> version
        declare -A prod_plugins test_plugins

        while IFS='|' read -r component version; do
            [[ -n "$component" ]] && prod_plugins["$component"]="$version"
        done <<< "$prod_plugins_raw"

        while IFS='|' read -r component version; do
            [[ -n "$component" ]] && test_plugins["$component"]="$version"
        done <<< "$test_plugins_raw"

        local missing_count=0 older_count=0

        for component in "${!prod_plugins[@]}"; do
            local prod_ver="${prod_plugins[$component]}"
            local test_ver="${test_plugins[$component]:-}"

            if [[ -z "$test_ver" ]]; then
                issues+=("MISSING PLUGIN on test: ${component} (prod version: ${prod_ver})")
                (( missing_count++ )) || true
            elif [[ "$prod_ver" -gt "$test_ver" ]] 2>/dev/null; then
                issues+=("OLDER PLUGIN on test: ${component} — test has ${test_ver}, prod has ${prod_ver}")
                (( older_count++ )) || true
            fi
        done

        info "Plugin check: ${missing_count} missing, ${older_count} older on test"
    fi

    # -------------------------------------------------------------------------
    # 3. Present findings and decide whether to continue
    # -------------------------------------------------------------------------
    if [[ ${#issues[@]} -eq 0 ]]; then
        info "Compatibility check passed — no issues found."
        return 0
    fi

    # Print all issues prominently.
    echo "" | tee -a "$LOG_FILE"
    echo "╔══════════════════════════════════════════════════════════════════╗" | tee -a "$LOG_FILE"
    echo "║         COMPATIBILITY CHECK FAILED — ISSUES FOUND               ║" | tee -a "$LOG_FILE"
    echo "╚══════════════════════════════════════════════════════════════════╝" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    for issue in "${issues[@]}"; do
        echo "  ⚠  $issue" | tee -a "$LOG_FILE"
    done
    echo "" | tee -a "$LOG_FILE"

    # Check for a core downgrade specifically — that is always a hard blocker
    # unless explicitly forced.
    local has_downgrade=false
    for issue in "${issues[@]}"; do
        [[ "$issue" == CORE\ DOWNGRADE* ]] && has_downgrade=true && break
    done

    if [[ "$has_downgrade" == "true" ]]; then
        warn "A Moodle core DOWNGRADE was detected."
    fi

    # Decision logic.
    if [[ "$FORCE" == "true" ]]; then
        warn "--force is set. Continuing despite the issues above."
        return 0
    fi

    # Is stdin a terminal? (i.e. interactive run)
    if [[ -t 0 ]]; then
        local answer=""
        while true; do
            printf "Continue anyway? [yes/no]: "
            read -r answer
            case "${answer,,}" in
                yes|y) info "User chose to continue."; return 0 ;;
                no|n)  info "User chose to abort."; cleanup; exit 1 ;;
                *)     echo "Please type 'yes' or 'no'." ;;
            esac
        done
    else
        # Non-interactive (cron). Abort — we cannot prompt.
        die "Compatibility issues found and running non-interactively without --force. Aborting."
    fi
}

# Fetch plugin component|version rows from the PRODUCTION database (local).
get_prod_plugin_versions() {
    case "$PROD_DB_TYPE" in
        pgsql)
            PGPASSWORD="$PROD_DB_PASS" psql \
                -h "$PROD_DB_HOST" \
                -p "$PROD_DB_PORT" \
                -U "$PROD_DB_USER" \
                -d "$PROD_DB_NAME" \
                -t -A -F'|' \
                -c "SELECT plugin, value
                    FROM mdl_config_plugins
                    WHERE name = 'version'
                    ORDER BY plugin;" \
                2>/dev/null || true
            ;;
        mariadb|mysql)
            MYSQL_PWD="$PROD_DB_PASS" mysql \
                -h "$PROD_DB_HOST" \
                -P "$PROD_DB_PORT" \
                -u "$PROD_DB_USER" \
                -D "$PROD_DB_NAME" \
                --batch --skip-column-names \
                -e "SELECT plugin, value
                    FROM mdl_config_plugins
                    WHERE name = 'version'
                    ORDER BY plugin;" \
                2>/dev/null \
                | tr '\t' '|' || true
            ;;
    esac
}

# Fetch plugin component|version rows from the TEST database (remote via SSH).
get_test_plugin_versions() {
    case "$TEST_DB_TYPE" in
        pgsql)
            remote_exec_capture \
                "PGPASSWORD=$(printf '%q' "$TEST_DB_PASS") \
                 psql \
                    -h $(printf '%q' "$TEST_DB_HOST") \
                    -p $(printf '%q' "$TEST_DB_PORT") \
                    -U $(printf '%q' "$TEST_DB_USER") \
                    -d $(printf '%q' "$TEST_DB_NAME") \
                    -t -A -F'|' \
                    -c \"SELECT plugin, value
                         FROM mdl_config_plugins
                         WHERE name = 'version'
                         ORDER BY plugin;\"" \
                2>/dev/null || true
            ;;
        mariadb|mysql)
            remote_exec_capture \
                "MYSQL_PWD=$(printf '%q' "$TEST_DB_PASS") \
                 mysql \
                    -h $(printf '%q' "$TEST_DB_HOST") \
                    -P $(printf '%q' "$TEST_DB_PORT") \
                    -u $(printf '%q' "$TEST_DB_USER") \
                    -D $(printf '%q' "$TEST_DB_NAME") \
                    --batch --skip-column-names \
                    -e \"SELECT plugin, value
                         FROM mdl_config_plugins
                         WHERE name = 'version'
                         ORDER BY plugin;\"" \
                2>/dev/null \
                | tr '\t' '|' || true
            ;;
    esac
}


# =============================================================================
# SECTION 10: PREFLIGHT
# =============================================================================
preflight() {
    section "Preflight checks"

    [[ -d "$PROD_MOODLEDATA" ]] || die "Production moodledata not found: $PROD_MOODLEDATA"

    command -v ssh   &>/dev/null || die "ssh not installed"
    command -v rsync &>/dev/null || die "rsync not installed"

    if [[ "$FILES_ONLY" != "true" ]]; then
        case "$PROD_DB_TYPE" in
            pgsql)   command -v pg_dump   &>/dev/null || die "pg_dump not found"
                     command -v psql      &>/dev/null || die "psql not found" ;;
            mariadb) command -v mysqldump &>/dev/null || die "mysqldump not found"
                     command -v mysql     &>/dev/null || die "mysql client not found" ;;
        esac
    fi

    info "Testing SSH to test server..."
    remote_exec "echo 'SSH OK'" \
        || die "Cannot SSH to test server."

    remote_exec "[[ -f '${TEST_MOODLE_ROOT}/config.php' ]]" \
        || die "Test config.php not found remotely: ${TEST_MOODLE_ROOT}/config.php"

    remote_exec "[[ -d '${TEST_MOODLEDATA}' ]]" \
        || die "Test moodledata not found remotely: ${TEST_MOODLEDATA}"

    remote_exec "command -v ${TEST_PHP_CLI} >/dev/null" \
        || die "PHP CLI not found on test server: ${TEST_PHP_CLI}"

    # Check that admin/tool/replace exists on test (needed for URL replace)
    remote_exec "[[ -f '${TEST_MOODLE_ROOT}/admin/tool/replace/cli/replace.php' ]]" \
        || die "admin/tool/replace/cli/replace.php not found on test server. Install the tool_replace plugin."

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
# SECTION 11: SSH HELPERS
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

# Execute a remote command, streaming output to log and stdout.
remote_exec() {
    ssh_base "$@" 2>&1 | tee -a "$LOG_FILE"
}

# Execute a remote command, capturing stdout only (no tee — for parsing).
remote_exec_capture() {
    ssh_base "$@" 2>/dev/null
}


# =============================================================================
# SECTION 12: DUMP PRODUCTION DATABASE
# =============================================================================
dump_prod_db() {
    section "Dumping production database"

    local ts
    ts=$(date '+%Y%m%d_%H%M%S')

    case "$PROD_DB_TYPE" in
        pgsql)
            DUMP_LOCAL_PATH="${TEMP_DIR}/db_${ts}.sql.gz"
            local temp_sql="${TEMP_DIR}/db_${ts}.sql"
            info "Dumping (pg_dump plain SQL + gzip) -> $DUMP_LOCAL_PATH"

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

    mv "${DUMP_LOCAL_PATH}.inprogress" "$DUMP_LOCAL_PATH"

    local size
    size=$(du -sh "$DUMP_LOCAL_PATH" | cut -f1)
    info "Dump complete: $(basename "$DUMP_LOCAL_PATH") (${size})"

    # shellcheck disable=SC2012
    ls -t "${TEMP_DIR}"/db_* 2>/dev/null \
        | tail -n +"$((KEEP_DUMPS + 1))" \
        | xargs -r rm --
    info "Dump rotation done (keeping ${KEEP_DUMPS})"
}


# =============================================================================
# SECTION 13: SYNC MOODLEDATA
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
# SECTION 14: POST-IMPORT (executed on test server via SSH heredoc)
#
# URL replacement uses admin/tool/replace/cli/replace.php which correctly
# handles serialised PHP data, JSON, and plain strings in all DB tables.
#
# Supported replace.php options passed through from config:
#   --skiptables=   from REPLACE_SKIP_TABLES
#   --shorten       from REPLACE_SHORTEN
# =============================================================================
run_post_import() {
    section "Running post-import steps on test server"

    local remote_dump="${TEST_MOODLEDATA}/${DUMP_SUBDIR}/$(basename "$DUMP_LOCAL_PATH")"
    info "Remote dump path: $remote_dump"

    # Build the replace.php options string here on production,
    # so the heredoc receives a simple ready-to-use string.
    local replace_extra_opts=""
    if [[ -n "$REPLACE_SKIP_TABLES" ]]; then
        replace_extra_opts+=" --skiptables=$(printf '%q' "$REPLACE_SKIP_TABLES")"
    fi
    if [[ "$REPLACE_SHORTEN" == "true" ]]; then
        replace_extra_opts+=" --shorten"
    fi

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
         REPLACE_EXTRA_OPTS=$(printf '%q' "$replace_extra_opts") \
         DUMP_PATH=$(printf '%q' "$remote_dump") \
         bash -s" <<'ENDSSH' 2>&1 | tee -a "$LOG_FILE"
set -euo pipefail

LOG="/tmp/moodle_mirror_postimport_$$.log"

log_r()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [REMOTE] $*" | tee -a "$LOG"; }
warn_r() { log_r "WARN $*"; }

log_r "=== Post-import start ==="

# ---------------------------------------------------------------------------
# 0. Protect config.php
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 1. Maintenance mode ON
# ---------------------------------------------------------------------------
log_r "Enabling maintenance mode..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/maintenance.php" \
    --enable 2>&1 | tee -a "$LOG" \
    || warn_r "Could not enable maintenance mode"

# ---------------------------------------------------------------------------
# 2. Import database dump
# ---------------------------------------------------------------------------
log_r "Importing database: $DUMP_PATH"
[[ -f "$DUMP_PATH" ]] || { log_r "ERROR: dump not found at $DUMP_PATH"; exit 1; }

case "$TEST_DB_TYPE" in
    pgsql)
        export PGPASSWORD="$TEST_DB_PASS"

        log_r "Resetting PostgreSQL public schema..."
        psql \
            -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" \
            -U "$TEST_DB_USER" -d "$TEST_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "DROP SCHEMA IF EXISTS public CASCADE;" \
            >>"$LOG" 2>&1

        psql \
            -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" \
            -U "$TEST_DB_USER" -d "$TEST_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "CREATE SCHEMA public AUTHORIZATION \"$TEST_DB_USER\";" \
            >>"$LOG" 2>&1

        psql \
            -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" \
            -U "$TEST_DB_USER" -d "$TEST_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "GRANT ALL ON SCHEMA public TO \"$TEST_DB_USER\";" \
            >>"$LOG" 2>&1 || true

        psql \
            -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" \
            -U "$TEST_DB_USER" -d "$TEST_DB_NAME" \
            -v ON_ERROR_STOP=1 \
            -c "GRANT ALL ON SCHEMA public TO public;" \
            >>"$LOG" 2>&1 || true

        log_r "Restoring PostgreSQL dump..."
        gzip -dc "$DUMP_PATH" \
            | psql \
                -h "$TEST_DB_HOST" -p "$TEST_DB_PORT" \
                -U "$TEST_DB_USER" -d "$TEST_DB_NAME" \
                -q -v ON_ERROR_STOP=1 \
                > /dev/null 2>>"$LOG"
        ;;

    mariadb|mysql)
        export MYSQL_PWD="$TEST_DB_PASS"

        log_r "Dropping existing views in test database..."
        mysql \
            -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
            -Nse "
SET SESSION group_concat_max_len = 1000000;
SELECT IFNULL(
  CONCAT('DROP VIEW IF EXISTS ',
    GROUP_CONCAT(CONCAT('\`', table_name, '\`') SEPARATOR ','), ';'),
  'SELECT 1;'
)
FROM information_schema.views
WHERE table_schema = '$TEST_DB_NAME';
" "$TEST_DB_NAME" \
            | mysql \
                -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
                "$TEST_DB_NAME" \
            2>&1 | tee -a "$LOG" || true

        log_r "Dropping existing tables in test database..."
        mysql \
            -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
            -Nse "
SET SESSION group_concat_max_len = 1000000;
SET FOREIGN_KEY_CHECKS=0;
SELECT IFNULL(
  CONCAT('DROP TABLE IF EXISTS ',
    GROUP_CONCAT(CONCAT('\`', table_name, '\`') SEPARATOR ','), ';'),
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

        log_r "Restoring MariaDB dump..."
        gzip -dc "$DUMP_PATH" \
            | mysql \
                -h "$TEST_DB_HOST" -P "$TEST_DB_PORT" -u "$TEST_DB_USER" \
                "$TEST_DB_NAME" \
            2>&1 | tee -a "$LOG"

        unset MYSQL_PWD
        ;;
esac

log_r "Database import complete"

# ---------------------------------------------------------------------------
# 3. Restore config.php before any PHP CLI calls
# ---------------------------------------------------------------------------
restore_config
trap - EXIT

# ---------------------------------------------------------------------------
# 4. Read test site values from its own config.php
# ---------------------------------------------------------------------------
log_r "Reading test site configuration..."

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

# ---------------------------------------------------------------------------
# 5. URL replacement via admin/tool/replace/cli/replace.php
#
#    This tool handles all of:
#      - plain strings
#      - serialised PHP data (a:1:{s:3:"url";s:...})
#      - JSON encoded strings
#    It is safer than a raw DB search/replace for Moodle data.
#
#    Options used:
#      --search          production wwwroot
#      --replace         test wwwroot
#      --non-interactive no confirmation prompt
#      --skiptables      from REPLACE_SKIP_TABLES config (optional)
#      --shorten         from REPLACE_SHORTEN config (optional)
# ---------------------------------------------------------------------------
log_r "Replacing production URL with test URL in database..."
log_r "  search : $PROD_WWWROOT"
log_r "  replace: $TEST_WWWROOT"
[[ -n "$REPLACE_EXTRA_OPTS" ]] && log_r "  extra  : $REPLACE_EXTRA_OPTS"

# shellcheck disable=SC2086
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/tool/replace/cli/replace.php" \
    --search="$PROD_WWWROOT" \
    --replace="$TEST_WWWROOT" \
    --non-interactive \
    $REPLACE_EXTRA_OPTS \
    2>&1 | tee -a "$LOG" \
    || warn_r "replace.php returned non-zero — check log for details"

# ---------------------------------------------------------------------------
# 6. Set critical config values explicitly via cfg.php
#    Belt-and-suspenders: ensures mdl_config table is consistent with
#    what config.php declares, even if replace.php missed an edge case.
# ---------------------------------------------------------------------------
set_cfg() {
    "$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/cfg.php" \
        --name="$1" --set="$2" \
        2>&1 | tee -a "$LOG" \
        || warn_r "Could not set cfg $1"
}

log_r "Setting critical config values..."
set_cfg wwwroot     "$TEST_WWWROOT"
set_cfg dataroot    "$TEST_DATAROOT"
set_cfg noemailever 1

log_r "Sanitisation complete"

# ---------------------------------------------------------------------------
# 7. Purge caches
# ---------------------------------------------------------------------------
log_r "Purging caches..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/purge_caches.php" \
    2>&1 | tee -a "$LOG" || warn_r "Cache purge failed"

# ---------------------------------------------------------------------------
# 8. Run upgrade
# ---------------------------------------------------------------------------
log_r "Running upgrade check..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/upgrade.php" \
    --non-interactive \
    2>&1 | tee -a "$LOG" || warn_r "upgrade.php returned non-zero"

# ---------------------------------------------------------------------------
# 9. Maintenance mode OFF
# ---------------------------------------------------------------------------
log_r "Disabling maintenance mode..."
"$TEST_PHP_CLI" "${TEST_MOODLE_ROOT}/admin/cli/maintenance.php" \
    --disable 2>&1 | tee -a "$LOG" \
    || warn_r "Could not disable maintenance mode"

log_r "=== Post-import complete ==="
ENDSSH

    info "Post-import finished"
}


# =============================================================================
# SECTION 15: SUMMARY
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
    info "Config       : $CONFIG_FILE"
}


# =============================================================================
# SECTION 16: MAIN
# =============================================================================
SCRIPT_START=$(date +%s)

main() {
    section "Moodle Mirror: Production → Test ($(date))"
    info "Script dir   : $SCRIPT_DIR"
    info "Config file  : $CONFIG_FILE"
    info "Log file     : $LOG_FILE"
    [[ "$DRY_RUN"    == "true" ]] && info "*** DRY RUN MODE ***"
    [[ "$FILES_ONLY" == "true" ]] && info "*** FILES ONLY ***"
    [[ "$DB_ONLY"    == "true" ]] && info "*** DB ONLY ***"
    [[ "$FORCE"      == "true" ]] && warn "*** --force: compatibility check will not prompt ***"

    acquire_lock

    # Read production config.php, apply any overrides from config block.
    load_moodle_config
    apply_overrides

    # Working dir is now known — set it up.
    setup_temp

    # Basic preflight (SSH, paths, tools).
    preflight

    # Compatibility check — runs before any destructive action.
    # Skipped for --files-only (no DB import will happen).
    if [[ "$FILES_ONLY" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        compatibility_check
    fi

    # DB dump goes first — lands in moodledata/mirror/ before rsync.
    if [[ "$FILES_ONLY" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        dump_prod_db
    fi

    # rsync carries moodledata/ including the fresh dump.
    if [[ "$DB_ONLY" != "true" ]]; then
        sync_moodledata
    fi

    # --db-only: no full rsync, but we still need to push the dump.
    if [[ "$DB_ONLY" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        sync_dump_only
    fi

    # Post-import: DB import + URL replace + sanitise + upgrade on test.
    if [[ "$FILES_ONLY" != "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
        run_post_import
    fi

    print_summary
    cleanup
}

main "$@"
