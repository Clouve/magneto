#!/bin/bash

# Generic Docker Compose Stop Script
# This script can stop any Docker Compose application or bundle
#
# Usage Modes:
#   1. From parent directory with name: ./stop.sh <app-or-bundle-name> [--cleanup]
#   2. From parent directory with path: ./stop.sh <relative-path> [--cleanup]
#   3. From app/bundle directory: ../stop.sh [--cleanup]
#   4. From app/bundle directory: ../../stop.sh [--cleanup]
#
# Options:
#   --cleanup, -v    Also remove volumes (deletes all data)
#
# Examples:
#   ./stop.sh wordpress                  # Stop WordPress (searches apps/ and bundles/)
#   ./stop.sh education-kit -v           # Stop Education Kit and remove volumes
#   ./stop.sh apps/wordpress             # Stop WordPress using relative path
#   ./stop.sh bundles/education-kit -v   # Stop Education Kit using relative path
#   cd apps/wordpress && ../../stop.sh   # Stop from within app directory

set -e

# ============================================================================
# Determine working directory
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if we're being called with an app/bundle name or from within a directory
if [ $# -ge 1 ] && [ "${1:0:1}" != "-" ]; then
    # Mode 1: Called with app/bundle name or path from parent directory
    TARGET_ARG="$1"
    shift

    # Check if the argument contains a path separator (relative path mode)
    if [[ "$TARGET_ARG" == *"/"* ]]; then
        # Relative path mode: use the path directly
        WORK_DIR="$SCRIPT_DIR/$TARGET_ARG"
        DISPLAY_NAME="$(basename "$TARGET_ARG")"

        if [ ! -d "$WORK_DIR" ] || [ ! -f "$WORK_DIR/docker-compose.yml" ]; then
            echo "✗ Error: Directory '$TARGET_ARG' not found or missing docker-compose.yml"
            exit 1
        fi
    else
        # Simple name mode: search in apps/ and bundles/
        TARGET_NAME="$TARGET_ARG"

        # Try to find the target in apps or bundles subdirectories
        if [ -d "$SCRIPT_DIR/apps/$TARGET_NAME" ] && [ -f "$SCRIPT_DIR/apps/$TARGET_NAME/docker-compose.yml" ]; then
            WORK_DIR="$SCRIPT_DIR/apps/$TARGET_NAME"
            DISPLAY_NAME="$TARGET_NAME"
        elif [ -d "$SCRIPT_DIR/bundles/$TARGET_NAME" ] && [ -f "$SCRIPT_DIR/bundles/$TARGET_NAME/docker-compose.yml" ]; then
            WORK_DIR="$SCRIPT_DIR/bundles/$TARGET_NAME"
            DISPLAY_NAME="$TARGET_NAME"
        else
            echo "✗ Error: Application or bundle '$TARGET_NAME' not found"
            echo ""
            echo "Available applications:"
            for dir in "$SCRIPT_DIR/apps"/*/; do
                if [ -f "$dir/docker-compose.yml" ]; then
                    echo "  - $(basename "$dir")"
                fi
            done
            echo ""
            echo "Available bundles:"
            for dir in "$SCRIPT_DIR/bundles"/*/; do
                if [ -f "$dir/docker-compose.yml" ]; then
                    echo "  - $(basename "$dir")"
                fi
            done
            echo ""
            echo "Tip: You can also use relative paths like 'apps/wordpress' or 'bundles/education-kit'"
            exit 1
        fi
    fi
else
    # Mode 2: Called from within an app/bundle directory
    WORK_DIR="$(pwd)"
    DISPLAY_NAME="$(basename "$WORK_DIR")"

    # Verify docker-compose.yml exists in current directory
    if [ ! -f "$WORK_DIR/docker-compose.yml" ]; then
        echo "✗ Error: docker-compose.yml not found in current directory"
        echo ""
        echo "Usage:"
        echo "  From parent directory: $0 <app-or-bundle-name> [--cleanup]"
        echo "  From parent directory: $0 <relative-path> [--cleanup]"
        echo "  From app/bundle directory: $0 [--cleanup]"
        exit 1
    fi
fi

# ============================================================================
# Parse remaining arguments
# ============================================================================
REMOVE_VOLUMES=false
for arg in "$@"; do
    case $arg in
        --cleanup|-v)
            REMOVE_VOLUMES=true
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [app-or-bundle-name] [--cleanup|-v]"
            exit 1
            ;;
    esac
done

# ============================================================================
# Check prerequisites
# ============================================================================
if ! command -v docker-compose &> /dev/null; then
    echo "✗ Error: docker-compose is not installed or not in PATH"
    exit 1
fi

# ============================================================================
# Stop the services
# ============================================================================
cd "$WORK_DIR"

if [ "$REMOVE_VOLUMES" = true ]; then
    if docker-compose down -v; then
        echo ""
        echo "✓ $DISPLAY_NAME stopped and volumes removed successfully"
    else
        echo "✗ Failed to stop $DISPLAY_NAME"
        exit 1
    fi
else
    echo "Stopping $DISPLAY_NAME (data will be preserved)..."
    if docker-compose down; then
        echo ""
        echo "✓ $DISPLAY_NAME stopped successfully"
        echo ""
        echo "Data is preserved in Docker volumes."
        echo "To remove all data, run with --cleanup flag"
    else
        echo "✗ Failed to stop $DISPLAY_NAME"
        exit 1
    fi
fi

echo ""

