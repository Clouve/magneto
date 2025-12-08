#!/bin/bash

# Generic Build and Tag Docker Images Script (Multi-Platform)
# This script builds custom application Docker images for multiple platforms (amd64, arm64).
# All builds are multi-platform by default.
#
# This script can build any Docker application or bundle that has an image directory
#
# Usage Modes:
#   1. From parent directory with name: ./build.sh <app-or-bundle-name> [--push] [--cleanup]
#   2. From parent directory with path: ./build.sh <relative-path> [--push] [--cleanup]
#   3. From app/bundle directory: ../build.sh [--push] [--cleanup]
#   4. From app/bundle directory: ../../build.sh [--push] [--cleanup]
#   5. Build all: ./build.sh --all [--push] [--cleanup]
#
# Options:
#   --push         Build and push multi-platform images to registry
#   --cleanup      Remove images and buildx cache before building
#   --all          Build all apps/bundles found in apps/ and bundles/ directories
#
# Examples:
#   ./build.sh gibbon                      # Build Gibbon multi-platform images locally (amd64 + arm64)
#   ./build.sh gibbon --push               # Build and push Gibbon multi-platform images to registry
#   ./build.sh gibbon --cleanup            # Remove Gibbon images, then build multi-platform locally
#   ./build.sh gibbon --cleanup --push     # Remove Gibbon images, then build and push multi-platform
#   ./build.sh apps/wordpress              # Build WordPress using relative path
#   ./build.sh bundles/education-kit       # Build Education Kit using relative path
#   ./build.sh --all                       # Build all apps/bundles locally
#   ./build.sh --all --push                # Build and push all apps/bundles to registry
#   ./build.sh --all --cleanup             # Remove all images, then build all apps/bundles locally
#   ./build.sh --all --cleanup --push      # Remove all images, then build and push all apps/bundles
#   cd apps/gibbon && ../../build.sh       # Build from within app directory

set -e

# ============================================================================
# Helper function to display usage
# ============================================================================
show_usage() {
    echo "Usage: $0 <app-or-bundle-name> [--push] [--cleanup]"
    echo "       $0 <relative-path> [--push] [--cleanup]"
    echo "       $0 --all [--push] [--cleanup]"
    echo ""
    echo "Supported applications and bundles:"
    for dir in "$SCRIPT_DIR/apps"/*/ "$SCRIPT_DIR/bundles"/*/; do
        if [ -d "$dir/image" ]; then
            # Get relative path from SCRIPT_DIR
            local rel_path="${dir#$SCRIPT_DIR/}"
            rel_path="${rel_path%/}"
            basename "$dir" | sed "s/^/  - /"
        fi
    done
    echo ""
    echo "Options:"
    echo "  --push         Build and push multi-platform images to registry"
    echo "  --cleanup      Remove images and buildx cache before building"
    echo "  --all          Build all apps/bundles found in apps/ and bundles/ directories"
    echo ""
    echo "Examples:"
    echo "  $0 gibbon                      # Build Gibbon multi-platform images locally"
    echo "  $0 gibbon --push               # Build and push Gibbon multi-platform images"
    echo "  $0 gibbon --cleanup            # Remove Gibbon images, then build multi-platform locally"
    echo "  $0 gibbon --cleanup --push     # Remove Gibbon images, then build and push multi-platform"
    echo "  $0 apps/wordpress              # Build WordPress using relative path"
    echo "  $0 bundles/education-kit       # Build Education Kit using relative path"
    echo "  $0 --all                       # Build all apps/bundles locally"
    echo "  $0 --all --push                # Build and push all apps/bundles to registry"
    echo "  $0 --all --cleanup             # Remove all images, then build all apps/bundles locally"
    echo "  $0 --all --cleanup --push      # Remove all images, then build and push all apps/bundles"
}

# ============================================================================
# Helper function to discover all apps and bundles with image directories
# ============================================================================
discover_targets() {
    local targets=()
    for dir in "$SCRIPT_DIR/apps"/*/ "$SCRIPT_DIR/bundles"/*/; do
        if [ -d "$dir/image" ]; then
            # Get relative path from SCRIPT_DIR
            local rel_path="${dir#$SCRIPT_DIR/}"
            rel_path="${rel_path%/}"
            targets+=("$rel_path")
        fi
    done
    echo "${targets[@]}"
}

