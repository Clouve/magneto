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

# clv_password_line REGEX PREFIX: copies its input to its output, with the line that matches REGEX (an awk regex)
# replaced by PREFIX followed by CLV_DB_PASSWORD as a PHP single-quoted string (each \ and ' after a \) and ";". awk
# reads the value from its environment, so it is never on a command line, and any character in it reads back the same
# (tests/installer-db-password.test.sh).
clv_password_line() {
    awk -v re="$1" -v prefix="$2" '
        function phpq(s,   i, c, out) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "\\" || c == "\047") out = out "\\"
                out = out c
            }
            return "\047" out "\047"
        }
        $0 ~ re { print prefix phpq(ENVIRON["CLV_DB_PASSWORD"]) ";"; next }
        { print }
    '
}

# This script runs as root, and the site's folder belongs to www-data, whose code can put a link, a folder or a pipe
# at config.php, or swap one in while this script works. sed -i and cat > read and write through a link: a config.php
# linked to /proc/self/environ became a file holding this script's environment. So config.php is edited only from
# inside the site's folder (in_folder), only when it is a regular file and not a link, read with O_NOFOLLOW, and the
# result goes into a new file that this script creates (dd conv=excl) and renames over config.php (mv -fT).
# Nothing a link points to is read or changed (tests/gibbon-root-paths.test.sh).

# in_folder DIR COMMAND...: runs COMMAND in a subshell inside DIR, once cd -P has moved there and /bin/pwd -P (the
# kernel's answer, getcwd; bash's builtin pwd only resolves the stored path again) has shown the folder to be DIR
# itself, with no link on the way. Status 125 when it isn't. The image's root-paths.sh has the same function; this
# script keeps its own copy because it also runs on its own.
in_folder() {
    local dir="$1" want
    shift
    want="$(realpath -sm -- "$dir" 2>/dev/null)" || return 125
    (
        if ! cd -P -- "$dir" 2>/dev/null || [[ "$(/bin/pwd -P 2>/dev/null)" != "$want" ]]; then
            exit 125
        fi
        "$@"
    )
}

