#!/bin/bash

# Prompt for the directory to execute the commands
read -p "Enter the directory path to execute the commands: " execute_directory

# Change to the specified directory
cd "$execute_directory"

# Switch to the desired branch
echo "Executing: git switch moodle_401_stable -f"
git switch musi_401_stable -f

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

# Amend the commit
echo "Executing: git commit --amend"
git commit --amend

# Push to the desired branch with force
echo "Executing: git push univie moodle_401_stable -f"
git push univie moodle_401_stable -f

echo "Executing: git push wunderbyte moodle_401_stable -f"
git push wunderbyte moodle_401_stable -f

# Prompt for the commit message
read -p "Enter the commit message: " commit_message

# Find the latest tag starting with "USI"
latest_tags=$(git tag --list "USI*" --sort=-v:refname | head -n 3)

# Prompt for the tag
echo "Three latest tags starting with 'USI':"
echo "$latest_tags"
read -p "Enter the new tag: " tag

# Use the default tag if no input provided
tag=${tag}

# Archive the repository
echo "Executing: git archive -o ../release.zip HEAD"
git archive -o ../release.zip HEAD

# Zip submodule directories
echo "Executing: git submodule --quiet foreach 'cd \$toplevel; zip -ru ../release.zip \$sm_path'"
git submodule --quiet foreach 'cd $toplevel; zip -ru ../release.zip $sm_path'

# Switch to the desired branch
echo "Executing: git switch -f musi_41_allinone"
git switch -f musi_41_allinone

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

# Prompt for release name:
read -p "Enter the new tag: " release

# Create a tag
echo "Executing: git tag -a \"$tag\" -m \"Release information\""
git tag -a "$tag" -m "$release"

# Push to the desired branch with tags
echo "Executing: git push wunderbyte musi_40_allinone --tags"
git push wunderbyte musi_41_allinone --tags

echo "Executing: git push univie musi_41_allinone --tags"
git push univie musi_41_allinone --tags
