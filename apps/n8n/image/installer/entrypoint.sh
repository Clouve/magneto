#!/bin/bash

# n8n Docker Entrypoint Script
# This script handles the complete n8n initialization process:
# 1. Waits for PostgreSQL to be ready
# 2. Generates encryption key if not provided
# 3. Configures n8n environment
# 4. Starts n8n server via the original entrypoint

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set error handling
set -e

# n8n configuration
N8N_DATA_DIR="/home/node/.n8n"
INSTALLED_MARKER="$N8N_DATA_DIR/.n8n_initialized"

echo -e "${YELLOW}[INFO]${NC} Starting n8n initialization..."
echo -e "${YELLOW}[INFO]${NC} n8n version: 2.12.3"

# ============================================================================
# STEP 1: Wait for PostgreSQL to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for PostgreSQL to be ready..."

# Extract database connection details from environment variables
PG_HOST="${DB_POSTGRESDB_HOST:-n8n-postgres}"
PG_PORT="${DB_POSTGRESDB_PORT:-5432}"
PG_USER="${DB_POSTGRESDB_USER:-n8n}"
PG_PASSWORD="${DB_POSTGRESDB_PASSWORD:-n8n}"

max_attempts=60
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" > /dev/null 2>&1; then
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
# STEP 2: Configure n8n environment
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Configuring n8n..."

# Ensure data directory exists with proper permissions
mkdir -p "$N8N_DATA_DIR"

# Set database type to PostgreSQL
export DB_TYPE="postgresdb"

# Generate encryption key if not provided
if [ -z "$N8N_ENCRYPTION_KEY" ]; then
    # Check if we previously generated one and stored it
    ENCRYPTION_KEY_FILE="$N8N_DATA_DIR/.encryption_key"
    if [ -f "$ENCRYPTION_KEY_FILE" ]; then
        export N8N_ENCRYPTION_KEY=$(cat "$ENCRYPTION_KEY_FILE")
        echo -e "${GREEN}[INFO]${NC} Using previously generated encryption key"
    else
        export N8N_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 32)
        echo "$N8N_ENCRYPTION_KEY" > "$ENCRYPTION_KEY_FILE"
        chmod 600 "$ENCRYPTION_KEY_FILE"
        echo -e "${YELLOW}[WARNING]${NC} No N8N_ENCRYPTION_KEY provided. Generated random encryption key."
        echo -e "${YELLOW}[WARNING]${NC} Encryption key stored at: $ENCRYPTION_KEY_FILE"
        echo -e "${YELLOW}[WARNING]${NC} Please save this key securely! Losing it means losing access to stored credentials."
    fi
fi

echo -e "${GREEN}[SUCCESS]${NC} n8n environment configured"

# ============================================================================
# STEP 3: Check if n8n is already initialized
# ============================================================================

if [ -f "$INSTALLED_MARKER" ]; then
    echo -e "${GREEN}[INFO]${NC} n8n appears to be already initialized. Skipping first-run setup."
    echo -e "${GREEN}[INFO]${NC} Marker file found: $INSTALLED_MARKER"
else
    echo -e "${YELLOW}[INFO]${NC} First-time initialization detected. Running setup..."

    # Run the installation script
    /clouve/n8n/installer/install.sh

    # Create marker file to indicate initialization is complete
    echo "$(date)" > "$INSTALLED_MARKER"
    echo -e "${GREEN}[SUCCESS]${NC} n8n initialization completed!"
fi

# ============================================================================
# STEP 4: Update configuration (runs on every startup)
# ============================================================================

# Run the configuration update script to handle URL changes and other dynamic config
if [ -f /clouve/n8n/installer/update-config.sh ]; then
    echo -e "${YELLOW}[INFO]${NC} Running configuration update script..."
    /clouve/n8n/installer/update-config.sh
fi

# ============================================================================
# STEP 5: Fix permissions and start n8n
# ============================================================================

# Ensure proper ownership of data directory
chown -R node:node "$N8N_DATA_DIR"

echo -e "${GREEN}[SUCCESS]${NC} n8n is ready to use!"
echo -e "${GREEN}[INFO]${NC} Access n8n at: http://localhost:5678"
echo -e "${YELLOW}[INFO]${NC} Starting n8n server..."

# Switch to node user and start n8n via the original entrypoint
# The original entrypoint handles custom certificates and exec'ing n8n
# We call it with no arguments so it runs "exec n8n" (its default behavior)
exec su-exec node /docker-entrypoint.sh
