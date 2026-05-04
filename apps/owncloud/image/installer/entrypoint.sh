#!/bin/bash

# ownCloud Docker Entrypoint Wrapper Script
# This script wraps the official ownCloud entrypoint with Clouve-specific initialization:
# 1. Calls the original ownCloud entrypoint to set up the environment
# 2. Waits for the database to be ready
# 3. Runs ownCloud installation if not already installed
# 4. Detects and handles URL changes for existing installations
# 5. Starts the ownCloud server
#
# Note: We don't modify the official image's entrypoint - it remains at its original location.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Path to the original ownCloud entrypoint (from the official image)
ORIGINAL_ENTRYPOINT="/usr/bin/entrypoint"

# ownCloud data directory
OWNCLOUD_DATA_DIR="/mnt/data"

# ownCloud installation path
OWNCLOUD_INSTALL_PATH="/var/www/owncloud"

# Marker file to track the last known domain
DOMAIN_MARKER="$OWNCLOUD_DATA_DIR/.owncloud_domain"

# Set error handling
set -e

echo -e "${YELLOW}[INFO]${NC} Starting ownCloud initialization..."

# ============================================================================
# STEP 1: Wait for database to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for database to be ready..."
max_attempts=60
attempt=0

# Extract database host from OWNCLOUD_DB_HOST
DB_HOST="${OWNCLOUD_DB_HOST:-owncloud-mariadb}"

# Wait for database to be accessible
while [ $attempt -lt $max_attempts ]; do
    if mysqladmin ping -h "$DB_HOST" --silent 2>/dev/null; then
        echo -e "${GREEN}[SUCCESS]${NC} Database is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo -e "${YELLOW}[WAIT]${NC} Database not ready yet... (attempt $attempt/$max_attempts)"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}[ERROR]${NC} Database failed to become ready after $max_attempts attempts"
    exit 1
fi

# Wait a bit more to ensure database is fully initialized
sleep 3

# ============================================================================
# STEP 2: Check if ownCloud is already installed
# ============================================================================

# The official ownCloud image uses /mnt/data/config/config.php to determine if installed
if [ -f "$OWNCLOUD_DATA_DIR/config/config.php" ]; then
    echo -e "${GREEN}[INFO]${NC} ownCloud appears to be already installed."
    OWNCLOUD_INSTALLED=true
else
    echo -e "${YELLOW}[INFO]${NC} ownCloud not yet installed. Automatic installation will be handled by the official entrypoint."
    OWNCLOUD_INSTALLED=false
fi

# ============================================================================
# STEP 3: Check and update domain if changed (for existing installations)
# ============================================================================

if [ "$OWNCLOUD_INSTALLED" = true ] && [ -n "$OWNCLOUD_DOMAIN" ]; then
    echo -e "${YELLOW}[INFO]${NC} Checking if OWNCLOUD_DOMAIN has changed..."

    # Read the previously stored domain from the marker file
    PREVIOUS_DOMAIN=""
    if [ -f "$DOMAIN_MARKER" ]; then
        PREVIOUS_DOMAIN=$(cat "$DOMAIN_MARKER" 2>/dev/null || echo "")
        echo -e "${YELLOW}[INFO]${NC} Previous domain from marker: $PREVIOUS_DOMAIN"
    else
        echo -e "${YELLOW}[INFO]${NC} No domain marker file found (first run after initialization)"
    fi

    echo -e "${YELLOW}[INFO]${NC} Current OWNCLOUD_DOMAIN: $OWNCLOUD_DOMAIN"

    # Check if domain has changed
    if [ -n "$PREVIOUS_DOMAIN" ] && [ "$PREVIOUS_DOMAIN" != "$OWNCLOUD_DOMAIN" ]; then
        echo -e "${YELLOW}[INFO]${NC} URL has changed!"
        echo -e "${YELLOW}[INFO]${NC}   Old domain: $PREVIOUS_DOMAIN"
        echo -e "${YELLOW}[INFO]${NC}   New domain: $OWNCLOUD_DOMAIN"
        echo -e "${YELLOW}[INFO]${NC} Updating ownCloud configuration..."

        # Update the overwrite.cli.url in config.php using occ command
        # The official ownCloud image provides the occ command at /usr/bin/occ
        if [ -f "/usr/bin/occ" ]; then
            # Set the overwrite.cli.url to the new domain
            # This is the URL that ownCloud will use for CLI operations and redirects
            echo -e "${YELLOW}[INFO]${NC} Updating overwrite.cli.url..."
            /usr/bin/occ config:system:set overwrite.cli.url --value="http://$OWNCLOUD_DOMAIN" 2>&1 || true

            # Update trusted domains
            # First, get the current trusted domains and check if we need to add the new one
            echo -e "${YELLOW}[INFO]${NC} Updating trusted domains..."

            # Extract just the hostname part (without port) for trusted domains
            NEW_DOMAIN_HOST=$(echo "$OWNCLOUD_DOMAIN" | cut -d':' -f1)

            # Set trusted domain at index 0 (the primary domain)
            /usr/bin/occ config:system:set trusted_domains 0 --value="$NEW_DOMAIN_HOST" 2>&1 || true

            # Also set the full domain with port at index 1
            /usr/bin/occ config:system:set trusted_domains 1 --value="$OWNCLOUD_DOMAIN" 2>&1 || true

            echo -e "${GREEN}[SUCCESS]${NC} ownCloud domain updated successfully!"
        else
            echo -e "${YELLOW}[WARNING]${NC} occ command not found, skipping domain update"
        fi
    else
        echo -e "${GREEN}[INFO]${NC} OWNCLOUD_DOMAIN unchanged: $OWNCLOUD_DOMAIN"
    fi

    # Always update the domain marker file with the current domain
    echo "$OWNCLOUD_DOMAIN" > "$DOMAIN_MARKER"
    echo -e "${YELLOW}[INFO]${NC} Updated domain marker file"
else
    echo -e "${YELLOW}[INFO]${NC} Skipping domain update check (first-time installation or OWNCLOUD_DOMAIN not set)"
fi

# ============================================================================
# STEP 4: Display configuration information
# ============================================================================

echo -e "${GREEN}[INFO]${NC} ownCloud Configuration:"
echo -e "${GREEN}[INFO]${NC}   Domain: ${OWNCLOUD_DOMAIN:-localhost:8080}"
echo -e "${GREEN}[INFO]${NC}   Admin User: ${OWNCLOUD_ADMIN_USERNAME:-admin}"
echo -e "${GREEN}[INFO]${NC}   Database Host: ${OWNCLOUD_DB_HOST:-owncloud-mariadb}"
echo -e "${GREEN}[INFO]${NC}   Database Name: ${OWNCLOUD_DB_NAME:-owncloud}"

# ============================================================================
# STEP 5: Call the original ownCloud entrypoint
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Starting ownCloud server via original entrypoint..."

# Call the original ownCloud entrypoint at its original location (untouched)
# This handles all the ownCloud-specific initialization including:
# - Setting up the ownCloud environment
# - Running automatic installation if needed
# - Starting the web server
if [ -f "$ORIGINAL_ENTRYPOINT" ]; then
    exec "$ORIGINAL_ENTRYPOINT" "$@"
else
    echo -e "${RED}[ERROR]${NC} Original ownCloud entrypoint not found at $ORIGINAL_ENTRYPOINT"
    exit 1
fi

