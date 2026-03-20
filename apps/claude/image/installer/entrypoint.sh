#!/bin/bash

# Linux Server Docker Entrypoint Script
# This script initializes the Ubuntu Linux server container:
# 0. Re-applies apt-get service-start guards (policy-rc.d + systemctl no-op)
# 1. Creates the admin user from environment variables
# 2-4. chat/install.sh  — developer tools, Claude Code, ttyd
# 5.   files/install.sh — FileBrowser Quantum
# 6. Starts the nginx reverse proxy (foreground)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set error handling - don't exit on error, just log it
set +e

# ============================================================================
# STEP 0: Re-apply apt-get service-start guards
# ============================================================================
# These files live under /usr which is a named volume. Writing them here
# ensures they are always present regardless of when the volume was created,
# so apt-get never hangs waiting for systemd during runtime package installs.

# Prevents invoke-rc.d from starting services after package installation
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

# Replaces systemctl with a no-op so packages that call it directly (e.g. nginx)
# don't hang waiting for a systemd socket that doesn't exist in containers
printf '#!/bin/sh\nexit 0\n' > /usr/bin/systemctl
chmod +x /usr/bin/systemctl

echo -e "${GREEN}[INFO]${NC} apt-get service-start guards applied."

# ============================================================================
# STEP 1: Configure user account
# ============================================================================

USERNAME="${CLAUDE_USERNAME:-admin}"
PASSWORD="${CLAUDE_PASSWORD:-changeme}"
ROOT_PASSWORD="${CLAUDE_ROOT_PASSWORD:-${PASSWORD}}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

echo -e "${YELLOW}[INFO]${NC} Configuring user: $USERNAME..."

if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash "$USERNAME"
    usermod -aG sudo "$USERNAME"
    echo -e "${GREEN}[SUCCESS]${NC} User '$USERNAME' created."
else
    echo -e "${GREEN}[INFO]${NC} User '$USERNAME' already exists."
fi

# Set user and root passwords
echo "$USERNAME:$PASSWORD" | chpasswd
echo "root:$ROOT_PASSWORD" | chpasswd
echo -e "${GREEN}[SUCCESS]${NC} Passwords configured."

# Allow sudo without password for the admin user
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USERNAME"
chmod 440 /etc/sudoers.d/"$USERNAME"

USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)

# ============================================================================
# STEPS 2-4: Chat feature (developer tools, Claude Code, ttyd)
# ============================================================================

# . /clouve/claude/installer/chat/install.sh

# ============================================================================
# STEP 5: Files feature (FileBrowser Quantum)
# ============================================================================

. /clouve/claude/installer/files/install.sh

# ============================================================================
# STEP 6: Start nginx reverse proxy
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} Linux server is ready!"
echo -e "${GREEN}[INFO]${NC} Web terminal available at http://localhost/chat"
echo -e "${GREEN}[INFO]${NC} File browser available at http://localhost/files/"
echo -e "${GREEN}[INFO]${NC} Username: $USERNAME"

echo -e "${YELLOW}[INFO]${NC} Starting nginx..."
exec nginx -g "daemon off;"
