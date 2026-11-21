#!/bin/bash
set -e

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
export TIMESTAMP=$TIMESTAMP
export MOODLE_PACKAGE_PATH="/clouve/$MOODLE_PATH"
export MOODLE_INSTALL_PATH="/var/www/html"
export MOODLE_PACKAGE_INSTALLER="/clouve/moodle/installer"
export INSTALLED_VERSIONS_PATH="/var/www/html/clouve/installed"
export MOODLEDATA_PATH="/var/moodledata"
export INSTALLED_VERSION_STAMP="$INSTALLED_VERSIONS_PATH/version"

# stamp_folders, stamp_read and safe_write: clouve/installed/ is on the volume, which www-data can change, and this
# script runs as root (tests/moodle-version-stamp.test.sh).
. "$MOODLE_PACKAGE_INSTALLER/stamp.sh"
# reap_www_data: after each step that runs the site's PHP as www-data, and before root touches files again, every
# process that PHP left running is ended; when it can't make sure, the start stops there (`|| exit 1`;
# installer/www-data.sh, tests/moodle-root-paths.test.sh).
. "$MOODLE_PACKAGE_INSTALLER/www-data.sh"

# Read the integer Moodle code version ($version in version.php) from a code tree.
# Moodle 5.1+ may nest the codebase under public/, so check there first.
# The site's copy is www-data's: dd reads at most 1 MiB, doesn't follow a link at version.php (nofollow; a link there
# gives nothing) and doesn't wait on a pipe (nonblock, and -f skips one), and only the digits of $version come out.
moodle_code_version() {
  local root="$1" vf
  for vf in "$root/public/version.php" "$root/version.php"; do
    if [[ -f "$vf" ]]; then
      dd if="$vf" iflag=nofollow,nonblock bs=1M count=1 status=none 2>/dev/null |
        sed -nE 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' | head -1
      return 0
    fi
  done
}

# Exact Moodle version baked into THIS image — the authoritative upgrade trigger.
IMAGE_VERSION="$(moodle_code_version "$MOODLE_PACKAGE_PATH")"

echo "TIMESTAMP=$TIMESTAMP"
echo "MOODLE_VERSION=$MOODLE_RELEASE (build $IMAGE_VERSION)"

# Set Apache log level if specified
if [[ $MOODLE_LOG_LEVEL ]]; then
  echo "Setting apache log level to [$MOODLE_LOG_LEVEL]"
  sed -i "s/LogLevel warn/LogLevel $MOODLE_LOG_LEVEL/g" /etc/apache2/apache2.conf
fi

# Wait for database to be ready
echo "Waiting for mysql server $DB_HOST ..."
while ! mysqladmin ping -h"$DB_HOST" --skip-ssl --silent; do
  sleep 1
  echo "--> still waiting for mysql server $DB_HOST ..."
done
echo "MySQL server $DB_HOST is up!"

# A link at clouve/ or clouve/installed/ would send every read and write below wherever it points. It is removed
# without being followed; an installed site gets both folders back, empty, and its stamp from its code.
stamp_folders "$MOODLE_INSTALL_PATH"

# An installed site (anything at config.php) whose clouve/installed/ is gone is not a new site, and is never installed
# again: install.php loads config.php when one is there, and www-data can write config.php. The folder is made again,
# empty, and the stamp is recorded from the site's code below, as for a linked folder (tests/moodle-root-paths.test.sh).
if [[ ! -d "$INSTALLED_VERSIONS_PATH" ]] && [[ -e "$MOODLE_INSTALL_PATH/config.php" || -L "$MOODLE_INSTALL_PATH/config.php" ]]; then
  echo "⚠ Warning: $INSTALLED_VERSIONS_PATH is missing but the site has a config.php, so the folder is made again and the site is not installed again"
  if ! { in_folder "$MOODLE_INSTALL_PATH" mkdir -p -- clouve &&
      in_folder "$MOODLE_INSTALL_PATH/clouve" mkdir -p -- installed; } 2>/dev/null; then
    echo "✗ Error: can't make $INSTALLED_VERSIONS_PATH" >&2
    exit 1
  fi
