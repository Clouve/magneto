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

# Snapshot the entrypoint's env into /etc/profile.d/clouve-env.sh so every
# var that docker-compose / Kubernetes set on this container survives the
# `su -` invoked by ttyd's clv-session wrapper for each user shell. The
# bash_profile selector and the per-client CLAUDE.md/GEMINI.md/AGENTS.md
# templates rely on these being present at login time — without this
# snapshot, post-su shells start with the bare login env and envsubst
# renders empty placeholders.
#
# This is a generic propagation: any env var the orchestrator sets on the
# service (ai-studio's own vars OR a downstream app's app-specific vars
# like GIBBON_HOST, CLOUVE_OPS_PASSWORD, etc.) reaches login shells
# without per-app /etc/profile.d/ shims.
#
# The denylist below excludes shell/system vars that login shells will
# (and should) re-derive themselves. Bash exports function definitions
# as env vars with funky names containing `()` — the printable-name
# regex below filters them out. Values are quoted with `printf %q` so
# any shell-active characters (spaces, $, quotes, newlines) survive
# sourcing intact.
#
# The auth server's _update_profile_env() (image/installer/auth/server.py)
# rewrites individual lines in this file when AI_STUDIO_HOST is detected
# from the HTTP Host header or when an API key is saved interactively;
# its `startswith("export VAR=")` matcher is compatible with %q quoting.
clouve_env_excludes='^(PATH|PWD|OLDPWD|SHLVL|_|HOME|USER|LOGNAME|MAIL|TERM|SHELL|HOSTNAME|HOSTTYPE|MACHTYPE|OSTYPE|IFS|PS[0-9]|BASH.*|COLUMNS|LINES|OPTIND|RANDOM|SECONDS|UID|EUID|PPID|GROUPS|FUNCNAME)$'

{
    # `env -0` emits NUL-separated KEY=VALUE entries so embedded newlines
    # survive (rare, but possible — and printf %q handles them either way).
    while IFS='=' read -r -d '' var value; do
        [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ "$var" =~ $clouve_env_excludes ]] && continue
        printf 'export %s=%q\n' "$var" "$value"
    done < <(env -0)
} > /etc/profile.d/clouve-env.sh
chmod 644 /etc/profile.d/clouve-env.sh
unset clouve_env_excludes
echo -e "${GREEN}[SUCCESS]${NC} Session environment configured via /etc/profile.d/."

# Load skills requested via AI_STUDIO_SKILLS. No-op when the var is unset.
# Runs after the env snapshot above so the loader's git-fetch path can read
# AI_STUDIO_SKILLS_REPO/REF/PATH/TOKEN from the same propagation mechanism.
. /clouve/ai-studio/installer/chat/skills.sh

# Install the interactive AI client selector as the user's login shell profile.
# On each terminal open, the user will be prompted to choose their preferred
# AI coding assistant client (Claude Code, Gemini CLI, OpenAI Codex CLI, or none).
cp /clouve/ai-studio/installer/chat/.bash_profile "$USER_HOME/.bash_profile"
chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"
chmod 644 "$USER_HOME/.bash_profile"
echo -e "${GREEN}[SUCCESS]${NC} AI client selector installed as login profile."

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

# Authentication is handled by nginx auth_request (session cookie validated
# against the auth server) instead of ttyd's built-in Basic Auth. This allows
# the SPA to embed /_clv/chat in an iframe without triggering a second login prompt.
ttyd \
    --port 7890 \
    --base-path /_clv/chat \
    --interface 127.0.0.1 \
    --writable \
    /usr/local/bin/clv-session &
TTYD_PID=$!

sleep 1
if kill -0 $TTYD_PID 2>/dev/null; then
    echo -e "${GREEN}[SUCCESS]${NC} ttyd started (PID $TTYD_PID)."
else
    echo -e "${RED}[WARNING]${NC} ttyd may not have started correctly."
fi
