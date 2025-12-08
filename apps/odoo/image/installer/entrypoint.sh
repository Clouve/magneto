#!/bin/bash

# Odoo Docker Entrypoint Script
# This script handles the complete Odoo initialization process:
# 1. Waits for PostgreSQL to be ready
# 2. Initializes Odoo database if not already initialized
# 3. Starts Odoo server

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set error handling
set -e

# Odoo configuration
ODOO_DATA_DIR="/var/lib/odoo"
ODOO_CONF="/etc/odoo/odoo.conf"
INSTALLED_MARKER="$ODOO_DATA_DIR/.odoo_initialized"

echo -e "${YELLOW}[INFO]${NC} Starting Odoo initialization..."
echo -e "${YELLOW}[INFO]${NC} Odoo version: 19.0"

# ============================================================================
# STEP 1: Wait for PostgreSQL to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for PostgreSQL to be ready..."

# Extract database connection details from environment variables
DB_HOST="${POSTGRES_DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${POSTGRES_DB_USER:-odoo}"
DB_PASSWORD="${POSTGRES_DB_PASSWORD:-odoo}"

max_attempts=60
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" > /dev/null 2>&1; then
        echo -e "${GREEN}[SUCCESS]${NC} PostgreSQL is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo -e "${YELLOW}[WAIT]${NC} PostgreSQL not ready yet... (attempt $attempt/$max_attempts)"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}[ERROR]${NC} PostgreSQL failed to become ready after $max_attempts attempts"
    exit 1
fi

# Wait a bit more to ensure PostgreSQL is fully initialized
sleep 3

# ============================================================================
# STEP 2: Create Odoo configuration file (always)
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Configuring Odoo..."

# Ensure configuration directory exists
mkdir -p "$(dirname "$ODOO_CONF")"

# Master password for database manager
ODOO_MASTER_PASSWORD="${ODOO_MASTER_PASSWORD:-}"

# Create Odoo configuration file
echo -e "${YELLOW}[INFO]${NC} Creating Odoo configuration file at $ODOO_CONF..."

cat > "$ODOO_CONF" <<EOF
[options]
; Database configuration
db_host = $DB_HOST
db_port = $DB_PORT
db_user = $DB_USER
db_password = $DB_PASSWORD

; Data directory
data_dir = $ODOO_DATA_DIR

; Addons path
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons

; Master password for database manager
; This password protects database management operations (create, delete, backup, restore)
EOF

# Set master password if provided
if [ -n "$ODOO_MASTER_PASSWORD" ]; then
    echo "admin_passwd = $ODOO_MASTER_PASSWORD" >> "$ODOO_CONF"
    echo -e "${GREEN}[SUCCESS]${NC} Master password configured from environment variable"
else
    # Generate a random master password
    GENERATED_PASSWD=$(python3 -c 'import base64, os; print(base64.b64encode(os.urandom(24)).decode())')
    echo "admin_passwd = $GENERATED_PASSWD" >> "$ODOO_CONF"
    echo -e "${YELLOW}[WARNING]${NC} No ODOO_MASTER_PASSWORD provided. Generated random master password."
    echo -e "${YELLOW}[WARNING]${NC} Master password: $GENERATED_PASSWD"
    echo -e "${YELLOW}[WARNING]${NC} Please save this password securely!"
fi

# Set proper permissions on configuration file
chmod 640 "$ODOO_CONF"
chown odoo:odoo "$ODOO_CONF"

echo -e "${GREEN}[SUCCESS]${NC} Odoo configuration file created successfully"

# ============================================================================
# STEP 3: Check if Odoo is already initialized
# ============================================================================

# Create data directory if it doesn't exist
mkdir -p "$ODOO_DATA_DIR"

if [ -f "$INSTALLED_MARKER" ]; then
    echo -e "${GREEN}[INFO]${NC} Odoo appears to be already initialized. Skipping database initialization."
    echo -e "${GREEN}[INFO]${NC} Marker file found: $INSTALLED_MARKER"
else
    echo -e "${YELLOW}[INFO]${NC} First-time initialization detected. Running setup..."

    # Run the installation script
    /clouve/odoo/installer/install.sh

    # Create marker file to indicate initialization is complete
    echo "$(date)" > "$INSTALLED_MARKER"
    echo -e "${GREEN}[SUCCESS]${NC} Odoo initialization completed!"
fi

# ============================================================================
# STEP 4: Update configuration (runs on every startup)
# ============================================================================

# Run the configuration update script to handle URL changes and other dynamic config
if [ -f /clouve/odoo/installer/update-config.sh ]; then
    echo -e "${YELLOW}[INFO]${NC} Running configuration update script..."
    /clouve/odoo/installer/update-config.sh
fi

# ============================================================================
# STEP 5: Start Odoo
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} Odoo is ready to use!"
echo -e "${GREEN}[INFO]${NC} Access Odoo at: http://localhost:8069"
echo -e "${YELLOW}[INFO]${NC} Starting Odoo server..."

# Call the original Odoo entrypoint with the configuration file
# The -c flag specifies the configuration file to use
# If no arguments are provided, default to "odoo" command
if [ $# -eq 0 ]; then
    exec /entrypoint-original.sh odoo -c /etc/odoo/odoo.conf
else
    exec /entrypoint-original.sh "$@" -c /etc/odoo/odoo.conf
fi

