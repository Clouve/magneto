#!/bin/bash
# Builds and pushes images to the clouve-develop environment Harbor registry (dev.cr0.io).
# NOT for local development — use build.sh directly for local builds.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A push needs a new --tag <YYYY.MM.DD>: images reach this environment only as
# dated tags, through a listing's new version, never as :latest (see build.sh).
export PUSH_NEEDS_DATED_TAG=1
export REGISTRY=dev.cr0.io/clouveinc8
"$SCRIPT_DIR"/build.sh "$@"
