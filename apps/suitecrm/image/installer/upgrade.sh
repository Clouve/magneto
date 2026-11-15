#!/bin/bash
# upgrade.sh [--finish-as-is]
#
# SuiteCRM's in-place upgrade. entrypoint.sh calls it when the volume holds an older SuiteCRM than the image, or
# when an earlier start left an upgrade unfinished. The stand-in answers the health check meanwhile, and
# nothing of SuiteCRM's runs: Apache and the background jobs start only after this script.
#
# SuiteCRM's own procedure is two console commands, run as www-data with the new version's package:
# suitecrm:app:upgrade copies the new code over the old, and suitecrm:app:upgrade-finalize repairs the database,
# runs the migrations and records the new version. This script wraps them so that customer data is never lost
# and the container can stop at any moment:
#
#   - It checks that the volume has room and that every file in the install is www-data's (SuiteCRM's commands
#     run as www-data and can't replace a file of root's). When not, it doesn't try: the version on the volume
#     keeps running, and tmp/clouve-backup/upgrade-skipped says why.
#   - It makes a backup in tmp/clouve-backup/<from>-to-<to>/: the code and settings as a tar.gz, and a dump of
#     the database. The customer's files (public/legacy/upload, uploads/ or media/, public/media-upload/ or
#     public/media/) stay on the volume and are not in it, and neither are tmp/, cache/ and logs/. The backup
#     is written under another name, checked, renamed and only then counted: the file "complete" in it holds
#     the checksums, and a fingerprint of the database (its tables, columns and each table's checksum).
#   - The customer's upload folders don't depend on SuiteCRM's keep-list. 8.9.1's upgrade deletes uploads/ and
#     public/media-upload/ unless its compiled keep-list names them. So before SuiteCRM's first command the
#     script renames those folders into root's state folder (tmp/clouve-backup/aside/), where SuiteCRM can't
#     reach them, and renames them back before the second command, whose migrations need them. A rename on one
#     disk is one step, and the state file says how far it got, so a stop at any point puts them back. The
#     image's two marker files get a copy there and stay in the install themselves: the earlier image installs
#     anew, and drops the database, when it starts on a volume without .suitecrm_initialized.
#   - As a second layer it still adds what the installed version's keep-list forgets (patch-keep-list.sh),
#     removes SuiteCRM's compiled cache, and runs the first command only when the list SuiteCRM has compiled
#     names every entry (keep-list.php).
#   - It runs the two commands with -n, and counts the upgrade as done only when both ended well, VERSION and
#     the database's version row say the new version, and SuiteCRM's own version command prints it. VERSION
#     alone proves nothing: it changes early in the copy.
#   - When a try fails, it goes back: it removes the upgraded code, as root, so that nothing in it can be in
#     the way, unpacks the old code as www-data and names the media folders back. The database is left alone
#     only when it is proven unchanged: SuiteCRM's second command never started, and the database's
#     fingerprint is the one the backup recorded. From 8.10 on the first command can change the database too
#     (pre-upgrade migrations). In every other case all tables are dropped (the upgrade adds some that the dump
#     doesn't know) and the dump is loaded. Then it tries once more. After two failed tries the old version
#     runs, and this build of the image doesn't try again until someone removes tmp/clouve-backup/upgrade-failed.
#   - When going back fails, it changes nothing more and exits with a failing status, so Apache never starts on
#     old code with a half-changed database, and the next start goes back again.
#   - A site between two versions that it can't put back (the backup is damaged or gone, or the customer's
#     files are missing) is never started and never backed up as if it were a version. The script says what it
#     found and exits with status 3, and entrypoint.sh keeps the container up for a person to repair it.
#
# The state file tmp/clouve-backup/state names the phase, and a start that finds one does the one thing that is
# safe there:
#   backup    the container stopped while the backup was written, so nothing in the site changed: the
#             unfinished backup goes and the site's own facts decide (entrypoint.sh)
#   upgrade   it stopped after the backup: when the upgrade had in fact finished, only the clean-up is left;
#             otherwise the old version is put back and the upgrade runs again. The key "step" says how far the
#             try got: prepare, aside (the customer's folders are being moved out), files (SuiteCRM's first
#             command), back (the folders are in place again), finalize (SuiteCRM's second command)
#   restore   it stopped while going back: going back runs again
#   failed    entrypoint.sh starts the old version (it doesn't call this script)
#   as-is     staff's own run with --finish-as-is was cut off: the script says so and waits
#
# A state file that is gone doesn't make a half-upgraded site a version of its own. When VERSION already says
# the image's version, the database has no finished-upgrade record and a complete backup <version>-to-<image
# version> is in the state folder, the script goes back from that backup and upgrades again.
#
# --finish-as-is is for staff, on a site between two versions with no backup to go back to, which the
# entrypoint leaves waiting. It runs SuiteCRM's two commands on the site as it is. There is no way back from
# it but a backup of the deployment, so it runs only when asked for by hand.
#
# A stop request (SIGTERM, SIGINT or SIGWINCH) ends the script within seconds. entrypoint.sh sends it to this
# script and to everything it started. The state file is kept, the next start goes on from it, and a try that
# was stopped is not counted as a failed one.
#
# Every step logs a line that starts with [clouve-upgrade], and what needs someone's attention logs
# "[clouve-upgrade] FAILED suitecrm <from> -> <to>: <reason>".
#
# Exit status: 0 when SuiteCRM is ready to start, upgraded or on the version it had. 1 when it must not start
# and a restart may help. 3 when it must not start and a person has to repair the site. 143 when it was
# stopped on request.

set -u

# shellcheck source=lib.sh
. /clouve/suitecrm/installer/lib.sh

app=suitecrm
to=$(sc_image_version)
build=$(sc_image_build)
package=SuiteCRM-$to
zip=/clouve/suitecrm/$package.zip
console_log=$SC_STATE_DIR/upgrade-console.log
max_attempts=2
reason=''
from='?'
attempts=0
counting=0
# The customer's upload folders under both names (8.9 and 8.10), and the image's two marker files.
aside_folders="uploads public/media-upload media public/media"
aside_markers=".suitecrm_initialized .suitecrm_url"
cd "$SC_ROOT" || exit 1

# console_log_ready: the console log is root's alone, like everything else in the state folder.
console_log_ready() {
    ( umask 077; : >> "$console_log" ) 2> /dev/null && chmod 600 "$console_log"
}

