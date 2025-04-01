#!/bin/bash

# Function to display usage information
usage() {
    echo "Usage: $0 -p|--project PROJECT_NAME -m|--mdlversion MOODLE_VERSION"
    echo "  -p, --project     Project name (must be in capital letters)"
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

# Define repository directory
repo_dir="/var/www/html/${project,,}-complete"

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
    git fetch upstream &>/dev/null

    if ! git ls-remote --heads wunderbyte "$branch" &>/dev/null && \
       ! git ls-remote --heads upstream "$branch" &>/dev/null; then
        echo "Error: Branch '$branch' does not exist in either wunderbyte or upstream."
        return 1
    fi
    return 0
}

# Function to validate all required branches
validate_branches() {
    local branches=("$MOODLE_STABLE" "$PROJECT_STABLE" "$PROJECT_ALLINONE")
    local failed=0

    echo "Validating required branches in $repo_dir..."
    for branch in "${branches[@]}"; do
        echo "Checking branch: $branch"
        if ! check_branch_exists "$branch" "$repo_dir"; then
            failed=1
        fi
    done

    if [ $failed -eq 1 ]; then
        echo "Error: One or more required branches are missing. Please ensure all required branches exist before running this script."
        exit 1
    fi

    echo "All required branches exist. Proceeding with deployment..."
}
# Function to calculate the release tag
calculate_release_tag() {
    # Split the version string into major, minor, and patch components
    IFS='.' read -ra version_parts <<< "$latest_version"
    major="${version_parts[0]}"
    minor="${version_parts[1]}"
    patch="${version_parts[2]}"

    # Check if patch is less than 9, then increment patch
    if [ "$patch" -lt 9 ]; then
        new_patch=$((patch + 1))
        new_minor="$minor"
        new_major="$major"
    # If patch is 9, reset patch to 0 and increment minor
    else
        new_patch=0
        # Check if minor is less than 9, then increment minor
        if [ "$minor" -lt 9 ]; then
            new_minor=$((minor + 1))
            new_major="$major"
        # If minor is 9, reset minor to 0 and increment major
        else
            new_minor=0
            new_major=$((major + 1))
        fi
    fi

    # Construct the new version string
    new_version="$new_major.$new_minor.$new_patch"
    calculated_tag="$project-v$new_version"
    echo "$calculated_tag"
}

# Function to detect the latest version based on tags
detect_latest_version() {
    latest_tags=$(git tag --list "$project-v*" | sort -V | tail -n 1)

    if [ -z "$latest_tags" ]; then
        latest_version="$project-v0.0.1"  # Set a default initial version
    else
        latest_version=${latest_tags#"$project-v"}
    fi
}

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
execute_directory="/var/www/html/${project,,}-complete/"

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

# Check VPN status
#check_vpn_status

# If VPN connection is active, proceed with your main script here
echo "Running main script..."

# Validate all required branches exist
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
rm auth/saml2/.extlib/ -rf
rm local/wb_faq/lang/ -rf

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
git_push "${project,,}" "$MUSI_STABLE" "-f"
git_push "wunderbyte" "$PROJECT_STABLE" "-f"

# Prompt for the commit message
read -p "Enter the commit message: " commit_message

# Find the latest tag starting with project name
latest_tags=$(git tag --list "$project*" --sort=-v:refname | head -n 3)

# Prompt for the tag
echo "Three latest tags starting with '$project':"
echo "$latest_tags"

# Detect the latest version based on existing tags
detect_latest_version

# Initialize release tag
releasetag=""
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
git_cmd "switch -f $PROJECT_ALLINONE"
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
git_push "${project,,}" "$PROJECT_ALLINONE" "--tags"
