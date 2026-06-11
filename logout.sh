#!/bin/bash

# Docker Registry Logout Script
# Removes the credential currently stored for a registry so that a subsequent
# `docker login` actually takes effect.
#
# Why this exists: Docker keeps exactly ONE credential per registry, and some
# credential helpers (notably Docker Desktop's "desktop" helper) silently
# refuse to overwrite an existing entry — `docker login` as a new user prints
# "Login Succeeded" but the OLD user keeps being served for pushes, which then
# fail with "unauthorized" because Harbor robot accounts are project-scoped.
# Run this script before logging in as a different user on the same registry.
#
# Usage:
#   ./logout.sh              # Remove stored credential for r.clv.zone
#   ./logout.sh <registry>   # Remove stored credential for another registry
#
# Typical flow when switching robot accounts:
#   ./logout.sh
#   docker login r.clv.zone -u 'robot$<project>+<name>' -p '<secret>'
#   ./build.sh apps/ai-studio --push

set -e

REGISTRY="${1:-r.clv.zone}"
CONFIG_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"

if ! command -v docker &> /dev/null; then
    echo "✗ Error: docker is not installed or not in PATH"
    exit 1
fi

# ============================================================================
# Resolve the credential helper for this registry
# ============================================================================
# Per-registry credHelpers take precedence over the global credsStore.
CREDS_HELPER=""
if [ -f "$CONFIG_FILE" ]; then
    CREDS_HELPER=$(python3 -c '
import sys, json
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(cfg.get("credHelpers", {}).get(sys.argv[2]) or cfg.get("credsStore") or "")
' "$CONFIG_FILE" "$REGISTRY" 2>/dev/null || true)
fi

# ============================================================================
# Look up the currently stored username for the registry
# ============================================================================
stored_username() {
    if [ -n "$CREDS_HELPER" ] && command -v "docker-credential-$CREDS_HELPER" &> /dev/null; then
        echo "$REGISTRY" | "docker-credential-$CREDS_HELPER" get 2>/dev/null \
            | python3 -c 'import sys, json; print(json.load(sys.stdin).get("Username", ""))' 2>/dev/null \
            || true
    elif [ -f "$CONFIG_FILE" ]; then
        # No helper: credentials live base64-encoded in config.json itself.
        python3 -c '
import sys, json, base64
try:
    auths = json.load(open(sys.argv[1])).get("auths", {})
except Exception:
    sys.exit(0)
for key in (sys.argv[2], "https://" + sys.argv[2], "http://" + sys.argv[2]):
    auth = auths.get(key, {}).get("auth")
    if auth:
        print(base64.b64decode(auth).decode().split(":", 1)[0])
        break
' "$CONFIG_FILE" "$REGISTRY" 2>/dev/null || true
    fi
}

CURRENT_USER=$(stored_username)

if [ -z "$CURRENT_USER" ]; then
    docker logout "$REGISTRY" > /dev/null 2>&1 || true
    echo "⊘ No credential stored for $REGISTRY — nothing to remove"
    exit 0
fi

echo "Currently stored credential for $REGISTRY: $CURRENT_USER"

# ============================================================================
# Remove the credential and verify it is actually gone
# ============================================================================
docker logout "$REGISTRY"

REMAINING_USER=$(stored_username)

# Some helpers fail to erase just like they fail to overwrite — fall back to
# erasing directly through the helper binary.
if [ -n "$REMAINING_USER" ] && [ -n "$CREDS_HELPER" ]; then
    echo "⚠ docker logout left the credential in place; erasing via docker-credential-$CREDS_HELPER..."
    echo "$REGISTRY" | "docker-credential-$CREDS_HELPER" erase 2>/dev/null || true
    REMAINING_USER=$(stored_username)
fi

if [ -n "$REMAINING_USER" ]; then
    echo "✗ Error: credential for $REGISTRY is still stored as '$REMAINING_USER'"
    echo "  Try restarting Docker Desktop and re-running this script."
    exit 1
fi

echo "✓ Removed credential for '$CURRENT_USER' from $REGISTRY"
echo ""
echo "You can now log in as a different user:"
echo "  docker login $REGISTRY -u '<username>' -p '<secret>'"
