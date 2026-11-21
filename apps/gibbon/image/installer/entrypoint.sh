#!/bin/bash
set -e

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
export TIMESTAMP=$TIMESTAMP
export GIBBON_PACKAGE_PATH="/clouve/$GIBBON_PATH"
export GIBBON_INSTALL_PATH="/var/www/html"
export GIBBON_PACKAGE_INSTALLER="/clouve/gibbon/installer"
export INSTALLED_VERSIONS_PATH="/var/www/html/clouve/installed"

# Root's reads and writes on the site's volume, which belongs to www-data: in_folder, plain_file, safe_write,
# remove_entry and make_folder never follow a link there (tests/gibbon-root-paths.test.sh).
# shellcheck source-path=SCRIPTDIR source=root-paths.sh
. "$GIBBON_PACKAGE_INSTALLER/root-paths.sh"
# reap_www_data: after each step that runs something as www-data, and before root touches files again, every process
# of www-data's still running is ended (installer/www-data.sh, the Moodle image's functions). Each call is a statement
# of its own, `reap_www_data STEP || exit 1`: a reap that can't make sure none is left stops the start.
# shellcheck source-path=SCRIPTDIR source=www-data.sh
. "$GIBBON_PACKAGE_INSTALLER/www-data.sh"

# state_folders: clouve/ and clouve/installed/ hold the install markers and the PHP libraries' record, so they must be
# real folders, or the markers would be read and written wherever a link points. A link at either, or anything else
# that isn't a folder, is removed without being followed, with a warning that names it. A site that is installed (it
# has config.php) gets both folders back, empty: its start then copies this version's code again and records it, as
# after an upgrade, instead of installing Gibbon over the site. A site without config.php installs as a new one.
state_folders() {
  local dir
  for dir in "$GIBBON_INSTALL_PATH/clouve" "$INSTALLED_VERSIONS_PATH"; do
    if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) ]]; then
      echo "⚠ Warning: $dir is a link or not a folder, so it is removed without being followed"
      if ! remove_entry "$dir"; then
        echo "✗ Error: can't remove $dir" >&2
        exit 1
      fi
      if [[ -e "$GIBBON_INSTALL_PATH/config.php" || -L "$GIBBON_INSTALL_PATH/config.php" ]] &&
          ! { make_folder "$GIBBON_INSTALL_PATH/clouve" && make_folder "$INSTALLED_VERSIONS_PATH"; }; then
        echo "✗ Error: can't make $INSTALLED_VERSIONS_PATH" >&2
        exit 1
      fi
    fi
  done
}

