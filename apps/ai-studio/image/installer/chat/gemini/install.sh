#!/bin/bash

# ============================================================================
# Gemini CLI installer — sourced by chat/.bash_profile at session start
# ============================================================================
# Installs Node.js 20 and Gemini CLI on first use. Subsequent calls are a
# no-op because both binaries persist in the /usr volume across restarts.
#
# Node.js 20+ is required by Gemini CLI (npm install -g @google/gemini-cli).

if ! command -v node &>/dev/null; then
    echo "  Installing Node.js 20..."
    NODE_VERSION="20.19.0"
    NODE_ARCH=$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
        | sudo tar xz --strip-components=1 -C /usr/local
    echo "  Node.js $(node --version) installed."
else
    echo "  Node.js already present ($(node --version))."
fi

if ! command -v gemini &>/dev/null; then
    echo "  Installing Gemini CLI..."
    sudo npm install -g @google/gemini-cli
    echo "  Gemini CLI installed."
else
    echo "  Gemini CLI already installed."
fi
