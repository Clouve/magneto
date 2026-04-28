#!/bin/bash

# AI Studio Docker Entrypoint Script
# This script initializes the Ubuntu Linux server container:
# 0.  Re-applies apt-get service-start guards (policy-rc.d + systemctl no-op)
# 0b. Restores /etc overlay from /var volume (if present)
# 1.  Creates the admin user from environment variables
# 2-4. chat/install.sh  — developer tools, session config, ttyd
# 5.   files/install.sh — FileBrowser Quantum
# 5b.  auth/server.py   — session-based authentication server
# 6.  Starts the nginx reverse proxy (foreground)

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
# STEP 0b: Restore /etc overlay
# ============================================================================
# /etc is NOT a persistent volume — it is rebuilt from the image layer on
# every container start. Any files written to /etc at runtime (package configs,
# alternatives symlinks, profile.d entries, etc.) are lost on restart.
#
# The /etc overlay is a tarball stored on the persistent /var volume. It is
# created after first-run package installation (in chat/install.sh) and
# restored here on every subsequent start, making all runtime /etc writes
# durable across restarts without requiring a dedicated /etc PVC.
#
# Auth files (/etc/passwd, /etc/shadow, /etc/group, /etc/gshadow,
# /etc/sudoers.d) and Docker/Kubernetes-managed networking files
# (/etc/resolv.conf, /etc/hosts, /etc/hostname) are excluded from the
# snapshot and are always derived from live state, never from the overlay.

if [ -f /var/lib/clouve/etc-overlay.tar.gz ]; then
    tar xzf /var/lib/clouve/etc-overlay.tar.gz -C / 2>/dev/null || true
    echo -e "${GREEN}[INFO]${NC} /etc overlay restored."
fi

# ============================================================================
# STEP 1: Configure user account
# ============================================================================

USERNAME="${AI_STUDIO_USERNAME:-admin}"
PASSWORD="${AI_STUDIO_PASSWORD:-changeme}"
ROOT_PASSWORD="${AI_STUDIO_ROOT_PASSWORD:-${PASSWORD}}"

# Export so chat/install.sh's generic env snapshot (env -0) picks them up
# and propagates them to login shells via /etc/profile.d/clouve-env.sh.
# The CLAUDE.md / GEMINI.md / AGENTS.md templates and the bash_profile's
# `su - root` instruction-rendering all read ROOT_PASSWORD.
export USERNAME PASSWORD ROOT_PASSWORD

# Normalize username: trim leading/trailing whitespace, collapse internal
# whitespace sequences into a single underscore.  This ensures the username
# is safe for useradd, home-directory paths, sudoers entries, and PAM auth.
USERNAME="$(printf '%s' "$USERNAME" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[[:space:]]\{1,\}/_/g')"

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
# STEPS 2-4: Chat feature (developer tools, session setup, ttyd)
# ============================================================================

. /clouve/ai-studio/installer/chat/install.sh

# ============================================================================
# STEP 5: Files feature (FileBrowser Quantum)
# ============================================================================

. /clouve/ai-studio/installer/files/install.sh

# ============================================================================
# STEP 5b: Start authentication server
# ============================================================================
# Lightweight Python HTTP server that validates OS credentials against
# /etc/shadow and manages session cookies. nginx uses auth_request to gate
# /_clv/chat and /_clv/browser behind this server, replacing per-service Basic Auth
# and PAM prompts with a unified SPA login form.

echo -e "${YELLOW}[INFO]${NC} Starting auth server..."
python3 /clouve/ai-studio/installer/auth/server.py &
AUTH_PID=$!
sleep 0.5

if kill -0 $AUTH_PID 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} Auth server started (PID $AUTH_PID)."
else
    echo -e "${RED}[WARNING]${NC} Auth server may not have started correctly."
fi

# ============================================================================
# STEP 6: Start nginx reverse proxy
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} AI Studio is ready!"
echo -e "${GREEN}[INFO]${NC} Web terminal available at http://localhost/_clv/chat"
echo -e "${GREEN}[INFO]${NC} File browser available at http://localhost/_clv/browser"
echo -e "${GREEN}[INFO]${NC} Username: $USERNAME"

# On SIGTERM (sent by `docker-compose down` / `kubectl delete pod`), snapshot
# /etc before nginx exits so any runtime edits — e.g. changes to
# /etc/nginx/sites-available/default made with vi — survive the next restart.
# The same exclusions as the first-run snapshot apply (auth files and
# Docker/Kubernetes-managed networking files are never saved to the overlay).
# Note: SIGKILL bypasses this handler; only graceful stops are captured.
_term() {
    echo -e "${YELLOW}[INFO]${NC} Caught SIGTERM — saving /etc overlay before shutdown..."
    mkdir -p /var/lib/clouve
    tar czf /var/lib/clouve/etc-overlay.tar.gz \
        --exclude=etc/resolv.conf \
        --exclude=etc/hosts \
        --exclude=etc/hostname \
        --exclude=etc/passwd \
        --exclude=etc/shadow \
        --exclude=etc/group \
        --exclude=etc/gshadow \
        --exclude=etc/sudoers.d \
        -C / etc
    echo -e "${GREEN}[INFO]${NC} /etc overlay saved."
    kill -TERM "$NGINX_PID" 2>/dev/null
}
trap _term SIGTERM SIGINT

echo -e "${YELLOW}[INFO]${NC} Starting nginx..."
nginx -g "daemon off;" &
NGINX_PID=$!
wait $NGINX_PID