# clear_uploads_cache: empties uploads/cache (Twig's compiled templates) as rm -rf uploads/cache/* did, and gives it to
# www-data with mode 755, without following a link: uploads/ holds the school's files, so when it isn't a real folder
# the cache is left alone, with a warning; a link or a file at uploads/cache is removed, not followed, and the folder
# made again. The rest runs from inside the folder: rm on plain names, chown -hR, and chmod -R as www-data once
# everything there is www-data's, so a link swapped in can only lead chmod to www-data's own files.
clear_uploads_cache() {
  local uploads="$GIBBON_INSTALL_PATH/uploads" cache="$GIBBON_INSTALL_PATH/uploads/cache"
  if ! in_folder "$uploads" true; then
    echo "⚠ Warning: $uploads is a link or not a folder, so its cache was not cleared"
    return 0
  fi
  if [[ -L "$cache" || ( -e "$cache" && ! -d "$cache" ) ]]; then
    echo "⚠ Warning: $cache is a link or not a folder, so it is removed without being followed"
    if ! remove_entry "$cache"; then
      echo "✗ Error: can't remove $cache" >&2
      exit 1
    fi
  fi
  if ! { make_folder "$cache" && in_folder "$cache" _clear_uploads_cache_here; }; then
    echo "✗ Error: can't clear $cache" >&2
    exit 1
  fi
}
_clear_uploads_cache_here() {
  rm -rf -- ./* && chown -hR www-data:www-data . && env -u CLOUVE_OPS_PASSWORD runuser -u www-data -- chmod -R 755 .
}

# marker_present FILE: FILE is a regular file and not a link. Something else there (a link, a folder) doesn't count,
# and a warning names it.
marker_present() {
  plain_file "$1" && return 0
  if [[ -e "$1" || -L "$1" ]]; then
    echo "⚠ Warning: $1 is a link or not a regular file, so it is ignored"
  fi
  return 1
}

echo "TIMESTAMP=$TIMESTAMP"
echo "GIBBON_VERSION=$GIBBON_VERSION"

if [[ $GIBBON_LOG_LEVEL ]]; then
  echo "Setting apache log level to [$GIBBON_LOG_LEVEL]"
  sed -i "s/LogLevel warn/LogLevel $GIBBON_LOG_LEVEL/g" /etc/apache2/apache2.conf
fi

echo "Waiting for mysql server $DB_HOST ..."
while ! mysqladmin ping -h"$DB_HOST" --skip-ssl --silent; do
  sleep 1
  echo "--> still waiting for mysql server $DB_HOST ..."
done
echo "Mysql server $DB_HOST DB is up!"

state_folders
# What a start cut off between making a new file and renaming it left (safe_write's and update-config.sh's).
clear_temp_files "$INSTALLED_VERSIONS_PATH" "$GIBBON_VERSION" .moodle-integration-setup
clear_temp_files "$GIBBON_INSTALL_PATH" config.php

if [[ ! -d "$INSTALLED_VERSIONS_PATH" ]]; then
  echo "##################################################################"
  echo "INITIALIZING Gibbon $GIBBON_VERSION"

  echo "Creating $INSTALLED_VERSIONS_PATH directory ..."
  if ! { make_folder "$GIBBON_INSTALL_PATH/clouve" && make_folder "$INSTALLED_VERSIONS_PATH"; }; then
    echo "✗ Error: can't make $INSTALLED_VERSIONS_PATH" >&2
    exit 1
  fi

  "$GIBBON_PACKAGE_INSTALLER"/install.sh
  # The installer ran the site's PHP as www-data: nothing of it may still run while root goes on, and a folder it may
  # have swapped for a link is put right again.
  reap_www_data "the installer" || exit 1
  state_folders

  echo "Marking installed version $GIBBON_VERSION ..."
  safe_write "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION" "$TIMESTAMP"

  echo "##################################################################"

  # ============================================================================
  # GIBBON INTEGRATION SQL FROM ENVIRONMENT VARIABLES
  # ============================================================================
  # Execute SQL from GIBBON_INTEGRATION_SQL_* environment variables
  # This allows bundles to inject SQL without mounting scripts (marketplace compatible)
  # Supports multi-part SQL via GIBBON_INTEGRATION_SQL_1, GIBBON_INTEGRATION_SQL_2, etc.

  # Check if any integration SQL parts are defined
  if [[ -n "$GIBBON_INTEGRATION_SQL_1" ]]; then
    echo "##################################################################"
    echo "GIBBON INTEGRATION SQL FROM ENVIRONMENT VARIABLES"
    echo "##################################################################"

    # Check if integration is enabled
    if [[ "$ENABLE_MOODLE_INTEGRATION" != "true" ]]; then
      echo "ℹ ENABLE_MOODLE_INTEGRATION is not set to 'true', skipping integration setup"
    else
      # Check if integration was already completed
      if marker_present "$INSTALLED_VERSIONS_PATH/.moodle-integration-setup"; then
        echo "ℹ Moodle integration already configured (marker file exists), skipping"
      else
        echo "Creating Moodle integration views..."

        # Concatenate all SQL parts in order, in a new file of root's that only root can read, with a name no one
        # can know before.
        echo "Collecting SQL parts..."
        integration_sql="$(mktemp)"

        part_num=1
        while true; do
          var_name="GIBBON_INTEGRATION_SQL_${part_num}"
          var_value="${!var_name}"

          if [[ -z "$var_value" ]]; then
            break
          fi

          echo "  Found part $part_num"
          echo "$var_value" >> "$integration_sql"
          echo "" >> "$integration_sql"  # Add newline between parts
          part_num=$((part_num + 1))
        done

        echo "✓ Collected $((part_num - 1)) SQL part(s)"

        # Execute SQL to create views
        echo "Executing SQL to create integration views..."
        if MYSQL_PWD="$DB_PASSWORD" mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" < "$integration_sql" 2>&1; then
          echo "✓ Integration views created successfully"

          # Verify views were created
          echo "Verifying integration views..."

          if MYSQL_PWD="$DB_PASSWORD" mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "SELECT COUNT(*) as user_count FROM moodleUser;" 2>/dev/null; then
            echo "✓ moodleUser view is accessible"
          else
            echo "⚠ Warning: moodleUser view verification failed"
          fi

          if MYSQL_PWD="$DB_PASSWORD" mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "SELECT COUNT(*) as course_count FROM moodleCourse;" 2>/dev/null; then
            echo "✓ moodleCourse view is accessible"
          else
            echo "⚠ Warning: moodleCourse view verification failed"
          fi

          if MYSQL_PWD="$DB_PASSWORD" mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "SELECT COUNT(*) as enrollment_count FROM moodleEnrolment;" 2>/dev/null; then
            echo "✓ moodleEnrolment view is accessible"
          else
            echo "⚠ Warning: moodleEnrolment view verification failed"
          fi

          # Mark integration as completed
          safe_write "$INSTALLED_VERSIONS_PATH/.moodle-integration-setup" "$TIMESTAMP"

          echo "✓ Gibbon-to-Moodle integration setup completed successfully!"
        else
          echo "✗ Error: Failed to create integration views"
          rm -f "$integration_sql"
          echo "  Continuing with startup..."
        fi

        # Cleanup
        rm -f "$integration_sql"
      fi
    fi

    echo "##################################################################"
  fi
fi

if ! marker_present "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION" && [[ -d "$GIBBON_PACKAGE_PATH" ]]; then
  echo "##################################################################"
  echo "UPGRADING Gibbon to $GIBBON_VERSION"

  "$GIBBON_PACKAGE_INSTALLER"/upgrade.sh
  reap_www_data "the upgrade's copy" || exit 1
  state_folders

  echo "Marking installed version $GIBBON_VERSION ..."
  safe_write "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION" "$TIMESTAMP"

  echo "##################################################################"
fi

# The image's PHP libraries reach a site already on this Gibbon version (tests/vendor-refresh.test.sh).
"$GIBBON_PACKAGE_INSTALLER"/refresh-vendor.sh gibbon "$GIBBON_PACKAGE_PATH" "$GIBBON_INSTALL_PATH" "$INSTALLED_VERSIONS_PATH"

echo "Clearing uploads cache ..."
clear_uploads_cache
reap_www_data "the cache cleanup" || exit 1

# ============================================================================
# UPDATE CONFIGURATION ON EVERY STARTUP
# ============================================================================
# This ensures config.php and database settings stay synchronized with
# environment variables even if they change after initial installation.
# This runs on every container startup, after installation/upgrade.

echo ""
echo "##################################################################"
echo "UPDATING CONFIGURATION FROM ENVIRONMENT VARIABLES"
echo "##################################################################"

# Without CLOUVE_OPS_PASSWORD: update-config.sh doesn't need it, so nothing it runs can show it. It can run chmod as
# config.php's owner (www-data), so what that left is ended too.
env -u CLOUVE_OPS_PASSWORD "$GIBBON_PACKAGE_INSTALLER"/update-config.sh
reap_www_data "update-config.sh" || exit 1

echo "##################################################################"
echo ""

echo "DONE!"

# ============================================================================
# CLOUVE-OPS SSHD: shell channel for the Magneto Agent container's Claude Code agent
# ============================================================================
# Backgrounded — applies the per-pod password from CLOUVE_OPS_PASSWORD
# (same value on all three services) to the clouve-ops user via chpasswd,
# then exec's sshd -D inside its own background tree. Dies with the
# container when apache (PID 1) exits.
"$GIBBON_PACKAGE_INSTALLER"/start-clouve-ops-sshd.sh &

# The sshd start above has its own copy of CLOUVE_OPS_PASSWORD. Apache, which this script becomes, must not carry it:
# mod_php's getenv() reads Apache's environment, so any PHP code could read the password, which signs in as
# clouve-ops, who has passwordless sudo. Nothing later here needs it, and the AI Assistant has its own copy
# (tests/app-ops-password.test.sh).
unset CLOUVE_OPS_PASSWORD

# ============================================================================
# CONFIGURE AND START CRON DAEMON FOR SCHEDULED TASKS
# ============================================================================
# Generate /etc/cron.d/gibbon-cron dynamically from GIBBON_CRON_INTERVAL.
# Default: * * * * * (every minute — the wrapper decides per-task cadence).
# Logs are written to /var/log/gibbon-cron.log.

echo "Configuring Gibbon cron job..."

GIBBON_CRON_INTERVAL="${GIBBON_CRON_INTERVAL:-* * * * *}"

echo "  Cron schedule: $GIBBON_CRON_INTERVAL"

FIELD_COUNT=$(echo "$GIBBON_CRON_INTERVAL" | awk '{print NF}')
if [ "$FIELD_COUNT" -ne 5 ]; then
  echo "⚠ Warning: GIBBON_CRON_INTERVAL appears to have invalid format (expected 5 fields, got $FIELD_COUNT)"
  echo "  Using default: * * * * *"
  GIBBON_CRON_INTERVAL="* * * * *"
fi

cat > /etc/cron.d/gibbon-cron << EOF
# Gibbon Cron Job Configuration
# Runs Gibbon's scheduled tasks based on GIBBON_CRON_INTERVAL
# Schedule: $GIBBON_CRON_INTERVAL

$GIBBON_CRON_INTERVAL root /clouve/gibbon/installer/gibbon-cron.sh

# Empty line required at end of crontab file
EOF

chmod 0644 /etc/cron.d/gibbon-cron

touch /var/log/gibbon-cron.log
chown www-data:www-data /var/log/gibbon-cron.log

echo "✓ Crontab file generated successfully"

echo "Starting cron daemon for Gibbon scheduled tasks..."
service cron start

if service cron status > /dev/null 2>&1; then
  echo "✓ Cron daemon started successfully"
  echo "  Gibbon cron schedule: $GIBBON_CRON_INTERVAL"
  echo "  Check logs at: /var/log/gibbon-cron.log"
else
  echo "⚠ Warning: Cron daemon may not have started properly"
fi

exec "$@"