# ============================================================================
# Helper function to discover container directories with Dockerfiles
# ============================================================================
discover_container_dirs() {
    local app_image_dir="$1"
    local container_dirs=()

    # Find all subdirectories that contain a Dockerfile
    for dir in "$app_image_dir"/*/; do
        if [ -d "$dir" ] && [ -f "$dir/Dockerfile" ]; then
            # Get just the directory name (e.g., "db", "redis")
            local dir_name=$(basename "$dir")
            container_dirs+=("$dir_name")
        fi
    done

    echo "${container_dirs[@]}"
}

# ============================================================================
# Helper function to get all image names for cleanup
# ============================================================================
get_all_images() {
    local images=()
    for dir in "$SCRIPT_DIR/apps"/*/ "$SCRIPT_DIR/bundles"/*/; do
        if [ -d "$dir/image" ]; then
            local config_file="$dir/image/build.config"

            if [ -f "$config_file" ]; then
                # Source the config file to get image names
                # shellcheck disable=SC1090
                source "$config_file"

                if [ -n "$APP_IMAGE" ]; then
                    images+=("$IMAGE_REGISTRY/$APP_IMAGE")
                fi

                # Dynamically discover all container directories and their images
                local app_image_dir="$dir/image"
                local container_dirs=($(discover_container_dirs "$app_image_dir"))

                for container_dir in "${container_dirs[@]}"; do
                    # Convert directory name to uppercase and append _IMAGE (e.g., db -> DB_IMAGE, redis -> REDIS_IMAGE)
                    local var_prefix=$(echo "$container_dir" | tr '[:lower:]' '[:upper:]')
                    local var_name="${var_prefix}_IMAGE"
                    local image_name="${!var_name}"

                    if [ -n "$image_name" ]; then
                        images+=("$IMAGE_REGISTRY/$image_name")
                    fi
                done

                # Reset all variables for next iteration
                # Get all variables that end with _IMAGE or _NAME
                for var in $(compgen -v | grep -E '_(IMAGE|NAME)$'); do
                    unset "$var"
                done
                unset APP_IMAGE
            fi
        fi
    done
    echo "${images[@]}"
}

# ============================================================================
# Helper function to get image names for a specific target
# ============================================================================
get_target_images() {
    local target_dir="$1"
    local images=()
    local config_file="$target_dir/image/build.config"

    if [ -f "$config_file" ]; then
        # Source the config file to get image names
        # shellcheck disable=SC1090
        source "$config_file"

        if [ -n "$APP_IMAGE" ]; then
            images+=("$IMAGE_REGISTRY/$APP_IMAGE")
        fi

        # Dynamically discover all container directories and their images
        local app_image_dir="$target_dir/image"
        local container_dirs=($(discover_container_dirs "$app_image_dir"))

        for container_dir in "${container_dirs[@]}"; do
            # Convert directory name to uppercase and append _IMAGE (e.g., db -> DB_IMAGE, redis -> REDIS_IMAGE)
            local var_prefix=$(echo "$container_dir" | tr '[:lower:]' '[:upper:]')
            local var_name="${var_prefix}_IMAGE"
            local image_name="${!var_name}"

            if [ -n "$image_name" ]; then
                images+=("$IMAGE_REGISTRY/$image_name")
            fi
        done

        # Reset all variables
        for var in $(compgen -v | grep -E '_(IMAGE|NAME)$'); do
            unset "$var"
        done
        unset APP_IMAGE
    fi

    echo "${images[@]}"
}

# ============================================================================
# Helper function to cleanup images
# ============================================================================
cleanup_images() {
    local images=("$@")

    if [ ${#images[@]} -eq 0 ]; then
        echo "⊘ No images to clean up"
        return 0
    fi

    echo "Removing local Docker images..."
    for img in "${images[@]}"; do
        # Try to remove all tags for this image
        if docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^$img:"; then
            echo "  Removing $img:*"
            # Get all tags for this image and remove them
            while IFS= read -r image_tag; do
                if docker rmi "$image_tag" 2>/dev/null; then
                    echo "    ✓ Removed $image_tag"
                else
                    echo "    ⊘ Could not remove $image_tag (may be in use or already removed)"
                fi
            done < <(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^$img:")
        else
            echo "  ⊘ $img not found locally (skipping)"
        fi
    done

    echo ""
    echo "Clearing Docker buildx cache..."
    if docker buildx prune -af; then
        echo "✓ Docker buildx cache cleared successfully"
    else
        echo "✗ Failed to clear Docker buildx cache"
        return 1
    fi

    return 0
}

# ============================================================================
# Parse command line arguments
# ============================================================================
# Determine script directory early for usage function
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 1 ]; then
    echo "Error: Application/bundle name or option is required"
    echo ""
    show_usage
    exit 1
fi

# Parse target name and options
BUILD_ALL=false
TARGET_DIR=""
DISPLAY_NAME=""
PUSH_IMAGES=false
CLEANUP=false

# Check if first argument is --all or --cleanup
if [ "$1" = "--all" ]; then
    BUILD_ALL=true
    shift
elif [ "$1" = "--cleanup" ]; then
    # --cleanup cannot be used as the first argument alone
    echo "Error: --cleanup must be used with an app/bundle name or --all"
    echo ""
    echo "Examples:"
    echo "  $0 gibbon --cleanup            # Remove Gibbon images, then build"
    echo "  $0 --all --cleanup             # Remove all images, then build all apps/bundles"
    echo ""
    show_usage
    exit 1
elif [ "${1:0:2}" != "--" ]; then
    # Check if the argument contains a path separator (relative path mode)
    if [[ "$1" == *"/"* ]]; then
        # Relative path mode: use the path directly
        TARGET_DIR="$SCRIPT_DIR/$1"
        DISPLAY_NAME="$(basename "$1")"

        if [ ! -d "$TARGET_DIR/image" ]; then
            echo "✗ Error: Directory '$1' not found or missing image directory"
            echo ""
            show_usage
            exit 1
        fi
    else
        # Simple name mode: search in apps/ and bundles/
        TARGET_NAME="$1"

        # Try to find the target in apps or bundles subdirectories
        if [ -d "$SCRIPT_DIR/apps/$TARGET_NAME/image" ]; then
            TARGET_DIR="$SCRIPT_DIR/apps/$TARGET_NAME"
            DISPLAY_NAME="$TARGET_NAME"
        elif [ -d "$SCRIPT_DIR/bundles/$TARGET_NAME/image" ]; then
            TARGET_DIR="$SCRIPT_DIR/bundles/$TARGET_NAME"
            DISPLAY_NAME="$TARGET_NAME"
        else
            echo "✗ Error: Application or bundle '$TARGET_NAME' not found or missing image directory"
            echo ""
            echo "Available applications and bundles:"
            for dir in "$SCRIPT_DIR/apps"/*/ "$SCRIPT_DIR/bundles"/*/; do
                if [ -d "$dir/image" ]; then
                    echo "  - $(basename "$dir")"
                fi
            done
            echo ""
            echo "Tip: You can also use relative paths like 'apps/wordpress' or 'bundles/education-kit'"
            exit 1
        fi
    fi
    shift
fi

# Parse remaining options
for arg in "$@"; do
    case $arg in
        --push)
            PUSH_IMAGES=true
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --all)
            echo "Error: --all must be the first argument"
            echo ""
            show_usage
            exit 1
            ;;
        *)
            echo "Unknown argument: $arg"
            echo ""
            show_usage
            exit 1
            ;;
    esac
done

# If --all mode, build all targets
if [ "$BUILD_ALL" = true ]; then
    echo "============================================================================"
    echo "Building all applications and bundles"
    echo "============================================================================"
    echo ""

    # Allow IMAGE_REGISTRY to be overridden via REGISTRY environment variable
    IMAGE_REGISTRY="${REGISTRY:-r.clv.zone/e2eorg}"

    # Cleanup all images if requested
    if [ "$CLEANUP" = true ]; then
        echo "============================================================================"
        echo "Cleanup: Removing all images and clearing cache"
        echo "============================================================================"
        echo ""

        # Get all images
        ALL_IMAGES=($(get_all_images))

        if [ ${#ALL_IMAGES[@]} -eq 0 ]; then
            echo "⊘ No images found to clean up"
        else
            echo "Found ${#ALL_IMAGES[@]} image(s) to clean up:"
            for img in "${ALL_IMAGES[@]}"; do
                echo "  - $img"
            done
            echo ""

            if ! cleanup_images "${ALL_IMAGES[@]}"; then
                echo "✗ Cleanup failed"
                exit 1
            fi
        fi

        echo ""
    fi

    # Discover all targets
    ALL_TARGETS=($(discover_targets))

    if [ ${#ALL_TARGETS[@]} -eq 0 ]; then
        echo "✗ No applications or bundles with image directories found in $SCRIPT_DIR"
        exit 1
    fi

    echo "Found ${#ALL_TARGETS[@]} target(s) to build:"
    for target in "${ALL_TARGETS[@]}"; do
        echo "  - $target"
    done
    echo ""

    # Build each target
    SUCCESS_COUNT=0
    FAILED_COUNT=0
    FAILED_TARGETS=()

    for target in "${ALL_TARGETS[@]}"; do
        echo "============================================================================"
        echo "Building: $target ($(($SUCCESS_COUNT + $FAILED_COUNT + 1))/${#ALL_TARGETS[@]})"
        echo "============================================================================"
        echo ""

        # Build the target by recursively calling this script
        # Note: Don't pass --cleanup to recursive calls since we already cleaned up
        BUILD_CMD="$0 $target"
        if [ "$PUSH_IMAGES" = true ]; then
            BUILD_CMD="$BUILD_CMD --push"
        fi

        # Temporarily disable exit on error for this command
        set +e
        $BUILD_CMD
        BUILD_EXIT_CODE=$?
        set -e

        if [ $BUILD_EXIT_CODE -eq 0 ]; then
            echo "✓ Successfully built $target"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "✗ Failed to build $target"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            FAILED_TARGETS+=("$target")
        fi
        echo ""
    done

    # Summary
    echo "============================================================================"
    echo "Build Summary"
    echo "============================================================================"
    echo ""
    echo "Total targets: ${#ALL_TARGETS[@]}"
    echo "Successful builds: $SUCCESS_COUNT"
    echo "Failed builds: $FAILED_COUNT"

    if [ $FAILED_COUNT -gt 0 ]; then
        echo ""
        echo "Failed targets:"
        for target in "${FAILED_TARGETS[@]}"; do
            echo "  - $target"
        done
        echo ""
        exit 1
    fi

    echo ""
    echo "✓ All targets built successfully!"
    echo ""
    exit 0
fi

# ============================================================================
# Configure global variables
# ============================================================================
# Allow IMAGE_REGISTRY to be overridden via REGISTRY environment variable
IMAGE_REGISTRY="${REGISTRY:-r.clv.zone/e2eorg}"

DATE_TAG=$(date +%Y.%m.%d)
PLATFORMS="linux/amd64,linux/arm64"

# ============================================================================
# Determine target image directory
# ============================================================================
APP_IMAGE_DIR="$TARGET_DIR/image"

# Check if image directory exists
if [ ! -d "$APP_IMAGE_DIR" ]; then
    echo "✗ Error: Image directory not found: $APP_IMAGE_DIR"
    echo ""
    echo "Note: This script only builds targets that have an image directory."
    exit 1
fi

# ============================================================================
# Load target-specific configuration
# ============================================================================
CONFIG_FILE="$APP_IMAGE_DIR/build.config"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "✗ Error: Configuration file not found: $CONFIG_FILE"
    echo ""
    echo "Each target must have a build.config file in its image directory."
    echo "Expected location: $DISPLAY_NAME/image/build.config"
    exit 1
fi

# Source the configuration file
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Validate required configuration variables
# APP_IMAGE is always required
if [ -z "$APP_IMAGE" ]; then
    echo "✗ Error: Configuration file is missing required variable: $CONFIG_FILE"
    echo ""
    echo "Missing variable: APP_IMAGE"
    echo ""
    echo "Required variables: APP_IMAGE"
    echo "Optional variables: <CONTAINER_DIR>_IMAGE, <CONTAINER_DIR>_NAME (e.g., DB_IMAGE, DB_NAME, REDIS_IMAGE, REDIS_NAME)"
    exit 1
fi

# Discover all container directories with Dockerfiles
CONTAINER_DIRS=($(discover_container_dirs "$APP_IMAGE_DIR"))

# Validate that each discovered container directory has corresponding IMAGE and NAME variables
CONTAINER_CONFIGS=()
for container_dir in "${CONTAINER_DIRS[@]}"; do
    # Convert directory name to uppercase (e.g., db -> DB, redis -> REDIS)
    var_prefix=$(echo "$container_dir" | tr '[:lower:]' '[:upper:]')
    image_var="${var_prefix}_IMAGE"
    name_var="${var_prefix}_NAME"

    # Get the values of these variables
    image_value="${!image_var}"
    name_value="${!name_var}"

    # Check if both are provided or both are missing
    if [ -n "$image_value" ] || [ -n "$name_value" ]; then
        if [ -z "$image_value" ] || [ -z "$name_value" ]; then
            echo "✗ Error: Both ${image_var} and ${name_var} must be provided together: $CONFIG_FILE"
            echo ""
            if [ -z "$image_value" ]; then
                echo "Missing variable: ${image_var}"
            fi
            if [ -z "$name_value" ]; then
                echo "Missing variable: ${name_var}"
            fi
            echo ""
            echo "Note: Found Dockerfile in '$container_dir/' directory, so both ${image_var} and ${name_var} are required."
            exit 1
        fi

        # Store the configuration for this container
        CONTAINER_CONFIGS+=("$container_dir:$image_value:$name_value")
    else
        echo "⚠ Warning: Found Dockerfile in '$container_dir/' but no ${image_var} or ${name_var} in build.config"
        echo "  Skipping build for '$container_dir/' container"
    fi
done

echo "Building and tagging Docker images for $DISPLAY_NAME..."
echo ""

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "✗ Error: docker is not installed or not in PATH"
    exit 1
fi

# Check if docker buildx is available
if ! docker buildx version &> /dev/null; then
    echo "✗ Error: docker buildx is not available"
    echo "  Please ensure you have Docker 19.03+ with buildx support"
    exit 1
fi

# Navigate to the app image directory
cd "$APP_IMAGE_DIR"

# Check if Dockerfile exists in image directory
if [ ! -f "Dockerfile" ]; then
    echo "✗ Error: Dockerfile not found in $APP_IMAGE_DIR"
    exit 1
fi

# Validate that all configured containers have Dockerfiles
for config in "${CONTAINER_CONFIGS[@]}"; do
    IFS=':' read -r container_dir image_name display_name <<< "$config"

    if [ ! -f "$container_dir/Dockerfile" ]; then
        var_prefix=$(echo "$container_dir" | tr '[:lower:]' '[:upper:]')
        echo "✗ Error: Dockerfile not found for '$container_dir' container"
        echo "  Expected location: $APP_IMAGE_DIR/$container_dir/Dockerfile"
        echo "  Note: ${var_prefix}_IMAGE and ${var_prefix}_NAME are configured, so a Dockerfile is required."
        exit 1
    fi
done

# ============================================================================
# Cleanup images if requested
# ============================================================================
if [ "$CLEANUP" = true ]; then
    echo "============================================================================"
    echo "Cleanup: Removing $DISPLAY_NAME images and clearing cache"
    echo "============================================================================"
    echo ""

    # Get images for this target
    TARGET_IMAGES=($(get_target_images "$TARGET_DIR"))

    if [ ${#TARGET_IMAGES[@]} -eq 0 ]; then
        echo "⊘ No images found to clean up for $DISPLAY_NAME"
    else
        echo "Found ${#TARGET_IMAGES[@]} image(s) to clean up:"
        for img in "${TARGET_IMAGES[@]}"; do
            echo "  - $img"
        done
        echo ""

        if ! cleanup_images "${TARGET_IMAGES[@]}"; then
            echo "✗ Cleanup failed"
            exit 1
        fi
    fi

    echo ""
fi

# ============================================================================
# STEP 1: Build application image from Dockerfile
# ============================================================================
TOTAL_STEPS=$((1 + ${#CONTAINER_CONFIGS[@]}))

echo "Step 1/$TOTAL_STEPS: Building $DISPLAY_NAME image from Dockerfile for platforms: $PLATFORMS..."
if [ "$PUSH_IMAGES" = true ]; then
    echo "Building and pushing multi-platform image..."
    if docker buildx build \
        --platform "$PLATFORMS" \
        --tag "$IMAGE_REGISTRY/$APP_IMAGE:$DATE_TAG" \
        --tag "$IMAGE_REGISTRY/$APP_IMAGE:latest" \
        --provenance=false \
        --push \
        .; then
        echo "✓ $DISPLAY_NAME multi-platform image built and pushed successfully!"
    else
        echo "✗ Failed to build and push $DISPLAY_NAME Docker image"
        exit 1
    fi
else
    echo "Building multi-platform image (not pushing to registry)..."
    if docker buildx build \
        --platform "$PLATFORMS" \
        --tag "$IMAGE_REGISTRY/$APP_IMAGE:$DATE_TAG" \
        --tag "$IMAGE_REGISTRY/$APP_IMAGE:latest" \
        --provenance=false \
        .; then
        echo "✓ $DISPLAY_NAME multi-platform image built successfully!"
        echo "  Note: Images built for both amd64 and arm64 platforms (stored in build cache)."
        echo "  Use --push to push images to registry."
    else
        echo "✗ Failed to build $DISPLAY_NAME Docker image"
        exit 1
    fi
fi

echo ""

# ============================================================================
# STEP 2+: Build container images from Dockerfiles (if configured)
# ============================================================================
if [ ${#CONTAINER_CONFIGS[@]} -gt 0 ]; then
    STEP_NUM=2
    for config in "${CONTAINER_CONFIGS[@]}"; do
        IFS=':' read -r container_dir image_name display_name <<< "$config"

        echo "Step $STEP_NUM/$TOTAL_STEPS: Building $display_name image from Dockerfile for platforms: $PLATFORMS..."

        if [ "$PUSH_IMAGES" = true ]; then
            echo "Building and pushing multi-platform $display_name image..."
            if docker buildx build \
                --platform "$PLATFORMS" \
                --tag "$IMAGE_REGISTRY/$image_name:$DATE_TAG" \
                --tag "$IMAGE_REGISTRY/$image_name:latest" \
                --provenance=false \
                --push \
                "$container_dir/"; then
                echo "✓ $display_name multi-platform image built and pushed successfully!"
            else
                echo "✗ Failed to build and push $display_name Docker image"
                exit 1
            fi
        else
            echo "Building multi-platform $display_name image (not pushing to registry)..."
            if docker buildx build \
                --platform "$PLATFORMS" \
                --tag "$IMAGE_REGISTRY/$image_name:$DATE_TAG" \
                --tag "$IMAGE_REGISTRY/$image_name:latest" \
                --provenance=false \
                "$container_dir/"; then
                echo "✓ $display_name multi-platform image built successfully!"
                echo "  Note: Images built for both amd64 and arm64 platforms (stored in build cache)."
                echo "  Use --push to push images to registry."
            else
                echo "✗ Failed to build $display_name Docker image"
                exit 1
            fi
        fi

        echo ""
        STEP_NUM=$((STEP_NUM + 1))
    done
else
    echo "No additional containers configured for this target"
    echo ""
fi

echo "============================================================================"
if [ "$PUSH_IMAGES" = true ]; then
    echo "✓ All multi-platform images built and pushed successfully!"
else
    echo "✓ All multi-platform images built successfully!"
fi
echo "============================================================================"
echo ""
echo "$DISPLAY_NAME Image Tags (Platforms: $PLATFORMS):"
echo "  - $IMAGE_REGISTRY/$APP_IMAGE:$DATE_TAG"
echo "  - $IMAGE_REGISTRY/$APP_IMAGE:latest"
echo ""

# Show all container image tags
for config in "${CONTAINER_CONFIGS[@]}"; do
    IFS=':' read -r container_dir image_name display_name <<< "$config"

    echo "$display_name Image Tags (Platforms: $PLATFORMS):"
    echo "  - $IMAGE_REGISTRY/$image_name:$DATE_TAG"
    echo "  - $IMAGE_REGISTRY/$image_name:latest"
    echo ""
done

# ============================================================================
# Final instructions
# ============================================================================
if [ "$PUSH_IMAGES" = false ]; then
    echo "To push multi-platform images to registry, run:"
    echo "  $0 $DISPLAY_NAME --push"
    echo ""
    echo "Note: Multi-platform images (amd64 + arm64) are stored in build cache."
    echo "      Use --push to push them to the registry."
    echo ""
fi

