#!/bin/bash

# n8n Installation Script
# This script handles the initial n8n setup and database verification

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

set -e

echo -e "${YELLOW}[INFO]${NC} Running n8n installation script..."

# Database connection details
PG_HOST="${DB_POSTGRESDB_HOST:-n8n-postgres}"
PG_PORT="${DB_POSTGRESDB_PORT:-5432}"
PG_USER="${DB_POSTGRESDB_USER:-n8n}"
PG_PASSWORD="${DB_POSTGRESDB_PASSWORD:-n8n}"
PG_DATABASE="${DB_POSTGRESDB_DATABASE:-n8n}"

# ============================================================================
# STEP 1: Verify PostgreSQL connection
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Verifying PostgreSQL connection..."

export PGPASSWORD="$PG_PASSWORD"
if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "SELECT 1" > /dev/null 2>&1; then
    echo -e "${GREEN}[SUCCESS]${NC} PostgreSQL connection verified!"
else
    echo -e "${RED}[ERROR]${NC} Failed to connect to PostgreSQL"
    exit 1
fi

# ============================================================================
# STEP 2: Ensure data directory exists
# ============================================================================

N8N_DATA_DIR="/home/node/.n8n"
mkdir -p "$N8N_DATA_DIR"
chown -R node:node "$N8N_DATA_DIR"

# ============================================================================
# STEP 3: Installation complete
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} n8n installation completed successfully!"
echo -e "${GREEN}[INFO]${NC} ================================================"
echo -e "${GREEN}[INFO]${NC} n8n is ready to use!"
echo -e "${GREEN}[INFO]${NC} ================================================"
echo -e "${GREEN}[INFO]${NC} Access n8n at: http://localhost:5678"
echo -e "${GREEN}[INFO]${NC} Database: $PG_DATABASE"
echo -e "${GREEN}[INFO]${NC} On first access, you will create an owner account."
echo -e "${GREEN}[INFO]${NC} ================================================"
