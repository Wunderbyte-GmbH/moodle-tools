#!/bin/bash

# Get project name and repository path
PROJECT_NAME="$1"
REPO_PATH="$2"

echo "=== WKO Plugin Configuration and Push Script ==="
echo "Project: $PROJECT_NAME"
echo "Repository: $REPO_PATH"

# Check required parameters
if [ -z "$PROJECT_NAME" ] || [ -z "$REPO_PATH" ]; then
    echo "Error: Both project name and repository path are required."
    echo "Usage: $0 PROJECT_NAME REPO_PATH"
    exit 1
fi

# Change to repository directory
if [ -d "$REPO_PATH" ]; then
    cd "$REPO_PATH" || exit 1
else
    echo "ERROR: Repository path does not exist: $REPO_PATH"
    exit 1
fi

# Only proceed for WKO project
project_lowercase="${PROJECT_NAME,,}"
if [ "$project_lowercase" != "wko" ]; then
    echo "Project '$PROJECT_NAME' is not WKO. Skipping."
    exit 0
fi

echo "=== Processing WKO submodules ==="

# Define submodules and their repository mappings
SUBMODULES=(
    "availability/condition/metadata:moodle-availability_metadata.git"
    "local/rabbitmq:moodle-local_rabbitmq.git"
    "local/quizattemptexport:moodle-local_quizattemptexport.git"
    "local/wko_connect:moodle-local_wko_connect.git"
    "blocks/handout:moodle-block_handout.git"
    "local/handoutpdf:moodle-local_handoutpdf.git"
)

# Root URL for WKO repositories
NEW_ROOT_URL="ssh://git@git01.lx.oe.wknet:2222/digi-pa/wko-exam/"

# Counters
successful=0
failed=0

# Process each submodule
for submodule_entry in "${SUBMODULES[@]}"; do
    # Split entry into path and repo name
    SUBMODULE_PATH="${submodule_entry%:*}"
    REPO_FILE="${submodule_entry#*:}"
    NEW_URL="${NEW_ROOT_URL}${REPO_FILE}"
    
    echo ""
    echo "--- Processing: $SUBMODULE_PATH ---"
    
    if [ -d "$SUBMODULE_PATH" ]; then
        (
            cd "$SUBMODULE_PATH" || exit 1
            
            # Configure push URL
            echo "  Setting push URL: $NEW_URL"
            git config remote.origin.pushurl "$NEW_URL"
            
            # Show current state
            current_commit=$(git rev-parse HEAD)
            echo "  Current commit: $current_commit"
            
            # Push with force (since force push is enabled)
            echo "  Pushing to remote..."
            echo "  Command: git push --force origin HEAD:main"
            git push --force origin HEAD:main
            push_exit_code=$?
            
            if [ $push_exit_code -eq 0 ]; then
                echo "  ✓ Successfully pushed"
                exit 0
            else
                echo "  ✗ Push failed with exit code: $push_exit_code"
                exit 1
            fi
        )
        
        if [ $? -eq 0 ]; then
            successful=$((successful + 1))
        else
            failed=$((failed + 1))
        fi
    else
        echo "  ✗ Directory not found"
        failed=$((failed + 1))
    fi
done

echo ""
echo "=== Summary ==="
echo "Successful: $successful"
echo "Failed: $failed"

if [ $failed -eq 0 ]; then
    echo "✓ All submodules processed successfully!"
    exit 0
else
    echo "⚠ Some operations failed."
    exit 1
fi