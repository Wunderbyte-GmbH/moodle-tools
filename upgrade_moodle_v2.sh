#!/bin/bash

# Stricter error handling:
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: The return value of a pipeline is the status of the last command
#              to exit with a non-zero status, or zero if no command exited
#              with a non-zero status.
set -euo pipefail

# --- Configuration ---
# Optional: Set the Moodle directory path here if you want to skip the prompt.
# MOODLE_DIR=""
# Optional: Set the Apache/web server user here to override detection.
# APACHE_USER_OVERRIDE=""
MOODLE_CLI_PATH="admin/cli" # Relative path to Moodle CLI tools
CONFIG_FILE="config.php"

# --- Functions ---

# Function to print commands before executing them
announce_command() {
  printf "==> Executing: %s\n" "$*" >&2 # Print to stderr
  "$@"
}

# Function to print error messages
error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}

# Function to print warning messages
warning_msg() {
  printf "WARNING: %s\n" "$1" >&2
}

# Function to check if required commands exist
check_prerequisites() {
  local missing=0
  for cmd in git php sudo find chown chmod ps grep awk uniq head dirname; do
    if ! command -v "$cmd" &> /dev/null; then
      warning_msg "Required command '$cmd' not found in PATH."
      missing=1
    fi
  done
  # [[ $missing -eq 1 ]] && error_exit "Please install missing commands and ensure they are in your PATH."
  # Decide if you want to make prerequisites mandatory or just warn. Warning is often sufficient.
}

# Function to find the Moodle directory
find_moodle_dir() {
    local target_dir=""
    # Use predefined MOODLE_DIR if set
    if [[ -n "${MOODLE_DIR:-}" ]]; then
        target_dir="$MOODLE_DIR"
    else
        # Prompt for the directory
        read -p "Enter the path to your Moodle installation directory: " target_dir
        if [[ -z "$target_dir" ]]; then
            error_exit "Moodle directory path cannot be empty."
        fi
    fi

    # Resolve the directory path if it's relative
    if [[ ! "$target_dir" =~ ^/ ]]; then
        local script_dir
        script_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
        target_dir="$script_dir/$target_dir"
    fi

    # Canonicalize the path (resolve .., ., //)
    if ! target_dir=$(realpath -m "$target_dir"); then
         error_exit "Failed to resolve path: $target_dir"
    fi


    # Basic validation checks
    if [[ ! -d "$target_dir" ]]; then
        error_exit "Directory does not exist: $target_dir"
    fi
    if [[ ! -f "$target_dir/$CONFIG_FILE" ]]; then
        error_exit "Moodle '$CONFIG_FILE' not found in: $target_dir"
    fi
    if [[ ! -f "$target_dir/$MOODLE_CLI_PATH/upgrade.php" ]]; then
        error_exit "Moodle '$MOODLE_CLI_PATH/upgrade.php' not found in: $target_dir"
    fi
     if [[ ! -f "$target_dir/$MOODLE_CLI_PATH/maintenance.php" ]]; then
        error_exit "Moodle '$MOODLE_CLI_PATH/maintenance.php' not found in: $target_dir"
    fi

    echo "$target_dir" # Return the validated directory path
}

# Function to check git status
check_git_status() {
    local moodle_path="$1"
    # Check if it's a git repository
    if [[ ! -d "$moodle_path/.git" ]]; then
        error_exit "Not a git repository: $moodle_path"
    fi

    printf "--> Checking git status in %s...\n" "$moodle_path"
    # Change to the directory for git commands
    pushd "$moodle_path" > /dev/null

    if ! git diff --quiet || ! git diff --cached --quiet; then
        git status
        popd > /dev/null
        error_exit "There are uncommitted changes or staged files. Please commit, stash, or reset them before proceeding."
    fi

    # Check for untracked files (optional, can be noisy)
    # local untracked=$(git status --porcelain --untracked-files=normal | grep '^??')
    # if [[ -n "$untracked" ]]; then
    #    printf "Warning: Untracked files found:\n%s\n" "$untracked" >&2
    #    # Decide if you want to exit or just warn
    # fi

    popd > /dev/null
    printf "--> Git status is clean.\n"
}

