#!/bin/bash

# Odoo Installation Script
# This script handles the initial Odoo database setup and configuration

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

set -e

echo -e "${YELLOW}[INFO]${NC} Running Odoo installation script..."

# Database connection details
DB_HOST="${POSTGRES_DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${POSTGRES_DB_USER:-odoo}"
DB_PASSWORD="${POSTGRES_DB_PASSWORD:-odoo}"

# Odoo configuration
ODOO_DATA_DIR="/var/lib/odoo"
ODOO_ADDONS_DIR="/mnt/extra-addons"
ODOO_CONF="/etc/odoo/odoo.conf"

# Odoo database configuration
ODOO_DB_NAME="${ODOO_DB_NAME:-odoo}"
ODOO_ADMIN_EMAIL="${ODOO_ADMIN_EMAIL:-admin@example.com}"
ODOO_ADMIN_PASSWORD="${ODOO_ADMIN_PASSWORD:-admin}"
ODOO_LANGUAGE="${ODOO_LANGUAGE:-en_US}"
ODOO_COUNTRY="${ODOO_COUNTRY:-US}"

# ============================================================================
# STEP 1: Verify PostgreSQL connection
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Verifying PostgreSQL connection..."

# Test connection using psql
export PGPASSWORD="$DB_PASSWORD"
if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1" > /dev/null 2>&1; then
    echo -e "${GREEN}[SUCCESS]${NC} PostgreSQL connection verified!"
else
    echo -e "${RED}[ERROR]${NC} Failed to connect to PostgreSQL"
    exit 1
fi

# ============================================================================
# STEP 2: Create data and addons directories
# ============================================================================

# Ensure data directory exists and has proper permissions
mkdir -p "$ODOO_DATA_DIR"
chown -R odoo:odoo "$ODOO_DATA_DIR"

# Ensure addons directory exists
mkdir -p "$ODOO_ADDONS_DIR"
chown -R odoo:odoo "$ODOO_ADDONS_DIR"

# ============================================================================
# STEP 3: Check if database already exists
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Checking if database '$ODOO_DB_NAME' already exists..."

if psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -lqt | cut -d \| -f 1 | grep -qw "$ODOO_DB_NAME"; then
    echo -e "${GREEN}[INFO]${NC} Database '$ODOO_DB_NAME' already exists. Skipping database initialization."
    echo -e "${GREEN}[SUCCESS]${NC} Odoo is ready to use!"
    echo -e "${GREEN}[INFO]${NC} Access Odoo at: http://localhost:8069"
    echo -e "${GREEN}[INFO]${NC} Login with email: $ODOO_ADMIN_EMAIL"
    exit 0
fi

# ============================================================================
# STEP 4: Initialize Odoo database
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Initializing Odoo database '$ODOO_DB_NAME'..."
echo -e "${YELLOW}[INFO]${NC} This may take a few minutes..."

# Run Odoo database initialization as odoo user
# Using -i base to install base module which creates the database
su - odoo -s /bin/bash -c "odoo -c $ODOO_CONF \
    -d $ODOO_DB_NAME \
    -i base \
    --without-demo=all \
    --stop-after-init" 2>&1 | tee /tmp/odoo_init.log

# Check if initialization was successful
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    echo -e "${GREEN}[SUCCESS]${NC} Odoo database initialized successfully!"
else
    echo -e "${RED}[ERROR]${NC} Failed to initialize Odoo database"
    echo -e "${RED}[ERROR]${NC} Check logs at /tmp/odoo_init.log for details"
    cat /tmp/odoo_init.log
    exit 1
fi

# ============================================================================
# STEP 5: Configure admin user credentials
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Configuring admin user..."

# Use Odoo shell to properly configure admin user using ORM
# This ensures all hooks and validations are properly executed
# Pass environment variables explicitly to the odoo user
su - odoo -s /bin/bash -c "ODOO_ADMIN_EMAIL='$ODOO_ADMIN_EMAIL' ODOO_ADMIN_PASSWORD='$ODOO_ADMIN_PASSWORD' odoo shell -c $ODOO_CONF -d $ODOO_DB_NAME --stop-after-init" << 'PYTHON_SCRIPT' 2>&1 | tee /tmp/odoo_user_config.log
import os

# Get environment variables
admin_email = os.environ.get('ODOO_ADMIN_EMAIL', 'admin@example.com')
admin_password = os.environ.get('ODOO_ADMIN_PASSWORD', 'admin')

print(f"Configuring admin user with login: {admin_email}")

# Get the admin user (id=2)
admin = env['res.users'].browse(2)

if admin.exists():
    # Update login to use email address
    admin.write({'login': admin_email})
    print(f"Updated admin login to: {admin_email}")

    # Update password using the proper method
    admin.write({'password': admin_password})
    print(f"Updated admin password")

    # Update email in the related partner
    if admin.partner_id:
        admin.partner_id.write({'email': admin_email})
        print(f"Updated admin email to: {admin_email}")

    # Commit the changes
    env.cr.commit()
    print("Admin user configuration completed successfully!")
else:
    print("ERROR: Admin user not found!")
PYTHON_SCRIPT

# Check if configuration was successful
if grep -q "Admin user configuration completed successfully" /tmp/odoo_user_config.log; then
    echo -e "${GREEN}[SUCCESS]${NC} Admin user configured!"
    rm -f /tmp/odoo_user_config.log
else
    echo -e "${YELLOW}[WARNING]${NC} Failed to configure admin user"
    echo -e "${YELLOW}[INFO]${NC} Check logs at /tmp/odoo_user_config.log for details"
fi

# ============================================================================
# STEP 6: Configure database to be used by default
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Configuring Odoo to use database '$ODOO_DB_NAME' by default..."

# Add db_name to configuration file to make this database the default
if ! grep -q "^db_name" "$ODOO_CONF"; then
    echo "" >> "$ODOO_CONF"
    echo "; Default database" >> "$ODOO_CONF"
    echo "db_name = $ODOO_DB_NAME" >> "$ODOO_CONF"
    echo -e "${GREEN}[SUCCESS]${NC} Default database configured!"
else
    echo -e "${GREEN}[INFO]${NC} Default database already configured"
fi

# ============================================================================
# STEP 7: Installation complete
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} Odoo installation completed successfully!"
echo -e "${GREEN}[INFO]${NC} ================================================"
echo -e "${GREEN}[INFO]${NC} Odoo is ready to use!"
echo -e "${GREEN}[INFO]${NC} ================================================"
echo -e "${GREEN}[INFO]${NC} Access Odoo at: http://localhost:8069"
echo -e "${GREEN}[INFO]${NC} Database: $ODOO_DB_NAME"
echo -e "${GREEN}[INFO]${NC} Admin email/login: $ODOO_ADMIN_EMAIL"
echo -e "${GREEN}[INFO]${NC} ================================================"

