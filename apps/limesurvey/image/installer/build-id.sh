#!/bin/bash
# Prints this image's build id: <LimeSurvey version>+<build number>-<12 hex digits>, for example
# 7.10.0+261109-0123456789ab.
#
# The version and the build number are the package's own (application/config/version.php). The hex digits are the
# start of a SHA-256 over everything in /clouve/limesurvey/installer and /clouve/limesurvey/package: each file's
# path and content, and the path of each folder and link (with a link's target), in the C locale's order. So a
# rebuilt image has another id as soon as one file of the installer or of LimeSurvey's code differs, a patched file
# included. site.sh tries a failed upgrade again only on an image whose id differs from the one that failed.
#
# The Dockerfile runs this once everything is in place and writes the result to /clouve/limesurvey/image-build.
# Run in a container, it tells whether the two folders are still what the image was built with. It reads about
# 22,000 files, so it is not for every start: the entrypoint reads image-build.
#
# Usage: build-id.sh
# Exit status: 0 with the id on standard output, 1 with a message on standard error.

set -uo pipefail

root=/clouve/limesurvey

fail() {
    printf 'build-id: %s\n' "$1" >&2
    exit 1
}

cd "$root" || fail "cannot enter $root"

# shellcheck disable=SC2016  # PHP code
version="$(php -r '$c = include $argv[1]; echo $c["versionnumber"], "+", $c["buildnumber"];' \
    package/application/config/version.php 2>/dev/null)" || fail "cannot read the package's version.php"
case "$version" in
    *[!0-9A-Za-z.+]* | +* | *+ | *+*+*) fail "the package's version.php names no version and build number" ;;
    *+*) ;;
    *) fail "the package's version.php names no version and build number" ;;
esac

# One line for each file (its SHA-256 and its path), then one for each folder and link (its type, its path and a
# link's target). pipefail makes a file that can't be read stop the script instead of leaving it out.
files="$(find installer package -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)" ||
    fail "cannot read every file of $root/installer and $root/package"
others="$(find installer package ! -type f -printf '%y %p %l\n' | LC_ALL=C sort)" ||
    fail "cannot list $root/installer and $root/package"
hash="$(printf '%s\n%s\n' "$files" "$others" | sha256sum | cut -c1-12)"
case "$hash" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) fail "the checksum could not be made" ;;
esac
printf '%s-%s\n' "$version" "$hash"
