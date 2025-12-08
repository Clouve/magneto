#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REGISTRY=cr0.io/clouveinc327
"$SCRIPT_DIR"/build.sh $@