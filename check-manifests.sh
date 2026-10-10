#!/bin/bash
# ============================================================================
# Marketplace manifest checks
# ============================================================================
# Static checks on every marketplace manifest (apps/*/ and bundles/*/
# clv-docker-compose*.yml) against the limits the Clouve publish wizard
# enforces, so a manifest that ships here can be uploaded as it is:
#
#   x-clouve-bundle-metadata.appDescription  at most 1000 characters
#     (meso src/Pages/Developer/SubmitApplication/utils/bundleMetadataValidation.js
#      blocks NEXT on the Container Configuration step above that)
#
# Usage: ./check-manifests.sh     exit 0 = all manifests pass, 1 = violations
# ============================================================================

set -euo pipefail
cd "$(dirname "$0")"

python3 - apps/*/clv-docker-compose*.yml bundles/*/clv-docker-compose*.yml <<'PY'
import sys
import yaml

MAX_APP_DESCRIPTION = 1000
failures = 0
for path in sys.argv[1:]:
    with open(path) as f:
        doc = yaml.safe_load(f) or {}
    for name, svc in (doc.get("services") or {}).items():
        meta = (svc or {}).get("x-clouve-bundle-metadata") or {}
        desc = str(meta.get("appDescription") or "").strip()
        if len(desc) > MAX_APP_DESCRIPTION:
            failures += 1
            print(f"FAIL {path} [{name}]: appDescription is {len(desc)} characters "
                  f"(the publish wizard allows {MAX_APP_DESCRIPTION})")
print(f"{len(sys.argv) - 1} manifests checked, {failures} problem(s)")
sys.exit(1 if failures else 0)
PY
