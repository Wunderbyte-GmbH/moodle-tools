#!/bin/bash

# Function to calculate the release tag
calculate_release_tag() {
  if [ -z "$latest_version" ]; then
    echo "No existing tags found. Unable to calculate the release tag."
    exit 1
  fi

  # Split the version string into major, minor, and patch components
  IFS='.' read -ra version_parts <<< "$latest_version"
  major="${version_parts[0]}"
  minor="${version_parts[1]}"
  patch="${version_parts[2]}"

  # Check if patch is less than 9, then increment patch; otherwise, increment minor and reset patch to 0
  new_patch=$((patch < 9 ? patch + 1 : 0))
  new_minor=$((patch < 9 ? minor : minor + 1))

  # Construct the new version string
  new_version="$major.$new_minor.$new_patch"
  calculated_tag="USI-v$new_version"
  echo "$calculated_tag"
}

# Function to detect the latest version based on tags
detect_latest_version() {
  latest_tags=$(git tag --list "USI-v*" | sort -V | tail -n 1)
  latest_version=${latest_tags#"USI-v"}
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
  execute_directory="${user_input:-/var/www/html/usi/}"

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

# Function to perform git push
git_push() {
  local remote="$1"
  local branch="$2"
  shift 2  # Shift to remove the first two arguments (remote and branch)
  
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

# Define variables for branch names
MOODLE_STABLE="MOODLE_401_STABLE"
MUSI_STABLE="musi_401_stable"
MUSI_ALLINONE="musi_41_allinone"

# Set global variable
execute_directory="/var/www/html/usi/"

# Check if the script is not running with root privilages
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
check_vpn_status

# If VPN connection is active, proceed with your main script here
echo "Running main script..."

# Prompt for the directory to execute the commands
prompt_and_change_directory

# Switch to the desired branch
git_cmd "switch -f $MUSI_STABLE"

# Remove the directory
rm auth/saml2/.extlib/ -rf

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
git_push "univie" "$MUSI_STABLE" "-f"
git_push "wunderbyte" "$MUSI_STABLE" "-f"

# Fetch latest release
git_cmd "fetch wunderbyte"
git_cmd "switch $MUSI_ALLINONE -f"
git_cmd "pull wunderbyte $MUSI_ALLINONE"

# Prompt for the commit message
read -p "Enter the commit message: " commit_message

# Find the latest tag starting with "USI"
latest_tags=$(git tag --list "USI*" --sort=-v:refname | head -n 3)


# Prompt for the tag
echo "Three latest tags starting with 'USI':"
echo "$latest_tags"
attempts=0

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
    exit 1  # Exit with a non-zero status code indicating failure
fi

# Continue with the rest of your script here
echo "Continuing with the script..."

echo "Executing: git archive -o ../release.zip HEAD"
git archive -o ../release.zip HEAD

# Zip submodule directories
echo "Executing: git submodule --quiet foreach 'cd \$toplevel; zip -ru ../release.zip \$sm_path'"
git submodule --quiet foreach 'cd $toplevel; zip -ru ../release.zip $sm_path'

# Switch to the desired branch
git_cmd "switch -f $MUSI_ALLINONE"

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
git_push "wunderbyte" "$MUSI_ALLINONE" "--tags"
git_push "univie" "$MUSI_ALLINONE" "--tags"
