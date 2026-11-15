#!/bin/bash
# patch-keep-list.sh FILE ENTRY...
#
# Makes sure each ENTRY is on the keep-list (parameters.upgrades.toKeep) of SuiteCRM's
# config/services/system/upgrades.yaml. SuiteCRM's upgrade deletes every file and folder at the top of the
# install, of public/ and of public/legacy/ that the new package doesn't ship and that this list doesn't name.
#
# The Dockerfile runs it on the package, to add the image's own entries. upgrade.sh runs it as www-data on the
# installed copy before SuiteCRM's upgrade command, because the list that applies to an upgrade is the installed
# version's: 8.9.1's doesn't name uploads/ and public/media-upload/, where 8.9 keeps email attachments and file
# fields, and would delete them.
#
# Entries that are on the list already are left alone, and the file is rewritten in place only when something
# is missing, so its owner and mode stay. Exit status: 0 when every ENTRY is on the list afterwards, 1 when the
# file has no such list or could not be changed.

set -u

file="${1:-}"
if [ -z "$file" ] || [ $# -lt 2 ]; then
    echo "Usage: patch-keep-list.sh FILE ENTRY..." >&2
    exit 1
fi
shift
if [ ! -f "$file" ] || [ -L "$file" ]; then
    echo "[suitecrm] ERROR: $file is not a plain file, so the keep-list can't be checked" >&2
    exit 1
fi

# listed: the entries of the toKeep list, one per line, without their quotes.
listed() {
    awk '
        /^[[:space:]]+toKeep:[[:space:]]*$/ { inside = 1; next }
        inside && /^[[:space:]]+-[[:space:]]/ {
            line = $0
            sub(/^[[:space:]]+-[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            gsub(/^["\047]|["\047]$/, "", line)
            print line
            next
        }
        inside { exit }
    ' "$file"
}

have="$(listed)"
if [ -z "$have" ]; then
    echo "[suitecrm] ERROR: $file has no toKeep list, so the keep-list can't be changed" >&2
    exit 1
fi
missing=""
for entry in "$@"; do
    case "$entry" in
        '' | *[!A-Za-z0-9._/+-]*)
            echo "[suitecrm] ERROR: '$entry' is not a path the keep-list can hold" >&2
            exit 1
            ;;
    esac
    grep -qxF -- "$entry" <<< "$have" || missing="$missing$entry"$'\n'
done
[ -n "$missing" ] || exit 0

# The new entries go after the list's last entry, with its indentation.
new="$(MISSING="$missing" awk '
    function emit(   n, i, parts) {
        n = split(ENVIRON["MISSING"], parts, "\n")
        for (i = 1; i <= n; i++) {
            if (parts[i] != "") { print indent "- \047" parts[i] "\047" }
        }
        done = 1
    }
    /^[[:space:]]+toKeep:[[:space:]]*$/ && !done { inside = 1; print; next }
    inside && /^[[:space:]]+-[[:space:]]/ {
        indent = $0
        sub(/-[[:space:]].*$/, "", indent)
        print
        next
    }
    inside { emit(); inside = 0 }
    { print }
    END { if (inside) { emit() } }
' "$file")" || exit 1
[ -n "$new" ] || exit 1
# Written in place, so the file keeps its owner and mode.
if ! printf '%s\n' "$new" > "$file"; then
    echo "[suitecrm] ERROR: could not write $file" >&2
    exit 1
fi

have="$(listed)"
for entry in "$@"; do
    if ! grep -qxF -- "$entry" <<< "$have"; then
        echo "[suitecrm] ERROR: '$entry' is still not on the keep-list of $file" >&2
        exit 1
    fi
done
exit 0
