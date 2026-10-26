#!/bin/bash
# Builds and pushes images to the clouve-uat environment Harbor registry (demo.cr0.io).
# NOT for local development — use build.sh directly for local builds.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The new-disk gate: every app pushed here must have passed tests/new-disk-start.test.sh on its current
# source (see build.sh). --skip-new-disk-check overrides it.
export NEW_DISK_GATE=1
export REGISTRY=demo.cr0.io/clouveinc8
"$SCRIPT_DIR"/build.sh $@
