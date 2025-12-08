#!/bin/bash

# LimeSurvey Docker Entrypoint Wrapper Script
# This script wraps the official martialblog/limesurvey entrypoint with Clouve-specific initialization:
# 1. Waits for database to be ready
# 2. Tracks initialization state using a marker file
# 3. Calls the original entrypoint at /usr/local/bin/entrypoint.sh (untouched)
# 4. The original entrypoint handles all LimeSurvey initialization and starts Apache
#
# Note: We don't modify the official image's entrypoint - it remains at its original location.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set error handling
set -e

# Path to the original LimeSurvey entrypoint (from the official image)
ORIGINAL_ENTRYPOINT="/usr/local/bin/entrypoint.sh"

# Path to bundled LimeSurvey package (copied during Docker build)
LIMESURVEY_PACKAGE_PATH="/clouve/limesurvey/package"
LIMESURVEY_INSTALL_PATH="/var/www/html"

# Load environment variables with defaults matching the official image
DB_TYPE=${DB_TYPE:-'mysql'}
DB_HOST=${DB_HOST:-'limesurvey-mariadb'}
DB_PORT=${DB_PORT:-'3306'}
DB_SOCK=${DB_SOCK:-}
DB_NAME=${DB_NAME:-'limesurvey'}
DB_TABLE_PREFIX=${DB_TABLE_PREFIX:-'lime_'}
DB_USERNAME=${DB_USERNAME:-'limesurvey'}
DB_MYSQL_ENGINE=${DB_MYSQL_ENGINE:-'InnoDB'}

# Export variables needed by configure-suitecrm-plugin.sh and import-demo-data.sh
export DB_HOST DB_PORT DB_NAME DB_TABLE_PREFIX DB_USERNAME DB_PASSWORD
export ENABLE_SUITECRM_INTEGRATION
export SUITECRM_URL SUITECRM_ADMIN_USER SUITECRM_ADMIN_PASSWORD
export SUITECRM_DB_HOST SUITECRM_DB_PORT SUITECRM_DB_NAME SUITECRM_DB_USER SUITECRM_DB_PASSWORD

ADMIN_USER=${ADMIN_USER:-'admin'}
ADMIN_NAME=${ADMIN_NAME:-'Administrator'}
ADMIN_EMAIL=${ADMIN_EMAIL:-'admin@example.com'}

BASE_URL=${BASE_URL:-''}
PUBLIC_URL=${PUBLIC_URL:-}
URL_FORMAT=${URL_FORMAT:-'path'}
SHOW_SCRIPT_NAME=${SHOW_SCRIPT_NAME:-'true'}
TABLE_SESSION=${TABLE_SESSION:-}

DEBUG=${DEBUG:-0}
DEBUG_SQL=${DEBUG_SQL:-0}

LISTEN_PORT=${LISTEN_PORT:-"8080"}

INSTALLED_MARKER="/var/www/html/.limesurvey_initialized"

echo -e "${YELLOW}[INFO]${NC} Starting Clouve LimeSurvey initialization..."

# Validate required environment variables
if [ -z "$DB_PASSWORD" ]; then
    echo -e "${RED}[ERROR]${NC} Missing DB_PASSWORD or DB_PASSWORD_FILE"
    exit 1
fi

if [ -z "$ADMIN_PASSWORD" ]; then
    echo -e "${RED}[ERROR]${NC} Missing ADMIN_PASSWORD or ADMIN_PASSWORD_FILE"
    exit 1
fi

# ============================================================================
# STEP 1: Wait for database to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for database to be ready..."

if [ -z "$DB_SOCK" ]; then
    max_attempts=60
    attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if nc -z -w30 "$DB_HOST" "$DB_PORT" 2>&1 > /dev/null; then
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
fi

# Wait a bit more to ensure database is fully initialized
sleep 3

# ============================================================================
# STEP 2: Copy LimeSurvey files from bundle to /var/www/html if needed
# ============================================================================
# This handles the Kubernetes volume mount issue where an empty PVC
# overwrites the LimeSurvey files from the Docker image.
# Similar to how Moodle copies files from /clouve/moodle/package

