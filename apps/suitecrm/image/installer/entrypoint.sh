#!/bin/bash

# SuiteCRM 8 Docker Entrypoint Script
# This script handles the complete SuiteCRM initialization process:
# 1. Waits for MariaDB to be ready
# 2. Copies SuiteCRM files to the web root
# 3. Initializes SuiteCRM database if not already initialized
# 4. Starts Apache server

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set error handling
set -e

# SuiteCRM configuration
SUITECRM_PACKAGE_PATH="/clouve/suitecrm/app"
SUITECRM_INSTALL_PATH="/var/www/html"
SUITECRM_INSTALLER="/clouve/suitecrm/installer"
INSTALLED_MARKER="$SUITECRM_INSTALL_PATH/.suitecrm_initialized"

echo -e "${YELLOW}[INFO]${NC} Starting SuiteCRM initialization..."
echo -e "${YELLOW}[INFO]${NC} SuiteCRM version: ${SUITECRM_VERSION}"

# ============================================================================
# STEP 1: Wait for MariaDB to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for MariaDB to be ready..."

# Extract database connection details from environment variables
DB_HOST="${DATABASE_HOST:-suitecrm-mariadb}"
DB_PORT="${DATABASE_PORT:-3306}"
DB_USER="${DATABASE_USER:-suitecrm}"
DB_PASSWORD="${DATABASE_PASSWORD:-suitecrm}"
DB_NAME="${DATABASE_NAME:-suitecrm}"

max_attempts=60
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" --silent 2>/dev/null; then
        echo -e "${GREEN}[SUCCESS]${NC} MariaDB is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo -e "${YELLOW}[WAIT]${NC} MariaDB not ready yet... (attempt $attempt/$max_attempts)"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}[ERROR]${NC} MariaDB failed to become ready after $max_attempts attempts"
    exit 1
fi

# Wait a bit more to ensure MariaDB is fully initialized
sleep 3

# ============================================================================
# STEP 2: Copy SuiteCRM files to web root (if not already done)
# ============================================================================

