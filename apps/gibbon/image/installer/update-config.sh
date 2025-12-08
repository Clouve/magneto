#!/bin/bash
set -e

# ============================================================================
# Gibbon Configuration Update Script
# ============================================================================
# This script runs on every container startup to ensure configuration stays
# synchronized with environment variables. It handles two main tasks:
#
# 1. Update config.php with current database credentials from environment
# 2. Update absoluteURL in the database with current GIBBON_URL value
#
# This ensures that configuration changes (like URL updates or database
# credential rotations) are reflected without requiring a full reinstall.
# ============================================================================

CONFIG_FILE="$GIBBON_INSTALL_PATH/config.php"

echo "============================================================================"
echo "Updating Gibbon configuration from environment variables..."
echo "============================================================================"

# ============================================================================
# PART 1: Update config.php with database credentials from environment
# ============================================================================

if [ -f "$CONFIG_FILE" ]; then
    echo "Found config.php at $CONFIG_FILE"
    
    # Check if environment variables are set
    if [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        echo "WARNING: Database environment variables not fully set. Skipping config.php update."
        echo "  DB_HOST: ${DB_HOST:-(not set)}"
        echo "  DB_NAME: ${DB_NAME:-(not set)}"
        echo "  DB_USER: ${DB_USER:-(not set)}"
        echo "  DB_PASSWORD: ${DB_PASSWORD:-(not set)}"
    else
        echo "Updating database credentials in config.php..."
        
        # Use sed to update database configuration values
        # These sed commands will replace the hardcoded values with environment variable values
        
        # Update database server
        sed -i "s/^\$databaseServer = .*$/\$databaseServer = '${DB_HOST}';/" "$CONFIG_FILE"
        echo "  ✓ Updated \$databaseServer to: $DB_HOST"
        
        # Update database name
        sed -i "s/^\$databaseName = .*$/\$databaseName = '${DB_NAME}';/" "$CONFIG_FILE"
        echo "  ✓ Updated \$databaseName to: $DB_NAME"
        
        # Update database username
        sed -i "s/^\$databaseUsername = .*$/\$databaseUsername = '${DB_USER}';/" "$CONFIG_FILE"
        echo "  ✓ Updated \$databaseUsername to: $DB_USER"
        
        # Update database password (escape special characters for sed)
        # We need to escape special characters that might be in the password
        ESCAPED_PASSWORD=$(printf '%s\n' "$DB_PASSWORD" | sed -e 's/[\/&]/\\&/g')
        sed -i "s/^\$databasePassword = .*$/\$databasePassword = '${ESCAPED_PASSWORD}';/" "$CONFIG_FILE"
        echo "  ✓ Updated \$databasePassword"
        
        echo "Database credentials in config.php updated successfully!"
    fi
else
    echo "config.php not found at $CONFIG_FILE - Gibbon not yet installed, skipping config.php update"
fi

# ============================================================================
# PART 2: Update absoluteURL in database with current GIBBON_URL
# ============================================================================

if [ -f "$CONFIG_FILE" ]; then
    echo ""
    echo "Updating absoluteURL in database..."
    
    # Check if GIBBON_URL is set
    if [ -z "$GIBBON_URL" ]; then
        echo "WARNING: GIBBON_URL environment variable not set. Skipping database URL update."
    else
        echo "Target URL: $GIBBON_URL"
        
        # Wait for database to be ready
        echo "Ensuring database connection is ready..."
        MAX_RETRIES=30
        RETRY_COUNT=0

        # Use MYSQL_PWD environment variable to avoid password on command line
        export MYSQL_PWD="$DB_PASSWORD"

        # Use mysql client to test actual connection with credentials
        # Note: --skip-ssl is required to avoid SSL certificate validation issues
        while ! mysql -h"$DB_HOST" -u"$DB_USER" --skip-ssl -e "SELECT 1" >/dev/null 2>&1; do
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
                echo "ERROR: Database connection failed after $MAX_RETRIES attempts. Skipping URL update."
                unset MYSQL_PWD
                exit 0
            fi
            echo "  Waiting for database connection... (attempt $RETRY_COUNT/$MAX_RETRIES)"
            sleep 2
        done

        echo "Database connection ready!"

        # Check if gibbonSetting table exists (meaning Gibbon is installed)
        if mysql -h"$DB_HOST" -u"$DB_USER" "$DB_NAME" --skip-ssl -e "SELECT 1 FROM gibbonSetting LIMIT 1" >/dev/null 2>&1; then
            echo "Gibbon database tables found. Updating absoluteURL setting..."

            # ========================================================================
            # DETECT URL CHANGES
            # ========================================================================
            # Query the database for the previous absoluteURL value before updating
            # This allows us to detect if the URL has actually changed and only
            # trigger expensive operations (like cache invalidation) when needed.

            echo "Checking if GIBBON_URL has changed..."

            # Get the previous URL from the database
            PREVIOUS_URL=$(mysql -h"$DB_HOST" -u"$DB_USER" "$DB_NAME" --skip-ssl -sN -e \
                "SELECT value FROM gibbonSetting WHERE scope='System' AND name='absoluteURL';" 2>&1)

            # Check if query was successful
            if [ $? -eq 0 ] && [ -n "$PREVIOUS_URL" ]; then
                echo "  Previous URL from database: $PREVIOUS_URL"
                echo "  Current GIBBON_URL: $GIBBON_URL"

                # Compare previous URL with current GIBBON_URL
                if [ "$PREVIOUS_URL" != "$GIBBON_URL" ]; then
                    echo "  ✓ URL has changed!"
                    echo "    Old URL: $PREVIOUS_URL"
                    echo "    New URL: $GIBBON_URL"
                    URL_CHANGED=true
                else
                    echo "  URL has not changed (both are: $GIBBON_URL)"
                    URL_CHANGED=false
                fi
            else
                echo "  Could not retrieve previous URL from database (first run or query failed)"
                echo "  Will proceed with URL update..."
                URL_CHANGED=true
            fi

            # ========================================================================
            # UPDATE DATABASE URL
            # ========================================================================

            # Update the absoluteURL in the gibbonSetting table
            # The absoluteURL is stored with scope='System' and name='absoluteURL'
            # Use INSERT ... ON DUPLICATE KEY UPDATE to handle both new and existing entries
            # Note: gibbonSetting table has a unique key on (scope, name)
            mysql -h"$DB_HOST" -u"$DB_USER" "$DB_NAME" --skip-ssl <<-EOSQL
				INSERT INTO gibbonSetting (scope, name, nameDisplay, description, value)
				VALUES ('System', 'absoluteURL', 'Base URL', 'The address at which the whole system resides.', '$GIBBON_URL')
				ON DUPLICATE KEY UPDATE value = '$GIBBON_URL';
			EOSQL

            if [ $? -eq 0 ]; then
                echo "  ✓ absoluteURL updated successfully in database!"

                # Verify the update
                CURRENT_URL=$(mysql -h"$DB_HOST" -u"$DB_USER" "$DB_NAME" --skip-ssl -sN -e \
                    "SELECT value FROM gibbonSetting WHERE scope='System' AND name='absoluteURL';")
                echo "  Current absoluteURL in database: $CURRENT_URL"

                # ====================================================================
                # CONDITIONAL CACHE INVALIDATION
                # ====================================================================
                # Only perform expensive cache operations if URL actually changed

                if [ "$URL_CHANGED" = true ]; then
                    echo ""
                    echo "URL change detected - clearing Gibbon cache..."

                    # Clear Gibbon's uploads cache
                    if [ -d "/var/www/html/uploads/cache" ]; then
                        rm -rf /var/www/html/uploads/cache/* 2>/dev/null || true
                        echo "  ✓ Cleared uploads cache"
                    fi

                    echo "  ✓ Cache invalidation complete"
                else
                    echo ""
                    echo "URL unchanged - skipping cache invalidation"
                fi
            else
                echo "  WARNING: Failed to update absoluteURL in database"
            fi
        else
            echo "Gibbon database tables not found - installation not complete yet, skipping URL update"
        fi

        # Clean up password from environment
        unset MYSQL_PWD
    fi
else
    echo "config.php not found - Gibbon not yet installed, skipping database URL update"
fi

echo ""
echo "============================================================================"
echo "Configuration update complete!"
echo "============================================================================"