fi

# Check if this is a fresh installation
if [[ ! -d "$INSTALLED_VERSIONS_PATH" ]]; then
  echo "##################################################################"
  echo "INITIALIZING Moodle $MOODLE_RELEASE"

  echo "Creating $INSTALLED_VERSIONS_PATH directory ..."
  mkdir -p "$INSTALLED_VERSIONS_PATH"

  "$MOODLE_PACKAGE_INSTALLER"/install.sh
  reap_www_data "the install" || exit 1
  # install.php ran as www-data: a link it left at clouve/ or clouve/installed/ is removed, as above, before the stamp
  # is written there.
  stamp_folders "$MOODLE_INSTALL_PATH"

  echo "Marking installed version $MOODLE_RELEASE ($IMAGE_VERSION) ..."
  safe_write "$INSTALLED_VERSION_STAMP" "$IMAGE_VERSION"
  safe_write "$INSTALLED_VERSIONS_PATH/$MOODLE_RELEASE" "$TIMESTAMP"

  echo "##################################################################"
fi

# ============================================================================
# MOODLE INTEGRATION SQL FROM ENVIRONMENT VARIABLES
# ============================================================================
# Execute SQL from MOODLE_INTEGRATION_SQL_* environment variables
# This allows bundles to inject SQL without mounting scripts (marketplace compatible)
# Supports multi-part SQL via MOODLE_INTEGRATION_SQL_1, MOODLE_INTEGRATION_SQL_2, etc.
#
# Runs on every startup until it has succeeded once (marker-gated below) — not
# only on fresh install — so a seed that missed its window (e.g. Gibbon still
# installing when this pod first booted) retries on the next restart instead of
# being lost forever.

# MySQL string-literal escaping for values substituted into the integration SQL.
sql_escape() {
  local v="$1" bs="\\" q="'"
  v="${v//"$bs"/"$bs$bs"}"
  v="${v//"$q"/"$bs$q"}"
  printf '%s' "$v"
}

