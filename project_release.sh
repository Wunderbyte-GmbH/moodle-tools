#!/bin/bash

# Function to display usage information
usage() {
    echo "Usage: $0 -p|--project PROJECT_NAME -m|--mdlversion MOODLE_VERSION"
    echo "  -p, --project     Project name (e.g. WKO)"
    echo "  -m, --mdlversion  Moodle version (e.g., 403)"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project)
            project="$2"
            shift 2
            ;;
        -m|--mdlversion)
            moodle_version="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

# Validate required parameters
if [ -z "$project" ] || [ -z "$moodle_version" ]; then
    echo "Error: Both project name and Moodle version are required."
    usage
fi

# convert project name to all capital letters
if [[ ! "$project" =~ ^[A-Z]+$ ]]; then
    # Convert project name to capital letters
    project=${project^^}
fi

# Define lowercase project name
project_lowercase=${project,,}

# Define repository directory
repo_dir="/var/www/html/${project_lowercase}-complete"

# Check if repository directory exists
if [ ! -d "$repo_dir" ]; then
    echo "Error: Directory '$repo_dir' does not exist. Exiting..."
    exit 1
fi

# Define variables for branch names
MOODLE_STABLE="MOODLE_${moodle_version}_STABLE"
PROJECT_STABLE="${project}_${moodle_version}_STABLE"
PROJECT_ALLINONE="${project}_${moodle_version}_ALLINONE"

