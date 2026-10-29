#!/bin/bash

# Generic Build and Tag Docker Images Script (Multi-Platform)
# This script builds custom application Docker images for multiple platforms (amd64, arm64).
# All builds are multi-platform by default.
#
# This script can build any Docker application or bundle that has an image directory
#
# Usage Modes:
#   1. From parent directory with name: ./build.sh <app-or-bundle-name> [--push] [--cleanup] [--prune]
#   2. From parent directory with path: ./build.sh <relative-path> [--push] [--cleanup] [--prune]
#   3. From app/bundle directory: ../build.sh [--push] [--cleanup] [--prune]
#   4. From app/bundle directory: ../../build.sh [--push] [--cleanup] [--prune]
#   5. Build all: ./build.sh --all [--push] [--cleanup] [--prune]
#
# Options:
#   --push         Build and push multi-platform images to registry
#   --cleanup      Remove images and buildx cache before building
#   --prune        Prune the build cache of the builder this build uses (with
#                  --push: multiplatform-builder) first, so every layer is
#                  rebuilt and uploaded fresh. Fixes pushes failing with
#                  "unknown: blob sha256:... not found"
#   --all          Build all apps/bundles found in apps/ and bundles/ directories
#   --tag <tag>    Push/build a single explicit tag instead of the default
#                  ":<DATE>" + ":latest" pair (e.g. --tag 2025.11.20)
#   --skip-new-disk-check  Push to UAT or prod without a new-disk pass (below)
#
# New-disk gate: build-uat.sh and build-prod.sh set NEW_DISK_GATE=1. With it and
# --push, every app about to be pushed must have passed
# tests/new-disk-start.test.sh on its current source (it starts the app the way
# a cluster starts a new install, lib/new-disk-passes.sh keeps the record), or
# nothing is built or pushed. --skip-new-disk-check overrides that, and says so.
#
# Examples:
#   ./build.sh gibbon                      # Build Gibbon multi-platform images locally (amd64 + arm64)
#   ./build.sh gibbon --push               # Build and push Gibbon multi-platform images to registry
#   ./build.sh gibbon --cleanup            # Remove Gibbon images, then build multi-platform locally
#   ./build.sh gibbon --cleanup --push     # Remove Gibbon images, then build and push multi-platform
#   ./build.sh gibbon --push --tag 2025.11.20  # Build and push ONLY the :2025.11.20 tag (no :latest/:DATE)
#   ./build.sh gibbon --push --prune       # Rebuild Gibbon from scratch and upload every layer fresh
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
    echo "Usage: $0 <app-or-bundle-name> [--push] [--cleanup] [--prune] [--tag <tag>]"
    echo "       $0 <relative-path> [--push] [--cleanup] [--prune] [--tag <tag>]"
    echo "       $0 --all [--push] [--cleanup] [--prune] [--tag <tag>]"
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
    echo "  --prune        Prune the build cache of the builder this build uses first, so every"
    echo "                 layer is rebuilt and uploaded fresh (fixes 'blob ... not found' pushes)"
    echo "  --all          Build all apps/bundles found in apps/ and bundles/ directories"
    echo "  --tag <tag>    Push/build a single explicit tag instead of :<DATE> + :latest"
    echo "  --skip-new-disk-check  With build-uat.sh/build-prod.sh: push without a new-disk pass"
    echo ""
    echo "Examples:"
    echo "  $0 gibbon                      # Build Gibbon multi-platform images locally"
    echo "  $0 gibbon --push               # Build and push Gibbon multi-platform images"
    echo "  $0 gibbon --cleanup            # Remove Gibbon images, then build multi-platform locally"
    echo "  $0 gibbon --cleanup --push     # Remove Gibbon images, then build and push multi-platform"
    echo "  $0 gibbon --push --prune       # Rebuild Gibbon from scratch and upload every layer fresh"
    echo "  $0 gibbon --push --tag 2025.11.20  # Build and push ONLY the :2025.11.20 tag"
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
                    local var_prefix=$(echo "$container_dir" | tr '[:lower:]-' '[:upper:]_')
                    local var_name="${var_prefix}_IMAGE"
                    local image_name="${!var_name}"

                    if [ -n "$image_name" ]; then
                        images+=("$IMAGE_REGISTRY/$image_name")
                    fi
                done

                # Reset all variables for next iteration
                # Get all variables that end with _IMAGE, _NAME, or _CONTEXT
                for var in $(compgen -v | grep -E '_(IMAGE|NAME|CONTEXT)$'); do
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
            local var_prefix=$(echo "$container_dir" | tr '[:lower:]-' '[:upper:]_')
            local var_name="${var_prefix}_IMAGE"
            local image_name="${!var_name}"

            if [ -n "$image_name" ]; then
                images+=("$IMAGE_REGISTRY/$image_name")
            fi
        done

        # Reset all variables
        for var in $(compgen -v | grep -E '_(IMAGE|NAME|CONTEXT)$'); do
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
# Helper function to name the buildx builder this build uses
# ============================================================================
# - Push builds need multi-platform output, so they use the docker-container
#   driver (created on first use as "multiplatform-builder").
# - Local builds (--load) only need the host platform, so they use the default
#   docker driver. Crucially, the default driver shares its image cache with
#   the host daemon, which is required when one of our Dockerfiles uses
#   FROM <local-image> — locally-built images only exist in the host
#   daemon's cache, not in the docker-container driver's isolated cache.
#   The "default" builder is hard-bound to the "default" context and errors
#   out if the user is on Docker Desktop's "desktop-linux" context (or any
#   other), so we pick the builder bound to the *current* context.
resolve_builder_name() {
    if [ "$PUSH_IMAGES" = true ]; then
        echo "multiplatform-builder"
        return 0
    fi
    local current_context
    current_context="$(docker context show 2>/dev/null || echo default)"
    if docker buildx inspect "$current_context" &> /dev/null; then
        echo "$current_context"
    else
        echo "default"
    fi
}

