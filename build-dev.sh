#!/bin/bash
# Builds and pushes images to the Google Cloud clouve-develop environment registry.
# NOT for local development — use build.sh directly for local builds.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REGISTRY=dev.cr0.io/clouveinc8
"$SCRIPT_DIR"/build.sh $@