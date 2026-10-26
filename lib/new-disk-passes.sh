#!/bin/bash
# lib/new-disk-passes.sh: the record that an app passed tests/new-disk-start.test.sh, and the check build.sh's UAT and
# prod pushes make against it.
#
# A pass counts for the exact source it was run on: the hash of every file under the app's folder that git tracks or
# would track (tracked files, and untracked ones that aren't ignored, so uncommitted changes count), by path and
# content. Any change to the app makes the record stale, and build-uat.sh and build-prod.sh then refuse to push it.
#
# Source this file. It only defines functions and changes no shell option. It runs on bash 3.2 (the version macOS ships)
# and needs git and python3 (its standard library only).
#
#   nd_pass_dir                       the folder of the records
#   nd_source_hash APP_DIR            the hash of the app's source (status 1 outside a git work tree)
#   nd_record_pass APP HASH SETTLE [IMAGE..]  records a pass for APP at that source, its settle and its images
#   nd_has_pass APP APP_DIR           status 0 when APP has a full pass (a settle of 90 s or more) for its current source
#
# The records live in ${MAGNETO_NEW_DISK_PASS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/magneto/new-disk-passes}, one file
# per app, never in the repository. Errors start with ✗ and go to stderr.

# nd_pass_dir: the folder that holds one record per app.
nd_pass_dir() {
    printf '%s\n' "${MAGNETO_NEW_DISK_PASS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/magneto/new-disk-passes}"
}

# nd_source_hash APP_DIR: a sha256 over the app's files in byte order of their paths: for each, its path relative to
# APP_DIR, a NUL byte and the sha256 of its content, one per line. A tracked file deleted from the work tree counts as
# missing, which changes the hash too. When git can't list the files the status is 1: a hash of no files would match
# any other run that failed the same way.
nd_source_hash() {
    local dir="$1"
    if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '✗ %s is not in a git work tree, so its source has no hash\n' "$dir" >&2
        return 1
    fi
    (cd "$dir" && python3 -c '
import hashlib, subprocess, sys
try:
    listed = subprocess.run(["git", "ls-files", "-co", "--exclude-standard", "-z", "--", "."],
                            check=True, capture_output=True).stdout
except (OSError, subprocess.CalledProcessError) as err:
    sys.stderr.write("\u2717 git could not list the files of %s: %s\n" % (sys.argv[1], err))
    sys.exit(1)
total = hashlib.sha256()
for path in sorted(set(p for p in listed.split(b"\0") if p)):
    try:
        with open(path, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest().encode()
    except OSError:
        digest = b"missing"
    total.update(path + b"\0" + digest + b"\n")
print(total.hexdigest())
' "$dir")
}

# nd_record_pass APP HASH SETTLE [IMAGE_REF...]: writes the record of APP: its source hash, the time (UTC), the settle
# period of the run in seconds and, for each image reference, the image id it had. The file is replaced in one step, so
# a reader never sees half of it.
nd_record_pass() {
    local app="$1" hash="$2" settle="$3" dir ref id
    shift 3
    dir="$(nd_pass_dir)"
    if ! mkdir -p "$dir"; then
        printf '✗ could not make %s for the new-disk pass records\n' "$dir" >&2
        return 1
    fi
    {
        printf 'source=%s\n' "$hash"
        printf 'time=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'settle=%s\n' "$settle"
        for ref in "$@"; do
            id="$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null)" || id="unknown"
            printf 'image=%s %s\n' "$ref" "$id"
        done
    } > "$dir/$app.tmp" && mv -f "$dir/$app.tmp" "$dir/$app"
}

# nd_has_pass APP APP_DIR: status 0 when APP's record holds the hash of APP_DIR's current source and comes from a full
# run (a settle period of 90 s or more, the default), 1 otherwise: no record, an older source, a source with no hash, or
# a shortened run.
nd_has_pass() {
    local file want got settle
    file="$(nd_pass_dir)/$1"
    [ -f "$file" ] || return 1
    want="$(sed -n 's/^source=//p' "$file" | head -n 1)"
    settle="$(sed -n 's/^settle=//p' "$file" | head -n 1)"
    case "$settle" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$settle" -ge 90 ] || return 1
    got="$(nd_source_hash "$2")" || return 1
    [ -n "$want" ] && [ "$want" = "$got" ]
}