# Check if any integration SQL parts are defined
if [[ -n "$MOODLE_INTEGRATION_SQL_1" ]]; then
  echo "##################################################################"
  echo "MOODLE INTEGRATION SQL FROM ENVIRONMENT VARIABLES"
  echo "##################################################################"

  # Check if integration is enabled
  if [[ "$ENABLE_GIBBON_INTEGRATION" != "true" ]]; then
    echo "ℹ ENABLE_GIBBON_INTEGRATION is not set to 'true', skipping integration setup"
  else
    # Check if integration was already completed
    if [[ -f "$INSTALLED_VERSIONS_PATH/.gibbon-integration-setup" ]]; then
      echo "ℹ Gibbon integration already configured (marker file exists), skipping"
    else
      # Verify required environment variables
      if [[ -z "$GIBBON_DB_HOST" ]] || [[ -z "$GIBBON_DB_NAME" ]] || [[ -z "$GIBBON_DB_USER" ]] || [[ -z "$GIBBON_DB_PASSWORD" ]]; then
        echo "✗ Error: Missing required Gibbon database environment variables"
        echo "  Required: GIBBON_DB_HOST, GIBBON_DB_NAME, GIBBON_DB_USER, GIBBON_DB_PASSWORD"
        echo "  Continuing with startup..."
      else
        echo "Waiting for Gibbon database to be ready..."

        # Wait for Gibbon database to be accessible
        max_attempts=60
        attempt=0
        while [ $attempt -lt $max_attempts ]; do
          if mysqladmin ping -h"$GIBBON_DB_HOST" --skip-ssl --silent 2>/dev/null; then
            echo "✓ Gibbon database is ready"
            break
          fi
          attempt=$((attempt + 1))
          echo "  Waiting for Gibbon database... (attempt $attempt/$max_attempts)"
          sleep 2
        done

        if [ $attempt -eq $max_attempts ]; then
          echo "✗ Error: Gibbon database did not become ready in time"
          echo "  Continuing with startup..."
        else
          # Wait for Gibbon integration views to be created
          echo "Waiting for Gibbon integration views to be created..."
          view_check_attempts=30
          view_attempt=0
          views_ready=false

          while [ $view_attempt -lt $view_check_attempts ]; do
            if MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql --skip-ssl -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" \
               -e "SELECT 1 FROM moodleUser LIMIT 1;" 2>/dev/null >/dev/null; then
              echo "✓ Gibbon integration views are ready"
              views_ready=true
              break
            fi
            view_attempt=$((view_attempt + 1))
            echo "  Waiting for Gibbon integration views... (attempt $view_attempt/$view_check_attempts)"
            sleep 2
          done

          if [[ "$views_ready" != "true" ]]; then
            echo "✗ Error: Gibbon integration views not found"
            echo "  Make sure the Gibbon container has ENABLE_MOODLE_INTEGRATION=true"
            echo "  Continuing with startup..."
          else
            echo "Configuring Moodle External Database plugins..."

            # Concatenate all SQL parts in order, in a new file of root's that only root can read, with a name no
            # one can know before (it holds Gibbon's database password).
            echo "Collecting SQL parts..."
            integration_sql="$(mktemp)"

            part_num=1
            while true; do
              var_name="MOODLE_INTEGRATION_SQL_${part_num}"
              var_value="${!var_name}"

              if [[ -z "$var_value" ]]; then
                break
              fi

              echo "  Found part $part_num"

              # The bundle manifest ships ${GIBBON_DB_*} placeholders in the
              # SQL so the connection settings resolve per deployment (on
              # Kubernetes the host is ticket-prefixed and the password is a
              # generated secret). Expand exactly these variables — no other
              # $ in the SQL is touched.
              for gibbon_var in GIBBON_DB_HOST GIBBON_DB_NAME GIBBON_DB_USER GIBBON_DB_PASSWORD; do
                placeholder='${'"$gibbon_var"'}'
                replacement="$(sql_escape "${!gibbon_var}")"
                var_value="${var_value//"$placeholder"/"$replacement"}"
              done

              echo "$var_value" >> "$integration_sql"
              echo "" >> "$integration_sql"  # Add newline between parts
              part_num=$((part_num + 1))
            done

            echo "✓ Collected $((part_num - 1)) SQL part(s)"

            # Execute SQL to configure Moodle
            echo "Executing SQL to configure Moodle plugins..."
            if MYSQL_PWD="$DB_PASSWORD" mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" < "$integration_sql" 2>&1; then
              echo "✓ Moodle integration configured successfully"

              # Test connection to Gibbon database
              echo "Testing connection to Gibbon database..."
              if MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql --skip-ssl -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" \
                 -e "SELECT COUNT(*) as user_count FROM moodleUser;" 2>/dev/null; then
                echo "✓ Moodle can successfully connect to Gibbon database"
              else
                echo "⚠ Warning: Connection test to Gibbon database failed"
              fi

              # Mark integration as completed
              safe_write "$INSTALLED_VERSIONS_PATH/.gibbon-integration-setup" "$TIMESTAMP"

              # When the seed ran on a restart (not a fresh install), Moodle's
              # MUC cache may still hold the pre-integration config — purge so
              # the new plugin config takes effect immediately. File ownership
              # is normalized by the moodledata chown further down.
              # purge_caches.php loads config.php and the plugins' code, which
              # www-data can change, so it runs as www-data, as all of the
              # site's PHP does, and without CLOUVE_OPS_PASSWORD, which goes
              # before runuser (tests/moodle-root-paths.test.sh).
              for purge_cli in "$MOODLE_INSTALL_PATH/public/admin/cli/purge_caches.php" "$MOODLE_INSTALL_PATH/admin/cli/purge_caches.php"; do
                if [[ -f "$purge_cli" ]]; then
                  env -u CLOUVE_OPS_PASSWORD runuser -u www-data -- php "$purge_cli" || echo "⚠ Warning: cache purge failed (continuing)"
                  reap_www_data "purge_caches.php" || exit 1
                  # The purge ran the site's code: a link it left at clouve/ or clouve/installed/ is removed, as
                  # above, before root reads or writes there again.
                  stamp_folders "$MOODLE_INSTALL_PATH"
                  break
                fi
              done

              echo "✓ Moodle-to-Gibbon integration setup completed successfully!"
            else
              echo "✗ Error: Failed to configure Moodle integration"
              rm -f "$integration_sql"
              echo "  Continuing with startup..."
            fi

            # Cleanup
            rm -f "$integration_sql"
          fi
        fi
      fi
    fi
  fi

  echo "##################################################################"
