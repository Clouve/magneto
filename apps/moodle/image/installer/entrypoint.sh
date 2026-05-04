#!/bin/bash
set -e

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
export TIMESTAMP=$TIMESTAMP
export MOODLE_PACKAGE_PATH="/clouve/$MOODLE_PATH"
export MOODLE_INSTALL_PATH="/var/www/html"
export MOODLE_PACKAGE_INSTALLER="/clouve/moodle/installer"
export INSTALLED_VERSIONS_PATH="/var/www/html/clouve/installed"
export MOODLEDATA_PATH="/var/moodledata"

echo "TIMESTAMP=$TIMESTAMP"
echo "MOODLE_VERSION=$MOODLE_RELEASE"

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

# Check if this is a fresh installation
if [[ ! -d "$INSTALLED_VERSIONS_PATH" ]]; then
  echo "##################################################################"
  echo "INITIALIZING Moodle $MOODLE_RELEASE"

  echo "Creating $INSTALLED_VERSIONS_PATH directory ..."
  mkdir -p "$INSTALLED_VERSIONS_PATH"

  "$MOODLE_PACKAGE_INSTALLER"/install.sh

  echo "Marking installed version $MOODLE_RELEASE ..."
  touch "$INSTALLED_VERSIONS_PATH/$MOODLE_RELEASE"
  echo "$TIMESTAMP" > "$INSTALLED_VERSIONS_PATH/$MOODLE_RELEASE"

  echo "##################################################################"

  # ============================================================================
  # MOODLE INTEGRATION SQL FROM ENVIRONMENT VARIABLES
  # ============================================================================
  # Execute SQL from MOODLE_INTEGRATION_SQL_* environment variables
  # This allows bundles to inject SQL without mounting scripts (marketplace compatible)
  # Supports multi-part SQL via MOODLE_INTEGRATION_SQL_1, MOODLE_INTEGRATION_SQL_2, etc.

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
              if mysql --skip-ssl -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" -p"$GIBBON_DB_PASSWORD" "$GIBBON_DB_NAME" \
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

              # Concatenate all SQL parts in order
              echo "Collecting SQL parts..."
              > /tmp/moodle-integration.sql  # Create empty file

              part_num=1
              while true; do
                var_name="MOODLE_INTEGRATION_SQL_${part_num}"
                var_value="${!var_name}"

                if [[ -z "$var_value" ]]; then
                  break
                fi

                echo "  Found part $part_num"
                echo "$var_value" >> /tmp/moodle-integration.sql
                echo "" >> /tmp/moodle-integration.sql  # Add newline between parts
                part_num=$((part_num + 1))
              done

              echo "✓ Collected $((part_num - 1)) SQL part(s)"

              # Execute SQL to configure Moodle
              echo "Executing SQL to configure Moodle plugins..."
              if mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < /tmp/moodle-integration.sql 2>&1; then
                echo "✓ Moodle integration configured successfully"

                # Test connection to Gibbon database
                echo "Testing connection to Gibbon database..."
                if mysql --skip-ssl -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" -p"$GIBBON_DB_PASSWORD" "$GIBBON_DB_NAME" \
                   -e "SELECT COUNT(*) as user_count FROM moodleUser;" 2>/dev/null; then
                  echo "✓ Moodle can successfully connect to Gibbon database"
                else
                  echo "⚠ Warning: Connection test to Gibbon database failed"
                fi

                # Mark integration as completed
                touch "$INSTALLED_VERSIONS_PATH/.gibbon-integration-setup"
                echo "$TIMESTAMP" > "$INSTALLED_VERSIONS_PATH/.gibbon-integration-setup"

                echo "✓ Moodle-to-Gibbon integration setup completed successfully!"
              else
                echo "✗ Error: Failed to configure Moodle integration"
                rm -f /tmp/moodle-integration.sql
                echo "  Continuing with startup..."
              fi

              # Cleanup
              rm -f /tmp/moodle-integration.sql
            fi
          fi
        fi
      fi
    fi

    echo "##################################################################"
  fi
fi

# Check if upgrade is needed
if [[ ! -f "$INSTALLED_VERSIONS_PATH/$MOODLE_RELEASE" && -d "$MOODLE_PACKAGE_PATH" ]]; then
  echo "##################################################################"
  echo "UPGRADING Moodle to $MOODLE_RELEASE"

  "$MOODLE_PACKAGE_INSTALLER"/upgrade.sh

  echo "Marking installed version $MOODLE_RELEASE ..."
  touch "$INSTALLED_VERSIONS_PATH/$MOODLE_RELEASE"
  echo "$TIMESTAMP" > "$INSTALLED_VERSIONS_PATH/$MOODLE_RELEASE"

  echo "##################################################################"
fi

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

# ============================================================================
# CONFIGURE SSL PROXY ON EVERY STARTUP
# ============================================================================
# This ensures $CFG->sslproxy = true; is always present in config.php
# even if the initial installation timed out before this setting was added.

echo "Checking SSL proxy configuration..."

# Check if config.php exists (meaning Moodle has been installed)
if [ -f "$MOODLE_INSTALL_PATH/config.php" ]; then
  # Automatically detect if SSL proxy mode should be enabled based on MOODLE_URL protocol
  # If MOODLE_URL starts with https://, enable SSL proxy mode
  if [[ "${MOODLE_URL:-http://localhost}" =~ ^https:// ]]; then
    echo "SSL proxy mode should be ENABLED (detected HTTPS in MOODLE_URL: ${MOODLE_URL})"

    # Check if $CFG->sslproxy is already present in config.php
    if grep -q "^\$CFG->sslproxy" "$MOODLE_INSTALL_PATH/config.php"; then
      echo "✓ SSL proxy configuration already present in config.php"
    else
      echo "Adding SSL proxy configuration to config.php..."
      # Add $CFG->sslproxy = true; before the require_once line
      sed -i "/require_once.*lib\/setup.php/i \$CFG->sslproxy = true;\n" "$MOODLE_INSTALL_PATH/config.php"
      echo "✓ SSL proxy configuration added to config.php"
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

