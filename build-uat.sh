#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REGISTRY=demo.cr0.io/clouveinc8
"$SCRIPT_DIR"/build.sh $@