fi

# Check if an upgrade is needed by comparing the exact Moodle $version baked into
# this image against the version recorded on the data volume. Keying on the exact
# build (e.g. 2026100500) — not the coarse "5.3" release — means point-build bumps
# are detected, and a pod restart can never silently run newer code than the DB.
# www-data can write the stamp, and -gt below evaluates both sides as arithmetic, where a value such as a[$(cmd)] runs
# cmd. stamp_read takes the stamp only from a regular file of digits; anything else there is ignored, and the log
# names the file but never shows what is in it.
INSTALLED_VERSION="$(stamp_read "$INSTALLED_VERSION_STAMP")"
if [[ -z "$INSTALLED_VERSION" ]] && [[ -e "$INSTALLED_VERSION_STAMP" || -L "$INSTALLED_VERSION_STAMP" ]]; then
  echo "⚠ Warning: $INSTALLED_VERSION_STAMP is not a plain version number, so it is ignored"
fi

# Back-compat: installs created before the version stamp existed are seeded from
# the code currently on the volume so we don't trigger a spurious upgrade.
if [[ -z "$INSTALLED_VERSION" && -f "$MOODLE_INSTALL_PATH/config.php" ]]; then
  INSTALLED_VERSION="$(moodle_code_version "$MOODLE_INSTALL_PATH")"
  [[ -n "$INSTALLED_VERSION" ]] && safe_write "$INSTALLED_VERSION_STAMP" "$INSTALLED_VERSION"
fi
INSTALLED_VERSION="${INSTALLED_VERSION:-0}"

# Both sides must be plain digits before -gt sees them, at most 18 so that its 64-bit arithmetic can't wrap (the
# reseed above reads the volume's version.php); 10# reads them as decimal.
if [[ -d "$MOODLE_PACKAGE_PATH" && "$IMAGE_VERSION" =~ ^[0-9]{1,18}$ && "$INSTALLED_VERSION" =~ ^[0-9]{1,18}$ ]] \
    && [[ "10#$IMAGE_VERSION" -gt "10#$INSTALLED_VERSION" ]]; then
  echo "##################################################################"
  echo "UPGRADING Moodle $INSTALLED_VERSION -> $IMAGE_VERSION ($MOODLE_RELEASE)"

  # Status 3: upgrade.sh changed nothing, because the site can't move to this Moodle as it is (it said why). The site
  # keeps running the code on its volume, no new version is recorded, and the next start checks again.
  upgrade_status=0
  "$MOODLE_PACKAGE_INSTALLER"/upgrade.sh || upgrade_status=$?
  reap_www_data "the upgrade" || exit 1
  # The upgrade ran the site's code: a link it left at clouve/ or clouve/installed/ is removed, as above, before the
  # stamp is written there.
  stamp_folders "$MOODLE_INSTALL_PATH"
  if (( upgrade_status == 3 )); then
    echo "NOT UPGRADED: Moodle stays at $INSTALLED_VERSION, on the code already on the volume (see above)."
  elif (( upgrade_status != 0 )); then
    exit "$upgrade_status"
  else
    echo "Marking installed version $MOODLE_RELEASE ($IMAGE_VERSION) ..."
    safe_write "$INSTALLED_VERSION_STAMP" "$IMAGE_VERSION"
    safe_write "$INSTALLED_VERSIONS_PATH/$MOODLE_RELEASE" "$TIMESTAMP"
  fi

  echo "##################################################################"
