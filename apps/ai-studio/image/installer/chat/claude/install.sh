#!/bin/bash

# ============================================================================
# Claude Code installer — sourced by chat/.bash_profile at session start
# ============================================================================
# Installs Claude Code for the current user on first use. Subsequent calls are
# a no-op because the binary persists in the /usr volume across container restarts.
#
# Claude Code is installed as $USERNAME so the binary lands in
# ~/.local/bin/claude, which is already on PATH via chat/.bash_profile.
# After installation, the Claude Code onboarding wizard is pre-skipped so the
# CLI starts cleanly without prompting for a login method.

if [ ! -x "$HOME/.local/bin/claude" ]; then
    echo "  Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash
    if [ ! -x "$HOME/.local/bin/claude" ]; then
        echo "  ERROR: Claude Code installation failed — binary not found at $HOME/.local/bin/claude."
        return 1
    fi
    echo "  Claude Code installed."
else
    echo "  Claude Code already installed."
fi

# Pre-configure Claude Code to skip the first-run onboarding wizard.
# Only set onboarding state — the API key is read from the environment
# (ANTHROPIC_API_KEY set via /etc/profile.d/ or the key file); storing it
# in ~/.claude.json alongside the env var triggers an auth conflict warning.
echo "{}" | jq '.hasCompletedOnboarding = true | .oauthAccount = null' \
    > "$HOME/.claude.json"
chmod 600 "$HOME/.claude.json"
