#!/bin/bash

# Global configuration variables
# Pattern for finding branches
BRANCH_PATTERN="WKO_*_ALLINONE"

announce_command() {
    echo "Executing: $@"
    "$@"
}

# Function to read all configuration values from config.php at once
read_config() {
    local config_file="$1"

    # Check if config.php exists
    if [[ ! -f "$config_file" ]]; then
        echo "Error: config.php not found at $config_file." >&2
        return 1
    fi

    # Extract all configuration using PHP
    local config_values=$(php -r '
        // Define CLI_SCRIPT to allow command line execution
        define("CLI_SCRIPT", true);

        // Suppress errors to avoid notices from config.php
        error_reporting(E_ERROR);

        // Initialize $CFG object
        $CFG = new stdClass();

        // Include the config file
        include("'"$config_file"'");

        // Output all variables as shell exports with proper escaping
        echo "export MOODLE_DBTYPE=" . escapeshellarg(isset($CFG->dbtype) ? $CFG->dbtype : "") . ";\n";
        echo "export MOODLE_DBHOST=" . escapeshellarg(isset($CFG->dbhost) ? $CFG->dbhost : "") . ";\n";
        echo "export MOODLE_DBNAME=" . escapeshellarg(isset($CFG->dbname) ? $CFG->dbname : "") . ";\n";
        echo "export MOODLE_DBUSER=" . escapeshellarg(isset($CFG->dbuser) ? $CFG->dbuser : "") . ";\n";
        echo "export MOODLE_DBPASS=" . escapeshellarg(isset($CFG->dbpass) ? $CFG->dbpass : "") . ";\n";
        echo "export MOODLE_DATAROOT=" . escapeshellarg(isset($CFG->dataroot) ? $CFG->dataroot : "") . ";\n";
        echo "export MOODLE_WWWROOT=" . escapeshellarg(isset($CFG->wwwroot) ? $CFG->wwwroot : "") . ";\n";

        // Debug output to see what we got
        echo "# Config loaded successfully. DB: $CFG->dbtype, Host: $CFG->dbhost, Name: $CFG->dbname\n";
    ' 2>/dev/null)

    # Check if we got any output
    if [[ -z "$config_values" ]]; then
        echo "Error: Failed to extract configuration from config.php." >&2

        # Try a more direct approach to read the file
        echo "Attempting alternative config extraction method..."

        # Use grep to extract values directly from the file
        local db_type=$(grep -E '^\$CFG->dbtype\s*=' "$config_file" | cut -d"'" -f2 | cut -d'"' -f2)
        local db_host=$(grep -E '^\$CFG->dbhost\s*=' "$config_file" | cut -d"'" -f2 | cut -d'"' -f2)
        local db_name=$(grep -E '^\$CFG->dbname\s*=' "$config_file" | cut -d"'" -f2 | cut -d'"' -f2)
        local db_user=$(grep -E '^\$CFG->dbuser\s*=' "$config_file" | cut -d"'" -f2 | cut -d'"' -f2)
        local db_pass=$(grep -E '^\$CFG->dbpass\s*=' "$config_file" | cut -d"'" -f2 | cut -d'"' -f2)
        local data_root=$(grep -E '^\$CFG->dataroot\s*=' "$config_file" | cut -d"'" -f2 | cut -d'"' -f2)
        local www_root=$(grep -E '^\$CFG->wwwroot\s*=' "$config_file" | cut -d"'" -f2 | cut -d'"' -f2)

        # If we still don't have values, fail
        if [[ -z "$db_type" || -z "$db_name" ]]; then
            echo "Error: Could not extract configuration using alternative method." >&2
            return 1
        fi

        # Create export statements
        config_values="export MOODLE_DBTYPE=\"$db_type\";\n"
        config_values+="export MOODLE_DBHOST=\"$db_host\";\n"
        config_values+="export MOODLE_DBNAME=\"$db_name\";\n"
        config_values+="export MOODLE_DBUSER=\"$db_user\";\n"
        config_values+="export MOODLE_DBPASS=\"$db_pass\";\n"
        config_values+="export MOODLE_DATAROOT=\"$data_root\";\n"
        config_values+="export MOODLE_WWWROOT=\"$www_root\";\n"

        echo "Alternative method extracted the following configuration:"
        echo -e "$config_values" | grep -v "DBPASS"
    else
        echo "Primary method successful:"
        echo "$config_values" | grep -v "DBPASS" | grep -v "^#"
    fi

    # Evaluate the export statements to set all variables
    eval "$(echo -e "$config_values" | grep -v "^#")"

    # Verify that critical variables were set
    if [[ -z "$MOODLE_DBTYPE" ]]; then
        echo "Error: Failed to extract database type from config.php." >&2
        return 1
    fi

    echo "Successfully loaded Moodle configuration."
    echo "Database type: $MOODLE_DBTYPE, Host: $MOODLE_DBHOST, Database: $MOODLE_DBNAME, User:$MOODLE_DBUSER"

    # Set up backup directory path
    if [[ -n "$MOODLE_DATAROOT" ]]; then
        export MOODLE_BACKUP_DIR="${MOODLE_DATAROOT}/backups"
    else
        echo "Warning: MOODLE_DATAROOT not set, using default backup location." >&2
        export MOODLE_BACKUP_DIR="/tmp/moodle-backups"
    fi

    return 0
}

# Setup backup directory and clean up old backups if needed
setup_backup_directory() {
    # Create backup directory if it doesn't exist
    if [[ -d "$MOODLE_BACKUP_DIR" ]]; then
        cleanup_old_backups "$MOODLE_BACKUP_DIR"
    else
        mkdir -p "$MOODLE_BACKUP_DIR"
        echo "Created backup directory at $MOODLE_BACKUP_DIR"
    fi

    return 0
}

# Function to check git repository status and handle issues
check_git_status() {
    local repo_dir="$1"

    # Make sure we're in the right directory
    cd "$repo_dir" || return 1

    # Check git status
    local git_status=$(git status --porcelain)

    if [[ -n "$git_status" ]]; then
        echo "Error: Git repository is not clean. There are uncommitted changes or untracked files."
        git status

        echo ""
        echo "Options:"
        echo "1. Perform Hard Reset (WARNING: This will discard all local changes)"
        echo "2. Abort script"

        read -p "Please choose an option (1 or 2): " choice

        case $choice in
            1)
                echo "Performing hard reset..."
                announce_command git reset --hard HEAD
                announce_command git clean -fd
                echo "Reset complete."
                return 0
                ;;
            2)
                echo "Aborting script as requested."
                return 2  # Special return code for user abort
                ;;
            *)
                echo "Invalid option. Aborting script."
                return 1
                ;;
        esac
    fi

    echo "Git repository is clean."
    return 0
}