# Function to run git pull
run_git_pull() {
    local moodle_path="$1"
    printf "--> Pulling latest changes from origin...\n"
    pushd "$moodle_path" > /dev/null

    # Note: SSH key handling is removed. Ensure your environment is configured
    # correctly for Git access (e.g., SSH agent, ~/.ssh/config, HTTPS credentials).
    if ! announce_command git fetch origin; then
         popd > /dev/null
         error_exit "git fetch failed."
    fi
    # Consider specifying the branch if needed: git pull origin main (or master)
    if ! announce_command git pull --ff-only; then # Use --ff-only to avoid unexpected merges
        printf "ERROR: 'git pull --ff-only' failed. This might be because the local branch has diverged.\n" >&2
        printf "Attempting a regular 'git pull' which might create a merge commit...\n" >&2
       if ! announce_command git pull; then
            popd > /dev/null
            error_exit "git pull failed. Please resolve conflicts or issues manually in $moodle_path."
       fi
    fi

    popd > /dev/null
    printf "--> Git pull completed.\n"
}

# Function to detect the Apache/web server user
detect_apache_user() {
    # Use override if provided
    if [[ -n "${APACHE_USER_OVERRIDE:-}" ]]; then
        printf "--> Using specified Apache user: %s\n" "$APACHE_USER_OVERRIDE"
        echo "$APACHE_USER_OVERRIDE"
        return
    fi

    printf "--> Detecting web server user...\n"
    local detected_user
    # Common process names: apache2, httpd, nginx, lighttpd, litespeed, lsws, php-fpm
    # The [a]pache trick avoids grep finding itself.
    detected_user=$(ps aux | grep -E '[a]pache|[h]ttpd|[n]ginx|[p]hp-fpm' | grep -v 'root' | head -n 1 | awk '{print $1}')

    if [[ -z "$detected_user" ]]; then
        warning_msg "Web server user not automatically detected."
        read -p "Please enter the web server username (e.g., www-data, apache, nginx) [www-data]: " detected_user
        detected_user=${detected_user:-www-data} # Default to www-data if empty
    fi

    printf "--> Using web server user: %s\n" "$detected_user"
    echo "$detected_user"
}

# Function to set file/directory permissions
set_permissions() {
    local moodle_path="$1"
    local apache_user="$2"

    printf "--> Setting permissions in %s for user %s...\n" "$moodle_path" "$apache_user"
    pushd "$moodle_path" > /dev/null

    # Ownership: Set to apache_user:apache_user.
    # Moodle running as apache_user often needs to write to files/dirs during upgrades or plugin installs.
    # If your setup requires root ownership with group write for apache_user, adjust accordingly (e.g., chown root:"$apache_user").
    announce_command sudo chown "$apache_user":"$apache_user" . -R

    # Directory Permissions: 755 (rwxr-xr-x)
    # Owner: rwx, Group: rx, Others: rx
    announce_command sudo find . -type d -exec chmod 755 {} \;

    # File Permissions: 644 (rw-r--r--)
    # Owner: rw, Group: r, Others: r
    announce_command sudo find . -type f -exec chmod 644 {} \;

    # Secure config.php: 640 (rw-r-----) or 440 (r--r-----) recommended
    # Owner: rw (or r), Group: r, Others: none
    # Ensure the apache_user is in the group that owns config.php if not the owner.
    # If you used chown root:apache_user above, 640 is appropriate.
    # If you used chown apache_user:apache_user, 600 (rw-------) might be even better.
    if [[ -f "$CONFIG_FILE" ]]; then
         printf "--> Setting secure permissions for %s\n" "$CONFIG_FILE"
         announce_command sudo chmod 640 "$CONFIG_FILE" # Adjust if needed (e.g., 600)
         # Ensure config.php ownership allows apache_user to read it (already set by chown above)
    else
        warning_msg "$CONFIG_FILE not found during permission setting."
    fi


    popd > /dev/null
    printf "--> Permissions set.\n"
}

# Function to enable/disable Moodle maintenance mode
toggle_maintenance_mode() {
    local moodle_path="$1"
    local apache_user="$2"
    local mode="$3" # "enable" or "disable"

    local php_script="$moodle_path/$MOODLE_CLI_PATH/maintenance.php"
    local action_flag="--$mode"

    printf "--> Attempting to %s maintenance mode...\n" "$mode"
    # Run as the apache user
    if announce_command sudo -u "$apache_user" php "$php_script" "$action_flag"; then
        printf "--> Maintenance mode %sd successfully.\n" "$mode"
    else
        # Don't exit on failure here, as the main script might need to continue or clean up.
        warning_msg "Failed to $mode maintenance mode. Check Moodle logs and permissions."
        # If disabling failed, manual intervention is likely required.
        if [[ "$mode" == "disable" ]]; then
             printf "ERROR: FAILED TO DISABLE MAINTENANCE MODE. MOODLE IS LIKELY STILL IN MAINTENANCE.\n" >&2
             printf "Please run manually: sudo -u %s php %s --disable\n" "$apache_user" "$php_script" >&2
        fi
    fi
}

