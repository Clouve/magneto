#!/bin/bash
# Two edits to the official entrypoint (/entrypoint.sh of nextcloud:35.0.2-apache), made at build time: the Dockerfile
# runs this as root on that file. Each edit replaces one whole line. The script makes both on a copy, and writes the
# file only when each line was there exactly once, so an upstream change fails the build instead of shipping unpatched.
#
#   1. The init lock is opened read-only. Upstream opens /var/www/html/nextcloud-init-sync.lock as root with `9>`, which
#      creates, truncates and follows a symlink. The file and its folder are www-data's, so www-data could put a symlink
#      there and make root truncate any file. `9<` opens it read-only (flock needs no more), and our entrypoint has made
#      it a plain file of www-data's by then (nc_make_init_lock in lib.sh, step 8).
#   2. The volume's version.php runs as www-data. Upstream runs `php -r 'require "/var/www/html/version.php"; ...'` as
#      root, and version.php is www-data's: any code www-data put in it would run as root at the next start. The edit
#      runs it through upstream's own run_as, as upstream runs occ, with PHP's messages on stderr, and stops the start
#      unless what it prints is a version number (digits and dots), since the value goes on into version comparisons.
#
# Usage: patch-official-entrypoint.sh FILE
# Exit status: 0 when both edits are made; 1 when a line is missing or there more than once (the file is unchanged);
# 64 without FILE.

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo 'Usage: patch-official-entrypoint.sh FILE' >&2
    exit 64
fi
file=$1
copy=$(mktemp)
trap 'rm -f -- "$copy" "$copy.new"' EXIT
cat -- "$file" >"$copy"

# replace OLD NEW: OLD must be one whole line of the copy, exactly once; NEW (one line or more) takes its place. awk
# reads both from the environment, which keeps every character as it is.
replace() {
    local count
    count=$(grep -cFx -- "$1" "$copy") || :
    if [ "$count" != 1 ]; then
        printf 'patch-official-entrypoint: %s has this line %s times, not once, so nothing was changed:\n%s\n' \
            "$file" "${count:-0}" "$1" >&2
        exit 1
    fi
    OLD=$1 NEW=$2 awk '$0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next } { print }' "$copy" >"$copy.new"
    mv -f -- "$copy.new" "$copy"
}

# 1. The init lock, read-only.
replace '    ) 9> /var/www/html/nextcloud-init-sync.lock' \
    '    ) 9< /var/www/html/nextcloud-init-sync.lock'

# 2. version.php, as www-data. The lines are upstream's sh, kept as they are here.
IFS= read -r -d '' old_version <<'EOF' || :
            installed_version="$(php -r 'require "/var/www/html/version.php"; echo implode(".", $OC_Version);')"
EOF
IFS= read -r -d '' new_version <<'EOF' || :
            installed_version="$(run_as 'php -d display_errors=stderr -r '\''require "/var/www/html/version.php"; echo implode(".", $OC_Version);'\''')" || installed_version=''
            case "$installed_version" in
                '' | *[!0-9.]* | .* | *. | *..*)
                    echo "Can't start Nextcloud: /var/www/html/version.php, run as $user, does not give a version number."
                    exit 1
                    ;;
            esac
EOF
replace "${old_version%$'\n'}" "${new_version%$'\n'}"

# The file keeps its owner and mode: its content is written over, it is not replaced.
cat -- "$copy" >"$file"
