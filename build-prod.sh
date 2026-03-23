#!/bin/bash
# Builds and pushes images to the Google Cloud clouve-prod environment registry.
# NOT for local development — use build.sh directly for local builds.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REGISTRY=cr0.io/clouveinc327
"$SCRIPT_DIR"/build.sh $@