# Function to run Moodle upgrade
run_moodle_upgrade() {
    local moodle_path="$1"
    local apache_user="$2"
    local php_script="$moodle_path/$MOODLE_CLI_PATH/upgrade.php"

    printf "--> Starting Moodle upgrade process (non-interactive)...\n"
    # Run as the apache user
    if ! announce_command sudo -u "$apache_user" php "$php_script" --non-interactive; then
        error_exit "Moodle upgrade script ($php_script) failed. Check output above and Moodle logs."
    fi
    printf "--> Moodle upgrade script completed.\n"
}

# Function to run Moodle checks
run_moodle_checks() {
    local moodle_path="$1"
    local apache_user="$2"
    local php_script="$moodle_path/$MOODLE_CLI_PATH/checks.php"

    printf "--> Running Moodle environment checks...\n"
    # Run as the apache user
    # Note: checks.php might return non-zero exit status for warnings. Decide if that should stop the script.
    # For now, we just run it and report completion. Check its output manually.
    if ! announce_command sudo -u "$apache_user" php "$php_script"; then
         warning_msg "Moodle checks script ($php_script) reported issues or failed. Please review the output above."
    else
        printf "--> Moodle checks script completed.\n"
    fi
}

# --- Main Script Logic ---

# Trap to ensure maintenance mode is disabled on script exit (normal or error)
# The `trap` command executes the specified command when the script receives certain signals.
# EXIT signal is triggered on any script termination (normal exit, exit command, or signal).
# We need to check if MOODLE_DIR and APACHE_USER are set before trying to disable maintenance.
cleanup() {
    local exit_status=$? # Get the exit status of the last command
    if [[ -n "${MOODLE_INSTANCE_DIR:-}" && -n "${APACHE_USER:-}" ]]; then
        printf "\n--> Running cleanup: Disabling maintenance mode (if enabled)...\n"
        # Disable maintenance mode - use || true to prevent trap failing if command fails
        toggle_maintenance_mode "$MOODLE_INSTANCE_DIR" "$APACHE_USER" "disable" || true
    else
         printf "\n--> Skipping cleanup (Moodle dir or Apache user not determined).\n"
    fi
    # Preserve the original exit status
    exit $exit_status
}
trap cleanup EXIT INT TERM # Run cleanup on exit, interrupt (Ctrl+C), or termination signals

# 1. Check Prerequisites
check_prerequisites

# 2. Get Moodle Directory
MOODLE_INSTANCE_DIR=$(find_moodle_dir)
printf "--> Using Moodle directory: %s\n" "$MOODLE_INSTANCE_DIR"

# 3. Detect Apache User
APACHE_USER=$(detect_apache_user)

# 4. Enable Maintenance Mode (before any changes)
toggle_maintenance_mode "$MOODLE_INSTANCE_DIR" "$APACHE_USER" "enable"
# If enabling maintenance mode fails critically, you might want to exit here.
# For now, we proceed but rely on the upgrade script potentially handling it.

# 5. Check Git Status
check_git_status "$MOODLE_INSTANCE_DIR"

# 6. Pull Git Code
run_git_pull "$MOODLE_INSTANCE_DIR"

# 7. Set Permissions
set_permissions "$MOODLE_INSTANCE_DIR" "$APACHE_USER"

# 8. Run Moodle Upgrade
run_moodle_upgrade "$MOODLE_INSTANCE_DIR" "$APACHE_USER"

# 9. Run Moodle Checks
run_moodle_checks "$MOODLE_INSTANCE_DIR" "$APACHE_USER"

# 10. Success! Maintenance mode will be disabled by the trap.
printf "\n Moodle Upgrade Script Completed Successfully! \n"
printf "Maintenance mode should be automatically disabled now.\n"
printf "Please check the output of the Moodle checks above for any warnings.\n"

# The trap will run 'cleanup' automatically upon exiting here.
exit 0
