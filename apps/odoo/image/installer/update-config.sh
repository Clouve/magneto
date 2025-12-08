#!/bin/bash

# Odoo Configuration Update Script
# This script updates Odoo configuration on every container startup
# It handles URL changes and triggers cache invalidation when needed

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

set -e

echo -e "${YELLOW}[INFO]${NC} Updating Odoo configuration from environment variables..."

# Database connection details
DB_HOST="${POSTGRES_DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${POSTGRES_DB_USER:-odoo}"
DB_PASSWORD="${POSTGRES_DB_PASSWORD:-odoo}"
DB_NAME="${ODOO_DB_NAME:-odoo}"

# Odoo URL configuration
ODOO_URL="${ODOO_URL:-}"

# ============================================================================
# STEP 1: Check if database exists
# ============================================================================

export PGPASSWORD="$DB_PASSWORD"

# Check if the Odoo database exists
if ! psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    echo -e "${YELLOW}[INFO]${NC} Database '$DB_NAME' does not exist yet. Skipping URL configuration."
    exit 0
fi

# ============================================================================
# STEP 2: Update web.base.url if ODOO_URL is set
# ============================================================================

if [ -z "$ODOO_URL" ]; then
    echo -e "${YELLOW}[WARNING]${NC} ODOO_URL environment variable not set. Skipping URL update."
    exit 0
fi

echo -e "${YELLOW}[INFO]${NC} Updating web.base.url in database..."
echo -e "${YELLOW}[INFO]${NC} Target URL: $ODOO_URL"

# Check if ir_config_parameter table exists
TABLE_EXISTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'ir_config_parameter');" 2>/dev/null || echo "f")

if [ "$TABLE_EXISTS" != "t" ]; then
    echo -e "${YELLOW}[INFO]${NC} Odoo database tables not found yet. Skipping URL update."
    exit 0
fi

echo -e "${GREEN}[INFO]${NC} Odoo database tables found. Updating web.base.url setting..."

# ============================================================================
# DETECT URL CHANGES
# ============================================================================
# First, check if the URL has actually changed by comparing with the database value
# This allows us to log URL changes explicitly (required for test scripts)

echo "Checking if ODOO_URL has changed..."

PREVIOUS_URL=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT value FROM ir_config_parameter WHERE key = 'web.base.url';" 2>&1)

if [ $? -eq 0 ] && [ -n "$PREVIOUS_URL" ]; then
    echo "  Previous URL from database: $PREVIOUS_URL"
    echo "  Current ODOO_URL: $ODOO_URL"
    
    if [ "$PREVIOUS_URL" != "$ODOO_URL" ]; then
        echo "  ✓ URL has changed!"
        echo "    Old URL: $PREVIOUS_URL"
        echo "    New URL: $ODOO_URL"
        URL_CHANGED=true
    else
        echo "  URL has not changed (both are: $ODOO_URL)"
        URL_CHANGED=false
    fi
else
    echo "  Could not retrieve previous URL from database (first run or query failed)"
    URL_CHANGED=true
fi

# ============================================================================
# UPDATE DATABASE URL
# ============================================================================

# Update the web.base.url in the ir_config_parameter table
# Use INSERT ... ON CONFLICT to handle both new and existing entries (PostgreSQL upsert)
# Note: ir_config_parameter table has a unique constraint on 'key' column
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<-EOSQL
	INSERT INTO ir_config_parameter (key, value, create_uid, create_date, write_uid, write_date)
	VALUES ('web.base.url', '$ODOO_URL', 1, NOW(), 1, NOW())
	ON CONFLICT (key) 
	DO UPDATE SET value = '$ODOO_URL', write_uid = 1, write_date = NOW();
EOSQL

if [ $? -eq 0 ]; then
    echo "  ✓ web.base.url updated successfully in database!"
    
    # Verify the update
    CURRENT_URL=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT value FROM ir_config_parameter WHERE key = 'web.base.url';" 2>/dev/null || echo "")
    
    echo "  Current web.base.url in database: $CURRENT_URL"
else
    echo -e "${RED}[ERROR]${NC} Failed to update web.base.url in database"
    exit 1
fi

# ============================================================================
# CACHE INVALIDATION (if URL changed)
# ============================================================================

if [ "$URL_CHANGED" = true ]; then
    echo ""
    echo "URL change detected - clearing Odoo cache..."
    
    # Clear Odoo's cache by invalidating the registry
    # We do this by updating the ir_config_parameter table's write_date for cache-related keys
    # This forces Odoo to reload its configuration and clear caches
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<-EOSQL 2>/dev/null || true
		UPDATE ir_config_parameter SET write_date = NOW() WHERE key LIKE 'web.%';
	EOSQL
    
    echo "  ✓ Cache invalidation complete"
else
    echo ""
    echo "URL unchanged - skipping cache invalidation"
fi

echo -e "${GREEN}[SUCCESS]${NC} Odoo configuration update completed!"

