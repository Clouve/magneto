#!/bin/bash

# Odoo Installation Script
# This script handles the initial Odoo database setup and configuration.
# The entrypoint runs it as root. The odoo commands in it run as the odoo user
# (/usr/local/bin/odoo drops root's rights), and no password goes on a
# command line: each one goes to the one command that needs it, through that
# command's environment.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

set -e

# The rule for a secret's name and odoo_unset_secrets.
# shellcheck source=apps/odoo/image/installer/lib.sh
. /clouve/odoo/installer/lib.sh

echo -e "${YELLOW}[INFO]${NC} Running Odoo installation script..."

# Database connection details
DB_HOST="${ODOO_DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${ODOO_DB_USER:-odoo}"
DB_PASSWORD="${ODOO_DB_PASSWORD:-odoo}"

# Odoo configuration
ODOO_DATA_DIR="/var/lib/odoo"
ODOO_ADDONS_DIR="/mnt/extra-addons"
ODOO_CONF="/etc/odoo/odoo.conf"

# Odoo database configuration
ODOO_DB_NAME="${ODOO_DB_NAME:-odoo}"
ODOO_ADMIN_EMAIL="${ODOO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ODOO_ADMIN_PASSWORD:-admin}"
ODOO_LANGUAGE="${ODOO_LANGUAGE:-en_US}"
ODOO_COUNTRY="${ODOO_COUNTRY:-US}"

# The odoo commands below get none of the container's secrets in their
# environment: odoo_unset_secrets takes out every variable whose name is a
# secret's, and PGPASSWORD. Odoo reads the database password from odoo.conf.
# The admin step gets the admin's password by itself, and each psql gets
# PGPASSWORD by itself (Odoo would take a PGPASSWORD over odoo.conf). The
# copies above (DB_PASSWORD, ADMIN_PASSWORD) aren't exported, so they stay.
odoo_unset_secrets

# ============================================================================
# STEP 1: Verify PostgreSQL connection
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Verifying PostgreSQL connection..."

# Test connection using psql
if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1" > /dev/null 2>&1; then
    echo -e "${GREEN}[SUCCESS]${NC} PostgreSQL connection verified!"
else
    echo -e "${RED}[ERROR]${NC} Failed to connect to PostgreSQL"
    exit 1
fi

# ============================================================================
# STEP 2: Create data and addons directories
# ============================================================================

# The entrypoint has made both folders and given them to odoo already (its
# step 3), lost+found aside.
mkdir -p "$ODOO_DATA_DIR" "$ODOO_ADDONS_DIR"

# ============================================================================
# STEP 3: Check if database already exists
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Checking if database '$ODOO_DB_NAME' already exists..."

if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -lqt | cut -d \| -f 1 | grep -qw "$ODOO_DB_NAME"; then
    echo -e "${GREEN}[INFO]${NC} Database '$ODOO_DB_NAME' already exists. Skipping database initialization."
    echo -e "${GREEN}[SUCCESS]${NC} Odoo is ready to use!"
    echo -e "${GREEN}[INFO]${NC} Access Odoo at: http://localhost:8069"
    echo -e "${GREEN}[INFO]${NC} The admin signs in with the address in ODOO_ADMIN_EMAIL"
    exit 0
fi

# ============================================================================
# STEP 4: Initialize Odoo database
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Initializing Odoo database '$ODOO_DB_NAME'..."
echo -e "${YELLOW}[INFO]${NC} This may take a few minutes..."

# Run Odoo database initialization as odoo user (/usr/local/bin/odoo drops to it)
# Using -i base to install base module which creates the database
/usr/local/bin/odoo -c "$ODOO_CONF" \
    -d "$ODOO_DB_NAME" \
    -i base \
    --without-demo=all \
    --stop-after-init 2>&1 | tee /tmp/odoo_init.log

# Check if initialization was successful
if [ "${PIPESTATUS[0]}" -eq 0 ]; then
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
# The admin's login and password reach the shell through its environment,
# never on a command line, where any process in the container could read them.
# What the shell prints goes to the container's log, so it names the admin by
# user id, never by address: the address is the deploying person's own.
# The shell runs as the odoo user (/usr/local/bin/odoo drops to it).
ODOO_ADMIN_EMAIL="$ODOO_ADMIN_EMAIL" ODOO_ADMIN_PASSWORD="$ADMIN_PASSWORD" \
    /usr/local/bin/odoo shell -c "$ODOO_CONF" -d "$ODOO_DB_NAME" --stop-after-init << 'PYTHON_SCRIPT' 2>&1 | tee /tmp/odoo_user_config.log
import os

# Get environment variables
admin_email = os.environ.get('ODOO_ADMIN_EMAIL', 'admin@example.com')
admin_password = os.environ.get('ODOO_ADMIN_PASSWORD', 'admin')

# Get the admin user (id=2)
admin = env['res.users'].browse(2)
print(f"Configuring the admin user (res.users id {admin.id})")

if admin.exists():
    # Update login to use email address
    admin.write({'login': admin_email})
    print("Updated the admin's login")

    # Update password using the proper method
    admin.write({'password': admin_password})
    print(f"Updated admin password")

    # Update email in the related partner
    if admin.partner_id:
        admin.partner_id.write({'email': admin_email})
        print("Updated the admin's email")

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

# The entrypoint's odoo.conf pins this database with dbfilter at every
# start, so nothing more is written there.

# ============================================================================
# STEP 6: Installation complete
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} Odoo installation completed successfully!"
echo -e "${GREEN}[INFO]${NC} ================================================"
echo -e "${GREEN}[INFO]${NC} Odoo is ready to use!"
echo -e "${GREEN}[INFO]${NC} ================================================"
echo -e "${GREEN}[INFO]${NC} Access Odoo at: http://localhost:8069"
echo -e "${GREEN}[INFO]${NC} Database: $ODOO_DB_NAME"
echo -e "${GREEN}[INFO]${NC} Admin: res.users id 2, signing in with the address in ODOO_ADMIN_EMAIL"
echo -e "${GREEN}[INFO]${NC} ================================================"

