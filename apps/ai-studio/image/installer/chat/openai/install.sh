#!/bin/bash

# ============================================================================
# OpenAI Codex CLI installer — sourced by chat/.bash_profile at session start
# ============================================================================
# Installs Node.js 22 and OpenAI Codex CLI on first use. Subsequent calls are
# a no-op because both binaries persist in the /usr volume across restarts.
#
# Node.js 22+ is required by the OpenAI Codex CLI.

_node_major() { node --version 2>/dev/null | cut -c2- | cut -d. -f1; }

if ! command -v node &>/dev/null || [ "$(_node_major)" -lt 22 ]; then
    echo "  Installing Node.js 22..."
    NODE_VERSION="22.14.0"
    NODE_ARCH=$(uname -m | sed 's/x86_64/x64/;s/aarch64/arm64/')
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
        | sudo tar xz --strip-components=1 -C /usr/local
    echo "  Node.js $(node --version) installed."
else
    echo "  Node.js already present ($(node --version))."
fi

if ! command -v codex &>/dev/null; then
    echo "  Installing OpenAI Codex CLI..."
    sudo npm install -g @openai/codex
    echo "  OpenAI Codex CLI installed."
else
    echo "  OpenAI Codex CLI already installed."
fi
