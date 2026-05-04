#!/bin/bash

# Generic Docker Compose Logs Script
# This script can display logs for any Docker Compose application or bundle
#
# Usage Modes:
#   1. From parent directory with name: ./logs.sh <app-or-bundle-name> [service] [options]
#   2. From parent directory with path: ./logs.sh <relative-path> [service] [options]
#   3. From app/bundle directory: ../logs.sh [service] [options]
#   4. From app/bundle directory: ../../logs.sh [service] [options]
#
# Options:
#   -f, --follow       Follow log output (like tail -f)
#   -n, --lines N      Show last N lines (default: 100)
#   [service]          Optional service name to filter logs
#
# Examples:
#   ./logs.sh wordpress                      # Show WordPress logs
#   ./logs.sh wordpress -f                   # Follow WordPress logs
#   ./logs.sh education-kit moodle           # Show only Moodle service logs
#   ./logs.sh apps/wordpress -f              # Follow WordPress logs using relative path
#   ./logs.sh bundles/education-kit moodle   # Show Moodle logs using relative path
#   cd apps/wordpress && ../../logs.sh -f    # Follow from within directory

set -e

# ============================================================================
# Determine working directory
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if we're being called with an app/bundle name or from within a directory
TARGET_NAME=""
if [ $# -ge 1 ] && [ "${1:0:1}" != "-" ]; then
    TARGET_ARG="$1"

    # Check if the argument contains a path separator (relative path mode)
    if [[ "$TARGET_ARG" == *"/"* ]]; then
        # Relative path mode: use the path directly
        WORK_DIR="$SCRIPT_DIR/$TARGET_ARG"
        DISPLAY_NAME="$(basename "$TARGET_ARG")"
        TARGET_NAME="$TARGET_ARG"

        if [ ! -d "$WORK_DIR" ] || [ ! -f "$WORK_DIR/docker-compose.yml" ]; then
            echo "✗ Error: Directory '$TARGET_ARG' not found or missing docker-compose.yml"
            exit 1
        fi
        shift
    # Check if first argument is a valid app/bundle name (simple name mode)
    elif [ -d "$SCRIPT_DIR/apps/$TARGET_ARG" ] && [ -f "$SCRIPT_DIR/apps/$TARGET_ARG/docker-compose.yml" ]; then
        TARGET_NAME="$TARGET_ARG"
        WORK_DIR="$SCRIPT_DIR/apps/$TARGET_NAME"
        DISPLAY_NAME="$TARGET_NAME"
        shift
    elif [ -d "$SCRIPT_DIR/bundles/$TARGET_ARG" ] && [ -f "$SCRIPT_DIR/bundles/$TARGET_ARG/docker-compose.yml" ]; then
        TARGET_NAME="$TARGET_ARG"
        WORK_DIR="$SCRIPT_DIR/bundles/$TARGET_NAME"
        DISPLAY_NAME="$TARGET_NAME"
        shift
    else
        # Not a valid app/bundle name, assume we're in the directory and this is a service name
        WORK_DIR="$(pwd)"
        DISPLAY_NAME="$(basename "$WORK_DIR")"
    fi
else
    # Called from within an app/bundle directory
    WORK_DIR="$(pwd)"
    DISPLAY_NAME="$(basename "$WORK_DIR")"
fi

# Verify docker-compose.yml exists
if [ ! -f "$WORK_DIR/docker-compose.yml" ]; then
    echo "✗ Error: docker-compose.yml not found"
    echo ""
    if [ -z "$TARGET_NAME" ]; then
        echo "Usage:"
        echo "  From parent directory: $0 <app-or-bundle-name> [service] [options]"
        echo "  From parent directory: $0 <relative-path> [service] [options]"
        echo "  From app/bundle directory: $0 [service] [options]"
    else
        echo "Application or bundle '$TARGET_NAME' not found or has no docker-compose.yml"
        echo ""
        echo "Tip: You can also use relative paths like 'apps/wordpress' or 'bundles/education-kit'"
    fi
    exit 1
fi

# ============================================================================
# Parse remaining arguments
# ============================================================================
FOLLOW_MODE=false
LINES=100
SERVICE=""

while [ $# -gt 0 ]; do
    case $1 in
        -f|--follow)
            FOLLOW_MODE=true
            shift
            ;;
        -n|--lines)
            LINES="$2"
            shift 2
            ;;
        *)
            # Assume it's a service name
            SERVICE="$1"
            shift
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
# Display logs
# ============================================================================
cd "$WORK_DIR"

if [ "$FOLLOW_MODE" = true ]; then
    if [ -z "$SERVICE" ]; then
        echo "Following logs from $DISPLAY_NAME (press Ctrl+C to stop)..."
        docker-compose logs -f
    else
        echo "Following logs from $DISPLAY_NAME/$SERVICE (press Ctrl+C to stop)..."
        docker-compose logs -f "$SERVICE"
    fi
else
    if [ -z "$SERVICE" ]; then
        echo "Showing last $LINES lines of $DISPLAY_NAME logs..."
        docker-compose logs --tail="$LINES"
    else
        echo "Showing last $LINES lines of $DISPLAY_NAME/$SERVICE logs..."
        docker-compose logs --tail="$LINES" "$SERVICE"
    fi
fi

