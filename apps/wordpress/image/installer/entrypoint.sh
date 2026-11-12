#!/bin/bash

# WordPress Docker Entrypoint Wrapper Script
# This script wraps the official WordPress entrypoint with Clouve-specific initialization:
# 1. Extracts WordPress files from the base image (via original entrypoint)
# 2. Waits for the database to be ready
# 3. Installs WordPress if not already installed (using wp-cli)
# 4. Configures WordPress options
# 5. Starts Apache
#
# Note: We don't modify the official image's entrypoint - it remains at its original location.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Path to the original WordPress entrypoint (from the official image)
ORIGINAL_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

# WordPress installation directory
WP_DIR="/var/www/html"

# ----------------------------------------------------------------------------
# Helper: fix uploads directory permissions
# Called right before starting Apache so that it runs AFTER wp-cli / the
# original entrypoint have finished creating files (which run as root).
# ----------------------------------------------------------------------------
fix_uploads_permissions() {
    echo -e "${YELLOW}[INFO]${NC} Setting up uploads directory permissions..."
    mkdir -p "$WP_DIR/wp-content/uploads"
    chown -R www-data:www-data "$WP_DIR/wp-content/uploads"
    chmod -R 755 "$WP_DIR/wp-content/uploads"
    echo -e "${GREEN}[SUCCESS]${NC} Uploads directory is ready."
}

# Set error handling - don't exit on error, just log it
set +e

# WORDPRESS_DEBUG='false' would turn WP_DEBUG on: the official wp-config.php reads it at every request as
# !!getenv_docker('WORDPRESS_DEBUG', ''), so any value that isn't empty means on. Unset it when it says off (false, off
# or no, in any case). Apache, which this script becomes, and the AI Assistant's wp.sh, which reads PID 1's environment,
# then see WP_DEBUG off. Any other value, such as 1, keeps it on. tests/wordpress-debug.test.sh checks.
case "${WORDPRESS_DEBUG:-}" in
    [Ff][Aa][Ll][Ss][Ee] | [Oo][Ff][Ff] | [Nn][Oo]) unset WORDPRESS_DEBUG ;;
esac

# ============================================================================
# STEP 1: Extract WordPress files from the base image
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Running WordPress entrypoint to extract files..."

# Call the original WordPress docker-entrypoint.sh at its original location (untouched)
# This extracts WordPress files and generates wp-config.php
if [ -f "$ORIGINAL_ENTRYPOINT" ]; then
    # This Apache serves the site for the few seconds the official entrypoint takes, so it doesn't get
    # CLOUVE_OPS_PASSWORD either (see the unset below).
    env -u CLOUVE_OPS_PASSWORD "$ORIGINAL_ENTRYPOINT" apache2-foreground &
    WORDPRESS_PID=$!

    # Give WordPress entrypoint time to extract files
    sleep 5

    # Kill the background process (we'll start Apache properly later)
    kill $WORDPRESS_PID 2>/dev/null || true
    wait $WORDPRESS_PID 2>/dev/null || true

    echo -e "${GREEN}[SUCCESS]${NC} WordPress files extracted successfully"
else
    echo -e "${RED}[WARNING]${NC} Original WordPress entrypoint not found at $ORIGINAL_ENTRYPOINT"
fi

# ============================================================================
# CLOUVE-OPS SSHD: shell channel for the magneto-agent container's Claude Code
# ============================================================================
# Backgrounded — applies the per-pod password from CLOUVE_OPS_PASSWORD
# (same value on all three services) to the clouve-ops user via chpasswd,
# then exec's sshd -D inside its own background tree. Dies with the
# container when apache (PID 1) exits. Started here — after STEP 1, before
# the DB wait — so one call covers both `exec apache2-foreground` paths
# below and the magneto-agent's sidecar-fetcher can pull the persona while
# WordPress is still installing. Exits harmlessly (logged) when
# CLOUVE_OPS_PASSWORD is unset, i.e. on agent-less deployments.
#
# ORDERING IS LOAD-BEARING: this must come AFTER Step 1's kill/wait. The
# temporary apache2-foreground run above is SIGTERM'd, and its mpm_prefork
# shutdown reaps every process in the container — verified empirically:
# an sshd (and even unrelated canary processes) started before that
# window die at the kill, including in their own setsid session. Only
# processes started after the shutdown survive.
/clouve/wordpress/installer/start-clouve-ops-sshd.sh &

# The sshd start above has its own copy of CLOUVE_OPS_PASSWORD. Apache, which this script becomes, must not carry it:
# mod_php's getenv() reads Apache's environment, so any PHP code could read the password, which signs in as
# clouve-ops, who has passwordless sudo. Nothing later here needs it, and the AI Assistant has its own copy
# (tests/app-ops-password.test.sh).
unset CLOUVE_OPS_PASSWORD

