#!/bin/bash
# Stage the repo-root context/ tree into the build context as
# image/context-bundled/ so the Dockerfile's COPY can pick it up.
# build.sh runs this before `docker buildx build` and runs
# postbuild.sh afterwards to clean up. The staged directory is
# .gitignored — do not edit it directly; edit /context instead.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ ! -d "$REPO_ROOT/context" ]; then
    echo "✗ Error: $REPO_ROOT/context does not exist — cannot stage context-bundled/"
    exit 1
fi

rm -rf "$SCRIPT_DIR/context-bundled"
cp -R "$REPO_ROOT/context/" "$SCRIPT_DIR/context-bundled"
echo "✓ Staged $REPO_ROOT/context → $SCRIPT_DIR/context-bundled"
