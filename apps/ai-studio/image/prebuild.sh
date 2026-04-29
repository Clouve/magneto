#!/bin/bash
# Stage the canonical /skills tree into the build context as
# image/skills-bundled/ so the Dockerfile's COPY can pick it up.
# build.sh runs this before `docker buildx build` and runs
# postbuild.sh afterwards to clean up. The staged directory is
# .gitignored — do not edit it directly; edit /skills instead.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ ! -d "$REPO_ROOT/skills" ]; then
    echo "✗ Error: $REPO_ROOT/skills does not exist — cannot stage skills-bundled/"
    exit 1
fi

rm -rf "$SCRIPT_DIR/skills-bundled"
cp -R "$REPO_ROOT/skills/" "$SCRIPT_DIR/skills-bundled"
echo "✓ Staged $REPO_ROOT/skills → $SCRIPT_DIR/skills-bundled"