# Function to enable/disable maintenance mode
toggle_maintenance_mode() {
    local enable="$1"  # true or false
    local working_dir="$2"

    if [[ "$enable" == "true" ]]; then
        echo "Enabling maintenance mode..."
        announce_command php "$working_dir/admin/cli/maintenance.php" --enable
    else
        echo "Disabling maintenance mode..."
        announce_command php "$working_dir/admin/cli/maintenance.php" --disable
    fi

    return 0
}

check_site_availability() {
    local timeout=10

    echo "Checking site availability..."
    echo "Testing connection to $MOODLE_WWWROOT"

    # Check if curl is available
    if command -v curl &> /dev/null; then
        local status_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout $timeout "$MOODLE_WWWROOT")
        # 200 = OK, 503 = Service Unavailable (maintenance mode), 303 = See Other (redirect)
        if [[ "$status_code" -eq 200 || "$status_code" -eq 503 || "$status_code" -eq 303 || "$status_code" -eq 302 || "$status_code" -eq 301 ]]; then
            echo "Site is available (HTTP status: $status_code)"
            return 0
        else
            echo "Site is not available (HTTP status: $status_code)"
            return 1
        fi
    # Check if wget is available
    elif command -v wget &> /dev/null; then
        if wget -q --spider --timeout=$timeout "$MOODLE_WWWROOT"; then
            echo "Site is available"
            return 0
        else
            echo "Site is not available"
            return 1
        fi
    else
        echo "Warning: Neither curl nor wget is available. Cannot check site availability."
        read -p "Continue anyway? (y/n): " continue_anyway
        if [[ "$continue_anyway" == "y" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

cleanup_old_backups() {
    local backup_dir="$1"
    local keep_count=2  # Keep only 2 most recent backups

    # Check if backup directory exists
    if [[ ! -d "$backup_dir" ]]; then
        echo "No backup directory found at $backup_dir. Skipping cleanup."
        return 0
    fi

    # Get all backups sorted by modification time (newest first)
    local all_backups=($(find "$backup_dir" -name "db_*" -type f -printf "%T@ %p\n" | sort -nr | awk '{print $2}'))
    local total_count=${#all_backups[@]}

    echo "Found $total_count total backup(s) in $backup_dir."

    if [[ $total_count -le $keep_count ]]; then
        echo "Only $total_count backup(s) found. Keeping all (limit is $keep_count)."
        return 0
    fi

    # Calculate how many to delete
    local delete_count=$((total_count - keep_count))

    echo "Keeping the $keep_count most recent backup(s) and deleting $delete_count older one(s)."
    read -p "Proceed with deletion? (y/n): " confirm_delete

    if [[ "$confirm_delete" == "y" ]]; then
        # Extract the list of backups to keep (the newest ones)
        local keep_backups=("${all_backups[@]:0:$keep_count}")

        # Loop through all backups
        for ((i=$keep_count; i<$total_count; i++)); do
            local backup_to_delete="${all_backups[$i]}"
            echo "Deleting: $(basename "$backup_to_delete")"
            rm -f "$backup_to_delete"
        done

        echo "Cleanup complete. Kept the $keep_count most recent backup(s)."
    else
        echo "Cleanup cancelled. Keeping all backups."
    fi

    return 0
}

# Function to create a database backup
create_database_backup() {
    local working_dir="$1"

    echo "Creating database backup..."

    # Create backup directory if it doesn't exist
    if [[ ! -d "$MOODLE_BACKUP_DIR" ]]; then
        mkdir -p "$MOODLE_BACKUP_DIR"
        echo "Created backup directory at $MOODLE_BACKUP_DIR"
    fi

    # Check if backup directory is writable by current user
    if [[ ! -w "$MOODLE_BACKUP_DIR" ]]; then
        echo "Error: Backup directory $MOODLE_BACKUP_DIR is not writable by current user."
        echo "Please make sure the directory has appropriate permissions."
        return 1
    fi

    # Set backup filename with current date and hostname
    local current_date=$(date +"%Y%m%d_%H%M%S")
    local hostname=$(hostname)
    local backup_file="${MOODLE_BACKUP_DIR}/db_${hostname}_${current_date}.sql.gz"

    # Check if gzip is available
    if ! command -v gzip &> /dev/null; then
        echo "Warning: gzip not found. Cannot compress database backup."
        echo "Will try to create uncompressed backup instead."
        backup_file="${MOODLE_BACKUP_DIR}/db_${hostname}_${current_date}.sql"
    fi

    # Check if the required database dump tool exists
    local backup_success=false
    case "$MOODLE_DBTYPE" in
        "mysqli"|"mariadb")
            if command -v mysqldump &> /dev/null; then
                echo "Creating MySQL database backup..."
                if command -v gzip &> /dev/null; then
                    if mysqldump -h "$MOODLE_DBHOST" -u "$MOODLE_DBUSER" -p"$MOODLE_DBPASS" "$MOODLE_DBNAME" --single-transaction | gzip > "$backup_file"; then
                        backup_success=true
                    fi
                else
                    if mysqldump -h "$MOODLE_DBHOST" -u "$MOODLE_DBUSER" -p"$MOODLE_DBPASS" "$MOODLE_DBNAME" --single-transaction > "$backup_file"; then
                        backup_success=true
                    fi
                fi
            else
                echo "Error: mysqldump not found. Cannot create database backup."
                return 1
            fi
            ;;
        "pgsql")
            if command -v pg_dump &> /dev/null; then
                echo "Creating PostgreSQL database backup..."
                export PGPASSWORD="$MOODLE_DBPASS"
                if command -v gzip &> /dev/null; then
                    if pg_dump -h "$MOODLE_DBHOST" -U "$MOODLE_DBUSER" -d "$MOODLE_DBNAME" | gzip > "$backup_file"; then
                        backup_success=true
                    fi
                else
                    if pg_dump -h "$MOODLE_DBHOST" -U "$MOODLE_DBUSER" -d "$MOODLE_DBNAME" > "$backup_file"; then
                        backup_success=true
                    fi
                fi
                unset PGPASSWORD
            else
                echo "Error: pg_dump not found. Cannot create database backup."
                return 1
            fi
            ;;
        *)
            echo "Warning: Database type '$MOODLE_DBTYPE' is not supported for automated backup."
            return 1
            ;;
    esac

    if [[ "$backup_success" == "true" ]]; then
        echo "Database backup created successfully: $backup_file"
        return 0
    else
        echo "Failed to create database backup."
        return 1
    fi
}
# Determine the SSH key dynamically
find_ssh_key() {
    local ssh_dir="$1"
    if [[ -d "$ssh_dir" ]]; then
        local key
        key=$(find "$ssh_dir" -type f -name '*.pub' | sed 's/\.pub$//' | head -n 1)
        echo "$key"
    fi
}