# Function to check if a branch exists
check_branch_exists() {
    local branch=$1
    local repo_dir=$2

    if [ ! -d "$repo_dir/.git" ]; then
        echo "Error: Git repository not found in $repo_dir."
        return 1
    fi

    cd "$repo_dir" || return 1
    git fetch wunderbyte &>/dev/null

    # Check if branch exists in wunderbyte
    if git ls-remote --heads wunderbyte "$branch" &>/dev/null; then
        return 0
    fi

    if check_remote_exists "${project_lowercase}"; then
        # Only fetch from project_lowercase if it exists as a remote
        git fetch "${project_lowercase}" &>/dev/null
        # Only check project_lowercase if it exists as a remote
        if git ls-remote --heads "${project_lowercase}" "$branch" &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Function to validate all required branches and create PROJECT_ALLINONE if it doesn't exist
validate_branches() {
    echo "Validating required branches in $repo_dir..."

    # Check MOODLE_STABLE branch
    echo "Checking branch: $MOODLE_STABLE"
    if ! check_branch_exists "$MOODLE_STABLE" "$repo_dir"; then
        echo "Error: Branch '$MOODLE_STABLE' does not exist in either wunderbyte or upstream."
        echo "This branch is required. Exiting..."
        exit 1
    fi

    # Check PROJECT_STABLE branch
    echo "Checking branch: $PROJECT_STABLE"
    if ! check_branch_exists "$PROJECT_STABLE" "$repo_dir"; then
        echo "Error: Branch '$PROJECT_STABLE' does not exist in either wunderbyte or upstream."
        echo "This branch is required. Exiting..."
        exit 1
    fi

    # Check PROJECT_ALLINONE branch
    cd "$repo_dir"

    # Check if branch exists locally
    local_branch_exists=false
    if git branch --list | grep -q "^[* ]*${PROJECT_ALLINONE}$"; then
        local_branch_exists=true
    fi

    # Check if branch exists on remotes
    remote_branch_exists=false
    if git ls-remote --heads wunderbyte "$PROJECT_ALLINONE" 2>/dev/null | grep -q "$PROJECT_ALLINONE"; then
        remote_branch_exists=true
    fi

    if [ "$local_branch_exists" = false ] && [ "$remote_branch_exists" = false ]; then
        echo "Branch '$PROJECT_ALLINONE' does not exist locally or remotely. Creating it now..."
        create_allinone_branch
    else
        echo "Branch '$PROJECT_ALLINONE' exists. Proceeding with deployment..."
    fi
}

# Function to create the PROJECT_ALLINONE branch
create_allinone_branch() {
    echo "Current directory before cd: $(pwd)"
    echo "Attempting to cd to: $repo_dir"

    if [ ! -d "$repo_dir" ]; then
        echo "Error: Repository directory $repo_dir does not exist!"
        exit 1
    fi

    cd "$repo_dir" || {
        echo "Error: Failed to change to directory $repo_dir"
        exit 1
    }

    echo "Successfully changed to directory: $(pwd)"

    echo "Creating $PROJECT_ALLINONE branch..."

    # Switch to the PROJECT_STABLE branch first
    echo "Switching to $PROJECT_STABLE branch..."
    git switch -f "$PROJECT_STABLE"

    # Create a new branch for PROJECT_ALLINONE
    echo "Creating $PROJECT_ALLINONE branch..."
    git checkout -b "$PROJECT_ALLINONE"

    # Reset to initial Moodle commit
    echo "Resetting to initial Moodle commit..."
    # This is the hash of the initial commit - using the example from your input
    git reset --hard f9903ed0a41ce4df0cb3628a06d6c0a9455ac75c

    # Remove all files
    echo "Removing all files..."
    rm -rf *
    rm -f .htaccess

    # Add changes to git
    echo "Adding changes to git..."
    git add .

    # Commit changes (amend with empty commit allowed)
    echo "Committing changes..."
    git commit --amend --allow-empty -m "Initial empty commit for $PROJECT_ALLINONE"

    # Push to remote repositories
    echo "Pushing to remote repositories..."
    git_push "wunderbyte" "$PROJECT_ALLINONE"
    # Only push to project_lowercase if it exists
    if check_remote_exists "${project_lowercase}"; then
        git_push "${project_lowercase}" "$PROJECT_ALLINONE"
    else
        echo "Remote ${project_lowercase} does not exist, skipping push to it."
    fi

    # Push the stable branch as well
    git_push "wunderbyte" "$PROJECT_STABLE"
    # Only push to project_lowercase if it exists
    if check_remote_exists "${project_lowercase}"; then
        git_push "${project_lowercase}" "$PROJECT_STABLE"
    else
        echo "Remote ${project_lowercase} does not exist, skipping push to it."
    fi

    # Switch back to the PROJECT_STABLE branch
    echo "Switching back to $PROJECT_STABLE branch..."
    git switch -f "$PROJECT_STABLE"

    echo "Branch $PROJECT_ALLINONE created successfully."
}

# Function to calculate the release tag
calculate_release_tag() {
    # Extract Moodle version parts - for example 403 becomes 4.3
    local moodle_major="${moodle_version:0:1}"
    local moodle_minor="${moodle_version:2:2}"

    # Check if there are existing tags with this format
    local version_prefix="$project-v$moodle_major.$moodle_minor"
    local existing_tags=$(git tag --list "$version_prefix.*" | sort -V)

    if [ -z "$existing_tags" ]; then
        # No existing tags with this format, start with 0
        calculated_tag="$version_prefix.0"
    else
        # Get the latest tag and extract the patch version
        local latest_tag=$(echo "$existing_tags" | tail -n 1)
        local patch_version=$(echo "$latest_tag" | awk -F. '{print $NF}')

        # Increment the patch version
        local new_patch=$((patch_version + 1))
        calculated_tag="$version_prefix.$new_patch"
    fi

    echo "$calculated_tag"
}

# Extract Moodle version parts for use globally
moodle_major="${moodle_version:0:1}"
moodle_minor="${moodle_version:1:1}"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: $1 command not found. Please install it before running the script."
        exit 1
    }
}

# Function to check VPN connection status
check_vpn_status() {
    echo "Check the VPN connection status..."
    vpn_status=$(f5fpc --info | grep "Connection Status:")
    if [[ "$vpn_status" =~ "Session timed out" ]]; then
        echo "VPN connection is not active. Exiting..."
        exit 1
    elif [[ "$vpn_status" =~ "session established" ]]; then
        echo "VPN connection is active and working."
    else
        echo "Unable to determine VPN connection status. Exiting..."
        exit 1
    fi
}

