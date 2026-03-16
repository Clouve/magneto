#!/bin/bash

# Linux Server Docker Entrypoint Script
# This script initializes the Ubuntu Linux server container:
# 0. Re-applies apt-get service-start guards (policy-rc.d + systemctl no-op)
# 1. Creates the admin user from environment variables
# 2. Configures ANTHROPIC_API_KEY for all shell sessions (if provided)
# 3. Starts the ttyd web terminal on localhost
# 4. Starts the nginx reverse proxy (foreground)

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

# ============================================================================
# STEP 2: Write ANTHROPIC_API_KEY into the shell environment (optional)
# ============================================================================

if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo -e "${YELLOW}[INFO]${NC} Configuring ANTHROPIC_API_KEY..."

    # /etc/profile.d/ is sourced by every login shell (SSH, su -, web terminal)
    # This is the most reliable way to inject env vars for all session types
    cat > /etc/profile.d/clouve-env.sh <<EOF
export ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
EOF
    chmod 644 /etc/profile.d/clouve-env.sh

    # Pre-configure Claude Code to skip the first-run onboarding wizard.
    # Without this, Claude Code prompts the user to select a login method even
    # when ANTHROPIC_API_KEY is already set in the environment.
    USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
    # Only set onboarding state — do not store the key here.
    # Claude Code reads ANTHROPIC_API_KEY from the environment (set via
    # /etc/profile.d/clouve-env.sh above). Storing primaryApiKey in
    # ~/.claude.json alongside ANTHROPIC_API_KEY triggers an auth conflict warning.
    echo "{}" | jq \
        '.hasCompletedOnboarding = true | .oauthAccount = null' \
        > "$USER_HOME/.claude.json"
    chown "$USERNAME:$USERNAME" "$USER_HOME/.claude.json"
    chmod 600 "$USER_HOME/.claude.json"

    # Write global Claude Code context so every session starts with server awareness.
    # ~/.claude/CLAUDE.md is loaded automatically by Claude Code at startup.
    mkdir -p "$USER_HOME/.claude"
    HOSTNAME=$(hostname) envsubst '${USERNAME} ${ROOT_PASSWORD} ${HOSTNAME}' \
        < /clouve/linux/installer/CLAUDE.md.tpl \
        > "$USER_HOME/.claude/CLAUDE.md"
    chown -R "$USERNAME:$USERNAME" "$USER_HOME/.claude"
    chmod 600 "$USER_HOME/.claude/CLAUDE.md"

    # Auto-launch Claude Code on login and terminate the session when it exits.
    # ~/.bash_profile is sourced by every login shell (web terminal).
    cp /clouve/linux/installer/.bash_profile "$USER_HOME/.bash_profile"
    chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"
    chmod 644 "$USER_HOME/.bash_profile"

    echo -e "${GREEN}[SUCCESS]${NC} ANTHROPIC_API_KEY configured for all sessions."
else
    rm -f /etc/profile.d/clouve-env.sh
    echo -e "${YELLOW}[INFO]${NC} ANTHROPIC_API_KEY not set — skipping. Set it to use Claude Code."
fi

# ============================================================================
# STEP 3: Start ttyd web terminal on localhost
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Starting web terminal (ttyd)..."
ttyd \
    --port 7890 \
    --base-path /chat \
    --interface 127.0.0.1 \
    --credential "$USERNAME:$PASSWORD" \
    --writable \
    su - "$USERNAME" &
TTYD_PID=$!

sleep 1
if kill -0 $TTYD_PID 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} ttyd started (PID $TTYD_PID)."
else
    echo -e "${RED}[WARNING]${NC} ttyd may not have started correctly."
fi

# ============================================================================
# STEP 4: Start nginx reverse proxy
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} Linux server is ready!"
echo -e "${GREEN}[INFO]${NC} Web terminal available at http://localhost/chat"
echo -e "${GREEN}[INFO]${NC} Username: $USERNAME"

echo -e "${YELLOW}[INFO]${NC} Starting nginx..."
exec nginx -g "daemon off;"
