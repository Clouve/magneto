#!/bin/bash

# ============================================================================
# STEP 2: Install developer tools and Claude Code (first-run only)
# ============================================================================
# Developer tools are not baked into the image to keep it lean. They are
# installed on the first container start and persist in the /usr volume,
# so subsequent starts skip this block entirely.
#
# Claude Code is installed as $USERNAME so the binary lands in that user's
# ~/.local/bin/, which is automatically added to PATH by the default .bashrc.

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

if [ ! -x "$USER_HOME/.local/bin/claude" ]; then
    echo -e "${YELLOW}[INFO]${NC} Installing Claude Code for $USERNAME..."
    su - "$USERNAME" -c "curl -fsSL https://claude.ai/install.sh | bash"
    if [ ! -x "$USER_HOME/.local/bin/claude" ]; then
        echo -e "${RED}[ERROR]${NC} Claude Code installation failed — binary not found at $USER_HOME/.local/bin/claude."
        exit 1
    fi
    echo -e "${GREEN}[SUCCESS]${NC} Claude Code installed."
else
    echo -e "${GREEN}[INFO]${NC} Claude Code already installed."
fi

# ============================================================================
# STEP 3: Configure Claude Code session environment
# ============================================================================

# Ensure the home directory is owned by the user (handles volume remounts
# where the directory may have been created as root or with a stale UID).
chown "$USERNAME:$USERNAME" "$USER_HOME"
chmod 755 "$USER_HOME"

# If ANTHROPIC_API_KEY is provided at container startup, export it to all login
# shells via /etc/profile.d/. This is the most reliable injection point.
# If absent, the key will be resolved at login time via ~/.bash_profile:
#   stored ~/.claude_api_key → or prompt the user to enter it.
if [ -n "$ANTHROPIC_API_KEY" ]; then
    echo -e "${YELLOW}[INFO]${NC} Exporting ANTHROPIC_API_KEY to all shell sessions..."
    cat > /etc/profile.d/clouve-env.sh <<EOF
export ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
EOF
    chmod 644 /etc/profile.d/clouve-env.sh
    echo -e "${GREEN}[SUCCESS]${NC} ANTHROPIC_API_KEY configured via /etc/profile.d/."
else
    rm -f /etc/profile.d/clouve-env.sh
    echo -e "${YELLOW}[INFO]${NC} ANTHROPIC_API_KEY not set — user will be prompted at login."
fi

# Pre-configure Claude Code to skip the first-run onboarding wizard.
# Without this, Claude Code prompts the user to select a login method even
# when ANTHROPIC_API_KEY is already set in the environment.
# Only set onboarding state — do not store the key here.
# Claude Code reads ANTHROPIC_API_KEY from the environment (set via
# /etc/profile.d/clouve-env.sh above or exported from ~/.bash_profile).
# Storing primaryApiKey in ~/.claude.json alongside ANTHROPIC_API_KEY triggers
# an auth conflict warning.
echo "{}" | jq \
    '.hasCompletedOnboarding = true | .oauthAccount = null' \
    > "$USER_HOME/.claude.json"
chown "$USERNAME:$USERNAME" "$USER_HOME/.claude.json"
chmod 600 "$USER_HOME/.claude.json"

# Write global Claude Code context so every session starts with server awareness.
# ~/.claude/CLAUDE.md is loaded automatically by Claude Code at startup.
mkdir -p "$USER_HOME/.claude"
HOSTNAME=$(hostname) USERNAME="$USERNAME" ROOT_PASSWORD="$ROOT_PASSWORD" \
    envsubst '${USERNAME} ${ROOT_PASSWORD} ${HOSTNAME}' \
    < /clouve/claude/installer/chat/CLAUDE.md.tpl \
    > "$USER_HOME/.claude/CLAUDE.md"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.claude"
chmod 600 "$USER_HOME/.claude/CLAUDE.md"

# Install login shell profile. This auto-launches Claude Code for interactive
# user terminal sessions and gates access on a valid ANTHROPIC_API_KEY.
cp /clouve/claude/installer/chat/.bash_profile "$USER_HOME/.bash_profile"
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