up_log() { local IFS=' '; printf '[clouve-upgrade] %s\n' "$*"; }
up_phase() { up_log "$app $from -> $to: phase $1${2:+ ($2)}"; }
up_failed() { local IFS=' '; last_failed=$*; printf '[clouve-upgrade] FAILED %s %s -> %s: %s\n' "$app" "$from" "$to" "$*" >&2; }
# needs_staff: SuiteCRM must not start, and a person has to repair the site. The entrypoint then keeps the
# container up (status 3). The note for the AI Assistant, which can't read the container's log, gets the words
# of the FAILED line that was just printed (lib.sh, sc_attention_write).
last_failed=''
needs_staff() {
    sc_attention_write repair "$from" "$to" "$last_failed" || :
    exit 3
}

# stamp_get KEY: a value from the backup's "complete" file.
stamp_get() {
    local line
    while IFS= read -r line; do
        if [ "${line%%=*}" = "$1" ]; then printf '%s\n' "${line#*=}"; return 0; fi
    done < "$backup/complete"
}

# --- a stop request ---------------------------------------------------------------------------------------------------

# stop_now: the trap. The command that was running has ended by now, because the stop request went to the whole
# process group. The state file stays as it is, apart from the count: a try that was stopped is not a failed
# one.
stop_now() {
    trap '' TERM INT WINCH
    if [ "$counting" = 1 ] && [ "$attempts" -gt 0 ]; then
        sc_state_set "attempts=$((attempts - 1))" || :
    fi
    up_log "$app $from -> $to: stopped: the container was asked to stop, so the upgrade ends here. The next start goes on from the state file, and a try that was under way is not counted."
    exit 143
}
trap stop_now TERM INT WINCH

# One run at a time: the entrypoint's, or staff's own with --finish-as-is.
install -d -m 700 "$SC_RUN" 2> /dev/null
exec 9> "$SC_RUN/upgrade.lock"
if ! flock -n 9; then
    echo "[clouve-upgrade] another run of upgrade.sh is under way in this container, so this one does nothing" >&2
    exit 1
fi
[ -s "$SC_DB_CNF" ] || sc_db_cnf || { echo "[clouve-upgrade] could not write the database options file" >&2; exit 1; }

# --- the room on the volume ---------------------------------------------------------------------------------------

# kb_of PATH...: the size of the paths that exist, in KB.
kb_of() {
    local path total=0 kb
    for path in "$@"; do
        [ -e "$path" ] || continue
        kb=$(du -skx -- "$path" 2>/dev/null | cut -f1)
        total=$((total + ${kb:-0}))
    done
    echo "$total"
}

# up_space_ok: measures what the upgrade writes to the volume and compares it with the free space. SuiteCRM's
# command unpacks the package next to its zip and copies the modules folder aside; the backup adds the code
# archive and the dump (counted at half their unpacked size, and they compress to a fifth); the new code is a
# little bigger than the old; and 100 MB stay free. Sets $reason when there is too little.
up_space_ok() {
    local tree kept code data need free
    tree=$(kb_of "$SC_ROOT")
    kept=$(kb_of tmp cache logs lost+found public/legacy/upload uploads media public/media-upload public/media)
    code=$((tree - kept))
    [ "$code" -ge 0 ] || code=0
    data=$(sc_sql "SELECT COALESCE(ROUND(SUM(data_length) / 1024), 0) FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME'") || data=0
    case $data in '' | *[!0-9]*) data=0 ;; esac
    need=$(($(kb_of "$SC_PACKAGE") + $(kb_of "$zip") + $(kb_of public/legacy/modules) + code / 2 + data / 2 + 102400))
    free=$(df -Pk "$SC_ROOT" | awk 'NR == 2 { print $4 }')
    case $free in '' | *[!0-9]*) reason="could not read the free space of $SC_ROOT"; return 1 ;; esac
    if [ "$free" -lt "$need" ]; then
        reason="not enough free space on the volume: $((free / 1024)) MB free, about $((need / 1024)) MB needed"
        return 1
    fi
    up_log "$app $from -> $to: $((free / 1024)) MB free on the volume, about $((need / 1024)) MB needed"
}

# up_not_www: up to five paths in the install that are not www-data's, on one line. SuiteCRM's upgrade runs as
# www-data and can neither replace nor remove them. Root's own places are left out: lost+found, and in tmp/
# everything named clouve-* (the state folder, what was moved aside from it, and the AI Assistant's backups).
up_not_www() {
    find . \( -path ./lost+found -o -path './tmp/clouve-*' \) -prune -o ! -user www-data -print 2> /dev/null | head -n 5 |
        sed 's|^\./||' | xargs -r
}

# up_skip REASON: this start doesn't try the upgrade, and nothing has changed. The reason, the versions and the
# time go to tmp/clouve-backup/upgrade-skipped, for staff and for the AI Assistant, and the version on the
# volume keeps running. The note blocks nothing: the next start looks again, and removes it when it upgrades.
up_skip() {
    if sc_state_dir_make; then
        (
            umask 077
            printf 'from=%s\nto=%s\nbuild=%s\ntime=%s\nreason=%s\n' "$from" "$to" "$build" \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$SC_SKIPPED"
        ) || :
    fi
    up_failed "$1. Nothing was changed and $from keeps running. The next start tries again (${SC_SKIPPED#"$SC_ROOT"/} has this note until then)."
    exit 0
}

# --- the backup -----------------------------------------------------------------------------------------------------

# up_db_fingerprint: one checksum of the whole database: every table's columns and indexes, and every table's
# own checksum over its rows (CHECKSUM TABLE). Two moments of the same database give the same fingerprint only
# when no table, column, index or row differs. Prints it; status 1 when the database didn't answer.
up_db_fingerprint() {
    local tables parts
    tables=$(sc_sql "SELECT table_name FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME' AND table_type = 'BASE TABLE' ORDER BY table_name") || return 1
    [ -n "$tables" ] || return 1
    parts=$(
        sc_sql "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME' ORDER BY table_name" || exit 1
        sc_sql "SELECT table_name, ordinal_position, column_name, column_type, is_nullable, IFNULL(column_default, '<null>'), extra FROM information_schema.columns WHERE table_schema = '$DATABASE_NAME' ORDER BY table_name, ordinal_position" || exit 1
        sc_sql "SELECT table_name, index_name, seq_in_index, column_name, non_unique FROM information_schema.statistics WHERE table_schema = '$DATABASE_NAME' ORDER BY table_name, index_name, seq_in_index" || exit 1
        {
            printf 'CHECKSUM TABLE '
            sed 's/`/``/g; s/.*/`&`/' <<< "$tables" | paste -sd, -
        } | mysql --defaults-extra-file="$SC_DB_CNF" --connect-timeout=10 -N -B "$DATABASE_NAME" || exit 1
    ) || return 1
    printf '%s\n' "$parts" | sha256sum | cut -d' ' -f1
}