if [ ! -f "$SUITECRM_INSTALL_PATH/public/index.php" ]; then
    echo -e "${YELLOW}[INFO]${NC} Copying SuiteCRM files to web root..."

    # Copy all files from the package to the install path (including hidden files)
    cp -r "$SUITECRM_PACKAGE_PATH"/* "$SUITECRM_INSTALL_PATH/"
    cp -r "$SUITECRM_PACKAGE_PATH"/.[!.]* "$SUITECRM_INSTALL_PATH/" 2>/dev/null || true

    # Set proper permissions
    chown -R www-data:www-data "$SUITECRM_INSTALL_PATH"
    chmod -R 755 "$SUITECRM_INSTALL_PATH"
    
    # Make specific directories writable
    chmod -R 775 "$SUITECRM_INSTALL_PATH/cache"
    chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/cache"
    chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/custom"
    chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/modules"
    chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/themes"
    chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/upload"
    
    echo -e "${GREEN}[SUCCESS]${NC} SuiteCRM files copied successfully!"
else
    echo -e "${GREEN}[INFO]${NC} SuiteCRM files already present in web root."
fi

# ============================================================================
# STEP 3: Check if SuiteCRM is already initialized
# ============================================================================

if [ -f "$INSTALLED_MARKER" ]; then
    echo -e "${GREEN}[INFO]${NC} SuiteCRM appears to be already initialized. Skipping installation."
    echo -e "${GREEN}[INFO]${NC} Marker file found: $INSTALLED_MARKER"

    # ============================================================================
    # STEP 3a: Update SUITECRM_URL if it has changed (for existing installations)
    # ============================================================================

    if [ -n "$SUITECRM_URL" ]; then
        echo -e "${YELLOW}[INFO]${NC} Checking if SUITECRM_URL has changed..."

        # Use a separate marker file to track the last known URL
        # This is more reliable than reading from .env.local which may not persist
        URL_MARKER="$SUITECRM_INSTALL_PATH/.suitecrm_url"

        # Read the previously stored URL from the marker file
        PREVIOUS_URL=""
        if [ -f "$URL_MARKER" ]; then
            PREVIOUS_URL=$(cat "$URL_MARKER" 2>/dev/null || echo "")
            echo -e "${YELLOW}[INFO]${NC} Previous URL from marker: $PREVIOUS_URL"
        else
            echo -e "${YELLOW}[INFO]${NC} No URL marker file found (first run after initialization)"
        fi

        echo -e "${YELLOW}[INFO]${NC} Current SUITECRM_URL: $SUITECRM_URL"

        # Check if URL has changed
        if [ -n "$PREVIOUS_URL" ] && [ "$PREVIOUS_URL" != "$SUITECRM_URL" ]; then
            echo -e "${YELLOW}[INFO]${NC} URL has changed!"
            echo -e "${YELLOW}[INFO]${NC}   Old URL: $PREVIOUS_URL"
            echo -e "${YELLOW}[INFO]${NC}   New URL: $SUITECRM_URL"

            # Update .env.local if it exists
            ENV_FILE="$SUITECRM_INSTALL_PATH/.env.local"
            if [ -f "$ENV_FILE" ]; then
                echo -e "${YELLOW}[INFO]${NC} Updating .env.local..."
                sed -i "s|^SITE_URL=.*|SITE_URL=$SUITECRM_URL|g" "$ENV_FILE"
                echo -e "${GREEN}[SUCCESS]${NC} SITE_URL updated in .env.local!"
            else
                echo -e "${YELLOW}[WARNING]${NC} .env.local not found at $ENV_FILE"
            fi

            # Update the database configuration
            echo -e "${YELLOW}[INFO]${NC} Updating SuiteCRM database configuration..."
            cd "$SUITECRM_INSTALL_PATH"

            # Update via SQL - SuiteCRM 8 stores the site URL in the config table
            mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
                -e "UPDATE config SET value = '$SUITECRM_URL' WHERE category = 'site' AND name = 'site_url';" 2>/dev/null || true

            # Also update in the legacy config if it exists
            LEGACY_CONFIG="$SUITECRM_INSTALL_PATH/public/legacy/config.php"
            if [ -f "$LEGACY_CONFIG" ]; then
                echo -e "${YELLOW}[INFO]${NC} Updating legacy config.php..."
                # Update site_url in legacy config.php
                # The config.php has a line like: 'site_url' => 'http://old.url',
                sed -i "s|'site_url'\s*=>\s*'[^']*'|'site_url' => '$SUITECRM_URL'|g" "$LEGACY_CONFIG"
                echo -e "${GREEN}[SUCCESS]${NC} Updated legacy config.php!"
            fi

            # Clear cache to ensure changes take effect
            echo -e "${YELLOW}[INFO]${NC} Clearing SuiteCRM cache..."
            rm -rf "$SUITECRM_INSTALL_PATH/cache/"* 2>/dev/null || true
            rm -rf "$SUITECRM_INSTALL_PATH/public/legacy/cache/"* 2>/dev/null || true

            echo -e "${GREEN}[SUCCESS]${NC} SUITECRM_URL update completed!"
        else
            echo -e "${GREEN}[INFO]${NC} SUITECRM_URL unchanged: $SUITECRM_URL"
        fi

        # Always update the URL marker file with the current URL
        echo "$SUITECRM_URL" > "$URL_MARKER"
        echo -e "${YELLOW}[INFO]${NC} Updated URL marker file"
    else
        echo -e "${YELLOW}[INFO]${NC} SUITECRM_URL environment variable not set, skipping URL update"
    fi
else
    echo -e "${YELLOW}[INFO]${NC} First-time initialization detected. Running setup..."

    # Run the installation script
    "$SUITECRM_INSTALLER/install.sh"

    # Create marker file to indicate initialization is complete
    echo "$(date)" > "$INSTALLED_MARKER"

    # Store the initial URL in the marker file
    if [ -n "$SUITECRM_URL" ]; then
        URL_MARKER="$SUITECRM_INSTALL_PATH/.suitecrm_url"
        echo "$SUITECRM_URL" > "$URL_MARKER"
        echo -e "${YELLOW}[INFO]${NC} Created URL marker file with initial URL: $SUITECRM_URL"
    fi

    echo -e "${GREEN}[SUCCESS]${NC} SuiteCRM initialization completed!"
fi

# ============================================================================
# STEP 4: Set proper permissions on every startup
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Setting proper permissions..."
chown -R www-data:www-data "$SUITECRM_INSTALL_PATH"
chmod -R 755 "$SUITECRM_INSTALL_PATH"

# Make specific directories writable
chmod -R 775 "$SUITECRM_INSTALL_PATH/cache" 2>/dev/null || true
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/cache" 2>/dev/null || true
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/custom" 2>/dev/null || true
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/modules" 2>/dev/null || true
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/themes" 2>/dev/null || true
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/upload" 2>/dev/null || true

echo -e "${GREEN}[SUCCESS]${NC} Permissions set successfully!"

# ============================================================================
# STEP 5: Start Apache
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} SuiteCRM is ready to use!"
echo -e "${GREEN}[INFO]${NC} Access SuiteCRM at: http://localhost:8080"
echo -e "${YELLOW}[INFO]${NC} Starting Apache..."

exec "$@"