# ============================================================================
# STEP 2: Wait for database to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for database to be ready..."
max_attempts=60
attempt=0

# Extract host and port from WORDPRESS_DB_HOST
DB_HOST="${WORDPRESS_DB_HOST%%:*}"
DB_PORT="${WORDPRESS_DB_HOST##*:}"
if [ "$DB_PORT" = "$DB_HOST" ]; then
    DB_PORT="3306"
fi

# Try to connect using mysql client if available, otherwise use PHP
while [ $attempt -lt $max_attempts ]; do
    if command -v mysql &> /dev/null; then
        # Use mysql client if available
        # The password goes in MYSQL_PWD, in this one command's environment: a command line can be read by every
        # process in the container.
        if MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$DB_HOST" -P "$DB_PORT" -u "${WORDPRESS_DB_USER}" -e "SELECT 1" > /dev/null 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} Database is ready!"
            break
        fi
    else
        # Use PHP as fallback. The code reads the settings from its environment, so no password is on its command line.
        # shellcheck disable=SC2016  # PHP code, for php
        if CLV_DB_HOST="$DB_HOST" CLV_DB_PORT="$DB_PORT" php -r '
            mysqli_report(MYSQLI_REPORT_OFF);
            $c = @mysqli_connect(getenv("CLV_DB_HOST"), getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"),
                getenv("WORDPRESS_DB_NAME"), (int) getenv("CLV_DB_PORT"));
            exit($c ? 0 : 1);' > /dev/null 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} Database is ready!"
            break
        fi
    fi
    attempt=$((attempt + 1))
    echo -e "${YELLOW}[WAIT]${NC} Database not ready yet... (attempt $attempt/$max_attempts)"
    sleep 5
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}[ERROR]${NC} Database failed to become ready after $max_attempts attempts"
    exit 1
fi

# Wait a bit more to ensure database is fully initialized
sleep 3

# ============================================================================
# STEP 3: Check if WordPress files exist
# ============================================================================

if [ ! -f "$WP_DIR/wp-load.php" ]; then
    echo -e "${RED}[ERROR]${NC} WordPress files not found in $WP_DIR"
    exit 1
fi

# ============================================================================
# STEP 4: Check if WordPress is already installed
# ============================================================================

# Check if WordPress is already installed by checking for wp_options table
WORDPRESS_INSTALLED=false
if command -v mysql &> /dev/null; then
    if MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$DB_HOST" -P "$DB_PORT" -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -e "SELECT 1 FROM wp_options LIMIT 1" > /dev/null 2>&1; then
        WORDPRESS_INSTALLED=true
        echo -e "${GREEN}[INFO]${NC} WordPress appears to be already installed."
    fi
fi

# ============================================================================
# STEP 4a: Update WordPress URL if it has changed (for existing installations)
# ============================================================================

if [ "$WORDPRESS_INSTALLED" = true ] && [ -n "$WORDPRESS_SITE_URL" ]; then
    echo -e "${YELLOW}[INFO]${NC} Checking if WordPress site URL needs to be updated..."

    # Change to WordPress directory
    cd "$WP_DIR" || exit 1

    # Get current siteurl from database
    CURRENT_SITEURL=$(wp option get siteurl --allow-root 2>/dev/null || echo "")
    CURRENT_HOME=$(wp option get home --allow-root 2>/dev/null || echo "")

    # Check if URL has changed
    if [ "$CURRENT_SITEURL" != "$WORDPRESS_SITE_URL" ] || [ "$CURRENT_HOME" != "$WORDPRESS_SITE_URL" ]; then
        echo -e "${YELLOW}[INFO]${NC} WordPress URL has changed:"
        echo -e "${YELLOW}[INFO]${NC}   Current siteurl: $CURRENT_SITEURL"
        echo -e "${YELLOW}[INFO]${NC}   Current home: $CURRENT_HOME"
        echo -e "${YELLOW}[INFO]${NC}   New URL: $WORDPRESS_SITE_URL"
        echo -e "${YELLOW}[INFO]${NC} Updating WordPress URLs in database..."

        # Update siteurl and home options
        if wp option update siteurl "$WORDPRESS_SITE_URL" --allow-root 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} Updated 'siteurl' to $WORDPRESS_SITE_URL"
        else
            echo -e "${RED}[WARNING]${NC} Failed to update 'siteurl'"
        fi

        if wp option update home "$WORDPRESS_SITE_URL" --allow-root 2>&1; then
            echo -e "${GREEN}[SUCCESS]${NC} Updated 'home' to $WORDPRESS_SITE_URL"
        else
            echo -e "${RED}[WARNING]${NC} Failed to update 'home'"
        fi

        # Flush rewrite rules to ensure permalinks work with new URL
        wp rewrite flush --hard --allow-root 2>/dev/null || true

        echo -e "${GREEN}[SUCCESS]${NC} WordPress URL update completed!"
    else
        echo -e "${GREEN}[INFO]${NC} WordPress URL is already up to date: $WORDPRESS_SITE_URL"
    fi

    # Ensure debug output is never displayed on the frontend
    wp config set WP_DEBUG_DISPLAY false --raw --allow-root 2>/dev/null || true
    echo -e "${GREEN}[INFO]${NC} WP_DEBUG_DISPLAY set to false."

    # WordPress is installed and URL is updated, fix permissions and start Apache
    fix_uploads_permissions
    echo -e "${GREEN}[SUCCESS]${NC} WordPress is ready to use!"
    echo -e "${GREEN}[INFO]${NC} Access WordPress at: ${WORDPRESS_SITE_URL}"
    echo -e "${GREEN}[INFO]${NC} Starting Apache..."
    exec apache2-foreground
