#!/bin/bash

# ============================================================================
# STEP 2: Install developer tools (first-run only)
# ============================================================================
# Developer tools are not baked into the image to keep it lean. They are
# installed on the first container start and persist in the /usr volume,
# so subsequent starts skip this block entirely.
# AI coding assistant CLIs are NOT installed here — the user selects and
# installs their preferred client interactively at session start.

if ! command -v git &>/dev/null; then
    echo -e "${YELLOW}[INFO]${NC} Installing developer tools..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
        apt-get install -y --no-install-recommends \
            wget git vim nano htop unzip \
            net-tools iputils-ping procps less \
        && rm -rf /var/lib/apt/lists/*
    echo -e "${GREEN}[SUCCESS]${NC} Developer tools installed."

    # Snapshot /etc to the persistent /var volume so all runtime-written files
    # survive container restarts. Excludes auth files (regenerated each start
    # from live env vars) and Docker/Kubernetes-managed networking files
    # (injected as bind mounts that take precedence over the volume anyway).
    echo -e "${YELLOW}[INFO]${NC} Saving /etc overlay..."
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
    echo -e "${GREEN}[SUCCESS]${NC} /etc overlay saved."
else
    echo -e "${GREEN}[INFO]${NC} Developer tools already present."
fi

# ============================================================================
# STEP 3: Configure session environment
# ============================================================================

# Ensure the home directory is owned by the user (handles volume remounts
# where the directory may have been created as root or with a stale UID).
chown "$USERNAME:$USERNAME" "$USER_HOME"
chmod 755 "$USER_HOME"

# Export all provided API keys and the root password to all login shells via
# /etc/profile.d/ so the interactive session selector can access them.
{
    [ -n "$ANTHROPIC_API_KEY" ]  && echo "export ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
    [ -n "$GEMINI_API_KEY" ]     && echo "export GEMINI_API_KEY=$GEMINI_API_KEY"
    [ -n "$OPENAI_API_KEY" ]     && echo "export OPENAI_API_KEY=$OPENAI_API_KEY"
    [ -n "$AI_STUDIO_CLIENT" ]   && echo "export AI_STUDIO_CLIENT=$AI_STUDIO_CLIENT"
    echo "export ROOT_PASSWORD=$ROOT_PASSWORD"
} > /etc/profile.d/clouve-env.sh
chmod 644 /etc/profile.d/clouve-env.sh
echo -e "${GREEN}[SUCCESS]${NC} Session environment configured via /etc/profile.d/."

# Install the interactive AI client selector as the user's login shell profile.
# On each terminal open, the user will be prompted to choose their preferred
# AI coding assistant client (Claude Code, Gemini CLI, OpenAI Codex CLI, or none).
cp /clouve/ai-studio/installer/chat/.bash_profile "$USER_HOME/.bash_profile"
chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"
chmod 644 "$USER_HOME/.bash_profile"
echo -e "${GREEN}[SUCCESS]${NC} AI client selector installed as login profile."

# ── Generate landing page from template ──────────────────────────────────────
# Stamp client-specific content into index.html based on AI_STUDIO_CLIENT.
# When unset the page reflects the interactive multi-client experience.
case "${AI_STUDIO_CLIENT:-}" in
    claude-code)
        CLV_CARD_DESC="Browser-based terminal — Claude Code launches automatically at session start."
        CLV_TERM_TITLE="claude — bash"
        CLV_TERM_CMD="claude"
        CLV_TERM_WELCOME="✻ Welcome to Claude Code! How can I help?"
        CLV_FEATURE_TITLE="Claude Code pre-installed"
        CLV_FEATURE_DESC="The latest Claude Code CLI is ready to use. Bring your Anthropic API key and start building immediately."
        ;;
    gemini-cli)
        CLV_CARD_DESC="Browser-based terminal — Gemini CLI launches automatically at session start."
        CLV_TERM_TITLE="gemini — bash"
        CLV_TERM_CMD="gemini"
        CLV_TERM_WELCOME="Hi, I'm Gemini. How can I help you today?"
        CLV_FEATURE_TITLE="Gemini CLI pre-installed"
        CLV_FEATURE_DESC="Google's Gemini CLI is ready to use. Bring your Gemini API key and start building immediately."
        ;;
    codex-cli)
        CLV_CARD_DESC="Browser-based terminal — OpenAI Codex CLI launches automatically at session start."
        CLV_TERM_TITLE="codex — bash"
        CLV_TERM_CMD="codex"
        CLV_TERM_WELCOME="Welcome to Codex! What should we build?"
        CLV_FEATURE_TITLE="OpenAI Codex CLI pre-installed"
        CLV_FEATURE_DESC="OpenAI's Codex CLI is ready to use. Bring your OpenAI API key and start building immediately."
        ;;
    *)
        CLV_CARD_DESC="Browser-based terminal — choose Claude Code, Gemini CLI, or OpenAI Codex CLI at session start."
        CLV_TERM_TITLE="ai-studio — bash"
        CLV_TERM_CMD="claude"
        CLV_TERM_WELCOME="✻ Welcome to Claude Code! How can I help?"
        CLV_FEATURE_TITLE="Multiple AI clients"
        CLV_FEATURE_DESC="Choose from Claude Code, Gemini CLI, or OpenAI Codex CLI at each session start. Your preference is remembered."
        ;;
esac
export CLV_CARD_DESC CLV_TERM_TITLE CLV_TERM_CMD CLV_TERM_WELCOME CLV_FEATURE_TITLE CLV_FEATURE_DESC
envsubst '${CLV_CARD_DESC} ${CLV_TERM_TITLE} ${CLV_TERM_CMD} ${CLV_TERM_WELCOME} ${CLV_FEATURE_TITLE} ${CLV_FEATURE_DESC}' \
    < /clouve/ai-studio/installer/index.html.tpl \
    > /var/www/html/index.html
echo -e "${GREEN}[SUCCESS]${NC} Landing page generated for client: ${AI_STUDIO_CLIENT:-interactive}."

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
