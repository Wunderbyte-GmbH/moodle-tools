#!/bin/bash

announce_command() {
    echo "Executing: $@"
    "$@"
}

# Prompt for the directory
read -p "Enter the directory path where the git commands should be executed: " directory

# Check if the directory is a git repository
if [[ ! -d "$directory/.git" ]]; then
    echo "Error: $directory is not a git repository."
    exit 1
fi

# Change to the specified directory
announce_command cd "$directory"

# Check git status and abort if there are changes
GIT_STATUS=$(git status --porcelain)

if [[ -n "$GIT_STATUS" ]]; then
    echo "Error: There are uncommitted changes in the git repository. Please commit or stash them before running this script."
    git status
    exit 1
fi

# Get the new source and see if git can fetch the code
announce_command sudo -i git fetch origin

# All good, then checkout the source
announce_command sudo -i git pull

# Detect the Apache user
APACHE_USER=$(ps aux | grep -E '[a]pache|[h]ttpd' | grep -v root | awk '{print $1}' | uniq)

if [[ -z "$APACHE_USER" ]]; then
    echo "Warning: Apache user not found. Using default 'www-data'."
    APACHE_USER="www-data"
fi

# Change permission so apache can execute all PHP files
announce_command sudo chown root:"$APACHE_USER" . -R

# Change permission for directories
announce_command sudo find . -type d -exec chmod 755 {} \;

# Change permissions for files
announce_command sudo find . -type f -exec chmod 644 {} \;

# Perform the upgrade for moodleroot
announce_command sudo -u "$APACHE_USER" php admin/cli/upgrade.php --non-interactive

# Check if everything is OK for moodleroot
announce_command sudo -u "$APACHE_USER" php admin/cli/checks.php
