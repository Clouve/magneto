#!/bin/bash
# Remove the staging directory created by prebuild.sh so it doesn't
# linger in the working tree. Safe to run even if the dir is missing.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -rf "$SCRIPT_DIR/context-bundled"
