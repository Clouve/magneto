#!/bin/bash

# SuiteCRM 8 Installation Script
# This script handles the initial SuiteCRM database setup and configuration

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

set -e

echo -e "${YELLOW}[INFO]${NC} Running SuiteCRM installation script..."

# Database connection details
DB_HOST="${DATABASE_HOST:-suitecrm-mariadb}"
DB_PORT="${DATABASE_PORT:-3306}"
DB_USER="${DATABASE_USER:-suitecrm}"
DB_PASSWORD="${DATABASE_PASSWORD:-suitecrm}"
DB_NAME="${DATABASE_NAME:-suitecrm}"

# SuiteCRM configuration
SUITECRM_INSTALL_PATH="/var/www/html"
SUITECRM_URL="${SUITECRM_URL:-http://localhost:8080}"
SUITECRM_ADMIN_USER="${SUITECRM_ADMIN_USER:-admin}"
SUITECRM_ADMIN_PASSWORD="${SUITECRM_ADMIN_PASSWORD:-Admin@123}"

# ============================================================================
# STEP 1: Verify MariaDB connection
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Verifying MariaDB connection..."

# Test connection using mysql client
if mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1" > /dev/null 2>&1; then
    echo -e "${GREEN}[SUCCESS]${NC} MariaDB connection verified!"
else
    echo -e "${RED}[ERROR]${NC} Failed to connect to MariaDB"
    exit 1
fi

# ============================================================================
# STEP 2: Check if database already exists and has tables
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Checking if database '$DB_NAME' already exists..."

# Create database if it doesn't exist
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1

# Check if database has tables (indicating it's already installed)
TABLE_COUNT=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SHOW TABLES;" 2>/dev/null | wc -l)

if [ "$TABLE_COUNT" -gt 1 ]; then
    echo -e "${GREEN}[INFO]${NC} Database '$DB_NAME' already has tables. Skipping installation."
    echo -e "${GREEN}[SUCCESS]${NC} SuiteCRM is ready to use!"
    echo -e "${GREEN}[INFO]${NC} Access SuiteCRM at: $SUITECRM_URL"
    exit 0
fi

# ============================================================================
# STEP 3: Create .env.local configuration file
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Creating SuiteCRM configuration file..."

cd "$SUITECRM_INSTALL_PATH"

# Create .env.local file with database configuration
cat > .env.local <<EOF
###> doctrine/doctrine-bundle ###
DATABASE_URL=mysql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?serverVersion=mariadb-10.11.0
###< doctrine/doctrine-bundle ###

###> symfony/framework-bundle ###
APP_ENV=prod
APP_SECRET=$(openssl rand -hex 32)
###< symfony/framework-bundle ###

###> nelmio/cors-bundle ###
CORS_ALLOW_ORIGIN='^https?://(localhost|127\.0\.0\.1)(:[0-9]+)?$'
###< nelmio/cors-bundle ###

SITE_URL=${SUITECRM_URL}
LEGACY_SESSION_NAME=SUITECRM_SESSION_ID
EOF

echo -e "${GREEN}[SUCCESS]${NC} Configuration file created!"

# ============================================================================
# STEP 4: Run SuiteCRM installation via CLI
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Installing SuiteCRM database schema..."
echo -e "${YELLOW}[INFO]${NC} This may take a few minutes..."

# Run the installation command
cd "$SUITECRM_INSTALL_PATH"

# Determine demo data setting
# SUITECRM_INSTALL_DEMO_DATA can be 'yes', 'no', 'true', 'false', '1', '0'
# Default to 'no' if not set
DEMO_DATA="no"
if [ -n "$SUITECRM_INSTALL_DEMO_DATA" ]; then
    case "${SUITECRM_INSTALL_DEMO_DATA,,}" in
        yes|true|1)
            DEMO_DATA="yes"
            echo -e "${YELLOW}[INFO]${NC} Demo data will be installed"
            ;;
        no|false|0)
            DEMO_DATA="no"
            echo -e "${YELLOW}[INFO]${NC} Demo data will NOT be installed (clean installation)"
            ;;
        *)
            echo -e "${YELLOW}[WARNING]${NC} Invalid SUITECRM_INSTALL_DEMO_DATA value: $SUITECRM_INSTALL_DEMO_DATA. Using default: no"
            DEMO_DATA="no"
            ;;
    esac
else
    echo -e "${YELLOW}[INFO]${NC} SUITECRM_INSTALL_DEMO_DATA not set. Using default: no (clean installation)"
fi

# Install SuiteCRM using the console command
# Note: SuiteCRM 8 CLI installer has specific parameters
php bin/console suitecrm:app:install \
    -U "$DATABASE_USER" \
    -P "$DATABASE_PASSWORD" \
    -H "$DATABASE_HOST" \
    -N "$DATABASE_NAME" \
    -u "$SUITECRM_ADMIN_USER" \
    -p "$SUITECRM_ADMIN_PASSWORD" \
    -S "$SUITECRM_URL" \
    -d "$DEMO_DATA" 2>&1 | tee /tmp/suitecrm_install.log

# Check if installation was successful
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo -e "${GREEN}[SUCCESS]${NC} SuiteCRM database installed successfully!"
else
    echo -e "${RED}[ERROR]${NC} Failed to install SuiteCRM database"
    echo -e "${RED}[ERROR]${NC} Check logs at /tmp/suitecrm_install.log for details"
    cat /tmp/suitecrm_install.log
    exit 1
fi

# ============================================================================
# STEP 5: Set proper permissions
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Setting proper permissions..."

chown -R www-data:www-data "$SUITECRM_INSTALL_PATH"
chmod -R 755 "$SUITECRM_INSTALL_PATH"

# Make specific directories writable
chmod -R 775 "$SUITECRM_INSTALL_PATH/cache"
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/cache"
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/custom"
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/modules"
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/themes"
chmod -R 775 "$SUITECRM_INSTALL_PATH/public/legacy/upload"

echo -e "${GREEN}[SUCCESS]${NC} Permissions set successfully!"

# ============================================================================
# STEP 6: Generate OAuth2 keys for API access
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Generating OAuth2 keys for API access..."

OAUTH2_KEY_PATH="$SUITECRM_INSTALL_PATH/public/legacy/Api/V8/OAuth2"

if [ ! -f "$OAUTH2_KEY_PATH/private.key" ] || [ ! -f "$OAUTH2_KEY_PATH/public.key" ]; then
    cd "$OAUTH2_KEY_PATH"
    openssl genrsa -out private.key 2048 2>/dev/null
    openssl rsa -in private.key -pubout -out public.key 2>/dev/null
    chown www-data:www-data private.key public.key
    chmod 600 private.key public.key
    echo -e "${GREEN}[SUCCESS]${NC} OAuth2 keys generated successfully!"
else
    echo -e "${GREEN}[INFO]${NC} OAuth2 keys already exist."
fi

# ============================================================================
# STEP 7: Installation complete
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} SuiteCRM installation completed successfully!"
echo -e "${GREEN}[INFO]${NC} ================================================"
echo -e "${GREEN}[INFO]${NC} SuiteCRM is ready to use!"
echo -e "${GREEN}[INFO]${NC} ================================================"
echo -e "${GREEN}[INFO]${NC} Access SuiteCRM at: $SUITECRM_URL"
echo -e "${GREEN}[INFO]${NC} Admin username: $SUITECRM_ADMIN_USER"
echo -e "${GREEN}[INFO]${NC} ================================================"