# ============================================================================
# Helper function to prune a buildx builder's cache (--prune)
# ============================================================================
# Drops every cache record, so the next build starts from scratch. It also
# drops BuildKit's memory of which registry repositories already hold each
# layer. With that memory a push asks the registry to mount a layer from one
# of those repositories instead of uploading it, and Harbor rejects the mount
# ("unknown: blob sha256:... not found") when its database was recreated but
# its storage kept the old repositories (e.g. a rebuilt kind cluster).
prune_builder_cache() {
    local builder="$1"
    echo "Pruning build cache of buildx builder '$builder'..."
    if docker buildx prune --builder "$builder" --all --force; then
        echo "✓ Build cache of '$builder' pruned; every layer will be rebuilt"
        return 0
    fi
    echo "✗ Failed to prune build cache of '$builder'"
    return 1
}

# ============================================================================
# The new-disk gate (build-uat.sh and build-prod.sh turn it on)
# ============================================================================
# new_disk_gate TARGET_DIR...: with NEW_DISK_GATE=1 and --push, stops the whole
# push, before any docker call, unless every app has a new-disk pass for its
# current source. lib/new-disk-passes.sh is read here and only here, so a copy
# of this script without lib/ still builds when the gate is off.
new_disk_gate() {
    local dir name missing=0
    if [ "${NEW_DISK_GATE:-}" != 1 ] || [ "$PUSH_IMAGES" != true ]; then
        return 0
    fi
    if [ "$SKIP_NEW_DISK_CHECK" = true ]; then
        echo "⚠ Pushing without the new-disk check (--skip-new-disk-check)"
        return 0
    fi
    if [ ! -f "$SCRIPT_DIR/lib/new-disk-passes.sh" ]; then
        echo "✗ $SCRIPT_DIR/lib/new-disk-passes.sh is missing, so the new-disk check can't run"
        echo "  (or push anyway with --skip-new-disk-check)"
        exit 1
    fi
    # shellcheck source=lib/new-disk-passes.sh
    . "$SCRIPT_DIR/lib/new-disk-passes.sh"
    for dir in "$@"; do
        name="$(basename "$dir")"
        if ! nd_has_pass "$name" "$dir"; then
            echo "✗ $name: no new-disk pass for its current source. Run: bash tests/new-disk-start.test.sh $name"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        echo "  (or push anyway with --skip-new-disk-check)"
        exit 1
    fi
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
PRUNE=false
CUSTOM_TAG=""
SKIP_NEW_DISK_CHECK=false

# Check if first argument is --all or --cleanup
if [ "$1" = "--all" ]; then
    BUILD_ALL=true
    shift
elif [ "$1" = "--cleanup" ] || [ "$1" = "--prune" ]; then
    # --cleanup / --prune cannot be used as the first argument alone
    echo "Error: $1 must be used with an app/bundle name or --all"
    echo ""
    echo "Examples:"
    if [ "$1" = "--cleanup" ]; then
        echo "  $0 gibbon --cleanup            # Remove Gibbon images, then build"
        echo "  $0 --all --cleanup             # Remove all images, then build all apps/bundles"
    else
        echo "  $0 gibbon --push --prune       # Prune the push builder's cache, then build and push Gibbon"
        echo "  $0 --all --push --prune        # Prune it once, then build and push all apps/bundles"
    fi
    echo ""
    show_usage
    exit 1
elif [ "${1:0:2}" != "--" ]; then
    # Check if the argument contains a path separator (path mode)
    if [[ "$1" == *"/"* ]]; then
        # Path mode: resolve as absolute, then relative to the current
        # working directory, then relative to the script directory. This
        # lets the script be invoked from anywhere with a path like
        # `./magneto/apps/gibbon` or an absolute path.
        if [[ "$1" == /* ]]; then
            TARGET_DIR="$1"
        elif [ -d "$1/image" ]; then
            TARGET_DIR="$(cd "$1" && pwd)"
        else
            TARGET_DIR="$SCRIPT_DIR/$1"
        fi
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
# Use a while loop (not for-in) so flags that take a value, like
# `--tag <value>`, can consume the following token with an extra shift.
while [ $# -gt 0 ]; do
    case "$1" in
        --push)
            PUSH_IMAGES=true
            ;;
        --cleanup)
            CLEANUP=true
            ;;
        --prune)
            PRUNE=true
            ;;
        --skip-new-disk-check)
            SKIP_NEW_DISK_CHECK=true
            ;;
        --tag)
            # Require a value, and reject the next token if it is another
            # flag (or missing) — tags never start with "--".
            if [ -z "${2:-}" ] || [ "${2:0:2}" = "--" ]; then
                echo "Error: --tag requires a value (e.g. --tag 2025.11.20)"
                echo ""
                show_usage
                exit 1
            fi
            CUSTOM_TAG="$2"
            shift
            ;;
        --tag=*)
            CUSTOM_TAG="${1#--tag=}"
            if [ -z "$CUSTOM_TAG" ]; then
                echo "Error: --tag requires a value (e.g. --tag=2025.11.20)"
                echo ""
                show_usage
                exit 1
            fi
            ;;
        --all)
            echo "Error: --all must be the first argument"
            echo ""
            show_usage
            exit 1
            ;;
        *)
            echo "Unknown argument: $1"
            echo ""
            show_usage
            exit 1
            ;;
    esac
    shift
done

# If --all mode, build all targets
if [ "$BUILD_ALL" = true ]; then
    echo "============================================================================"
    echo "Building all applications and bundles"
    echo "============================================================================"
    echo ""

    # The new-disk gate checks every app before anything is cleaned, pruned or built.
    GATE_DIRS=()
    for target in $(discover_targets); do
        GATE_DIRS+=("$SCRIPT_DIR/$target")
    done
    new_disk_gate ${GATE_DIRS[@]+"${GATE_DIRS[@]}"}

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

    # Prune the builder's cache once here, not once per target
    if [ "$PRUNE" = true ]; then
        PRUNE_BUILDER="$(resolve_builder_name)"
        if docker buildx inspect "$PRUNE_BUILDER" &> /dev/null; then
            if ! prune_builder_cache "$PRUNE_BUILDER"; then
                exit 1
            fi
        else
            echo "⊘ Builder '$PRUNE_BUILDER' does not exist yet; nothing to prune"
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
        # Note: Don't pass --cleanup or --prune to recursive calls since we already did them
        BUILD_CMD="$0 $target"
        if [ "$PUSH_IMAGES" = true ]; then
            BUILD_CMD="$BUILD_CMD --push"
        fi
        if [ "$SKIP_NEW_DISK_CHECK" = true ]; then
            BUILD_CMD="$BUILD_CMD --skip-new-disk-check"
        fi
        if [ -n "$CUSTOM_TAG" ]; then
            BUILD_CMD="$BUILD_CMD --tag $CUSTOM_TAG"
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

# The new-disk gate, before any docker call for this target.
new_disk_gate "$TARGET_DIR"

# ============================================================================
# Configure global variables
# ============================================================================
# Allow IMAGE_REGISTRY to be overridden via REGISTRY environment variable
IMAGE_REGISTRY="${REGISTRY:-r.clv.zone/e2eorg}"

DATE_TAG=$(date +%Y.%m.%d)
PLATFORMS="linux/amd64,linux/arm64"
LOCAL_PLATFORM="linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"

# ============================================================================
# Tag selection helpers
# ============================================================================
# Default behavior tags two refs per image: ":<DATE>" and the bare ":latest".
# When --tag <value> is supplied it overrides both with a single explicit tag.
#
# tag_args_for populates the TAG_ARGS array with the docker buildx --tag flags
# for a given base image reference (registry/repo, no tag).
tag_args_for() {
    local base="$1"
    TAG_ARGS=()
    if [ -n "$CUSTOM_TAG" ]; then
        TAG_ARGS+=(--tag "$base:$CUSTOM_TAG")
    else
        TAG_ARGS+=(--tag "$base:$DATE_TAG")
        TAG_ARGS+=(--tag "$base")
    fi
}

# print_tags_for echoes the same tags as human-readable summary lines.
print_tags_for() {
    local base="$1"
    if [ -n "$CUSTOM_TAG" ]; then
        echo "  - $base:$CUSTOM_TAG"
    else
        echo "  - $base:$DATE_TAG"
        echo "  - $base"
    fi
}

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
    var_prefix=$(echo "$container_dir" | tr '[:lower:]-' '[:upper:]_')
    image_var="${var_prefix}_IMAGE"
    name_var="${var_prefix}_NAME"
    context_var="${var_prefix}_CONTEXT"

    # Get the values of these variables
    image_value="${!image_var}"
    name_value="${!name_var}"
    # Optional: per-container build context override (path relative to the
    # app/bundle directory). If unset, the container's own subdirectory is
    # used as the docker build context (the original default).
    context_value="${!context_var:-}"

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
        CONTAINER_CONFIGS+=("$container_dir:$image_value:$name_value:$context_value")
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

# Pick the builder based on whether we're pushing (see resolve_builder_name).
BUILDX_BUILDER="$(resolve_builder_name)"
if [ "$PUSH_IMAGES" = true ] && ! docker buildx inspect "$BUILDX_BUILDER" &> /dev/null; then
    echo "Creating buildx builder '$BUILDX_BUILDER' with docker-container driver..."
    docker buildx create --name "$BUILDX_BUILDER" --driver docker-container --bootstrap
fi
docker buildx use "$BUILDX_BUILDER"

if [ "$PRUNE" = true ]; then
    if ! prune_builder_cache "$BUILDX_BUILDER"; then
        exit 1
    fi
    echo ""
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
    IFS=':' read -r container_dir image_name display_name context_value <<< "$config"

    if [ ! -f "$container_dir/Dockerfile" ]; then
        var_prefix=$(echo "$container_dir" | tr '[:lower:]-' '[:upper:]_')
        echo "✗ Error: Dockerfile not found for '$container_dir' container"
        echo "  Expected location: $APP_IMAGE_DIR/$container_dir/Dockerfile"
        echo "  Note: ${var_prefix}_IMAGE and ${var_prefix}_NAME are configured, so a Dockerfile is required."
        exit 1
    fi

    # Validate that any context override resolves to an existing directory.
    if [ -n "$context_value" ] && [ ! -d "$TARGET_DIR/$context_value" ]; then
        var_prefix=$(echo "$container_dir" | tr '[:lower:]-' '[:upper:]_')
        echo "✗ Error: ${var_prefix}_CONTEXT='$context_value' does not resolve to a directory"
        echo "  Expected location: $TARGET_DIR/$context_value"
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
# Optional pre/post-build hooks
# ============================================================================
# A target may include image/prebuild.sh to stage extra files into the build
# context (e.g. ai-studio bakes the repo-root /context tree into image/context-bundled/),
# and image/postbuild.sh to clean up afterwards. The cleanup runs on EXIT so
# it fires whether the build succeeds or fails.
if [ -f "$APP_IMAGE_DIR/prebuild.sh" ]; then
    echo "Running prebuild hook: $APP_IMAGE_DIR/prebuild.sh"
    bash "$APP_IMAGE_DIR/prebuild.sh"
    echo ""
fi
if [ -f "$APP_IMAGE_DIR/postbuild.sh" ]; then
    trap 'bash "$APP_IMAGE_DIR/postbuild.sh" >/dev/null 2>&1 || true' EXIT
fi

# ============================================================================
# STEP 1: Build application image from Dockerfile
# ============================================================================
TOTAL_STEPS=$((1 + ${#CONTAINER_CONFIGS[@]}))

echo "Step 1/$TOTAL_STEPS: Building $DISPLAY_NAME image from Dockerfile for platforms: $PLATFORMS..."
tag_args_for "$IMAGE_REGISTRY/$APP_IMAGE"
if [ "$PUSH_IMAGES" = true ]; then
    echo "Building and pushing multi-platform image..."
    if docker buildx build \
        --platform "$PLATFORMS" \
        "${TAG_ARGS[@]}" \
        --provenance=false \
        --push \
        .; then
        echo "✓ $DISPLAY_NAME multi-platform image built and pushed successfully!"
    else
        echo "✗ Failed to build and push $DISPLAY_NAME Docker image"
        exit 1
    fi
else
    echo "Building image for local platform ($LOCAL_PLATFORM) and loading into Docker..."
    if docker buildx build \
        --platform "$LOCAL_PLATFORM" \
        "${TAG_ARGS[@]}" \
        --provenance=false \
        --load \
        .; then
        echo "✓ $DISPLAY_NAME image built and loaded into Docker successfully!"
        echo "  Note: Built for local platform ($LOCAL_PLATFORM) only. Use --push for multi-platform (amd64 + arm64)."
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
        IFS=':' read -r container_dir image_name display_name context_value <<< "$config"

        # Resolve the docker build context. Default: container subdirectory
        # under image/ (e.g. mysql/, postgres/). Override: <PREFIX>_CONTEXT
        # in build.config — a path relative to the app/bundle directory,
        # used when a sub-container needs to COPY files from outside its
        # own subdirectory.
        if [ -n "$context_value" ]; then
            build_context="$TARGET_DIR/$context_value"
            dockerfile_args=(--file "$APP_IMAGE_DIR/$container_dir/Dockerfile")
        else
            build_context="$container_dir/"
            dockerfile_args=()
        fi

        echo "Step $STEP_NUM/$TOTAL_STEPS: Building $display_name image from Dockerfile for platforms: $PLATFORMS..."
        tag_args_for "$IMAGE_REGISTRY/$image_name"

        if [ "$PUSH_IMAGES" = true ]; then
            echo "Building and pushing multi-platform $display_name image..."
            if docker buildx build \
                --platform "$PLATFORMS" \
                "${TAG_ARGS[@]}" \
                --provenance=false \
                --push \
                "${dockerfile_args[@]}" \
                "$build_context"; then
                echo "✓ $display_name multi-platform image built and pushed successfully!"
            else
                echo "✗ Failed to build and push $display_name Docker image"
                exit 1
            fi
        else
            echo "Building $display_name image for local platform ($LOCAL_PLATFORM) and loading into Docker..."
            if docker buildx build \
                --platform "$LOCAL_PLATFORM" \
                "${TAG_ARGS[@]}" \
                --provenance=false \
                --load \
                "${dockerfile_args[@]}" \
                "$build_context"; then
                echo "✓ $display_name image built and loaded into Docker successfully!"
                echo "  Note: Built for local platform ($LOCAL_PLATFORM) only. Use --push for multi-platform (amd64 + arm64)."
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
    echo "✓ All images built and loaded into Docker successfully!"
fi
echo "============================================================================"
echo ""
if [ "$PUSH_IMAGES" = true ]; then
    echo "$DISPLAY_NAME Image Tags (Platforms: $PLATFORMS):"
else
    echo "$DISPLAY_NAME Image Tags (Platform: $LOCAL_PLATFORM):"
fi
print_tags_for "$IMAGE_REGISTRY/$APP_IMAGE"
echo ""

# Show all container image tags
for config in "${CONTAINER_CONFIGS[@]}"; do
    IFS=':' read -r container_dir image_name display_name context_value <<< "$config"

    if [ "$PUSH_IMAGES" = true ]; then
        echo "$display_name Image Tags (Platforms: $PLATFORMS):"
    else
        echo "$display_name Image Tags (Platform: $LOCAL_PLATFORM):"
    fi
    print_tags_for "$IMAGE_REGISTRY/$image_name"
    echo ""
done

# ============================================================================
# Final instructions
# ============================================================================
if [ "$PUSH_IMAGES" = false ]; then
    echo "To push multi-platform images to registry, run:"
    echo "  $0 $DISPLAY_NAME --push"
    echo ""
fi

