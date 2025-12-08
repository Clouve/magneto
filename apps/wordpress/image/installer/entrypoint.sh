#!/bin/bash

# WordPress Docker Entrypoint Wrapper Script
# This script wraps the official WordPress entrypoint with Clouve-specific initialization:
# 1. Extracts WordPress files from the base image (via original entrypoint)
# 2. Waits for the database to be ready
# 3. Installs WordPress if not already installed (using wp-cli)
# 4. Configures WordPress options
# 5. Starts Apache
#
# Note: We don't modify the official image's entrypoint - it remains at its original location.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Path to the original WordPress entrypoint (from the official image)
ORIGINAL_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

# WordPress installation directory
WP_DIR="/var/www/html"

# Set error handling - don't exit on error, just log it
set +e

# ============================================================================
# STEP 1: Extract WordPress files from the base image
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Running WordPress entrypoint to extract files..."

# Call the original WordPress docker-entrypoint.sh at its original location (untouched)
# This extracts WordPress files and generates wp-config.php
if [ -f "$ORIGINAL_ENTRYPOINT" ]; then
    "$ORIGINAL_ENTRYPOINT" apache2-foreground &
    WORDPRESS_PID=$!

    # Give WordPress entrypoint time to extract files
    sleep 5

    # Kill the background process (we'll start Apache properly later)
    kill $WORDPRESS_PID 2>/dev/null || true
    wait $WORDPRESS_PID 2>/dev/null || true

    echo -e "${GREEN}[SUCCESS]${NC} WordPress files extracted successfully"
else
    echo -e "${RED}[WARNING]${NC} Original WordPress entrypoint not found at $ORIGINAL_ENTRYPOINT"
fi

# ============================================================================
# STEP 2: Wait for database to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for database to be ready..."
max_attempts=60
attempt=0

# Extract host and port from WORDPRESS_DB_HOST
DB_HOST="${WORDPRESS_DB_HOST%%:*}"
DB_PORT="${WORDPRESS_DB_HOST##*:}"
if [ "$DB_PORT" = "$DB_HOST" ]; then
    DB_PORT="3306"
fi

# Try to connect using mysql client if available, otherwise use PHP
while [ $attempt -lt $max_attempts ]; do
    if command -v mysql &> /dev/null; then
        # Use mysql client if available
        if mysql -h "$DB_HOST" -P "$DB_PORT" -u "${WORDPRESS_DB_USER}" -p"${WORDPRESS_DB_PASSWORD}" -e "SELECT 1" > /dev/null 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} Database is ready!"
            break
        fi
    else
        # Use PHP as fallback
        if php -r "mysqli_connect('$DB_HOST', '${WORDPRESS_DB_USER}', '${WORDPRESS_DB_PASSWORD}', '${WORDPRESS_DB_NAME}', $DB_PORT);" > /dev/null 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} Database is ready!"
            break
        fi
    fi
    attempt=$((attempt + 1))
    echo -e "${YELLOW}[WAIT]${NC} Database not ready yet... (attempt $attempt/$max_attempts)"
    sleep 5
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}[ERROR]${NC} Database failed to become ready after $max_attempts attempts"
    exit 1
fi

# Wait a bit more to ensure database is fully initialized
sleep 3

# ============================================================================
# STEP 3: Check if WordPress files exist
# ============================================================================

if [ ! -f "$WP_DIR/wp-load.php" ]; then
    echo -e "${RED}[ERROR]${NC} WordPress files not found in $WP_DIR"
    exit 1
fi

# ============================================================================
# STEP 4: Check if WordPress is already installed
# ============================================================================

# Check if WordPress is already installed by checking for wp_options table
WORDPRESS_INSTALLED=false
if command -v mysql &> /dev/null; then
    if mysql -h "$DB_HOST" -P "$DB_PORT" -u "${WORDPRESS_DB_USER}" -p"${WORDPRESS_DB_PASSWORD}" "${WORDPRESS_DB_NAME}" -e "SELECT 1 FROM wp_options LIMIT 1" > /dev/null 2>&1; then
        WORDPRESS_INSTALLED=true
        echo -e "${GREEN}[INFO]${NC} WordPress appears to be already installed."
    fi
fi

# ============================================================================
# STEP 4a: Update WordPress URL if it has changed (for existing installations)
# ============================================================================

