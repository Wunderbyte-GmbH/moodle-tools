#!/bin/bash

announce_command() {
    echo "Executing: $@"
    "$@"
}

# Prompt for the directory
read -p "Enter the directory path where the commands should be executed: " directory

# Change to the specified directory
announce_command cd "$directory"

# Check git status
announce_command sudo git status

# Get the new source and see if git can fetch the code
announce_command sudo git fetch origin

# All good, then checkout the source
announce_command sudo git pull

# Change permission so apache can execute all PHP files
announce_command sudo chown root:www-data . -R

# Change permission for directories
announce_command sudo find . -type d -exec chmod 755 {} \;

# Change permissions for files
announce_command sudo find . -type f -exec chmod 644 {} \;

# Perform the upgrade for moodleroot
announce_command sudo -u www-data php admin/cli/upgrade.php --non-interactive

# Check if everything is OK for moodleroot
announce_command sudo -u www-data php admin/cli/checks.php
