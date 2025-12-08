#!/bin/bash

# Generic Docker Compose Status Script
# This script can display status for any Docker Compose application or bundle
#
# Usage Modes:
#   1. From parent directory with name: ./status.sh <app-or-bundle-name>
#   2. From parent directory with path: ./status.sh <relative-path>
#   3. From app/bundle directory: ../status.sh
#   4. From app/bundle directory: ../../status.sh
#
# Examples:
#   ./status.sh wordpress                # Show WordPress status
#   ./status.sh education-kit            # Show Education Kit status
#   ./status.sh apps/wordpress           # Show WordPress status using relative path
#   ./status.sh bundles/education-kit    # Show Education Kit status using relative path
#   cd apps/wordpress && ../../status.sh # Show status from within directory

set -e

# ============================================================================
# Determine working directory
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if we're being called with an app/bundle name or from within a directory
if [ $# -ge 1 ]; then
    # Mode 1: Called with app/bundle name or path from parent directory
    TARGET_ARG="$1"

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
        echo "  From parent directory: $0 <app-or-bundle-name>"
        echo "  From parent directory: $0 <relative-path>"
        echo "  From app/bundle directory: $0"
        exit 1
    fi
fi

# ============================================================================
# Check prerequisites
# ============================================================================
if ! command -v docker-compose &> /dev/null; then
    echo "✗ Error: docker-compose is not installed or not in PATH"
    exit 1
fi

# ============================================================================
# Display status
# ============================================================================
cd "$WORK_DIR"

echo "=========================================="
echo "$DISPLAY_NAME Status"
echo "=========================================="
echo ""

# Check if any containers are running
if ! docker-compose ps --services --filter "status=running" 2>/dev/null | grep -q .; then
    echo "⚠ $DISPLAY_NAME is not running"
    echo ""
    echo "To start: docker-compose up -d"
    exit 0
fi

# Display container status
echo "Container Status:"
echo ""
docker-compose ps
echo ""

# Display resource usage if containers are running
RUNNING_CONTAINERS=$(docker-compose ps -q 2>/dev/null)
if [ -n "$RUNNING_CONTAINERS" ]; then
    echo "=========================================="
    echo "Resource Usage"
    echo "=========================================="
    echo ""
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" $RUNNING_CONTAINERS 2>/dev/null || echo "Unable to retrieve resource usage"
    echo ""
fi

