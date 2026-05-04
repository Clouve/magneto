#!/bin/bash
set -e

# ============================================================================
# UPDATE MOODLE CONFIG.PHP WITH CURRENT ENVIRONMENT VARIABLES
# ============================================================================
# This script updates Moodle's config.php file with current environment variable
# values for database credentials and wwwroot on every container startup.
# This allows dynamic configuration changes without manual file edits.
#
# It also updates the mdl_config table in the database to ensure Moodle's
# internal cache reflects the current wwwroot value.
# ============================================================================

CONFIG_FILE="${MOODLE_INSTALL_PATH}/config.php"

echo "============================================================================"
echo "UPDATING MOODLE CONFIGURATION"
echo "============================================================================"

# Check if config.php exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ℹ config.php not found at $CONFIG_FILE"
    echo "  Moodle has not been installed yet. Skipping configuration update."
    echo "============================================================================"
    exit 0
fi

echo "Found config.php at: $CONFIG_FILE"

# ============================================================================
# PART 1: UPDATE DATABASE CREDENTIALS IN CONFIG.PHP
# ============================================================================

# Check if environment variables are set
if [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
    echo "⚠ WARNING: Database environment variables not fully set. Skipping database config update."
    echo "  DB_HOST: ${DB_HOST:-(not set)}"
    echo "  DB_NAME: ${DB_NAME:-(not set)}"
    echo "  DB_USER: ${DB_USER:-(not set)}"
    echo "  DB_PASSWORD: ${DB_PASSWORD:-(not set)}"
else
    echo "Updating database credentials in config.php..."
    
    # Escape special characters in password for sed
    # This handles passwords with special characters like $, &, /, \, etc.
    DB_PASSWORD_ESCAPED=$(printf '%s\n' "$DB_PASSWORD" | sed -e 's/[\/&]/\\&/g')
    DB_HOST_ESCAPED=$(printf '%s\n' "$DB_HOST" | sed -e 's/[\/&]/\\&/g')
    DB_NAME_ESCAPED=$(printf '%s\n' "$DB_NAME" | sed -e 's/[\/&]/\\&/g')
    DB_USER_ESCAPED=$(printf '%s\n' "$DB_USER" | sed -e 's/[\/&]/\\&/g')
    
    # Update database configuration values in config.php
    # These sed commands will replace the hardcoded values with environment variable values
    
    # Update database host
    sed -i "s/^\$CFG->dbhost[[:space:]]*=.*$/\$CFG->dbhost    = '${DB_HOST_ESCAPED}';/" "$CONFIG_FILE"
    echo "  ✓ Updated \$CFG->dbhost to: $DB_HOST"
    
    # Update database name
    sed -i "s/^\$CFG->dbname[[:space:]]*=.*$/\$CFG->dbname    = '${DB_NAME_ESCAPED}';/" "$CONFIG_FILE"
    echo "  ✓ Updated \$CFG->dbname to: $DB_NAME"
    
    # Update database user
    sed -i "s/^\$CFG->dbuser[[:space:]]*=.*$/\$CFG->dbuser    = '${DB_USER_ESCAPED}';/" "$CONFIG_FILE"
    echo "  ✓ Updated \$CFG->dbuser to: $DB_USER"
    
    # Update database password
    sed -i "s/^\$CFG->dbpass[[:space:]]*=.*$/\$CFG->dbpass    = '${DB_PASSWORD_ESCAPED}';/" "$CONFIG_FILE"
    echo "  ✓ Updated \$CFG->dbpass to: [REDACTED]"
    
    echo "✓ Database credentials updated successfully in config.php"
fi

# ============================================================================
# PART 2: UPDATE WWWROOT IN CONFIG.PHP AND DATABASE
# ============================================================================

if [ -z "$MOODLE_URL" ]; then
    echo "⚠ WARNING: MOODLE_URL environment variable not set. Skipping wwwroot update."
else
    # ============================================================================
    # DETECT URL CHANGES
    # ============================================================================
    # First, check if the URL has actually changed by comparing with the database value
    # This allows us to log URL changes explicitly (required for test scripts)

    echo "Checking if MOODLE_URL has changed..."

    PREVIOUS_WWWROOT=""
    URL_HAS_CHANGED=false

    # Check if we can connect to the database to get the previous URL
    if mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
       -e "SELECT 1;" >/dev/null 2>&1; then

        # Get the current wwwroot value from the database
        PREVIOUS_WWWROOT=$(mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
          -sN -e "SELECT value FROM mdl_config WHERE name = 'wwwroot';" 2>/dev/null || echo "")

        if [ -n "$PREVIOUS_WWWROOT" ]; then
            echo "  Previous URL from database: $PREVIOUS_WWWROOT"
            echo "  Current MOODLE_URL: $MOODLE_URL"

            # Check if URL has changed
            if [ "$PREVIOUS_WWWROOT" != "$MOODLE_URL" ]; then
                URL_HAS_CHANGED=true
                echo "  ✓ URL has changed!"
                echo "    Old URL: $PREVIOUS_WWWROOT"
                echo "    New URL: $MOODLE_URL"
            else
                echo "  ℹ URL unchanged: $MOODLE_URL"
            fi
        else
            echo "  ℹ No previous URL found in database (first run after installation)"
        fi
    else
        echo "  ⚠ WARNING: Could not connect to database to check previous URL"
        echo "    Will proceed with updating config.php"
    fi

    # ============================================================================
    # UPDATE CONFIG.PHP
    # ============================================================================

    echo "Updating wwwroot in config.php..."

    # Escape special characters in URL for sed
    MOODLE_URL_ESCAPED=$(printf '%s\n' "$MOODLE_URL" | sed -e 's/[\/&]/\\&/g')

    # Update wwwroot in config.php
    sed -i "s/^\$CFG->wwwroot[[:space:]]*=.*$/\$CFG->wwwroot   = '${MOODLE_URL_ESCAPED}';/" "$CONFIG_FILE"
    echo "  ✓ Updated \$CFG->wwwroot to: $MOODLE_URL"

    # ============================================================================
    # UPDATE WWWROOT IN DATABASE
    # ============================================================================
    # Moodle caches the wwwroot value in the mdl_config table
    # We need to update it there as well to ensure consistency

    echo "Updating wwwroot in database (mdl_config table)..."

    # Check if we can connect to the database
    if mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
       -e "SELECT 1;" >/dev/null 2>&1; then

        # Update the wwwroot value in mdl_config table
        # The wwwroot is stored with name='wwwroot' in the mdl_config table
        # Use INSERT ... ON DUPLICATE KEY UPDATE to handle both new and existing entries
        mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
          -e "INSERT INTO mdl_config (name, value) VALUES ('wwwroot', '$MOODLE_URL') ON DUPLICATE KEY UPDATE value = '$MOODLE_URL';" 2>&1

        # Verify the update
        CURRENT_WWWROOT=$(mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
          -sN -e "SELECT value FROM mdl_config WHERE name = 'wwwroot';" 2>/dev/null || echo "")

        if [ "$CURRENT_WWWROOT" = "$MOODLE_URL" ]; then
            echo "  ✓ Updated wwwroot in database to: $MOODLE_URL"
        else
            echo "  ⚠ WARNING: Database wwwroot value does not match expected value"
            echo "    Expected: $MOODLE_URL"
            echo "    Current:  $CURRENT_WWWROOT"
        fi

        # If URL has changed, clear Moodle's cache to ensure changes take effect immediately
        if [ "$URL_HAS_CHANGED" = true ]; then
            echo "URL change detected - invalidating Moodle cache..."
            # We do this by updating the allversionshash which forces cache invalidation
            mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
              -e "UPDATE mdl_config SET value = CONCAT(value, '1') WHERE name = 'allversionshash';" 2>&1 || true
            echo "  ✓ Cache invalidation triggered"
        fi

    else
        echo "  ⚠ WARNING: Could not connect to database to update wwwroot"
        echo "    The config.php file has been updated, but the database value may be stale"
        echo "    This may cause issues until the database is accessible"
    fi

    echo "✓ wwwroot updated successfully"
fi

echo "============================================================================"
echo "✓ MOODLE CONFIGURATION UPDATE COMPLETED"
echo "============================================================================"

