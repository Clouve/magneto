#!/bin/bash

# Generic Docker Compose Start Script
# This script can start any Docker Compose application or bundle
#
# Usage Modes:
#   1. From parent directory with name: ./start.sh <app-or-bundle-name> [--cleanup]
#   2. From parent directory with path: ./start.sh <relative-path> [--cleanup]
#   3. From app/bundle directory: ../start.sh [--cleanup]
#   4. From app/bundle directory: ../../start.sh [--cleanup]
#
# Examples:
#   ./start.sh wordpress                 # Start WordPress (searches apps/ and bundles/)
#   ./start.sh education-kit             # Start Education Kit (searches apps/ and bundles/)
#   ./start.sh apps/wordpress            # Start WordPress using relative path
#   ./start.sh bundles/education-kit     # Start Education Kit using relative path
#   cd apps/wordpress && ../../start.sh  # Start from within app directory
#   cd bundles/education-kit && ../../start.sh --cleanup  # Clean start from bundle

set -e

# ============================================================================
# Determine working directory
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if we're being called with an app/bundle name or from within a directory
if [ $# -ge 1 ] && [ "${1:0:2}" != "--" ]; then
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
CLEAN_MODE=false
for arg in "$@"; do
    case $arg in
        --cleanup)
            CLEAN_MODE=true
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [app-or-bundle-name] [--cleanup]"
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
# Handle clean mode
# ============================================================================
if [ "$CLEAN_MODE" = true ]; then
    echo ""
    echo "Stopping containers and removing volumes..."
    cd "$WORK_DIR"
    docker-compose down -v 2>/dev/null || true
    echo "✓ Cleanup complete"
    echo ""
fi

# ============================================================================
# Start the services
# ============================================================================
echo "Starting $DISPLAY_NAME..."
echo ""

cd "$WORK_DIR"

if docker-compose up -d; then
    echo ""
    echo "✓ $DISPLAY_NAME started successfully!"
    echo ""
    echo "Container Status:"
    docker-compose ps
    echo ""
    
    # Try to detect and display access information
    echo "=========================================="
    echo "Access Information"
    echo "=========================================="
    
    # Check for common ports and display URLs
    PORTS=$(docker-compose ps --format json 2>/dev/null | grep -o '"PublishedPort":[0-9]*' | cut -d: -f2 | sort -u || docker-compose port 2>/dev/null | grep -o '0.0.0.0:[0-9]*' | cut -d: -f2 | sort -u || echo "")
    
    if [ -n "$PORTS" ]; then
        for port in $PORTS; do
            echo "  http://localhost:$port"
        done
    else
        echo "  Check docker-compose.yml for port mappings"
    fi
    
    echo ""
    echo "For logs: docker-compose logs -f"
    echo "To stop: docker-compose down"
    echo ""
else
    echo "✗ Failed to start $DISPLAY_NAME"
    echo ""
    echo "Troubleshooting:"
    echo "  - Check logs: docker-compose logs"
    echo "  - Check container status: docker-compose ps"
    echo "  - Verify Docker is running: docker info"
    exit 1
fi