# Function to prompt for directory and change to it
prompt_and_change_directory() {
    read -p "Enter the directory path to execute the commands (default: $execute_directory): " user_input

    # Use the default value if the user input is empty
    execute_directory="${user_input:-$repo_dir/}"

    if [ ! -d "$execute_directory" ]; then
        echo "Error: Directory '$execute_directory' does not exist. Exiting..."
        exit 1
    fi

    cd "$execute_directory"
}

# Function to perform git operations
git_cmd() {
    local operation="$1"
    echo "Executing: git $operation"
    git $operation
    if [ $? -ne 0 ]; then
        echo "Error: Git operation failed. Exiting..."
        exit 1
    fi
}

# Function to check if a remote exists
check_remote_exists() {
    local remote_name="$1"
    git remote | grep -q "^$remote_name$"
    return $?
}

# Function to perform git push
git_push() {
    local remote="$1"
    local branch="$2"
    shift 2  # Shift to remove the first two arguments (remote and branch)

    # Check if the specified remote exists
    if ! check_remote_exists "$remote"; then
        echo "Remote '$remote' does not exist. Skipping git push command."
        return 0  # Return success (0) to continue script execution
    fi

    local tags_option=""
    local force_option=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --tags)
                tags_option="--tags"
                ;;
            -f)
                force_option="-f"
                ;;
            *)
                # Handle additional options as needed
                ;;
        esac
        shift
    done

    echo "Executing: git push $remote $branch $tags_option $force_option"
    git push $remote $branch $tags_option $force_option

    if [ $? -ne 0 ]; then
        echo "Error: Git push failed. Exiting..."
        exit 1
    fi
}

# Function to perform git tag
git_tag() {
    local tag="$1"
    local message="$2"
    echo "Executing: git tag -a $tag -m \"$message\""
    git tag -a $tag -m "$message"
    if [ $? -ne 0 ]; then
        echo "Error: Git tag creation failed. Exiting..."
        exit 1
    fi
}

# Stop at errors
set -e

# Set global variable for default directory
execute_directory="/var/www/html/${project_lowercase}-complete/"

# Check if the script is not running with root privileges
if [ "$(id -u)" -eq 0 ]; then
    echo "Please run the script without root privileges."
    exit 1
fi

# Check if the required commands exist
required_commands=("f5fpc" "git" "zip" "unzip")
for cmd in "${required_commands[@]}"; do
    command_exists "$cmd"
done

# Check VPN status only for MUSI project
if [ "$project_lowercase" = "musi" ]; then
    check_vpn_status
fi

# If VPN connection is active, proceed with your main script here
echo "Running main script..."

# Validate all required branches exist and create PROJECT_ALLINONE if it doesn't exist
validate_branches

# Prompt for the directory to execute the commands
prompt_and_change_directory

# Switch to the desired branch
git_cmd "fetch wunderbyte"
git_cmd "fetch --tags wunderbyte"
git_cmd "switch -f $PROJECT_STABLE"
git_cmd "reset --hard wunderbyte/$PROJECT_STABLE"
git_cmd "submodule sync"

# Remove the directory
#rm auth/saml2/.extlib/ -rf
#rm local/wb_faq/lang/ -rf
rm -rf auth/saml2/
rm -rf local/wb_faq/lang/
rm -rf payment/gateway/aau/
rm -rf payment/gateway/saferpay/
rm -rf question/type/multichoiceset
rm -rf local/handout

# Also clean up any existing .git files in these locations
find auth/saml2 payment/gateway/aau payment/gateway/saferpay -name ".git" -type f -delete 2>/dev/null || true

# Update submodules
git_cmd "submodule update --remote --init --recursive -f"

# Check git status
git_cmd "status"

