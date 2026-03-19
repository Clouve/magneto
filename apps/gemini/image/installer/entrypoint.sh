#!/bin/bash

# Linux Server Docker Entrypoint Script
# This script initializes the Ubuntu Linux server container:
# 0. Re-applies apt-get service-start guards (policy-rc.d + systemctl no-op)
# 1. Creates the admin user from environment variables
# 2. Installs developer tools, Node.js 20, and Gemini CLI (first-run only)
# 3. Configures Gemini CLI: injects API key if provided, otherwise defers to login-time prompt
# 4. Starts the ttyd web terminal on localhost
# 5. Starts the nginx reverse proxy (foreground)

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

USERNAME="${GEMINI_USERNAME:-admin}"
PASSWORD="${GEMINI_PASSWORD:-changeme}"
ROOT_PASSWORD="${GEMINI_ROOT_PASSWORD:-${PASSWORD}}"
GEMINI_API_KEY="${GEMINI_API_KEY:-}"

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
# STEP 2: Install developer tools, Node.js 20, and Gemini CLI (first-run only)
# ============================================================================
# Developer tools and Gemini CLI are not baked into the image to keep it lean.
# They are installed on the first container start and persist in the /usr volume,
# so subsequent starts skip this block entirely.
#
# Node.js 20+ is required by the Gemini CLI (npm install -g @google/gemini-cli).

if ! command -v git &>/dev/null; then
    echo -e "${YELLOW}[INFO]${NC} Installing developer tools..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
        apt-get install -y --no-install-recommends \
            wget git vim nano htop unzip \
            net-tools iputils-ping procps less \
        && rm -rf /var/lib/apt/lists/*
    echo -e "${GREEN}[SUCCESS]${NC} Developer tools installed."
else
    echo -e "${GREEN}[INFO]${NC} Developer tools already present."
fi

if ! command -v node &>/dev/null; then
    echo -e "${YELLOW}[INFO]${NC} Installing Node.js 20..."
    NODE_VERSION="20.19.0"
    NODE_ARCH=$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
        | tar xz --strip-components=1 -C /usr/local
    echo -e "${GREEN}[SUCCESS]${NC} Node.js $(node --version) installed."
else
    echo -e "${GREEN}[INFO]${NC} Node.js already present ($(node --version))."
fi

if ! command -v gemini &>/dev/null; then
    echo -e "${YELLOW}[INFO]${NC} Installing Gemini CLI..."
    npm install -g @google/gemini-cli
    echo -e "${GREEN}[SUCCESS]${NC} Gemini CLI installed."
else
    echo -e "${GREEN}[INFO]${NC} Gemini CLI already installed."
fi

# ============================================================================
# STEP 3: Configure Gemini CLI session environment
# ============================================================================

# Ensure the home directory is owned by the user (handles volume remounts
# where the directory may have been created as root or with a stale UID).
chown "$USERNAME:$USERNAME" "$USER_HOME"
chmod 755 "$USER_HOME"

# If GEMINI_API_KEY is provided at container startup, export it to all login
# shells via /etc/profile.d/. This is the most reliable injection point.
# If absent, the key will be resolved at login time via ~/.bash_profile:
#   stored ~/.gemini_api_key → or prompt the user to enter it.
if [ -n "$GEMINI_API_KEY" ]; then
    echo -e "${YELLOW}[INFO]${NC} Exporting GEMINI_API_KEY to all shell sessions..."
    cat > /etc/profile.d/clouve-env.sh <<EOF
export GEMINI_API_KEY=$GEMINI_API_KEY
EOF
    chmod 644 /etc/profile.d/clouve-env.sh
    echo -e "${GREEN}[SUCCESS]${NC} GEMINI_API_KEY configured via /etc/profile.d/."
else
    rm -f /etc/profile.d/clouve-env.sh
    echo -e "${YELLOW}[INFO]${NC} GEMINI_API_KEY not set — user will be prompted at login."
fi

# Create the Gemini CLI config directory and write the server context file.
# GEMINI.md is read by Gemini CLI from the current directory hierarchy,
# so placing it in the home directory ensures it is loaded for every session.
mkdir -p "$USER_HOME/.gemini"
HOSTNAME=$(hostname) USERNAME="$USERNAME" ROOT_PASSWORD="$ROOT_PASSWORD" \
    envsubst '${USERNAME} ${ROOT_PASSWORD} ${HOSTNAME}' \
    < /clouve/gemini/installer/GEMINI.md.tpl \
    > "$USER_HOME/GEMINI.md"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.gemini"
chown "$USERNAME:$USERNAME" "$USER_HOME/GEMINI.md"
chmod 600 "$USER_HOME/GEMINI.md"

# Install login shell profile. This auto-launches Gemini CLI for interactive
# user terminal sessions and gates access on a valid GEMINI_API_KEY.
cp /clouve/gemini/installer/.bash_profile "$USER_HOME/.bash_profile"
chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"
chmod 644 "$USER_HOME/.bash_profile"

# ============================================================================
# STEP 4: Start ttyd web terminal on localhost
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Starting web terminal (ttyd)..."

# Create a session wrapper that ignores all arguments.
# ttyd supports ?arg= URL query parameters which clients can use to inject extra
# arguments to the spawned command (e.g. --noprofile to bypass .bash_profile).
# The wrapper discards all arguments and always starts a login shell as $USERNAME.
printf '#!/bin/bash\nexec su - %s\n' "$USERNAME" > /usr/local/bin/clv-session
chmod 755 /usr/local/bin/clv-session

ttyd \
    --port 7890 \
    --base-path /chat \
    --interface 127.0.0.1 \
    --credential "$USERNAME:$PASSWORD" \
    --writable \
    /usr/local/bin/clv-session &
TTYD_PID=$!

sleep 1
if kill -0 $TTYD_PID 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} ttyd started (PID $TTYD_PID)."
else
    echo -e "${RED}[WARNING]${NC} ttyd may not have started correctly."
fi

# ============================================================================
# STEP 5: Start nginx reverse proxy
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} Linux server is ready!"
echo -e "${GREEN}[INFO]${NC} Web terminal available at http://localhost/chat"
echo -e "${GREEN}[INFO]${NC} Username: $USERNAME"

echo -e "${YELLOW}[INFO]${NC} Starting nginx..."
exec nginx -g "daemon off;"
