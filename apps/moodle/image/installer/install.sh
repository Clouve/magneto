#!/bin/bash
set -e

# Run upgrade script to copy files
"$MOODLE_PACKAGE_INSTALLER"/upgrade.sh

# Wait a bit for database to be fully ready
sleep 5

# Run Moodle CLI installation
echo "Executing Moodle CLI installer at $MOODLE_INSTALL_PATH/admin/cli/install.php ..."

# Set default values if not provided
MOODLE_SITE_NAME="${MOODLE_SITE_NAME:-Moodle Site}"
MOODLE_USERNAME="${MOODLE_USERNAME:-admin}"
MOODLE_PASSWORD="${MOODLE_PASSWORD:-Admin@123}"
MOODLE_EMAIL="${MOODLE_EMAIL:-admin@example.com}"
MOODLE_FULLNAME="${MOODLE_FULLNAME:-Administrator}"
MOODLE_SHORTNAME="${MOODLE_SHORTNAME:-Admin}"

# Run the installation. install.php reads its options from $_SERVER['argv']. The two passwords never go on a command
# line, where every process in the container can read them: this short PHP program adds --dbpass and --adminpass to
# that list from its environment and then runs install.php in the same process. The other options go as before.
# shellcheck disable=SC2016  # PHP code, for php
CLV_DB_PASSWORD="$DB_PASSWORD" CLV_ADMIN_PASSWORD="$MOODLE_PASSWORD" \
CLV_INSTALL_PHP="$MOODLE_INSTALL_PATH/admin/cli/install.php" php -r '
    $script = getenv("CLV_INSTALL_PHP");
    $argv = array_merge([$script], array_slice($argv, 1), [
        "--dbpass=" . getenv("CLV_DB_PASSWORD"),
        "--adminpass=" . getenv("CLV_ADMIN_PASSWORD"),
    ]);
    $argc = count($argv);
    $_SERVER["argv"] = $argv;
    $_SERVER["argc"] = $argc;
    require $script;
' -- \
  --lang=en \
  --wwwroot="${MOODLE_URL:-http://localhost}" \
  --dataroot="$MOODLEDATA_PATH" \
  --dbtype=mysqli \
  --dbhost="$DB_HOST" \
  --dbname="$DB_NAME" \
  --dbuser="$DB_USER" \
  --dbport=3306 \
  --prefix=mdl_ \
  --fullname="$MOODLE_SITE_NAME" \
  --shortname="$MOODLE_SITE_NAME" \
  --summary="Moodle Learning Management System" \
  --adminuser="$MOODLE_USERNAME" \
  --adminemail="$MOODLE_EMAIL" \
  --non-interactive \
  --agree-license

echo "Moodle installation completed successfully!"

# Note: SSL proxy configuration is now handled in entrypoint.sh on every startup
# This ensures the setting is applied even if installation times out

# Set proper permissions after installation
chown -R www-data:www-data "$MOODLE_INSTALL_PATH"
chmod -R 755 "$MOODLE_INSTALL_PATH"
chown -R www-data:www-data "$MOODLEDATA_PATH"
chmod -R 0777 "$MOODLEDATA_PATH"