fi

# The image's PHP libraries reach a site already on this Moodle version (tests/vendor-refresh.test.sh).
"$MOODLE_PACKAGE_INSTALLER"/refresh-vendor.sh moodle "$MOODLE_PACKAGE_PATH" "$MOODLE_INSTALL_PATH" "$INSTALLED_VERSIONS_PATH"

# Ensure proper permissions
echo "Setting permissions for Moodle files ..."
chown -R www-data:www-data "$MOODLE_INSTALL_PATH"
chmod -R 755 "$MOODLE_INSTALL_PATH"

echo "Setting permissions for moodledata ..."
chown -R www-data:www-data "$MOODLEDATA_PATH"
chmod -R 0777 "$MOODLEDATA_PATH"

# ============================================================================
# UPDATE MOODLE CONFIGURATION ON EVERY STARTUP
# ============================================================================
# This updates config.php with current environment variable values for:
# - Database credentials (DB_HOST, DB_NAME, DB_USER, DB_PASSWORD)
# - Moodle URL (MOODLE_URL -> $CFG->wwwroot)
# - SSL proxy configuration (based on MOODLE_URL protocol)
# This runs on every container startup, after installation/upgrade.

# Run the update-config.sh script to update database credentials and wwwroot
"$MOODLE_PACKAGE_INSTALLER"/update-config.sh

# The Education Kit: Moodle's own copy of Gibbon's database password (the sign-in through Gibbon and the enrolment
# sync) follows the deployment's, so a rotated password reaches it here too (release 4.5.6). It does nothing outside
# the kit.
"$MOODLE_PACKAGE_INSTALLER"/gibbon-integration-password.sh
reap_www_data "gibbon-integration-password.php" || exit 1

# ============================================================================
# CONFIGURE SSL PROXY ON EVERY STARTUP
# ============================================================================
# This ensures $CFG->sslproxy = true; is always present in config.php
# even if the initial installation timed out before this setting was added.
# config.php is read and changed through update-config.sh, which never follows a link there and changes it by renaming
# a new file over it: a link or anything but a regular file there is left as it is, with a warning, and the start goes
# on (tests/moodle-root-paths.test.sh).

echo "Checking SSL proxy configuration..."