fi

# ============================================================================
# STEP 5: Install WordPress
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Starting WordPress automatic installation..."

# Change to WordPress directory
cd "$WP_DIR" || exit 1

# wp-cli should already be installed in the Dockerfile
if ! command -v wp &> /dev/null; then
    echo -e "${RED}[ERROR]${NC} wp-cli is not available"
    exit 1
fi

# Run wp-cli core install command with --allow-root flag.
# The admin's password never goes on a command line, where every process in the container can read it. The install
# runs without one, so wp-cli makes a random one, and --quiet keeps wp-cli from printing it to the log. Then wp eval
# sets the real password from WORDPRESS_ADMIN_PASSWORD in its environment, trimmed at both ends as wp_install would
# store it (WordPress's sign-in trims what's typed too). Apache hasn't started yet, so no one can sign in with the
# random one in between. The login is looked up as wp_install stored it (sanitize_user, strict).
echo -e "${YELLOW}[INFO]${NC} Running wp core install..."
# shellcheck disable=SC2016  # PHP code, for wp eval
if wp core install \
    --url="${WORDPRESS_SITE_URL}" \
    --title="${WORDPRESS_SITE_TITLE}" \
    --admin_user="${WORDPRESS_ADMIN_USER}" \
    --admin_email="${WORDPRESS_ADMIN_EMAIL}" \
    --skip-email \
    --quiet \
    --allow-root 2>&1 &&
    wp eval '
        $user = get_user_by("login", sanitize_user(getenv("WORDPRESS_ADMIN_USER"), true));
        if (!$user || getenv("WORDPRESS_ADMIN_PASSWORD") === false || getenv("WORDPRESS_ADMIN_PASSWORD") === "") {
            exit(1);
        }
        wp_set_password(trim(getenv("WORDPRESS_ADMIN_PASSWORD")), $user->ID);
        echo "Admin account: WordPress user " . $user->ID . "\n";' --allow-root 2>&1; then
    echo -e "${GREEN}[SUCCESS]${NC} WordPress installation completed successfully!"
else
    INSTALL_EXIT_CODE=$?
    echo -e "${RED}[ERROR]${NC} WordPress installation failed with exit code $INSTALL_EXIT_CODE"
fi

# ============================================================================
# STEP 6: Configure WordPress options
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Configuring WordPress options..."
wp option update timezone_string "UTC" --allow-root 2>/dev/null || true
wp rewrite structure '/%postname%/' --hard --allow-root 2>/dev/null || true
wp rewrite flush --hard --allow-root 2>/dev/null || true

# Ensure debug output is never displayed on the frontend
wp config set WP_DEBUG_DISPLAY false --raw --allow-root 2>/dev/null || true
echo -e "${GREEN}[INFO]${NC} WP_DEBUG_DISPLAY set to false."

# ============================================================================
# STEP 7: Start Apache
# ============================================================================

fix_uploads_permissions

echo -e "${GREEN}[SUCCESS]${NC} WordPress is now ready to use!"
echo -e "${GREEN}[INFO]${NC} Access WordPress at: ${WORDPRESS_SITE_URL}"
# The admin is named in the log by WordPress user id only (printed at the install above): their login is made of their
# name, and a log line about a person never holds their name or email address.

echo -e "${YELLOW}[INFO]${NC} Starting Apache..."
exec apache2-foreground

