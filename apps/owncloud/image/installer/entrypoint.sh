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

# Root's reads and writes on the data volume, which belongs to www-data: safe_read and safe_write never follow a link
# there, and never wait on a pipe (tests/owncloud-domain-marker.test.sh).
# shellcheck source-path=SCRIPTDIR source=root-paths.sh
. /clouve/app/installer/root-paths.sh
# reap_www_data: ends every process of www-data's that occ left running (www-data.sh).
# shellcheck source-path=SCRIPTDIR source=www-data.sh
. /clouve/app/installer/www-data.sh

# looks_like_host TEXT: TEXT is a host name, with a port or without (letters, digits, dots and hyphens, then :port).
# The marker's old domain goes to the log only then: the volume is www-data's, so the marker may hold anything.
looks_like_host() {
    [[ ${#1} -le 259 && "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]
}

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

    # Read the previously stored domain from the marker file: only a regular file, never through a link, at most 300
    # bytes, and only a host name counts. Anything else there is named in the log, and its contents never are.
    PREVIOUS_DOMAIN=""
    if [ -e "$DOMAIN_MARKER" ] || [ -L "$DOMAIN_MARKER" ]; then
        if MARKER_TEXT="$(safe_read "$DOMAIN_MARKER" 300)"; then
            if [ "$MARKER_TEXT" = "$OWNCLOUD_DOMAIN" ] || looks_like_host "$MARKER_TEXT"; then
                PREVIOUS_DOMAIN="$MARKER_TEXT"
                echo -e "${YELLOW}[INFO]${NC} Previous domain from marker: $PREVIOUS_DOMAIN"
            else
                echo -e "${YELLOW}[WARNING]${NC} $DOMAIN_MARKER doesn't hold a host name, so it is ignored"
            fi
        else
            echo -e "${YELLOW}[WARNING]${NC} $DOMAIN_MARKER is a link or not a regular file, so it is ignored"
        fi
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
            env -u CLOUVE_OPS_PASSWORD /usr/bin/occ config:system:set overwrite.cli.url --value="http://$OWNCLOUD_DOMAIN" 2>&1 || true

            # Update trusted domains
            # First, get the current trusted domains and check if we need to add the new one
            echo -e "${YELLOW}[INFO]${NC} Updating trusted domains..."

            # Extract just the hostname part (without port) for trusted domains
            NEW_DOMAIN_HOST=$(echo "$OWNCLOUD_DOMAIN" | cut -d':' -f1)

            # Set trusted domain at index 0 (the primary domain)
            env -u CLOUVE_OPS_PASSWORD /usr/bin/occ config:system:set trusted_domains 0 --value="$NEW_DOMAIN_HOST" 2>&1 || true

            # Also set the full domain with port at index 1
            env -u CLOUVE_OPS_PASSWORD /usr/bin/occ config:system:set trusted_domains 1 --value="$OWNCLOUD_DOMAIN" 2>&1 || true
            # occ ran the apps' code as www-data: nothing of it may still run when root goes on with the volume, and a
            # reap that can't make sure stops the start.
            reap_www_data "the domain update" || exit 1

            echo -e "${GREEN}[SUCCESS]${NC} ownCloud domain updated successfully!"
        else
            echo -e "${YELLOW}[WARNING]${NC} occ command not found, skipping domain update"
        fi
    else
        echo -e "${GREEN}[INFO]${NC} OWNCLOUD_DOMAIN unchanged: $OWNCLOUD_DOMAIN"
    fi

    # Always update the domain marker file with the current domain: into a new file that replaces whatever is there,
    # a link included, without following it (safe_write). First, what a start cut off before the rename left.
    clear_temp_files "$OWNCLOUD_DATA_DIR" .owncloud_domain
    safe_write "$DOMAIN_MARKER" "$OWNCLOUD_DOMAIN"
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

