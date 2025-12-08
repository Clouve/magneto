#!/bin/bash
set -e

TIMESTAMP=$(date +"%Y-%m-%d-%H-%M-%S")
export TIMESTAMP=$TIMESTAMP
export GIBBON_PACKAGE_PATH="/clouve/$GIBBON_PATH"
export GIBBON_INSTALL_PATH="/var/www/html"
export GIBBON_PACKAGE_INSTALLER="/clouve/gibbon/installer"
export INSTALLED_VERSIONS_PATH="/var/www/html/clouve/installed"

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

if [[ ! -d "$INSTALLED_VERSIONS_PATH" ]]; then
  echo "##################################################################"
  echo "INITIALIZING Gibbon $GIBBON_VERSION"

  echo "Creating $INSTALLED_VERSIONS_PATH directory ..."
  mkdir -p "$INSTALLED_VERSIONS_PATH"

  "$GIBBON_PACKAGE_INSTALLER"/install.sh

  echo "Marking installed version $GIBBON_VERSION ..."
  touch "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION"
  echo "$TIMESTAMP" > "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION"

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
      if [[ -f "$INSTALLED_VERSIONS_PATH/.moodle-integration-setup" ]]; then
        echo "ℹ Moodle integration already configured (marker file exists), skipping"
      else
        echo "Creating Moodle integration views..."

        # Concatenate all SQL parts in order
        echo "Collecting SQL parts..."
        > /tmp/gibbon-integration.sql  # Create empty file

        part_num=1
        while true; do
          var_name="GIBBON_INTEGRATION_SQL_${part_num}"
          var_value="${!var_name}"

          if [[ -z "$var_value" ]]; then
            break
          fi

          echo "  Found part $part_num"
          echo "$var_value" >> /tmp/gibbon-integration.sql
          echo "" >> /tmp/gibbon-integration.sql  # Add newline between parts
          part_num=$((part_num + 1))
        done

        echo "✓ Collected $((part_num - 1)) SQL part(s)"

        # Execute SQL to create views
        echo "Executing SQL to create integration views..."
        if mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < /tmp/gibbon-integration.sql 2>&1; then
          echo "✓ Integration views created successfully"

          # Verify views were created
          echo "Verifying integration views..."

          if mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SELECT COUNT(*) as user_count FROM moodleUser;" 2>/dev/null; then
            echo "✓ moodleUser view is accessible"
          else
            echo "⚠ Warning: moodleUser view verification failed"
          fi

          if mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SELECT COUNT(*) as course_count FROM moodleCourse;" 2>/dev/null; then
            echo "✓ moodleCourse view is accessible"
          else
            echo "⚠ Warning: moodleCourse view verification failed"
          fi

          if mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SELECT COUNT(*) as enrollment_count FROM moodleEnrolment;" 2>/dev/null; then
            echo "✓ moodleEnrolment view is accessible"
          else
            echo "⚠ Warning: moodleEnrolment view verification failed"
          fi

          # Mark integration as completed
          touch "$INSTALLED_VERSIONS_PATH/.moodle-integration-setup"
          echo "$TIMESTAMP" > "$INSTALLED_VERSIONS_PATH/.moodle-integration-setup"

          echo "✓ Gibbon-to-Moodle integration setup completed successfully!"
        else
          echo "✗ Error: Failed to create integration views"
          rm -f /tmp/gibbon-integration.sql
          echo "  Continuing with startup..."
        fi

        # Cleanup
        rm -f /tmp/gibbon-integration.sql
      fi
    fi

    echo "##################################################################"
  fi
fi

if [[ ! -f "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION" && -d "$GIBBON_PACKAGE_PATH" ]]; then
  echo "##################################################################"
  echo "UPGRADING Gibbon to $GIBBON_VERSION"

  "$GIBBON_PACKAGE_INSTALLER"/upgrade.sh

  echo "Marking installed version $GIBBON_VERSION ..."
  touch "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION"
  echo "$TIMESTAMP" > "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION"

  echo "##################################################################"
fi

echo "Clearing uploads cache ..."
rm -rf /var/www/html/uploads/cache/*
chown -R www-data:www-data /var/www/html/uploads/cache
chmod -R 755 /var/www/html/uploads/cache

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

"$GIBBON_PACKAGE_INSTALLER"/update-config.sh

echo "##################################################################"
echo ""

echo "DONE!"

exec "$@"
