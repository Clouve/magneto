#!/bin/bash

# ============================================================================
# Base image tags in the Dockerfiles
# ============================================================================
# build.sh builds with --pull, so each build takes the newest image of the tag
# a Dockerfile names. A FROM or COPY --from with no tag means :latest, and the
# next build can then take a new major version of it with no one choosing to.
# This test reads every Dockerfile under apps/ and bundles/ and fails on a FROM
# or COPY --from=<image> that names no tag, or names :latest, which with --pull
# is whatever :latest is that day (a digest counts as a tag). A
# --from that names a stage of the same Dockerfile, or a stage number, is not
# an image.
#
# Usage: bash tests/dockerfile-base-tags.test.sh [REPO_DIR]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${1:-$SCRIPT_DIR/..}"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

if ! command -v python3 >/dev/null 2>&1; then
  echo "This test needs python3." >&2
  exit 2
fi

# untagged_in DIR: the images with no tag (or :latest) in DIR's apps/ and bundles/ Dockerfiles, one
# "<path>: <image>" line each.
untagged_in() {
  (cd "$1" && python3 -I - <<'PY'
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
            if ":" not in last or last.rsplit(":", 1)[1] == "latest":
                print("%s: %s" % (path, ref))
PY
  )
}

# The scan itself, on a Dockerfile written to hold each case: no tag, :latest in a FROM and in a COPY --from, a
# pinned base, a stage and a digest.
PROBE="$(mktemp -d)"
trap 'rm -rf "$PROBE"' EXIT
mkdir -p "$PROBE/apps/probe/image"
printf 'FROM alpine AS one\nFROM mariadb:latest\nCOPY --from=composer:latest /c /c\nFROM php:8.3-apache\nCOPY --from=one /o /o\nFROM debian@sha256:%064d\n' 0 \
  > "$PROBE/apps/probe/image/Dockerfile"
want="apps/probe/image/Dockerfile: alpine
apps/probe/image/Dockerfile: mariadb:latest
apps/probe/image/Dockerfile: composer:latest"
if [ "$(untagged_in "$PROBE")" != "$want" ]; then
  printf '%sThe scan misses a case on its own probe:%s\n' "$RED" "$RESET"
  untagged_in "$PROBE" | sed 's/^/    /'
  exit 1
fi

untagged="$(untagged_in "$REPO_DIR")"

FAILED=0
echo "Base image tags in the Dockerfiles"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '  %sFAIL%s %s names no tag, so --pull takes whatever :latest is\n' "$RED" "$RESET" "$line"
  FAILED=1
done <<< "$untagged"

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sEvery base image names a tag.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sA base image names no tag.%s\n' "$RED" "$RESET"
exit 1