# Check if config.php exists (meaning Moodle has been installed)
if [ -e "$MOODLE_INSTALL_PATH/config.php" ] || [ -L "$MOODLE_INSTALL_PATH/config.php" ]; then
  # Automatically detect if SSL proxy mode should be enabled based on MOODLE_URL protocol
  # If MOODLE_URL starts with https://, enable SSL proxy mode
  if [[ "${MOODLE_URL:-http://localhost}" =~ ^https:// ]]; then
    echo "SSL proxy mode should be ENABLED (detected HTTPS in MOODLE_URL: ${MOODLE_URL})"

    # Check if $CFG->sslproxy is already present in config.php
    sslproxy_rc=0
    config_text="$("$MOODLE_PACKAGE_INSTALLER"/update-config.sh --read "$MOODLE_INSTALL_PATH/config.php")" || sslproxy_rc=$?
    if (( sslproxy_rc == 2 )); then
      echo "  No SSL proxy configuration was added."
    elif (( sslproxy_rc != 0 )); then
      exit "$sslproxy_rc"
    elif grep -q "^\$CFG->sslproxy" <<< "$config_text"; then
      echo "✓ SSL proxy configuration already present in config.php"
    else
      echo "Adding SSL proxy configuration to config.php..."
      # Add $CFG->sslproxy = true; before the require_once line
      "$MOODLE_PACKAGE_INSTALLER"/update-config.sh --edit "$MOODLE_INSTALL_PATH/config.php" \
        sed "/require_once.*lib\/setup.php/i \$CFG->sslproxy = true;\n" || sslproxy_rc=$?
      if (( sslproxy_rc == 0 )); then
        echo "✓ SSL proxy configuration added to config.php"
      elif (( sslproxy_rc == 2 )); then
        echo "  No SSL proxy configuration was added."
      else
        exit "$sslproxy_rc"
      fi
    fi
  else
    echo "SSL proxy mode DISABLED (detected HTTP in MOODLE_URL: ${MOODLE_URL:-http://localhost})"
    echo "Running in direct HTTP mode (suitable for local development)"
  fi
else
  echo "ℹ config.php not found - Moodle not yet installed, skipping SSL proxy configuration"
fi

echo "DONE!"

# ============================================================================
# CLOUVE-OPS SSHD: shell channel for the magneto-agent container's Claude Code agent
# ============================================================================
# Backgrounded — applies the per-pod password from CLOUVE_OPS_PASSWORD
# (same value on all three services) to the clouve-ops user via chpasswd,
# then exec's sshd -D inside its own background tree. Dies with the
# container when apache (PID 1) exits.
"$MOODLE_PACKAGE_INSTALLER"/start-clouve-ops-sshd.sh &

# The sshd start above has its own copy of CLOUVE_OPS_PASSWORD. Apache, which this script becomes, must not carry it:
# mod_php's getenv() reads Apache's environment, so any PHP code could read the password, which signs in as
# clouve-ops, who has passwordless sudo. Nothing later here needs it, and the AI Assistant has its own copy
# (tests/app-ops-password.test.sh).
unset CLOUVE_OPS_PASSWORD

# ============================================================================
# CONFIGURE AND START CRON DAEMON FOR SCHEDULED TASKS
# ============================================================================
# Generate crontab dynamically based on MOODLE_CRON_INTERVAL environment variable
# Default: */5 * * * * (every 5 minutes)
# The cron job will be configured in /etc/cron.d/moodle-cron
# Logs are written to /var/log/moodle-cron.log

echo "Configuring Moodle cron job..."

# Set default cron interval if not provided
MOODLE_CRON_INTERVAL="${MOODLE_CRON_INTERVAL:-*/5 * * * *}"

echo "  Cron schedule: $MOODLE_CRON_INTERVAL"

# Validate cron interval format (basic validation)
# A valid cron expression should have 5 fields (minute hour day month weekday)
FIELD_COUNT=$(echo "$MOODLE_CRON_INTERVAL" | awk '{print NF}')
if [ "$FIELD_COUNT" -ne 5 ]; then
  echo "⚠ Warning: MOODLE_CRON_INTERVAL appears to have invalid format (expected 5 fields, got $FIELD_COUNT)"
  echo "  Using default: */5 * * * *"
  MOODLE_CRON_INTERVAL="*/5 * * * *"
fi

# Generate crontab file dynamically
cat > /etc/cron.d/moodle-cron << EOF
# Moodle Cron Job Configuration
# Runs Moodle's scheduled tasks based on MOODLE_CRON_INTERVAL
# Schedule: $MOODLE_CRON_INTERVAL

$MOODLE_CRON_INTERVAL root /clouve/moodle/installer/moodle-cron.sh

# Empty line required at end of crontab file
EOF

# Set proper permissions for crontab file
chmod 0644 /etc/cron.d/moodle-cron

# Create log file if it doesn't exist
touch /var/log/moodle-cron.log
chown www-data:www-data /var/log/moodle-cron.log

echo "✓ Crontab file generated successfully"

# Start cron daemon
echo "Starting cron daemon for Moodle scheduled tasks..."
service cron start

if service cron status > /dev/null 2>&1; then
  echo "✓ Cron daemon started successfully"
  echo "  Moodle cron schedule: $MOODLE_CRON_INTERVAL"
  echo "  Check logs at: /var/log/moodle-cron.log"
else
  echo "⚠ Warning: Cron daemon may not have started properly"
fi

exec "$@"

