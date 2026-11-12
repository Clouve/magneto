#!/bin/bash

# ============================================================================
# Base image tags in the Dockerfiles
# ============================================================================
# build.sh builds with --pull, so each build takes the newest image of the tag
# a Dockerfile names. A FROM or COPY --from with no tag means :latest, and the
# next build can then take a new major version of it with no one choosing to.
# This test reads every Dockerfile under apps/ and bundles/ and fails on a FROM
# or COPY --from=<image> that names no tag (a digest counts as one). A
# --from that names a stage of the same Dockerfile, or a stage number, is not
# an image.
#
# The lines in KNOWN belong to apps that 4.5.5 doesn't rebuild. They are
# printed as KNOWN, not failed, and get a tag at their app's next rebuild.
# Until then build.sh --push refuses those apps (untagged_bases).
#
# Usage: bash tests/dockerfile-base-tags.test.sh [REPO_DIR]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${1:-$SCRIPT_DIR/..}"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'
RESET=$'\033[0m'

# "<Dockerfile path relative to the repo>: <image>", one per line.
KNOWN="apps/owncloud/image/Dockerfile: owncloud/server
apps/owncloud/image/mariadb/Dockerfile: mariadb
apps/suitecrm/image/Dockerfile: composer
apps/suitecrm/image/mariadb/Dockerfile: mariadb"

if ! command -v python3 >/dev/null 2>&1; then
  echo "This test needs python3." >&2
  exit 2
fi

# The images with no tag, one "<path>: <image>" line each, from the Dockerfiles as they are.
untagged="$(cd "$REPO_DIR" && python3 -I - <<'PY'
import glob
import re

for path in sorted(glob.glob("apps/**/Dockerfile*", recursive=True) + glob.glob("bundles/**/Dockerfile*", recursive=True)):
    stages = set()
    lines = []
    with open(path, encoding="utf-8") as f:
        joined = ""
        for raw in f:
            line = raw.rstrip("\n")
            if line.endswith("\\"):
                joined += line[:-1] + " "
                continue
            lines.append(joined + line)
            joined = ""
    for line in lines:
        words = line.split()
        if not words or words[0].startswith("#"):
            continue
        refs = []
        if words[0].upper() == "FROM":
            args = [w for w in words[1:] if not w.startswith("--")]
            if args:
                refs.append(args[0])
            if len(args) >= 3 and args[1].upper() == "AS":
                stages.add(args[2].lower())
        elif words[0].upper() in ("COPY", "ADD"):
            refs += [w.split("=", 1)[1] for w in words[1:] if w.startswith("--from=")]
        for ref in refs:
            if ref.lower() in stages or ref.isdigit() or ref.lower() == "scratch":
                continue
            if "@" in ref:
                continue
            last = ref.rsplit("/", 1)[-1]
            if ":" not in last:
                print("%s: %s" % (path, ref))
PY
)"

FAILED=0
echo "Base image tags in the Dockerfiles"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if grep -qxF -- "$line" <<< "$KNOWN"; then
    printf '  %sKNOWN%s %s names no tag (tag it at its next rebuild)\n' "$YELLOW" "$RESET" "$line"
  else
    printf '  %sFAIL%s %s names no tag, so --pull takes whatever :latest is\n' "$RED" "$RESET" "$line"
    FAILED=1
  fi
done <<< "$untagged"

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sEvery base image names a tag (KNOWN lines aside).%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sA base image names no tag.%s\n' "$RED" "$RESET"
exit 1