# up_backup: writes the backup under <name>.partial, checks it, stamps it and gives it its name. An older kept
# backup goes only once the new one is complete. Sets $reason and returns 1 when the backup is not good; the
# site is untouched either way.
up_backup() {
    local partial=$backup.partial status listing must creates tables last other fingerprint
    rm -rf -- "$SC_STATE_DIR"/*.partial
    if ! mkdir -- "$partial" || ! chmod 00700 -- "$partial"; then reason="could not make the backup folder"; return 1; fi

    # The code and the settings. Root reads, and links are stored as links, never followed.
    (
        umask 077
        tar -C "$SC_ROOT" --anchored --exclude=./tmp --exclude=./cache --exclude=./logs --exclude=./lost+found \
            --exclude=./public/legacy/upload --exclude=./uploads --exclude=./media \
            --exclude=./public/media-upload --exclude=./public/media -czf "$partial/code.tar.gz" .
    )
    status=$?
    if [ "$status" -ne 0 ]; then reason="the code archive could not be written (tar exit status $status)"; return 1; fi
    if ! gzip -t "$partial/code.tar.gz" 2>/dev/null || ! listing=$(tar -tzf "$partial/code.tar.gz" 2>/dev/null); then
        reason="the code archive does not read back"
        return 1
    fi
    for must in ./VERSION ./bin/console ./vendor/autoload.php ./public/index.php ./public/legacy/config.php \
        ./config/services/system/upgrades.yaml; do
        if ! grep -qxF -- "$must" <<< "$listing"; then
            reason="the code archive has no $must"
            return 1
        fi
    done
    sc_pause backup

    # The database, as the app's own user. The password is in the options file, never on the command line.
    ( umask 077; mysqldump --defaults-extra-file="$SC_DB_CNF" --single-transaction --routines --triggers \
        "$DATABASE_NAME" | gzip > "$partial/db.sql.gz"; exit "$((PIPESTATUS[0] + PIPESTATUS[1]))" )
    status=$?
    if [ "$status" -ne 0 ]; then reason="the database dump failed"; return 1; fi
    if ! gzip -t "$partial/db.sql.gz" 2>/dev/null; then reason="the database dump does not read back"; return 1; fi
    last=$(gzip -dc "$partial/db.sql.gz" | tail -n 1)
    case $last in
        '-- Dump completed'*) ;;
        *) reason="the database dump has no end line, so it is cut short"; return 1 ;;
    esac
    creates=$(gzip -dc "$partial/db.sql.gz" | grep -c '^CREATE TABLE ')
    tables=$(sc_base_table_count) || tables=''
    if [ -z "$tables" ] || [ "$tables" -lt 1 ] || [ "$creates" != "$tables" ]; then
        reason="the database dump holds $creates tables and the database has ${tables:-an unknown number}"
        return 1
    fi
    # What the database looks like now. A way back compares it with this before it leaves the database alone.
    if ! fingerprint=$(up_db_fingerprint) || [ -z "$fingerprint" ]; then
        reason="the database's tables could not be read for the backup's stamp"
        return 1
    fi

    # The stamp: what the backup is of, and the checksums a way back checks first.
    (
        umask 077
        {
            printf 'app=%s\nfrom=%s\nto=%s\nbuild=%s\nmade=%s\n' "$app" "$from" "$to" "$build" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf 'version_file=%s\ndatabase_version=%s\ntables=%s\n' "$(sc_read_version "$SC_ROOT/VERSION")" \
                "$(sc_db_version)" "$tables"
            printf 'had_uploads=%s\nhad_public_media_upload=%s\nhad_media=%s\nhad_public_media=%s\n' \
                "$([ -d uploads ] && echo yes || echo no)" "$([ -d public/media-upload ] && echo yes || echo no)" \
                "$([ -d media ] && echo yes || echo no)" "$([ -d public/media ] && echo yes || echo no)"
            printf 'code_sha256=%s\ndatabase_sha256=%s\ndatabase_fingerprint=%s\n' \
                "$(sha256sum < "$partial/code.tar.gz" | cut -d' ' -f1)" \
                "$(sha256sum < "$partial/db.sql.gz" | cut -d' ' -f1)" "$fingerprint"
        } > "$partial/complete"
    )
    if ! grep -q '^database_fingerprint=[0-9a-f]\{64\}$' "$partial/complete"; then
        reason="the backup's stamp could not be written"
        return 1
    fi
    chmod 600 "$partial"/* && sync "$partial"/* 2>/dev/null

    rm -rf -- "$backup.old"
    if [ -e "$backup" ] && ! mv "$backup" "$backup.old"; then reason="could not move the earlier backup aside"; return 1; fi
    if ! mv "$partial" "$backup"; then
        if [ -e "$backup.old" ]; then mv "$backup.old" "$backup"; fi
        reason="could not give the backup its name"
        return 1
    fi
    sync "$SC_STATE_DIR" 2> /dev/null || :
    # One backup is kept: with this one complete, the earlier ones go.
    for other in "$SC_STATE_DIR"/*-to-*; do
        if [ "$other" != "$backup" ] && [ -d "$other" ] && [ ! -L "$other" ]; then
            up_log "$app $from -> $to: removing the earlier backup ${other##*/}"
            rm -rf -- "$other"
        fi
    done
    up_log "$app $from -> $to: backup complete in ${backup#"$SC_ROOT"/} (code $(du -sh "$backup/code.tar.gz" | cut -f1), database $(du -sh "$backup/db.sql.gz" | cut -f1), $tables tables)"
}

# up_backup_good: succeeds when the backup is a stamped one of root's and both files still have the checksums
# the stamp recorded. Sets $reason when not.
up_backup_good() {
    local file
    reason="there is no complete backup in ${backup#"$SC_ROOT"/}"
    sc_state_dir_trusted || return 1
    [ -d "$backup" ] && [ ! -L "$backup" ] && [ "$(stat -c %u -- "$backup")" = 0 ] &&
        [ -z "$(find "$backup" -maxdepth 0 -perm /g=w,o=w 2> /dev/null)" ] || return 1
    for file in complete code.tar.gz db.sql.gz; do
        [ -f "$backup/$file" ] && [ ! -L "$backup/$file" ] && [ "$(stat -c %u -- "$backup/$file")" = 0 ] || return 1
    done
    [ "$(stamp_get to)" = "$to" ] && [ "$(stamp_get from)" = "$from" ] || return 1
    reason="the backup's code archive is damaged (its checksum changed)"
    [ "$(sha256sum < "$backup/code.tar.gz" | cut -d' ' -f1)" = "$(stamp_get code_sha256)" ] &&
        gzip -t "$backup/code.tar.gz" 2>/dev/null || return 1
    reason="the backup's database dump is damaged (its checksum changed)"
    [ "$(sha256sum < "$backup/db.sql.gz" | cut -d' ' -f1)" = "$(stamp_get database_sha256)" ] &&
        gzip -t "$backup/db.sql.gz" 2>/dev/null || return 1
    reason=''
}

