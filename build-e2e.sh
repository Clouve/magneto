#!/bin/bash
# Builds and pushes images to the Google Cloud clouve-develop environment registry.
# NOT for local development — use build.sh directly for local builds.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REGISTRY=r.clv.zone/e2eorg
"$SCRIPT_DIR"/build.sh $@