# Prompt to continue or stop executing the script after "git status"
read -p "Continue executing the script? (y/n): " continue_execution
if [[ $continue_execution != "y" ]]; then
    echo "Script execution stopped."
    exit 0
fi

# Rebase with upstream Moodle
 git_cmd "fetch upstream"
 git_cmd "rebase upstream/$MOODLE_STABLE"

# Amend the commit
git_cmd "commit --amend --no-edit"

# Push to the desired branch with force
# Only push to project_lowercase if it exists
if check_remote_exists "${project_lowercase}"; then
    git_push "${project_lowercase}" "$PROJECT_STABLE" "-f"
else
    echo "Remote ${project_lowercase} does not exist, skipping push to it."
fi
git_push "wunderbyte" "$PROJECT_STABLE" "-f"

# Prompt for the commit message
read -p "Enter the commit message: " commit_message

# Find the latest tag starting with project name and version format
latest_tags=$(git tag --list "$project-v$moodle_major.$moodle_minor.*" --sort=-v:refname | head -n 3)

# Prompt for the tag
echo "Three latest tags for Moodle $moodle_major.$moodle_minor format:"
echo "$latest_tags"

# Calculate the next release tag
calculated_tag=$(calculate_release_tag)

# Prompt the user for a release tag until a valid one is provided
read -p "Enter the new tag, leave empty for default. (default: $calculated_tag): " releasetag

if [ -z "$releasetag" ]; then
    releasetag=$(calculate_release_tag)
fi

# Archive the repository
# Get the parent directory of the script's location
parent_directory="$(dirname "$execute_directory")"
# Check if the parent directory has write permissions
if [ -w "$parent_directory" ]; then
    echo "Write permission exists on the parent directory."
else
    echo "Write permission does not exist on the parent directory. Exiting."
    exit 1
fi

# Continue with the rest of your script here
echo "Continuing with the script..."

echo "Executing: git archive -o ../release.zip HEAD"
git archive -o ../release.zip HEAD

# Zip submodule directories
echo "Executing: git submodule --quiet foreach 'cd \$toplevel; zip -ru ../release.zip \$sm_path'"
git submodule --quiet foreach 'cd $toplevel; zip -ru ../release.zip $sm_path'

# Switch to the desired branch
git_cmd "switch -f -C $PROJECT_ALLINONE --track wunderbyte/$PROJECT_ALLINONE"
git_cmd "reset --hard wunderbyte/$PROJECT_ALLINONE"

# Move the .git directory
echo "Executing: mv .git ../"
mv .git ../

# Clean up the directory
echo "Executing: rm * -rf"
rm * -rf

# Move the .git directory back
echo "Executing: mv ../.git ."
mv ../.git .

# Extract the archive
echo "Executing: unzip -o ../release.zip -d ."
unzip -o ../release.zip -d .

# Clean up the archive
echo "Executing: rm ../release.zip"
rm ../release.zip

# Clean up submodule references
echo "Executing: rm .gitmodules .git/modules/* -rf"
rm .gitmodules .git/modules/* -rf

# Remove any remaining .git files
echo "Executing: find . -name \".git\" -type f -delete"
find . -name ".git" -type f -delete

# Add all changes
git_cmd "add ."

# Commit the changes only if there are changes
if [[ -n $(git status -s) ]]; then
    echo "Executing: git commit -m \"$commit_message\""
    git commit -m "$commit_message"
    if [ $? -ne 0 ]; then
        echo "Error: Git commit failed. Exiting..."
        exit 1
    fi
else
    echo "No changes to commit. Skipping commit step."
fi

# Create a tag
git_tag $releasetag "Release information"

# Push to the desired branch with tags
git_push "wunderbyte" "$PROJECT_ALLINONE" "--tags"
# Only push to project_lowercase if it exists
if check_remote_exists "${project_lowercase}"; then
    git_push "${project_lowercase}" "$PROJECT_ALLINONE" "--tags"
else
    echo "Remote ${project_lowercase} does not exist, skipping push to it."
fi
