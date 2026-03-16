#!/bin/bash

# Linux Server Docker Entrypoint Script
# This script initializes the Ubuntu Linux server container:
# 0. Re-applies apt-get service-start guards (policy-rc.d + systemctl no-op)
# 1. Creates the admin user from environment variables
# 2. Configures ANTHROPIC_API_KEY for all shell sessions (if provided)
# 3. Configures SSH authorized key (if provided)
# 4. Ensures SSH host keys exist
# 5. Starts the SSH daemon
# 6. Starts the ttyd web terminal

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
    cat > "$USER_HOME/.claude/CLAUDE.md" <<EOF
# Server Context

## Environment
- OS: Ubuntu 24.04 LTS
- Hostname: $(hostname)
- User: $USERNAME (passwordless sudo enabled)

## Privileged Access
To run privileged commands use \`sudo\` (no password required for $USERNAME) or switch to root:
\`\`\`bash
sudo <command>
# or
su - root  # password: $ROOT_PASSWORD
\`\`\`

## Available Services
- Web terminal: port 7890
- SSH daemon: port 22
- HTTP: port 80
- HTTPS: port 443

## Notes
- Home directory is persisted across container restarts via a Docker volume mounted at /home
- Claude Code is pre-installed globally via npm (Node.js 22)
EOF
    chown -R "$USERNAME:$USERNAME" "$USER_HOME/.claude"
    chmod 600 "$USER_HOME/.claude/CLAUDE.md"

    # Auto-launch Claude Code on login and terminate the session when it exits.
    # ~/.bash_profile is sourced by every login shell (SSH and web terminal).
    cat > "$USER_HOME/.bash_profile" <<'EOF'
# Source ~/.bashrc for aliases, functions, and environment variables
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

# Auto-launch Claude Code only for interactive login shells (real terminal sessions).
# Guard required because Claude Code itself invokes bash with -l to inherit the login
# environment when running commands — without this check, every such invocation would
# launch a nested claude session instead of executing the intended command.
if [[ $- == *i* ]]; then
    claude
    exit $?
fi
EOF
    chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"
    chmod 644 "$USER_HOME/.bash_profile"

    echo -e "${GREEN}[SUCCESS]${NC} ANTHROPIC_API_KEY configured for all sessions."
else
    rm -f /etc/profile.d/clouve-env.sh
    echo -e "${YELLOW}[INFO]${NC} ANTHROPIC_API_KEY not set — skipping. Set it to use Claude Code."
fi

# ============================================================================
# STEP 3: Configure SSH authorized key (optional)
# ============================================================================

if [ -n "$CLAUDE_SSH_AUTHORIZED_KEY" ]; then
    echo -e "${YELLOW}[INFO]${NC} Adding SSH authorized key for $USERNAME..."
    USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
    mkdir -p "$USER_HOME/.ssh"
    echo "$CLAUDE_SSH_AUTHORIZED_KEY" >> "$USER_HOME/.ssh/authorized_keys"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"
    chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"
    echo -e "${GREEN}[SUCCESS]${NC} SSH authorized key added."
fi

# ============================================================================
# STEP 4: Ensure SSH host keys exist
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Checking SSH host keys..."
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -A
    echo -e "${GREEN}[SUCCESS]${NC} SSH host keys generated."
else
    echo -e "${GREEN}[INFO]${NC} SSH host keys already present."
fi

# ============================================================================
# STEP 5: Start SSH daemon
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Starting SSH daemon..."
/usr/sbin/sshd -D &
SSH_PID=$!

# Brief pause to confirm sshd started
sleep 1
if kill -0 $SSH_PID 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} SSH daemon started (PID $SSH_PID)."
else
    echo -e "${RED}[WARNING]${NC} SSH daemon may not have started correctly."
fi

# ============================================================================
# STEP 6: Start ttyd web terminal
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} Linux server is ready!"
echo -e "${GREEN}[INFO]${NC} Web terminal available at port 7890"
echo -e "${GREEN}[INFO]${NC} SSH available at port 22"
echo -e "${GREEN}[INFO]${NC} Username: $USERNAME"

echo -e "${YELLOW}[INFO]${NC} Starting web terminal (ttyd)..."
exec ttyd \
    --port 7890 \
    --credential "$USERNAME:$PASSWORD" \
    --writable \
    su - "$USERNAME"
