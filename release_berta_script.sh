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

  # Increment the minor version and reset the patch to 0
  new_minor=$((minor + 1))
  new_patch=0

  # Construct the new version string
  new_version="$major.$new_minor.$new_patch"
  calculated_tag="USI-v$new_version"
  echo "$calculated_tag"
}

# Function to detect the latest version based on tags
detect_latest_version() {
  latest_tags=$(git tag --list "USI-v*" | sort -V | tail -n 1)
  if [ -z "$latest_tags" ]; then
    echo "No existing tags found. Assuming default latest version."
    latest_version=""
  else
    latest_version=${latest_tags#"USI-v"}
  fi
}

moodle_base_branch=MOODLE_403_STABLE
desired_branch=BERTA_403_STABLE
allinone_branch=BERTA_403_ALLINONE
check_vpn=false

if $check_vpn ; then
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
else
    echo "VPN check is disabled. Skipping..."
fi


# If VPN connection is active, proceed with your main script here
echo "Running main script..."

# Prompt for the directory to execute the commands
read -p "Enter the directory path to execute the commands (default: /var/www/html/usi/): " execute_directory

# Use the default value if the user input is empty
if [ -z "$execute_directory" ]; then
  execute_directory="/var/www/html/usi/"
else
  execute_directory="$execute_directory"
fi

# Change to the specified directory
cd "$execute_directory"

# Switch to the desired branch
echo "Executing: git switch ${desired_branch} -f"
git switch ${desired_branch} -f

# Remove the directory
echo "Executing: rm auth/saml2/.extlib/ -rf"
rm auth/saml2/.extlib/ -rf

# Update submodules
echo "Executing: git submodule update --remote --init --recursive -f"
git submodule update --remote --init --recursive -f

# Check git status
echo "Executing: git status"
git status

# Prompt to continue or stop executing the script after "git status"
read -p "Continue executing the script? (y/n): " continue_execution
if [[ $continue_execution != "y" ]]; then
    echo "Script execution stopped."
    exit 0
fi

# Rebase with upstream Moodle
git fetch upstream
git rebase upstream/${moodle_base_branch}

# Amend the commit
echo "Executing: git commit --amend"
git commit --amend  --no-edit

echo "Executing: git push wunderbyte ${desired_branch} -f"
git push origin ${desired_branch} -f

# Prompt for the commit message
read -p "Enter the commit message: " commit_message

# Find the latest tag starting with "USI"
latest_tags=$(git tag --list "BERTA*" --sort=-v:refname | head -n 3)

# Prompt for the tag
echo "Three latest tags starting with 'BERTA':"
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
echo "Executing: git archive -o ../release.zip HEAD"
git archive -o ../release.zip HEAD

# Zip submodule directories
echo "Executing: git submodule --quiet foreach 'cd \$toplevel; zip -ru ../release.zip \$sm_path'"
git submodule --quiet foreach 'cd $toplevel; zip -ru ../release.zip $sm_path'

# Switch to the desired branch
echo "Executing: git switch -f ${allinone_branch}"
git switch -f ${allinone_branch}

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
echo "Executing: git add ."
git add .

# Commit the changes
echo "Executing: git commit -m \"$commit_message\""
git commit -m "$commit_message"

# Create a tag
echo "Executing: git tag -a \"$releasetag\" -m \"Release information\""
git tag -a "$releasetag" -m "$commit_message"

# Push to the desired branch with tags
echo "Executing: git push wunderbyte ${allinone_branch} --tags"
git push origin ${allinone_branch} --tags