# _clear_cache_here: what rm -rf uploads/cache/* did, from inside the folder (in_folder): plain names, and rm -rf
# removes a link as a link.
_clear_cache_here() { rm -rf -- ./* 2>/dev/null || true; }

# _config_edit_here: writes the four database settings into config.php, in the site's folder (in_folder). config.php
# keeps its owner and group (chown -h, which never follows a link), and its mode: the read and write bits come from the
# umask the new file is made with, and the execute bits (755 after an upgrade) are set by its owner, never by root, so
# a link swapped in can only lead to the owner's own files. A root-owned config.php keeps only its read and write
# bits. Status 5 when config.php isn't a regular file (or stops being one), 4 when something replaced the new file
# before the rename, 1 for anything else.
_config_edit_here() {
    local st uid gid mode size rand tmp xmode me
    set -o pipefail
    [[ -f config.php && ! -L config.php ]] || return 5
    st="$(stat -c '%u %g %a %s' -- config.php 2>/dev/null)" || return 5
    read -r uid gid mode size <<< "$st"
    [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{1,4}$ && "$size" =~ ^[0-9]+$ ]] || return 5
    mode=$(( 8#$mode & 8#777 ))
    rand="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [[ "$rand" =~ ^[0-9a-f]{16}$ ]] || return 1
    tmp=".config.php.$rand"
    me="$(id -u)"
    if ! dd if=config.php iflag=nofollow,nonblock status=none 2>/dev/null |
            sed -e "s/^\$databaseServer = .*$/\$databaseServer = '${DB_HOST}';/" \
                -e "s/^\$databaseName = .*$/\$databaseName = '${DB_NAME}';/" \
                -e "s/^\$databaseUsername = .*$/\$databaseUsername = '${DB_USER}';/" |
            CLV_DB_PASSWORD="$DB_PASSWORD" clv_password_line '^\\$databasePassword = ' '$databasePassword = ' |
            (umask "$(printf '%03o' $(( ~mode & 8#666 & 8#777 | 8#111 )))" &&
                dd of="$tmp" conv=excl oflag=nofollow status=none 2>/dev/null) ||
        # An empty result from a config.php that wasn't empty: a pipe was swapped in, so there is nothing to write.
        { [[ "$size" -gt 0 && ! -s "$tmp" ]]; } ||
        { [[ "$uid:$gid" != "$me:$(id -g)" ]] && ! chown -h -- "$uid:$gid" "$tmp" 2>/dev/null; }; then
        rm -rf -- "$tmp" 2>/dev/null || :
        return 1
    fi
    xmode="$(printf '%o' "$mode")"
    if (( mode & 8#111 )) && [[ "$uid" != 0 ]]; then
        if [[ "$me" == "$uid" ]]; then
            chmod "$xmode" -- "$tmp" 2>/dev/null
        else
            env -u CLOUVE_OPS_PASSWORD setpriv --reuid="$uid" --regid="$gid" --clear-groups chmod "$xmode" -- "$tmp" 2>/dev/null
        fi || { rm -rf -- "$tmp" 2>/dev/null; return 1; }
    fi
    if ! mv -fT -- "$tmp" config.php 2>/dev/null; then
        rm -rf -- "$tmp" 2>/dev/null || :
        return 1
    fi
    [[ -f config.php && ! -L config.php ]] || return 4
}

echo "============================================================================"
echo "Updating Gibbon configuration from environment variables..."
echo "============================================================================"

# ============================================================================
# PART 1: Update config.php with database credentials from environment
# ============================================================================

if [ -L "$CONFIG_FILE" ] || { [ -e "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; }; then
    # Only its name goes to the log, never what it holds or where a link points.
    echo "⚠ Warning: $CONFIG_FILE is a link or not a regular file, so its database settings were not updated"
elif [ -f "$CONFIG_FILE" ]; then
    echo "Found config.php at $CONFIG_FILE"
    
    # Check if environment variables are set
    if [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        echo "WARNING: Database environment variables not fully set. Skipping config.php update."
        echo "  DB_HOST: ${DB_HOST:-(not set)}"
        echo "  DB_NAME: ${DB_NAME:-(not set)}"
        echo "  DB_USER: ${DB_USER:-(not set)}"
        # Only whether the password is set: its value never goes to the log.
        if [ -n "$DB_PASSWORD" ]; then echo "  DB_PASSWORD: (set)"; else echo "  DB_PASSWORD: (not set)"; fi
    else
        echo "Updating database credentials in config.php..."

        # The server, name and user with sed, and the password off every command line (clv_password_line), in one
        # pass that writes a new config.php (_config_edit_here).
        rc=0
        in_folder "$GIBBON_INSTALL_PATH" _config_edit_here || rc=$?
        case $rc in
            0)
                echo "  ✓ Updated \$databaseServer to: $DB_HOST"
                echo "  ✓ Updated \$databaseName to: $DB_NAME"
                echo "  ✓ Updated \$databaseUsername to: $DB_USER"
                echo "  ✓ Updated \$databasePassword"
                echo "Database credentials in config.php updated successfully!"
                ;;
            5)
                echo "⚠ Warning: $CONFIG_FILE is a link or not a regular file, so its database settings were not updated"
                ;;
            *)
                case $rc in
                    125) why=": its folder has a link on the way to it" ;;
                    4) why=": something replaced the new file before it was renamed" ;;
                    *) why="" ;;
                esac
                echo "✗ Error: can't update $CONFIG_FILE$why" >&2
                exit 1
                ;;
        esac
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

                    # Clear Gibbon's uploads cache, from inside it: a link at uploads/ or uploads/cache fails the folder
                    # check, and then nothing is removed.
                    if in_folder "$GIBBON_INSTALL_PATH/uploads/cache" _clear_cache_here; then
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

