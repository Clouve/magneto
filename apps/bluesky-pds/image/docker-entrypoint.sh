#!/bin/bash

# Bluesky PDS Docker Entrypoint Script
# This script handles automatic generation of unique secrets and keys for each deployment:
# 1. Generates PDS_ADMIN_PASSWORD if not set
# 2. Generates PDS_JWT_SECRET if not set
# 3. Generates PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX if not set
# 4. Generates PDS_DPOP_SECRET if not set
# 5. Starts the PDS service

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Set error handling
set -e

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Generate a random alphanumeric string (for passwords)
generate_random_string() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# Generate a 64-character hex string (for JWT and DPoP secrets)
generate_hex_secret() {
    # Generate a 32-byte (256-bit) random value and convert to 64-char hex string
    openssl rand -hex 32
}

# Generate a K256 (secp256k1) private key in hexadecimal format
generate_k256_private_key_hex() {
    # Generate a 32-byte (256-bit) random key and convert to hex
    openssl rand -hex 32
}

# ============================================================================
# STEP 1: Generate secrets if not provided
# ============================================================================

echo -e "${BLUE}[INFO]${NC} Bluesky PDS Initialization"
echo -e "${BLUE}[INFO]${NC} ================================"

# Generate PDS_ADMIN_PASSWORD if not set
if [ -z "$PDS_ADMIN_PASSWORD" ]; then
    export PDS_ADMIN_PASSWORD=$(generate_random_string 24)
    echo -e "${GREEN}[GENERATED]${NC} PDS_ADMIN_PASSWORD: ${PDS_ADMIN_PASSWORD}"
else
    echo -e "${YELLOW}[USING EXISTING]${NC} PDS_ADMIN_PASSWORD is already set"
fi

# Generate PDS_JWT_SECRET if not set (must be 64-char hex string)
if [ -z "$PDS_JWT_SECRET" ]; then
    export PDS_JWT_SECRET=$(generate_hex_secret)
    echo -e "${GREEN}[GENERATED]${NC} PDS_JWT_SECRET: ${PDS_JWT_SECRET}"
else
    echo -e "${YELLOW}[USING EXISTING]${NC} PDS_JWT_SECRET is already set"
fi

# Generate PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX if not set
if [ -z "$PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX" ]; then
    export PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$(generate_k256_private_key_hex)
    echo -e "${GREEN}[GENERATED]${NC} PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX: ${PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX}"
else
    echo -e "${YELLOW}[USING EXISTING]${NC} PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX is already set"
fi

# Generate PDS_DPOP_SECRET if not set (must be 64-char hex string)
if [ -z "$PDS_DPOP_SECRET" ]; then
    export PDS_DPOP_SECRET=$(generate_hex_secret)
    echo -e "${GREEN}[GENERATED]${NC} PDS_DPOP_SECRET: ${PDS_DPOP_SECRET}"
else
    echo -e "${YELLOW}[USING EXISTING]${NC} PDS_DPOP_SECRET is already set"
fi

# ============================================================================
# STEP 2: Save generated secrets to a file for persistence
# ============================================================================

# Create secrets file if it doesn't exist
SECRETS_FILE="${PDS_DATA_DIRECTORY:-/pds}/.secrets"

if [ ! -f "$SECRETS_FILE" ]; then
    echo -e "${BLUE}[INFO]${NC} Saving generated secrets to ${SECRETS_FILE}"
    mkdir -p "$(dirname "$SECRETS_FILE")"
    cat > "$SECRETS_FILE" << EOF
# Bluesky PDS Auto-Generated Secrets
# Generated on: $(date)
# DO NOT SHARE THESE VALUES

PDS_ADMIN_PASSWORD=${PDS_ADMIN_PASSWORD}
PDS_JWT_SECRET=${PDS_JWT_SECRET}
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=${PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX}
PDS_DPOP_SECRET=${PDS_DPOP_SECRET}
EOF
    chmod 600 "$SECRETS_FILE"
    echo -e "${GREEN}[SUCCESS]${NC} Secrets saved to ${SECRETS_FILE}"
    echo -e "${YELLOW}[IMPORTANT]${NC} Please backup this file for disaster recovery!"
else
    echo -e "${BLUE}[INFO]${NC} Secrets file already exists at ${SECRETS_FILE}"
fi

# ============================================================================
# STEP 3: Display configuration summary
# ============================================================================

echo -e "${BLUE}[INFO]${NC} ================================"
echo -e "${BLUE}[INFO]${NC} Bluesky PDS Configuration Summary"
echo -e "${BLUE}[INFO]${NC} ================================"
echo -e "${BLUE}[INFO]${NC} Hostname: ${PDS_HOSTNAME:-not set}"
echo -e "${BLUE}[INFO]${NC} Data Directory: ${PDS_DATA_DIRECTORY:-/pds}"
echo -e "${BLUE}[INFO]${NC} Admin Password: ${PDS_ADMIN_PASSWORD}"
echo -e "${BLUE}[INFO]${NC} Invite Required: ${PDS_INVITE_REQUIRED:-0}"
echo -e "${BLUE}[INFO]${NC} ================================"

# ============================================================================
# STEP 4: Start the PDS service
# ============================================================================

echo -e "${GREEN}[INFO]${NC} Starting Bluesky PDS..."

# Execute the original PDS entrypoint or command
# The official Bluesky PDS image uses node to start the service
exec node --enable-source-maps index.js