# --- the customer's folders, out of SuiteCRM's reach and back ------------------------------------------------------

# up_merge_script: a bash function for www-data, merge FROM INTO: moves everything in the folder FROM into the
# folder INTO by renames, folder by folder, and removes FROM when it is empty. A rename is one step, so a stop
# never leaves half a file. When both sides hold a file of the same name, the one in INTO stays; the other one
# goes only when it is the same byte for byte, and is kept next to it as <name>.kept-<n> otherwise.
# shellcheck disable=SC2016  # the text is for the inner bash
up_merge_script='
merge() {
    local e name n
    for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        name=${e##*/}
        if [ ! -e "$2/$name" ] && [ ! -L "$2/$name" ]; then
            mv -T -- "$e" "$2/$name" || return 1
        elif [ -d "$e" ] && [ ! -L "$e" ] && [ -d "$2/$name" ] && [ ! -L "$2/$name" ]; then
            merge "$e" "$2/$name" || return 1
        elif [ -f "$e" ] && [ ! -L "$e" ] && [ -f "$2/$name" ] && cmp -s -- "$e" "$2/$name"; then
            rm -f -- "$e" || return 1
        else
            n=1
            while [ -e "$2/$name.kept-$n" ] || [ -L "$2/$name.kept-$n" ]; do n=$((n + 1)); done
            mv -T -- "$e" "$2/$name.kept-$n" || return 1
        fi
    done
    rmdir -- "$1"
}'

# up_merge FROM INTO: runs merge as www-data.
up_merge() {
    sc_as_www bash -c "$up_merge_script"'; merge "$1" "$2"' _ "$1" "$2"
}

# up_own PATH: gives PATH and everything in it to www-data, when something in it is someone else's. The staff
# step that puts an untrusted state folder back makes everything in it root's, the customer's folders included.
up_own() {
    if [ -n "$(find "$1" ! -user www-data -print -quit 2> /dev/null)" ]; then
        chown -hR www-data:www-data -- "$1"
    fi
}

# up_aside_take: copies the image's two marker files into root's state folder and renames the customer's upload
# folders into it. From here until up_aside_return, SuiteCRM's upgrade command can't reach the folders, whatever
# its keep-list says. The markers stay in the install as well: the earlier image takes a volume without
# .suitecrm_initialized for a new one and installs over it, so that file must never be missing, not even for
# the seconds this takes. Only a plain file is copied, never what a link points at.
up_aside_take() {
    local item name
    if [ ! -d "$SC_ASIDE" ]; then
        mkdir -- "$SC_ASIDE" && chmod 00700 -- "$SC_ASIDE" || return 1
    fi
    [ ! -L "$SC_ASIDE" ] && [ "$(stat -c %u -- "$SC_ASIDE")" = 0 ] || return 1
    if [ -L public ] || { [ -e public ] && [ ! -d public ]; }; then return 1; fi
    for item in $aside_markers; do
        [ -f "$SC_ROOT/$item" ] && [ ! -L "$SC_ROOT/$item" ] || continue
        rm -rf -- "${SC_ASIDE:?}/$item"
        cp -pP -- "$SC_ROOT/$item" "$SC_ASIDE/$item" || return 1
    done
    for item in $aside_folders; do
        name=${item//\//__}
        [ -e "$SC_ROOT/$item" ] || [ -L "$SC_ROOT/$item" ] || continue
        if [ -e "$SC_ASIDE/$name" ] || [ -L "$SC_ASIDE/$name" ]; then return 1; fi
        mv -T -- "$SC_ROOT/$item" "$SC_ASIDE/$name" || return 1
    done
    sync "$SC_ASIDE" 2> /dev/null || :
}

# up_aside_return: renames the folders back, and puts a marker back when SuiteCRM's command removed it. It can
# run at any time and any number of times: what is not aside is left alone. When SuiteCRM's new code has made a
# folder of the same name meanwhile, the customer's files are merged into it. Status 1 when something could not
# be put back; it then stays where it is, in the state folder or next to its place as <name>.clouve-aside.
up_aside_return() {
    local item name src dst stage status=0
    sc_state_dir_trusted || return 0
    for item in $aside_folders; do
        name=${item//\//__}
        src=$SC_ASIDE/$name
        dst=$SC_ROOT/$item
        stage=$dst.clouve-aside
        if [ -e "$src" ] || [ -L "$src" ]; then
            if [ "${item%/*}" != "$item" ] && [ ! -d "${dst%/*}" ]; then
                sc_as_www mkdir -p -- "${dst%/*}" || { status=1; continue; }
            fi
            if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
                mv -T -- "$src" "$dst" || { status=1; continue; }
                up_own "$dst"
            elif [ -d "$src" ] && [ ! -L "$src" ] && [ -d "$dst" ] && [ ! -L "$dst" ] && [ ! -e "$stage" ] && [ ! -L "$stage" ]; then
                mv -T -- "$src" "$stage" || { status=1; continue; }
            else
                status=1
                continue
            fi
        fi
        if [ -d "$stage" ] && [ ! -L "$stage" ]; then
            up_own "$stage"
            if [ -d "$dst" ] && [ ! -L "$dst" ]; then
                up_merge "$stage" "$dst" || status=1
            elif [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
                sc_as_www mv -T -- "$stage" "$dst" || status=1
            else
                status=1
            fi
        fi
    done
    for item in $aside_markers; do
        src=$SC_ASIDE/$item
        dst=$SC_ROOT/$item
        [ -e "$src" ] || [ -L "$src" ] || continue
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            rm -f -- "$src" || status=1
        elif mv -T -- "$src" "$dst"; then
            up_own "$dst"
        else
            status=1
        fi
    done
    if [ -d "$SC_ASIDE" ] && [ ! -L "$SC_ASIDE" ]; then rmdir -- "$SC_ASIDE" 2> /dev/null || :; fi
    return "$status"
}

# --- one try --------------------------------------------------------------------------------------------------------

# up_console COMMAND: runs one of SuiteCRM's upgrade commands as www-data, with -n so that nothing waits for an
# answer. Its whole output goes to the console log in the state folder, and to the container's log without the
# line each migration prints when it had no SQL to run. Fails when the command's status is not 0 or a step
# reports itself as failed.
up_console() {
    local status
    console_log_ready
    printf '\n== %s %s (%s)\n' "$1" "$package" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$console_log"
    sc_as_www php bin/console "$1" -n -t "$package" 2>&1 | tee -a "$console_log" |
        grep -v 'did not result in any SQL statements'
    status=${PIPESTATUS[0]}
    if [ "$status" -ne 0 ]; then
        reason="SuiteCRM's $1 ended with exit status $status"
        return 1
    fi
    if sed -n "/^== $1 /,\$p" "$console_log" | tac | sed "/^== $1 /q" | grep -q 'status: failed'; then
        reason="a step of SuiteCRM's $1 failed"
        return 1
    fi
}

# up_succeeded: the upgrade is done only when the files, the database and SuiteCRM itself all say the new version.
up_succeeded() {
    [ "$(sc_read_version "$SC_ROOT/VERSION")" = "$to" ] && [ "$(sc_db_version)" = "$to" ] &&
        sc_as_www php bin/console suitecrm:version 2> /dev/null | grep -qF -- "$to"
}

# up_keep_list_in_effect ENTRY...: succeeds when the keep-list that SuiteCRM has compiled, which is the one its
# upgrade command will read, names every ENTRY (keep-list.php starts SuiteCRM's kernel and reads the list from
# the compiled container, as the command does).
up_keep_list_in_effect() {
    console_log_ready
    sc_as_www php "$SC_INSTALLER/keep-list.php" "$SC_ROOT" "$@" 2>> "$console_log"
}

# up_will_delete: SuiteCRM's upgrade removes what it doesn't know at the top of the install, in public/ and in
# public/legacy/: what the new package doesn't ship and the keep-list doesn't name. This logs those entries
# before the first command, so that a file someone put there by hand is not lost without a word. They are in
# the backup's code.tar.gz.
up_will_delete() {
    local kept level entry rel gone='' count=0
    kept=$(sc_as_www php "$SC_INSTALLER/keep-list.php" "$SC_ROOT" --list 2> /dev/null) || return 0
    for level in . public public/legacy; do
        [ -d "$level" ] && [ ! -L "$level" ] || continue
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            rel=${level#.}
            rel=${rel#/}
            rel=${rel:+$rel/}$entry
            if [ -e "$SC_PACKAGE/$rel" ] || grep -qxF -- "$rel" <<< "$kept"; then continue; fi
            case " $aside_folders $aside_markers " in *" $rel "*) continue ;; esac
            count=$((count + 1))
            if [ "$count" -le 40 ]; then gone="$gone $rel"; fi
        done < <(ls -A -- "$level" 2> /dev/null)
    done
    if [ "$count" -gt 0 ]; then
        up_log "$app $from -> $to: SuiteCRM's upgrade removes what the new package doesn't ship and its keep-list doesn't name. $count such entries at the top of the install, in public/ and in public/legacy/ will be gone from the site (the backup's code.tar.gz has them):$gone$([ "$count" -gt 40 ] && echo ' ...')"
    fi
}

# up_attempt: the keep-list, the package and the two commands. Sets $reason and returns 1 when it failed.
up_attempt() {
    # What must be on the installed version's keep-list: the customer's upload folders under their 8.9 and 8.10
    # names, the image's own entries and lost+found (which www-data can't even read), and, although upstream's
    # list has had them in every version so far, what the site can't lose: the legacy uploads and
    # customisations and the three settings files.
    local keep="uploads public/media-upload media public/media public/legacy/upload public/legacy/custom"
    keep="$keep public/legacy/config.php public/legacy/config_override.php .env.local"
    keep="$keep clouve .suitecrm_initialized .suitecrm_url lost+found"
    local left status=0
    # Until the state says otherwise, nothing in the site or the database has changed in this try.
    sc_state_set step=prepare || { reason="the state file could not be written"; return 1; }
    sc_as_www rm -rf "$SC_ROOT/tmp/package"
    # shellcheck disable=SC2086  # one argument per entry
    if ! sc_as_www "$SC_INSTALLER/patch-keep-list.sh" config/services/system/upgrades.yaml $keep; then
        reason="the installed SuiteCRM's keep-list could not be changed"
        return 1
    fi
    # SuiteCRM compiles the list into its cache, and its upgrade command reads the compiled one. So the cache
    # goes, and the list is read back from what SuiteCRM compiles next. SuiteCRM's own cache:clear is not enough:
    # it rebuilds nothing when the cache was written in the same second. Without this proof the command is never
    # run: lost+found and the image's entries depend on the list, and the customer's folders get a second layer.
    if ! left=$(sc_symfony_cache_drop); then
        reason="SuiteCRM's compiled cache could not be removed (${left:-cache}), so its upgrade command was not run"
        return 1
    fi
    # shellcheck disable=SC2086  # one argument per entry
    if ! up_keep_list_in_effect $keep; then
        reason="the keep-list is not in effect in the installed SuiteCRM, so its upgrade command was not run"
        return 1
    fi
    up_will_delete
    if ! sc_as_www mkdir -p tmp/package/upgrade || ! sc_as_www cp "$zip" "tmp/package/upgrade/$package.zip"; then
        reason="the package could not be copied to the volume"
        return 1
    fi
    # The customer's folders leave the install before SuiteCRM's first command and come back right after it,
    # whether it ended well or not. The state says so first, so a stop in between puts them back. The markers
    # get a copy there and stay.
    sc_state_set step=aside || { reason="the state file could not be written"; return 1; }
    if ! up_aside_take; then
        up_aside_return
        reason="the customer's upload folders could not be moved out of the upgrade command's reach, so it was not run"
        return 1
    fi
    sc_pause aside
    # From SuiteCRM 8.10 on, the first command can change the database (pre-upgrade migrations). A way back
    # from here on compares the database with the backup's fingerprint before it leaves it alone.
    sc_state_set step=files || { up_aside_return; reason="the state file could not be written"; return 1; }
    up_console suitecrm:app:upgrade || status=1
    if ! up_aside_return; then
        reason="the customer's upload folders could not be put back from ${SC_ASIDE#"$SC_ROOT"/}${reason:+ (and $reason)}"
        return 1
    fi
    [ "$status" -eq 0 ] || return 1
    sc_state_set step=back || { reason="the state file could not be written"; return 1; }
    sc_pause upgrade
    # The second command changes the database for certain. The state says so before it starts, and a way back
    # then loads the dump without asking.
    sc_state_set step=finalize || { reason="the state file could not be written"; return 1; }
    up_console suitecrm:app:upgrade-finalize || return 1
    if ! up_succeeded; then
        reason="SuiteCRM's commands ended without an error, but SuiteCRM does not report $to"
        return 1
    fi
}

# up_finish: after a try that succeeded. The state file goes last, so a start that still finds it checks again.
up_finish() {
    local began elapsed kept
    sc_pause cleanup
    up_aside_return || :
    sc_as_www rm -rf "$SC_ROOT/tmp/package"
    sc_as_www bash -c 'date -u > "$1/.suitecrm_initialized"' _ "$SC_ROOT" 2> /dev/null
    began=$(sc_state_get started_epoch)
    case $began in '' | *[!0-9]*) elapsed='' ;; *) elapsed=$(($(date +%s) - began)) ;; esac
    rm -f -- "$SC_SKIPPED"
    sc_state_clear
    if [ -d "$backup" ]; then
        kept="The backup stays in ${backup#"$SC_ROOT"/} until someone removes it."
    else
        kept="There is no backup of the site as it was before."
    fi
    up_log "DONE $app $from -> $to${elapsed:+ in $elapsed s}. $kept"
}

# --- the way back ---------------------------------------------------------------------------------------------------

# up_drop_tables: drops every table and view of the database. The dump only drops the tables it holds, and the
# upgrade adds new ones.
up_drop_tables() {
    local list kind name
    list=$(sc_sql "SELECT CONCAT(CASE table_type WHEN 'VIEW' THEN 'VIEW' WHEN 'SEQUENCE' THEN 'SEQUENCE' ELSE 'TABLE' END, ' \`', REPLACE(table_name, '\`', '\`\`'), '\`') FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME'") || return 1
    [ -n "$list" ] || return 0
    {
        echo 'SET FOREIGN_KEY_CHECKS = 0;'
        while read -r kind name; do echo "DROP $kind IF EXISTS $name;"; done <<< "$list"
    } | mysql --defaults-extra-file="$SC_DB_CNF" "$DATABASE_NAME" || return 1
    [ "$(sc_table_count)" = 0 ]
}

# up_remove_code: removes the code the backup's archive brings back, and nothing else: the customer's files,
# tmp/, cache/, logs/ and lost+found stay. Root does it, so that a file of root's or a closed folder that a
# command run as root left in the tree can't stop the way back half-way, with the code gone. rm -rf never
# follows a link, and the two folders it descends into by name are checked first. The image's two marker files
# stay as well, and the archive then writes over them: the earlier image, started on a volume without
# .suitecrm_initialized, installs anew and drops the database.
up_remove_code() {
    find . -mindepth 1 -maxdepth 1 ! -name tmp ! -name cache ! -name logs ! -name lost+found ! -name public \
        ! -name uploads ! -name media ! -name '*.clouve-aside' ! -name .suitecrm_initialized ! -name .suitecrm_url \
        -exec rm -rf -- {} + || return 1
    if [ -L public ] || [ ! -d public ]; then
        rm -rf -- public
        return
    fi
    find public -mindepth 1 -maxdepth 1 ! -name legacy ! -name media-upload ! -name media ! -name '*.clouve-aside' \
        -exec rm -rf -- {} + || return 1
    if [ -L public/legacy ] || [ ! -d public/legacy ]; then
        rm -rf -- public/legacy
        return
    fi
    find public/legacy -mindepth 1 -maxdepth 1 ! -name upload -exec rm -rf -- {} +
}

# up_restore: puts the old version back from the backup: the customer's folders when they were aside, the
# database unless it is proven unchanged, then the files. Returns 0 when the old version is back, 1 when going
# back failed (it can run again), 2 when there is no good backup, in which case nothing was touched, 3 when
# the old version is back but files of the customer's that the backup recorded are not on the volume.
up_restore() {
    local pair old new had status dir step recorded now lost=''
    up_phase restore
    # The backup is checked before anything is touched, the state file included.
    if ! up_backup_good; then
        up_failed "there is no good backup to go back to: $reason. Nothing more was changed: the files and the database are as the upgrade left them, and SuiteCRM is not started. Restore the deployment from a backup of its own, or see README.md, \"Staff runbook\"."
        return 2
    fi
    step=$(sc_state_get step)
    sc_state_set phase=restore || { reason="the state file could not be written"; return 1; }
    # The customer's folders first, when the try stopped while they were out of the install.
    if ! up_aside_return; then
        reason="the customer's upload folders could not be put back from ${SC_ASIDE#"$SC_ROOT"/}"
        return 1
    fi

    # The database. It is left alone only when that is proven: SuiteCRM's second command, which always changes
    # it, never started, and every table, column, index and row is what the backup's stamp recorded. From 8.10
    # on the first command can change it too. Otherwise every table goes, the dump comes back, and the table
    # count has to match.
    recorded=$(stamp_get database_fingerprint)
    if [ "$step" != finalize ] && [ -n "$recorded" ] && now=$(up_db_fingerprint) && [ "$now" = "$recorded" ]; then
        up_log "$app $from -> $to: the database has the same tables, columns and rows as when the backup was made, so the database is left as it is"
    else
        if [ "$step" = finalize ]; then
            up_log "$app $from -> $to: SuiteCRM's second command had started, so the dump is loaded"
        else
            up_log "$app $from -> $to: the database is not what the backup recorded, so the dump is loaded"
        fi
        if ! up_drop_tables; then reason="the database's tables could not be dropped"; return 1; fi
        sc_pause restore
        gzip -dc "$backup/db.sql.gz" | mysql --defaults-extra-file="$SC_DB_CNF" "$DATABASE_NAME"
        status=$((PIPESTATUS[0] + PIPESTATUS[1]))
        if [ "$status" -ne 0 ]; then reason="the database dump could not be loaded"; return 1; fi
        if [ "$(sc_base_table_count)" != "$(stamp_get tables)" ]; then
            reason="the database has $(sc_base_table_count) tables after the dump was loaded, not $(stamp_get tables)"
            return 1
        fi
    fi

    # The files. What the backup left in place stays in place. Everything else goes, as root, and comes back
    # from the archive, as www-data. The three folders the archive is unpacked into are www-data's again first.
    if ! up_remove_code; then
        reason="the upgraded code could not be removed"
        return 1
    fi
    sc_pause removed
    for dir in . public public/legacy; do
        if [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(stat -c %U -- "$dir")" != www-data ]; then
            chown -h www-data:www-data -- "$dir"
        fi
    done
    if ! sc_as_www tar -C "$SC_ROOT" -xzpf - < "$backup/code.tar.gz"; then
        reason="the code archive could not be unpacked"
        return 1
    fi
    # 8.10's migration renames uploads/ to media/ and public/media-upload/ to public/media/. The old version
    # looks in the old places, so they get their names back. When both are there, the files are merged by
    # renames: a copy that a stop cuts off would leave half a file.
    for pair in "uploads media had_uploads" "public/media-upload public/media had_public_media_upload"; do
        read -r old new had <<< "$pair"
        [ "$(stamp_get "$had")" = yes ] || continue
        if [ -d "$new" ] && [ ! -L "$new" ] && [ "$(stamp_get "had_${new//\//_}")" != yes ]; then
            if [ ! -e "$old" ] && [ ! -L "$old" ]; then
                sc_as_www mv -T -- "$new" "$old" || { reason="$new could not be named back to $old"; return 1; }
            elif ! up_merge "$new" "$old"; then
                reason="the files in $new could not be moved back to $old"
                return 1
            fi
        fi
        if [ ! -d "$old" ]; then lost="$lost $old/"; fi
    done
    sc_as_www rm -rf "$SC_ROOT/tmp/package"
    # The compiled cache is the newer version's. The old version compiles its own at its first use. Root
    # removes it, for the same reason it removes the code, and the folder is www-data's afterwards.
    if [ -L cache ] || { [ -e cache ] && [ ! -d cache ]; }; then rm -f -- cache; fi
    [ -d cache ] || sc_as_www mkdir cache
    find cache -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2> /dev/null
    if [ -n "$(find cache -mindepth 1 -print -quit 2> /dev/null)" ]; then
        reason="SuiteCRM's compiled cache could not be removed, so the old code would run on the new version's cache"
        return 1
    fi
    [ "$(stat -c %U -- cache)" = www-data ] || chown -h www-data:www-data -- cache
    # The archive has the database settings of the day the backup was made. The environment may have others by
    # now (a password that was rotated in between), and the next try's commands read them from the files.
    sc_as_www php "$SC_INSTALLER/settings.php" database "$SC_ROOT" > /dev/null ||
        up_log "$app $from -> $to: the database settings in the restored files could not be brought in step with the environment"

    # The check: the version on the volume and in the database read as they did when the backup was made.
    if [ "$(sc_read_version "$SC_ROOT/VERSION")" != "$(stamp_get version_file)" ] ||
        [ "$(sc_db_version)" != "$(stamp_get database_version)" ]; then
        reason="after going back, the version on the volume or in the database is not the one the backup was made of"
        return 1
    fi
    # And the customer's folders: the backup never held them, so it can't bring them back.
    if [ -n "$lost" ]; then
        new=${lost# }
        case $new in
            uploads/*) new="the backup recorded uploads/, and neither uploads/ nor media/ is on the volume" ;;
            *) new="the backup recorded public/media-upload/, and neither public/media-upload/ nor public/media/ is on the volume" ;;
        esac
        up_failed "$from's code and database are back, but $new: files the customer uploaded are gone, and the upgrade's backup never held them. SuiteCRM is not started. Restore those folders from a backup of the deployment and restart, or see README.md, \"Staff runbook\"."
        return 3
    fi
    sc_pause restored
    up_log "$app $from -> $to: ${from} is back, files and database, as the backup had them"
}

# go_back: the way back, and what a failure of it means for this start.
go_back() {
    counting=0
    up_restore
    case $? in
        0) return 0 ;;
        2 | 3) needs_staff ;;
        *)
            up_failed "going back to $from failed: $reason. Apache is not started, because the old code would run on a half-changed database. The state is kept, so the next start goes back again (README.md, \"Staff runbook\")."
            exit 1
            ;;
    esac
}

# give_up WHY: two tries failed. The old version is back and runs, and this build doesn't try again.
give_up() {
    sc_state_set phase=failed "reason=$1" "failed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    (
        umask 077
        {
            printf 'The upgrade of SuiteCRM from %s to %s failed %s times on %s (image build %s).\nLast reason: %s\n\n' \
                "$from" "$to" "$max_attempts" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$build" "$1"
            printf 'SuiteCRM %s was put back from the backup in tmp/clouve-backup/%s and runs.\n' "$from" "${backup##*/}"
            printf 'This build of the image does not try again while this file exists. A newer build tries by itself.\n'
            printf 'To try again with this build, remove this file and restart the container.\n'
            printf 'The output of SuiteCRM'"'"'s commands is in tmp/clouve-backup/upgrade-console.log and logs/upgrade.log.\n'
        } > "$SC_STATE_DIR/upgrade-failed"
    )
    up_failed "$1. $from was put back and runs. This build will not try again: remove ${SC_STATE_DIR#"$SC_ROOT"/}/upgrade-failed to let it, or start a newer build."
    exit 0
}

# finish_as_is: staff's own run, on a site between two versions with no backup to go back to. It runs
# SuiteCRM's two commands on the site as it is. Nothing is put back when it fails.
finish_as_is() {
    local volume_version database_version
    die() {
        echo "[clouve-upgrade] --finish-as-is: $*" >&2
        exit 1
    }
    [ "$(id -u)" = 0 ] || die "run it as root in the app container"
    volume_version=$(sc_read_version "$SC_ROOT/VERSION")
    [ "$volume_version" = "$to" ] || die "this is for a site whose VERSION already says $to, and this one says ${volume_version:-nothing}. Nothing was changed."
    sc_has_config_table || die "the database $DATABASE_NAME has no SuiteCRM tables. Nothing was changed."
    database_version=$(sc_db_version) || die "could not read SuiteCRM's version from the database. Nothing was changed."
    [ "$database_version" != "$to" ] || die "the database already records $to, so the upgrade is finished. Nothing was changed."
    if [ "$(sc_state_dir_status)" = untrusted ] || [ -n "$(sc_untrusted_dirs)" ]; then
        die "a state folder that is not root's is on the volume and may hold the backup. Put it back first (README.md, \"Staff runbook\"). Nothing was changed."
    fi
    case $(sc_state_get phase) in
        '' | as-is) ;;
        *) die "the state file says that an upgrade with a backup is under way. Restart the container: it goes back from the backup and upgrades. Nothing was changed." ;;
    esac
    [ -z "$(sc_backup_from_for "$to")" ] || die "a complete backup is on the volume. Restart the container: it goes back from it and upgrades. Nothing was changed."
    [ -s "$zip" ] || die "this image has no package $zip. Nothing was changed."
    from=unfinished
    backup=$SC_STATE_DIR/none
    sc_state_set phase=as-is from=unfinished "to=$to" "build=$build" "started_epoch=$(date +%s)" || die "the state file could not be written. Nothing was changed."
    up_log "$app unfinished -> $to: finishing the upgrade on the site as it is, because staff asked for it. There is no way back from here but a backup of the deployment."
    if up_attempt; then
        up_finish
        exit 0
    fi
    up_aside_return || :
    up_failed "finishing the upgrade as it is failed: $reason. Nothing was put back. Run it again, or restore the deployment from a backup."
    exit 1
}

# --- where this start begins ----------------------------------------------------------------------------------------

if [ "${1:-}" = --finish-as-is ]; then
    finish_as_is
fi

phase=$(sc_state_get phase)
last_reason=''
if [ -n "$phase" ]; then
    from=$(sc_state_get from)
    attempts=$(sc_state_get attempts)
    case $attempts in '' | *[!0-9]*) attempts=0 ;; esac
    if [ "$phase" = as-is ]; then
        # Staff's own run was cut off. The customer's folders come back first. The site is still between two
        # versions, with nothing to go back to.
        from=unfinished
        up_aside_return || :
        up_failed "finishing the upgrade on the site as it is (upgrade.sh --finish-as-is) was cut off. The site is between two versions and is not started. Run the command again, or restore the deployment from a backup (README.md, \"Staff runbook\")."
        needs_staff
    fi
    if [ "$phase" = backup ]; then
        # Nothing in the site had changed, whichever image wrote the state.
        up_log "$app ${from:-?} -> $(sc_state_get to): the backup was cut off before it was complete. Nothing in the site had changed, so the unfinished backup goes and the upgrade starts over."
        rm -rf -- "$SC_STATE_DIR"/*.partial
        sc_state_clear
        phase=''
    elif [ "$(sc_state_get to)" != "$to" ] || ! sc_is_version "$from"; then
        from=${from:-?}
        up_failed "the state file in ${SC_STATE_DIR#"$SC_ROOT"/} is of an upgrade to $(sc_state_get to), not to this image's $to. Nothing was changed and SuiteCRM is not started. Start the image that began that upgrade (README.md, \"Staff runbook\")."
        exit 1
    elif [ "$(sc_state_get build)" != "$build" ]; then
        # The tries so far were another build's. This one gets its own, and a failure is recorded under its id.
        up_log "$app $from -> $to: the upgrade was begun by another build of this image ($(sc_state_get build)), so this build's tries start at none"
        attempts=0
        sc_state_set "build=$build" attempts=0 || exit 1
    fi
fi
if [ -z "$phase" ]; then
    volume_version=$(sc_read_version "$SC_ROOT/VERSION")
    if [ "$volume_version" = "$to" ]; then
        # VERSION already says the new version, and entrypoint.sh found no finished-upgrade record: an upgrade
        # was cut off and its state file is gone. That is no version to run or to back up. With the complete
        # backup of that upgrade on the volume, this goes back from it and upgrades again.
        if [ "$(sc_db_version)" = "$to" ]; then
            up_log "$app $to: the site is on $to and finished, so there is nothing to upgrade"
            exit 0
        fi
        from=$(sc_backup_from_for "$to")
        if [ -z "$from" ]; then
            from=unfinished
            up_failed "VERSION says $to but the database has no finished-upgrade record for it, and the volume holds no backup that this image can trust. The site is between two versions and is not started. Restore the deployment from a backup, or finish the upgrade on the site as it is with $SC_INSTALLER/upgrade.sh --finish-as-is (README.md, \"Staff runbook\")."
            needs_staff
        fi
        backup=$SC_STATE_DIR/$from-to-$to
        up_log "$app $from -> $to: the state file is gone, but the complete backup $from-to-$to is there, so $from is put back from it first"
        sc_state_set phase=upgrade "from=$from" "to=$to" "build=$build" attempts=0 step=unknown "started_epoch=$(date +%s)" || exit 1
        phase=upgrade
        last_reason="the container stopped during the upgrade"
        go_back
    else
        from=$volume_version
    fi
fi
backup=$SC_STATE_DIR/$from-to-$to

case $phase in
    upgrade)
        if [ -z "$last_reason" ]; then
            if up_succeeded; then
                up_log "$app $from -> $to: the upgrade had finished before the container stopped, so only its clean-up is left"
                up_finish
                exit 0
            fi
            up_log "$app $from -> $to: the upgrade was cut off, so $from is put back first"
            last_reason="the container stopped during the upgrade"
            go_back
        fi
        ;;
    restore)
        up_log "$app $from -> $to: the way back was cut off, so it runs again"
        last_reason=$(sc_state_get reason)
        last_reason=${last_reason:-the container stopped while $from was put back}
        go_back
        ;;
esac

if [ -z "$phase" ]; then
    # A new run. Until the backup is complete nothing in the site changes, so a problem here means: no upgrade
    # at this start, and the version on the volume keeps running.
    if ! sc_is_version "$from" || [ "$(sc_version_cmp "$from" "$to")" != lt ]; then
        up_failed "the volume holds ${from:-no readable version}, which is not older than this image's $to, so there is nothing to upgrade"
        exit 1
    fi
    case $(sc_has_config_table; echo $?) in
        0) ;;
        *)
            up_failed "the database $DATABASE_NAME has no SuiteCRM tables, so there is nothing to upgrade. Nothing was changed and SuiteCRM is not started."
            needs_staff
            ;;
    esac
    if ! sc_state_dir_make; then
        up_failed "tmp/clouve-backup on the volume is not a folder that only root can change, so no backup can be kept there. Nothing was changed and $from keeps running. The next start moves that folder aside and tries again."
        exit 0
    fi
    if [ ! -s "$zip" ]; then
        up_skip "this image has no package $zip"
    fi
    foreign=$(up_not_www)
    if [ -n "$foreign" ]; then
        up_skip "files in the install are not www-data's, so SuiteCRM's upgrade, which runs as www-data, could not replace them ($foreign). Give them to www-data (chown -hR www-data:www-data <path>, in $SC_ROOT)"
    fi
    if ! up_space_ok; then
        up_skip "$reason"
    fi
    sc_state_set phase=backup "from=$from" "to=$to" "build=$build" attempts=0 "started_epoch=$(date +%s)" || up_skip "the state file could not be written"
    up_phase backup
    if ! up_backup; then
        rm -rf -- "$SC_STATE_DIR"/*.partial
        sc_state_clear
        up_skip "the backup could not be made: $reason"
    fi
    rm -f -- "$SC_SKIPPED"
fi

while :; do
    if [ "$attempts" -ge "$max_attempts" ]; then
        give_up "${last_reason:-the upgrade failed}"
    fi
    attempts=$((attempts + 1))
    sc_state_set phase=upgrade "attempts=$attempts" || exit 1
    counting=1
    up_phase upgrade "try $attempts of $max_attempts"
    if up_attempt; then
        counting=0
        up_finish
        exit 0
    fi
    counting=0
    last_reason=$reason
    up_log "$app $from -> $to: try $attempts failed: $reason"
    sc_state_set "reason=$reason"
    go_back
done