# Function to setup SSH key for git operations
setup_ssh_key() {
    local ssh_key=""

    if [[ $EUID -eq 0 ]]; then
        # Running as root, look in /root/.ssh/
        ssh_key=$(find_ssh_key "/root/.ssh")
    else
        # Running as a sudo user, look in the user's ~/.ssh/
        ssh_key=$(find_ssh_key "$HOME/.ssh")
    fi

    # If a key is found, configure git to use it
    if [[ -n "$ssh_key" ]]; then
        export GIT_SSH_COMMAND="ssh -i $ssh_key"
        echo "Using SSH key: $ssh_key"
        return 0
    else
        echo "No SSH key found, using default SSH behavior"
        return 0
    fi
}

# Function to detect the Apache/web server user
detect_apache_user() {
    # Try to detect Apache user from running processes
    local apache_user=$(ps aux | grep -E '[a]pache|[h]ttpd' | grep -v root | awk '{print $1}' | uniq)

    # If not found, try some common web server users
    if [[ -z "$apache_user" ]]; then
        # Try to find common web server users
        for user in www-data apache nginx httpd nobody _www; do
            if id "$user" &>/dev/null; then
                apache_user="$user"
                echo "Found web server user: $apache_user"
                break
            fi
        done
    fi

    # If still not found, use default
    if [[ -z "$apache_user" ]]; then
        apache_user="www-data"
        echo "Warning: Web server user not found. Using default '$apache_user'."
    else
        echo "Using web server user: $apache_user"
    fi

    # Export the variable to make it available globally
    export APACHE_USER="$apache_user"

    return 0
}