echo -e "${YELLOW}[INFO]${NC} Checking if LimeSurvey files need to be copied..."

# Check if /var/www/html is empty or missing critical files
if [ ! -f "$LIMESURVEY_INSTALL_PATH/index.php" ] || [ ! -d "$LIMESURVEY_INSTALL_PATH/application" ]; then
    echo -e "${YELLOW}[INFO]${NC} LimeSurvey files not found in $LIMESURVEY_INSTALL_PATH"
    echo -e "${YELLOW}[INFO]${NC} Copying LimeSurvey package from $LIMESURVEY_PACKAGE_PATH..."

    # Copy all files from the bundled package
    cp -prf "$LIMESURVEY_PACKAGE_PATH"/* "$LIMESURVEY_INSTALL_PATH"/

    # Copy hidden files (like .htaccess)
    cp -prf "$LIMESURVEY_PACKAGE_PATH"/.[a-zA-Z0-9]* "$LIMESURVEY_INSTALL_PATH"/ 2>/dev/null || true

    # Set proper ownership
    chown -R www-data:www-data "$LIMESURVEY_INSTALL_PATH"/

    # Set proper permissions
    chmod -R 755 "$LIMESURVEY_INSTALL_PATH"/

    echo -e "${GREEN}[SUCCESS]${NC} LimeSurvey files copied successfully!"
else
    echo -e "${GREEN}[INFO]${NC} LimeSurvey files already present in $LIMESURVEY_INSTALL_PATH"
fi

# ============================================================================
# STEP 3: Install SuiteCRM Integration Plugin (if enabled)
# ============================================================================

if [ "$ENABLE_SUITECRM_INTEGRATION" = "true" ]; then
    echo -e "${YELLOW}[INFO]${NC} SuiteCRM Integration is enabled"

    PLUGIN_SOURCE="$LIMESURVEY_PACKAGE_PATH/plugins/SuiteCRMIntegration"
    PLUGIN_DEST="$LIMESURVEY_INSTALL_PATH/plugins/SuiteCRMIntegration"

    if [ -d "$PLUGIN_SOURCE" ]; then
        # Always copy/update plugin files from package to ensure we have the latest version
        # This is important because the plugin code may be updated in new image builds
        echo -e "${YELLOW}[INFO]${NC} Syncing SuiteCRM Integration plugin from package..."

        # Copy plugin from package to plugins directory (always sync to get updates)
        cp -prf "$PLUGIN_SOURCE" "$PLUGIN_DEST"

        # Set proper ownership and permissions
        chown -R www-data:www-data "$PLUGIN_DEST"
        chmod -R 755 "$PLUGIN_DEST"

        echo -e "${GREEN}[SUCCESS]${NC} SuiteCRM Integration plugin synced!"
    else
        echo -e "${YELLOW}[WARNING]${NC} SuiteCRM Integration plugin source not found at $PLUGIN_SOURCE"
    fi
else
    echo -e "${YELLOW}[INFO]${NC} SuiteCRM Integration is disabled (ENABLE_SUITECRM_INTEGRATION != true)"
fi

# ============================================================================
# STEP 4: Call the original LimeSurvey entrypoint
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Calling original LimeSurvey entrypoint for configuration..."

# The original entrypoint handles:
# - config.php generation
# - security.php generation
# - Database initialization via console.php updatedb and install
# We'll call it in a way that allows us to add our custom logic

# Check if this is first-time initialization
if [ -f "$INSTALLED_MARKER" ]; then
    echo -e "${GREEN}[INFO]${NC} LimeSurvey appears to be already initialized."
    echo -e "${GREEN}[INFO]${NC} Marker file found: $INSTALLED_MARKER"
    echo -e "${YELLOW}[INFO]${NC} Checking if PUBLIC_URL has changed..."

    # ============================================================================
    # STEP 4a: Update PUBLIC_URL if it has changed (for existing installations)
    # ============================================================================

    CONFIG_FILE="$LIMESURVEY_INSTALL_PATH/application/config/config.php"

    if [ -f "$CONFIG_FILE" ] && [ -n "$PUBLIC_URL" ]; then
        # Extract current publicurl from config.php
        # The config.php has a line like: 'publicurl'=>'http://old.url',
        CURRENT_PUBLIC_URL=$(grep -oP "'publicurl'\s*=>\s*'\K[^']*" "$CONFIG_FILE" 2>/dev/null || echo "")

        if [ -n "$CURRENT_PUBLIC_URL" ] && [ "$CURRENT_PUBLIC_URL" != "$PUBLIC_URL" ]; then
            echo -e "${YELLOW}[INFO]${NC} PUBLIC_URL has changed!"
            echo -e "${YELLOW}[INFO]${NC}   Old URL: $CURRENT_PUBLIC_URL"
            echo -e "${YELLOW}[INFO]${NC}   New URL: $PUBLIC_URL"
            echo -e "${YELLOW}[INFO]${NC} Updating config.php..."

            # Update the publicurl in config.php using sed
            # This replaces the line: 'publicurl'=>'OLD_URL', with 'publicurl'=>'NEW_URL',
            sed -i "s|'publicurl'\s*=>\s*'[^']*'|'publicurl'=>'$PUBLIC_URL'|g" "$CONFIG_FILE"

            echo -e "${GREEN}[SUCCESS]${NC} PUBLIC_URL updated successfully in config.php!"
        elif [ -z "$CURRENT_PUBLIC_URL" ]; then
            echo -e "${YELLOW}[WARNING]${NC} Could not find publicurl in config.php"
        else
            echo -e "${GREEN}[INFO]${NC} PUBLIC_URL unchanged: $PUBLIC_URL"
        fi
    elif [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}[WARNING]${NC} config.php not found at $CONFIG_FILE"
    elif [ -z "$PUBLIC_URL" ]; then
        echo -e "${YELLOW}[INFO]${NC} PUBLIC_URL environment variable not set, skipping URL update"
    fi
else
    echo -e "${YELLOW}[INFO]${NC} First-time initialization detected."
    echo -e "${YELLOW}[INFO]${NC} The original entrypoint will handle database setup..."
fi

# ============================================================================
# STEP 5: Configure SuiteCRM Integration Plugin (if enabled and installed)
# ============================================================================

if [ "$ENABLE_SUITECRM_INTEGRATION" = "true" ] && [ -d "$LIMESURVEY_INSTALL_PATH/plugins/SuiteCRMIntegration" ]; then
    echo -e "${YELLOW}[INFO]${NC} Configuring SuiteCRM Integration plugin..."

    # Run the configuration script in the background with polling mechanism
    # This ensures LimeSurvey is fully initialized before configuration
    (
        # Wait for LimeSurvey to be fully initialized with polling
        echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Waiting for LimeSurvey to be fully initialized..."

        TIMEOUT=120
        ELAPSED=0
        POLL_INTERVAL=2

        while [ $ELAPSED -lt $TIMEOUT ]; do
            # Check 1: Verify BOTH plugins and plugin_settings tables exist
            # (configure-suitecrm-plugin.sh needs both tables)
            if mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
                -e "SELECT 1 FROM ${DB_TABLE_PREFIX}plugins LIMIT 1;" 2>/dev/null >/dev/null && \
               mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
                -e "SELECT 1 FROM ${DB_TABLE_PREFIX}plugin_settings LIMIT 1;" 2>/dev/null >/dev/null; then

                # Check 2: Verify config files exist and are not empty
                if [ -s "$LIMESURVEY_INSTALL_PATH/application/config/config.php" ] && \
                   [ -s "$LIMESURVEY_INSTALL_PATH/application/config/security.php" ]; then

                    # Check 3: Verify web server is responding (optional but recommended)
                    if curl -s -f http://localhost:8080 >/dev/null 2>&1; then
                        echo -e "${GREEN}[PLUGIN-CONFIG]${NC} LimeSurvey is fully initialized!"
                        break
                    fi
                fi
            fi

            sleep $POLL_INTERVAL
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
        done

        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Timeout waiting for LimeSurvey initialization after ${TIMEOUT}s"
            exit 1
        fi

        # Add a small delay to ensure database is fully stable after initialization
        echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Waiting 3 seconds for database to stabilize..."
        sleep 3

        # Wait for SuiteCRM database to be ready (for OAuth2 client setup)
        echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Waiting for SuiteCRM database to be ready..."
        SUITECRM_TIMEOUT=60
        SUITECRM_ELAPSED=0
        while [ $SUITECRM_ELAPSED -lt $SUITECRM_TIMEOUT ]; do
            if mariadb -h "${SUITECRM_DB_HOST:-suitecrm-mariadb}" -u "${SUITECRM_DB_USER:-suitecrm}" \
                -p"${SUITECRM_DB_PASSWORD}" "${SUITECRM_DB_NAME:-suitecrm}" \
                -e "SELECT 1 FROM oauth2clients LIMIT 1;" 2>/dev/null >/dev/null; then
                echo -e "${GREEN}[PLUGIN-CONFIG]${NC} SuiteCRM database is ready!"
                break
            fi
            sleep 2
            SUITECRM_ELAPSED=$((SUITECRM_ELAPSED + 2))
        done

        if [ $SUITECRM_ELAPSED -ge $SUITECRM_TIMEOUT ]; then
            echo -e "${YELLOW}[PLUGIN-CONFIG WARNING]${NC} SuiteCRM database not ready, OAuth2 setup may fail"
        fi

        # Run the configuration script
        /clouve/limesurvey/installer/configure-suitecrm-plugin.sh
    ) &

    echo -e "${GREEN}[SUCCESS]${NC} SuiteCRM Integration plugin configuration scheduled"
fi

# ============================================================================
# STEP 6: Install Demo Data (if enabled)
# ============================================================================

if [ "$INSTALL_DEMO_DATA" = "true" ]; then
    echo -e "${YELLOW}[INFO]${NC} Demo data installation is enabled"

    # Run the import script in the background
    # This ensures LimeSurvey is fully initialized before import
    /clouve/limesurvey/installer/import-demo-data.sh &

    echo -e "${GREEN}[SUCCESS]${NC} Demo data import scheduled"
else
    echo -e "${YELLOW}[INFO]${NC} Demo data installation is disabled (INSTALL_DEMO_DATA != true)"
fi

# ============================================================================
# STEP 7: Execute the original entrypoint
# ============================================================================

# The original entrypoint (at /usr/local/bin/entrypoint.sh) will:
# 1. Generate config.php if it doesn't exist
# 2. Generate security.php if it doesn't exist
# 3. Run console.php updatedb (which will fail if DB not initialized)
# 4. Run console.php install if updatedb failed
# 5. Start Apache

# Create our marker file to track that Clouve initialization has run
if [ ! -f "$INSTALLED_MARKER" ]; then
    echo "$(date)" > "$INSTALLED_MARKER"
    echo -e "${GREEN}[SUCCESS]${NC} Clouve initialization marker created!"
fi

echo -e "${GREEN}[SUCCESS]${NC} LimeSurvey is ready to use!"
echo -e "${GREEN}[INFO]${NC} Access LimeSurvey at: http://localhost:$LISTEN_PORT"
echo -e "${YELLOW}[INFO]${NC} Starting LimeSurvey via original entrypoint..."

# Call the original entrypoint at its original location (untouched)
# We pass all arguments to it so it can start Apache properly
if [ -f "$ORIGINAL_ENTRYPOINT" ]; then
    exec "$ORIGINAL_ENTRYPOINT" "$@"
else
    # Fallback: if the original entrypoint wasn't found, just execute the command
    echo -e "${RED}[ERROR]${NC} Original entrypoint not found at $ORIGINAL_ENTRYPOINT"
    echo -e "${YELLOW}[WARNING]${NC} Executing command directly as fallback"
    exec "$@"
fi

