#!/bin/bash
# Prints this image's build id: 16 hex digits, the start of a SHA-256 over everything a fix to this image can be
# in:
#   - every file of the installer (this folder);
#   - the Dockerfile the image was built from (the build copies it to /clouve/suitecrm/Dockerfile);
#   - SuiteCRM's release zip and the package's keep-list, which the build changes;
#   - PHP's version, its settings files and the extensions it loads;
#   - Apache's configuration (without the worker limit, which the entrypoint writes at every start).
#
# The Dockerfile runs this once everything is in place and writes the result to /clouve/suitecrm/BUILD. An
# upgrade that failed twice records the build it failed on, and only an image with another id tries again by
# itself. Run in a container, it tells whether those files are still what the image was built with. It reads the
# whole zip, so it is not for every start: the entrypoint reads BUILD.
#
# Usage: build-id.sh
# Exit status: 0 with the id on standard output, 1 with a message on standard error.

set -uo pipefail

fail() {
    printf 'build-id: %s\n' "$1" >&2
    exit 1
}

cd /clouve/suitecrm || fail "cannot enter /clouve/suitecrm"

# sums DIR...: one line per file (its SHA-256 and its path) and one per link (its path and its target), in the C
# locale's order. pipefail makes a file that can't be read stop the script instead of leaving it out.
sums() {
    find "$@" -type f ! -name zz-clouve-mpm.conf -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum || return 1
    find "$@" -type l -printf '%p -> %l\n' | LC_ALL=C sort
}

parts="$(
    sums installer || exit 1
    sha256sum Dockerfile SuiteCRM-*.zip app/config/services/system/upgrades.yaml || exit 1
    php -r 'echo PHP_VERSION, "\n";' || exit 1
    php -m || exit 1
    sums /usr/local/etc/php /etc/apache2 || exit 1
)" || fail "cannot read every file the build id covers"
id="$(printf '%s\n' "$parts" | sha256sum | cut -c1-16)"
[[ "$id" =~ ^[0-9a-f]{16}$ ]] || fail "the checksum could not be made"
printf '%s\n' "$id"