if [ "$WORDPRESS_INSTALLED" = true ] && [ -n "$WORDPRESS_SITE_URL" ]; then
    echo -e "${YELLOW}[INFO]${NC} Checking if WordPress site URL needs to be updated..."

    # Change to WordPress directory
    cd "$WP_DIR" || exit 1

    # Get current siteurl from database
    CURRENT_SITEURL=$(wp option get siteurl --allow-root 2>/dev/null || echo "")
    CURRENT_HOME=$(wp option get home --allow-root 2>/dev/null || echo "")

    # Check if URL has changed
    if [ "$CURRENT_SITEURL" != "$WORDPRESS_SITE_URL" ] || [ "$CURRENT_HOME" != "$WORDPRESS_SITE_URL" ]; then
        echo -e "${YELLOW}[INFO]${NC} WordPress URL has changed:"
        echo -e "${YELLOW}[INFO]${NC}   Current siteurl: $CURRENT_SITEURL"
        echo -e "${YELLOW}[INFO]${NC}   Current home: $CURRENT_HOME"
        echo -e "${YELLOW}[INFO]${NC}   New URL: $WORDPRESS_SITE_URL"
        echo -e "${YELLOW}[INFO]${NC} Updating WordPress URLs in database..."

        # Update siteurl and home options
        if wp option update siteurl "$WORDPRESS_SITE_URL" --allow-root 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} Updated 'siteurl' to $WORDPRESS_SITE_URL"
        else
            echo -e "${RED}[WARNING]${NC} Failed to update 'siteurl'"
        fi

        if wp option update home "$WORDPRESS_SITE_URL" --allow-root 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} Updated 'home' to $WORDPRESS_SITE_URL"
        else
            echo -e "${RED}[WARNING]${NC} Failed to update 'home'"
        fi

        # Flush rewrite rules to ensure permalinks work with new URL
        wp rewrite flush --hard --allow-root 2>/dev/null || true

        echo -e "${GREEN}[SUCCESS]${NC} WordPress URL update completed!"
    else
        echo -e "${GREEN}[INFO]${NC} WordPress URL is already up to date: $WORDPRESS_SITE_URL"
    fi

    # WordPress is installed and URL is updated, start Apache
    echo -e "${GREEN}[SUCCESS]${NC} WordPress is ready to use!"
    echo -e "${GREEN}[INFO]${NC} Access WordPress at: ${WORDPRESS_SITE_URL}"
    echo -e "${GREEN}[INFO]${NC} Starting Apache..."
    exec apache2-foreground
fi

# ============================================================================
# STEP 5: Install WordPress
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Starting WordPress automatic installation..."

# Change to WordPress directory
cd "$WP_DIR" || exit 1

# wp-cli should already be installed in the Dockerfile
if ! command -v wp &> /dev/null; then
    echo -e "${RED}[ERROR]${NC} wp-cli is not available"
    exit 1
fi

# Run wp-cli core install command with --allow-root flag
echo -e "${YELLOW}[INFO]${NC} Running wp core install..."
if wp core install \
    --url="${WORDPRESS_SITE_URL}" \
    --title="${WORDPRESS_SITE_TITLE}" \
    --admin_user="${WORDPRESS_ADMIN_USER}" \
    --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
    --admin_email="${WORDPRESS_ADMIN_EMAIL}" \
    --skip-email \
    --allow-root 2>&1; then
    echo -e "${GREEN}[SUCCESS]${NC} WordPress installation completed successfully!"
else
    INSTALL_EXIT_CODE=$?
    echo -e "${RED}[ERROR]${NC} WordPress installation failed with exit code $INSTALL_EXIT_CODE"
fi

# ============================================================================
# STEP 6: Configure WordPress options
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Configuring WordPress options..."
wp option update timezone_string "UTC" --allow-root 2>/dev/null || true
wp rewrite structure '/%postname%/' --hard --allow-root 2>/dev/null || true
wp rewrite flush --hard --allow-root 2>/dev/null || true

# ============================================================================
# STEP 7: Start Apache
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} WordPress is now ready to use!"
echo -e "${GREEN}[INFO]${NC} Access WordPress at: ${WORDPRESS_SITE_URL}"
echo -e "${GREEN}[INFO]${NC} Admin username: ${WORDPRESS_ADMIN_USER}"
echo -e "${GREEN}[INFO]${NC} Admin email: ${WORDPRESS_ADMIN_EMAIL}"

echo -e "${YELLOW}[INFO]${NC} Starting Apache..."
exec apache2-foreground