# Function to handle git tag selection and checkout
# Function to handle git tag selection and checkout
handle_git_checkout() {
    local repo_dir="$1"

    # Make sure we're in the right directory
    cd "$repo_dir" || return 1

    # Fetch all tags and branches from origin
    echo "Fetching latest tags and branches from origin..."
    announce_command git fetch --all --tags

    # Get the current branch
    local current_branch=$(git branch --show-current)
    echo "Current branch: $current_branch"

    # Get all local branches that match the pattern
    echo "Finding local branches matching $BRANCH_PATTERN..."
    local branches=()
    while IFS= read -r branch; do
        # Remove leading whitespace and asterisk
        branch=$(echo "$branch" | sed 's/^\*\?[[:space:]]*//')
        if [[ -n "$branch" && "$branch" == $BRANCH_PATTERN ]]; then
            branches+=("$branch")
        fi
    done < <(git branch)

    # If no branches found, exit with clear message
    if [[ ${#branches[@]} -eq 0 ]]; then
        echo "Error: No local branches found matching pattern $BRANCH_PATTERN."
        echo "Available branches:"
        git branch
        echo "Aborting."
        exit 1
    fi

    local branch_count=${#branches[@]}
    echo "Found $branch_count matching branches."

    # Get the last 5 tags starting with "WKO" ordered by creation time (newest first)
    echo "Finding recent WKO tags by creation time..."
    local wko_tags=($(git for-each-ref --sort=-creatordate --format '%(refname:short)' --count=5 refs/tags/WKO-v*))
    local tag_count=${#wko_tags[@]}

    # Display options to the user
    echo -e "\nPlease select which version to checkout:"

    # Display branch options with numbers
    echo -e "\n--- BRANCH OPTIONS ---"
    for ((i=0; i<branch_count; i++)); do
        if [[ "${branches[$i]}" == "$current_branch" ]]; then
            echo "$i) Branch: ${branches[$i]} [CURRENT]"
        else
            echo "$i) Branch: ${branches[$i]}"
        fi
    done

    # Display available tags with numbers
    echo -e "\n--- TAG OPTIONS ---"
    local tag_start=$branch_count
    for ((i=0; i<tag_count; i++)); do
        # Show tag with its creation date
        tag_date=$(git log -1 --format=%cd --date=short refs/tags/${wko_tags[$i]} 2>/dev/null || echo "unknown date")
        echo "$((i+tag_start))) Tag: ${wko_tags[$i]} (created: $tag_date)"
    done

    # Get user choice with validation
    local max_option=$((branch_count + tag_count - 1))
    local valid_choice=false
    local choice

    while [[ "$valid_choice" != "true" ]]; do
        read -p "Enter your choice (0-$max_option): " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -le "$max_option" ]]; then
            valid_choice=true
        else
            echo "Invalid choice. Please enter a number between 0 and $max_option."
        fi
    done

    # Process the user's choice
    if [[ "$choice" -lt "$branch_count" ]]; then
        # User selected a branch
        local selected_branch=${branches[$choice]}
        echo "Checking out latest code from branch $selected_branch..."

        # Check if we're already on the selected branch
        if [[ "$selected_branch" == "$current_branch" ]]; then
            echo "Already on branch $selected_branch"
        else
            announce_command git checkout "$selected_branch"
        fi

        announce_command git fetch origin
        announce_command git pull
    else
        # User selected a tag
        local tag_index=$((choice - branch_count))
        local selected_tag=${wko_tags[$tag_index]}
        echo "Checking out tag $selected_tag..."
        announce_command git fetch origin
        announce_command git checkout "$selected_tag"
    fi

    return 0
}

# Get the script's directory
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Prompt for the directory
read -p "Enter the directory path where the git commands should be executed: " directory

# Resolve the directory path relative to the script's directory
if [[ ! -d "$directory" ]]; then
    directory="$SCRIPT_DIR/$directory"
fi

# Check if the directory is a git repository
if [[ ! -d "$directory/.git" ]]; then
    echo "Error: $directory is not a git repository."
    exit 1
fi

# Change to the specified directory
announce_command cd "$directory"

# Read all Moodle configuration at once
if ! read_config "$directory/config.php"; then
    echo "Failed to read Moodle configuration. Aborting."
    exit 1
fi

# Setup SSH key for git operations
setup_ssh_key

# Detect and set Apache user
detect_apache_user

# Setup backup directory and clean up old backups if needed
setup_backup_directory

# Check git repository status
if ! check_git_status "$directory"; then
    # If the function returns non-zero and it's not 2 (user chose to abort)
    if [[ $? -ne 2 ]]; then
        echo "Error checking git repository status."
    fi
    exit 1
fi

# Create a database backup
if ! create_database_backup "$directory"; then
    read -p "Database backup failed. Continue without backup? (y/n): " continue_without_backup
    if [[ "$continue_without_backup" != "y" ]]; then
        echo "Aborting script."
        exit 1
    fi
fi

# Check site availability before proceeding
if ! check_site_availability; then
    read -p "Site availability check failed. Continue anyway? (y/n): " continue_anyway
    if [[ "$continue_anyway" != "y" ]]; then
        echo "Aborting script."
        exit 1
    fi
fi

# Enable maintenance mode before update
toggle_maintenance_mode "true" "$directory"

# Handle git checkout with tag selection
handle_git_checkout "$directory"

# Change permission so Apache can execute all PHP files
announce_command sudo chown root:"$APACHE_USER" . -R

# Change permission for directories
announce_command sudo find . -type d -exec chmod 755 {} \;

# Change permissions for files
announce_command sudo find . -type f -exec chmod 644 {} \;

# Perform the upgrade for Moodle
announce_command sudo -u "$APACHE_USER" php admin/cli/upgrade.php --non-interactive

# Check if everything is OK for Moodle
announce_command sudo -u "$APACHE_USER" php admin/cli/checks.php

CHECKS_OUTPUT=$(sudo -u "$APACHE_USER" php admin/cli/checks.php)

if echo "$CHECKS_OUTPUT" | grep -q "Error"; then
    echo "Upgrade check failed: 'checks.php' output contains errors."
    echo "Details:"
    echo "$CHECKS_OUTPUT"
    exit 1
fi

# Disable maintenance mode
toggle_maintenance_mode "false" "$directory"

# Final site availability check
if check_site_availability; then
    echo "Upgrade completed successfully and site is available."
else
    echo "Warning: Upgrade completed but site availability check failed."
    echo "You may need to manually check the site."
fi

echo "Moodle upgrade completed at $(date)"
