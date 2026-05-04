#!/bin/bash

# n8n Configuration Update Script
# This script updates n8n configuration on every container startup
# It handles webhook URL changes and other dynamic configuration

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

set -e

echo -e "${YELLOW}[INFO]${NC} Updating n8n configuration from environment variables..."

# n8n URL configuration
N8N_WEBHOOK_URL="${WEBHOOK_URL:-}"

# ============================================================================
# STEP 1: Update webhook URL if set
# ============================================================================

if [ -z "$N8N_WEBHOOK_URL" ]; then
    echo -e "${YELLOW}[INFO]${NC} WEBHOOK_URL environment variable not set. Skipping URL update."
    echo -e "${GREEN}[SUCCESS]${NC} n8n configuration update completed!"
    exit 0
fi

echo -e "${YELLOW}[INFO]${NC} Webhook URL configured: $N8N_WEBHOOK_URL"

# n8n handles URL configuration through environment variables at runtime
# (WEBHOOK_URL, N8N_HOST, N8N_PROTOCOL, N8N_PORT)
# No database updates needed - n8n reads these on startup

echo -e "${GREEN}[SUCCESS]${NC} n8n configuration update completed!"
