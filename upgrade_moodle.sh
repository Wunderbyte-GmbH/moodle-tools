#!/bin/bash

announce_command() {
    echo "Executing: $@"
    "$@"
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

# Check git status and abort if there are changes
GIT_STATUS=$(git status --porcelain --untracked-files=no)

if [[ -n "$GIT_STATUS" ]]; then
    echo "Error: There are uncommitted changes in the git repository. Please commit or stash them before running this script."
    git status
    exit 1
fi

# Determine the SSH key dynamically
find_ssh_key() {
    local ssh_dir="$1"
    if [[ -d "$ssh_dir" ]]; then
        local key
        key=$(find "$ssh_dir" -type f -name '*.pub' | sed 's/\.pub$//' | head -n 1)
        echo "$key"
    fi
}

if [[ $EUID -eq 0 ]]; then
    # Running as root, look in /root/.ssh/
    SSH_KEY=$(find_ssh_key "/root/.ssh")
else
    # Running as a sudo user, look in the user's ~/.ssh/
    SSH_KEY=$(find_ssh_key "$HOME/.ssh")
fi

# If no key is found, fallback to default SSH behavior
if [[ -n "$SSH_KEY" ]]; then
    export GIT_SSH_COMMAND="ssh -i $SSH_KEY"
fi

# Fetch the latest changes
announce_command git fetch origin

# Pull the latest code
announce_command git pull

# Detect the Apache user
APACHE_USER=$(ps aux | grep -E '[a]pache|[h]ttpd' | grep -v root | awk '{print $1}' | uniq)

if [[ -z "$APACHE_USER" ]]; then
    echo "Warning: Apache user not found. Using default 'www-data'."
    APACHE_USER="www-data"
fi

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
