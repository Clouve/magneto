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
#     the way, unpacks the old code as www-data and names the media folders back. Root removes and changes
#     owners only from inside the folder it checked, never by a path that www-data could point elsewhere
#     (lib.sh, sc_in_dir). The database is left alone
#     only when it is proven unchanged: SuiteCRM's second command never started, and the database's
#     fingerprint is the one the backup recorded. From 8.10 on the first command can change the database too
#     (pre-upgrade migrations). In every other case all tables are dropped (the upgrade adds some that the dump
#     doesn't know) and the dump is loaded, from inside the state folder that was checked, by a client that
#     runs as www-data with its sandbox on: a client command in a dump (system, source) is refused. Then it
#     tries once more. After two failed tries the old version
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
max_attempts=2
reason=''
from='?'
attempts=0
counting=0
# The customer's upload folders under both names (8.9 and 8.10), and the image's two marker files.
aside_folders="uploads public/media-upload media public/media"
aside_markers=".suitecrm_initialized .suitecrm_url"
cd "$SC_ROOT" || exit 1

# The functions that run inside the state folder (sc_in_state) run in a subshell, so they can't set $reason. They
# write it to this file of root's instead, and the caller reads it back with take_reason DEFAULT.
reason_file=$SC_RUN/reason
why() { local IFS=' '; printf '%s' "$*" > "$reason_file"; }
take_reason() {
    reason=$(cat -- "$reason_file" 2> /dev/null)
    rm -f -- "$reason_file"
    reason=${reason:-$1}
}

# console_log_ready: the console log, tmp/clouve-backup/upgrade-console.log, is root's alone, like everything else
# in the state folder. console_append adds standard input to it.
console_log_ready() { sc_in_state console_log_ready_here; }
console_log_ready_here() { ( umask 077; : >> upgrade-console.log ) 2> /dev/null && chmod 600 upgrade-console.log; }
console_append() { sc_in_state sh -c 'cat >> upgrade-console.log'; }

# parent_of PATH: the folder PATH is in, relative to the install ("" for its top folder).
parent_of() { case $1 in */*) printf '%s\n' "${1%/*}" ;; *) printf '\n' ;; esac; }
sc_real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }

# held_mv PARENT FROM TO: for a rename between the state folder and the install. It runs inside the state folder
# (sc_in_state), opens that folder as file descriptor 8 and renames FROM to TO from inside PARENT, a folder of the
# install that sc_in_dir checked. The state folder's side is named /proc/self/fd/8/<name>, a path that leads to the
# folder that was checked, whatever its name is by then. So neither end can be another folder: the customer's
# folders never leave the volume, and nothing of www-data's comes into root's folder.
held_mv() {
    exec 8< . || return 1
    sc_in_dir "$1" mv -T -- "$2" "$3"
}
# to_install STATE_PATH INSTALL_PATH, to_state INSTALL_PATH STATE_PATH: such a rename, each way.
to_install() { sc_in_state held_mv "$(parent_of "$2")" "/proc/self/fd/8/$1" "${2##*/}"; }
to_state() { sc_in_state held_mv "$(parent_of "$1")" "${1##*/}" "/proc/self/fd/8/$2"; }

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

# stamp_get KEY: a value from the backup's "complete" file. stamp_value NAME KEY does the reading, inside the state
# folder, for the backup folder NAME.
stamp_get() { sc_in_state stamp_value "${backup##*/}" "$1"; }
stamp_value() {
    local line
    sc_root_file "$1/complete" || return 0
    while IFS= read -r line; do
        if [ "${line%%=*}" = "$2" ]; then printf '%s\n' "${line#*=}"; return 0; fi
    done < "$1/complete"
}
# backup_file_good NAME FILE KEY: inside the state folder. NAME/FILE is a plain file of root's whose checksum is
# the one the stamp records under KEY, and gzip reads it whole.
backup_file_good() {
    sc_root_file "$1/$2" && [ "$(sha256sum < "$1/$2" | cut -d' ' -f1)" = "$(stamp_value "$1" "$3")" ] &&
        gzip -t "$1/$2" 2> /dev/null
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
# The copy of the database password that the way back's www-data client reads goes whenever this script ends. Only
# the run that holds the lock may remove it: a run that was refused must not take it from the one that runs.
trap 'sc_db_cnf_www_drop' EXIT
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
    local name out=''
    while IFS= read -r -d '' name; do
        out="$out $(printf '%q' "$name")"
    done < <(find . \( -path ./lost+found -o -path './tmp/clouve-*' \) -prune -o ! -user www-data -printf '%P\0' 2> /dev/null | head -z -n 5)
    printf '%s\n' "${out# }"
}

# up_skip REASON: this start doesn't try the upgrade, and nothing has changed. The reason, the versions and the
# time go to tmp/clouve-backup/upgrade-skipped, for staff and for the AI Assistant, and the version on the
# volume keeps running. The note blocks nothing: the next start looks again, and removes it when it upgrades.
up_skip() {
    if sc_state_dir_make; then
        printf 'from=%s\nto=%s\nbuild=%s\ntime=%s\nreason=%s\n' "$from" "$to" "$build" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" | sc_state_write upgrade-skipped || :
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
        } | mysql --defaults-extra-file="$SC_DB_CNF" --sandbox --connect-timeout=10 -N -B "$DATABASE_NAME" || exit 1
    ) || return 1
    printf '%s\n' "$parts" | sha256sum | cut -d' ' -f1
}

# up_backup: writes the backup under <name>.partial, checks it, stamps it and gives it its name, all from inside the
# state folder (up_backup_here). An older kept backup goes only once the new one is complete. Sets $reason and
# returns 1 when the backup is not good; the site is untouched either way.
up_backup() {
    rm -f -- "$reason_file"
    if sc_in_state up_backup_here "${backup##*/}"; then return 0; fi
    take_reason "the backup could not be written in ${SC_STATE_DIR#"$SC_ROOT"/}"
    return 1
}
up_backup_here() {
    local name=$1 part=$1.partial status listing must creates tables last other fingerprint
    rm -rf -- ./*.partial
    if ! mkdir -- "$part" || ! chmod 00700 -- "$part"; then why "could not make the backup folder"; return 1; fi

    # The code and the settings. Root reads, and links are stored as links, never followed. tar opens the archive
    # here, in the state folder, before it reads the install from SC_ROOT.
    (
        umask 077
        tar -C "$SC_ROOT" --anchored --exclude=./tmp --exclude=./cache --exclude=./logs --exclude=./lost+found \
            --exclude=./public/legacy/upload --exclude=./uploads --exclude=./media \
            --exclude=./public/media-upload --exclude=./public/media -czf "$part/code.tar.gz" .
    )
    status=$?
    if [ "$status" -ne 0 ]; then why "the code archive could not be written (tar exit status $status)"; return 1; fi
    if ! gzip -t "$part/code.tar.gz" 2>/dev/null || ! listing=$(tar -tzf "$part/code.tar.gz" 2>/dev/null); then
        why "the code archive does not read back"
        return 1
    fi
    for must in ./VERSION ./bin/console ./vendor/autoload.php ./public/index.php ./public/legacy/config.php \
        ./config/services/system/upgrades.yaml; do
        if ! grep -qxF -- "$must" <<< "$listing"; then
            why "the code archive has no $must"
            return 1
        fi
    done
    sc_pause backup

    # The database, as the app's own user. The password is in the options file, never on the command line.
    ( umask 077; mysqldump --defaults-extra-file="$SC_DB_CNF" --single-transaction --routines --triggers \
        "$DATABASE_NAME" | gzip > "$part/db.sql.gz"; exit "$((PIPESTATUS[0] + PIPESTATUS[1]))" )
    status=$?
    if [ "$status" -ne 0 ]; then why "the database dump failed"; return 1; fi
    if ! gzip -t "$part/db.sql.gz" 2>/dev/null; then why "the database dump does not read back"; return 1; fi
    last=$(gzip -dc "$part/db.sql.gz" | tail -n 1)
    case $last in
        '-- Dump completed'*) ;;
        *) why "the database dump has no end line, so it is cut short"; return 1 ;;
    esac
    creates=$(gzip -dc "$part/db.sql.gz" | grep -c '^CREATE TABLE ')
    tables=$(sc_base_table_count) || tables=''
    if [ -z "$tables" ] || [ "$tables" -lt 1 ] || [ "$creates" != "$tables" ]; then
        why "the database dump holds $creates tables and the database has ${tables:-an unknown number}"
        return 1
    fi
    # What the database looks like now. A way back compares it with this before it leaves the database alone.
    if ! fingerprint=$(up_db_fingerprint) || [ -z "$fingerprint" ]; then
        why "the database's tables could not be read for the backup's stamp"
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
                "$([ -d "$SC_ROOT/uploads" ] && echo yes || echo no)" "$([ -d "$SC_ROOT/public/media-upload" ] && echo yes || echo no)" \
                "$([ -d "$SC_ROOT/media" ] && echo yes || echo no)" "$([ -d "$SC_ROOT/public/media" ] && echo yes || echo no)"
            printf 'code_sha256=%s\ndatabase_sha256=%s\ndatabase_fingerprint=%s\n' \
                "$(sha256sum < "$part/code.tar.gz" | cut -d' ' -f1)" \
                "$(sha256sum < "$part/db.sql.gz" | cut -d' ' -f1)" "$fingerprint"
        } > "$part/complete"
    )
    if ! grep -q '^database_fingerprint=[0-9a-f]\{64\}$' "$part/complete"; then
        why "the backup's stamp could not be written"
        return 1
    fi
    chmod 600 "$part"/* && sync "$part"/* 2>/dev/null

    rm -rf -- "$name.old"
    if [ -e "$name" ] && ! mv -- "$name" "$name.old"; then why "could not move the earlier backup aside"; return 1; fi
    if ! mv -- "$part" "$name"; then
        if [ -e "$name.old" ]; then mv -- "$name.old" "$name"; fi
        why "could not give the backup its name"
        return 1
    fi
    sync . 2> /dev/null || :
    # One backup is kept: with this one complete, the earlier ones go.
    for other in ./*-to-*; do
        if [ "$other" != "./$name" ] && [ -d "$other" ] && [ ! -L "$other" ]; then
            up_log "$app $from -> $to: removing the earlier backup ${other#./}"
            rm -rf -- "$other"
        fi
    done
    up_log "$app $from -> $to: backup complete in ${backup#"$SC_ROOT"/} (code $(du -sh "$name/code.tar.gz" | cut -f1), database $(du -sh "$name/db.sql.gz" | cut -f1), $tables tables)"
}

# up_backup_good: succeeds when the backup is a stamped one of root's and both files still have the checksums
# the stamp recorded. Sets $reason when not. The way back checks the dump and the archive again, in the same call
# that uses them (up_load_dump, up_unpack_code).
up_backup_good() {
    if reason=$(sc_in_state up_backup_good_here "${backup##*/}"); then
        reason=''
        return 0
    fi
    reason=${reason:-there is no complete backup in ${backup#"$SC_ROOT"/}}
    return 1
}
# up_backup_good_here NAME: inside the state folder. Prints why NAME is not a good backup.
up_backup_good_here() {
    local name=$1 file
    if ! sc_real_dir "$name" || [ "$(stat -c %u -- "$name")" != 0 ] || [ -n "$(find "$name" -maxdepth 0 -perm /g=w,o=w 2> /dev/null)" ]; then
        echo "there is no complete backup in ${backup#"$SC_ROOT"/}"
        return 1
    fi
    for file in complete code.tar.gz db.sql.gz; do
        sc_root_file "$name/$file" || { echo "there is no complete backup in ${backup#"$SC_ROOT"/}"; return 1; }
    done
    if [ "$(stamp_value "$name" to)" != "$to" ] || [ "$(stamp_value "$name" from)" != "$from" ]; then
        echo "there is no complete backup in ${backup#"$SC_ROOT"/}"
        return 1
    fi
    backup_file_good "$name" code.tar.gz code_sha256 || { echo "the backup's code archive is damaged (its checksum changed)"; return 1; }
    backup_file_good "$name" db.sql.gz database_sha256 || { echo "the backup's database dump is damaged (its checksum changed)"; return 1; }
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
# It runs inside the folder PATH is in, checked by sc_in_dir, and follows no link. www-data can move tmp/, with the
# state folder and root's other folders in it, into PATH, so tmp/, the state folder and any folder of root's named
# clouve-* are left out, by their inodes and names, wherever they are. Status 1, with nothing changed, when the
# state folder or tmp/ is not at its place.
up_own() {
    local rel=${1#"$SC_ROOT"/} state tmp
    [ -n "$(find "$1" ! -user www-data -print -quit 2> /dev/null)" ] || return 0
    read -r state tmp <<< "$(sc_state_inos)"
    [ -n "$state" ] && [ -n "$tmp" ] || return 1
    sc_in_dir "$(parent_of "$rel")" find "${rel##*/}" -xdev \
        \( -inum "$state" -o -inum "$tmp" -o \( -type d -name 'clouve-*' -user root \) \) -prune -o \
        \( ! -user www-data -exec chown -h www-data:www-data -- {} + \)
}

# up_aside_take: copies the image's two marker files into root's state folder and renames the customer's upload
# folders into it. From here until up_aside_return, SuiteCRM's upgrade command can't reach the folders, whatever
# its keep-list says. The markers stay in the install as well: the earlier image takes a volume without
# .suitecrm_initialized for a new one and installs over it, so that file must never be missing, not even for
# the seconds this takes. Only a plain file is copied, never what a link points at.
up_aside_take() {
    local item name
    sc_in_state up_aside_dir_ready || return 1
    if [ -L public ] || { [ -e public ] && [ ! -d public ]; }; then return 1; fi
    for item in $aside_markers; do
        [ -f "$SC_ROOT/$item" ] && [ ! -L "$SC_ROOT/$item" ] || continue
        sc_in_state up_copy_marker "$item" || return 1
    done
    for item in $aside_folders; do
        name=${item//\//__}
        [ -e "$SC_ROOT/$item" ] || [ -L "$SC_ROOT/$item" ] || continue
        if sc_in_state sc_present "aside/$name"; then return 1; fi
        to_state "$item" "aside/$name" || return 1
    done
    sc_in_state sync aside 2> /dev/null || :
}
# up_aside_dir_ready and up_copy_marker NAME: inside the state folder.
up_aside_dir_ready() {
    if [ ! -d aside ]; then
        mkdir -- aside && chmod 00700 -- aside || return 1
    fi
    [ ! -L aside ] && [ "$(stat -c %u -- aside)" = 0 ]
}
up_copy_marker() { rm -rf -- "aside/$1" && cp -pP -- "$SC_ROOT/$1" "aside/$1"; }

# up_aside_return: renames the folders back, and puts a marker back when SuiteCRM's command removed it. It can
# run at any time and any number of times: what is not aside is left alone. When SuiteCRM's new code has made a
# folder of the same name meanwhile, the customer's files are merged into it. Status 1 when something could not
# be put back; it then stays where it is, in the state folder or next to its place as <name>.clouve-aside.
up_aside_return() {
    local item name dst stage has status=0
    sc_state_dir_trusted || return 0
    for item in $aside_folders; do
        name=${item//\//__}
        dst=$SC_ROOT/$item
        stage=$dst.clouve-aside
        has=0
        sc_in_state sc_present "aside/$name" || has=$?
        # The state folder was there a moment ago, and now it isn't the one that was checked.
        if [ "$has" = "$SC_NOT_PINNED" ]; then status=1; continue; fi
        if [ "$has" = 0 ]; then
            if [ "${item%/*}" != "$item" ] && [ ! -d "${dst%/*}" ]; then
                sc_as_www mkdir -p -- "${dst%/*}" || { status=1; continue; }
            fi
            if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
                to_install "aside/$name" "$item" || { status=1; continue; }
                up_own "$dst"
            elif sc_in_state sc_real_dir "aside/$name" && [ -d "$dst" ] && [ ! -L "$dst" ] && [ ! -e "$stage" ] && [ ! -L "$stage" ]; then
                to_install "aside/$name" "$item.clouve-aside" || { status=1; continue; }
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
        dst=$SC_ROOT/$item
        has=0
        sc_in_state sc_present "aside/$item" || has=$?
        if [ "$has" = "$SC_NOT_PINNED" ]; then status=1; continue; fi
        [ "$has" = 0 ] || continue
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            sc_state_rm "aside/$item" || status=1
        elif to_install "aside/$item" "$item"; then
            up_own "$dst"
        else
            status=1
        fi
    done
    sc_in_state sh -c '[ -d aside ] && [ ! -L aside ] && rmdir -- aside' 2> /dev/null || :
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
    printf '\n== %s %s (%s)\n' "$1" "$package" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | console_append
    sc_as_www php bin/console "$1" -n -t "$package" 2>&1 | sc_in_state tee -a upgrade-console.log |
        grep -v 'did not result in any SQL statements'
    status=${PIPESTATUS[0]}
    if [ "$status" -ne 0 ]; then
        reason="SuiteCRM's $1 ended with exit status $status"
        return 1
    fi
    if sc_in_state sed -n "/^== $1 /,\$p" upgrade-console.log | tac | sed "/^== $1 /q" | grep -q 'status: failed'; then
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
    local status
    console_log_ready
    sc_as_www php "$SC_INSTALLER/keep-list.php" "$SC_ROOT" "$@" 2> "$SC_RUN/keep-list.err"
    status=$?
    console_append < "$SC_RUN/keep-list.err"
    rm -f -- "$SC_RUN/keep-list.err"
    return "$status"
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
            if [ "$count" -le 40 ]; then gone="$gone $(printf '%q' "$rel")"; fi
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
    sc_state_rm upgrade-skipped
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
    } | mysql --defaults-extra-file="$SC_DB_CNF" --sandbox "$DATABASE_NAME" || return 1
    [ "$(sc_table_count)" = 0 ]
}

# up_remove_code: removes the code the backup's archive brings back, and nothing else: the customer's files,
# tmp/, cache/, logs/ and lost+found stay. Each folder is emptied from inside, once sc_in_dir checked that it is the
# install's own folder and not a link that www-data put in its place, and by www-data (sc_clear): www-data can move
# tmp/, with root's state folder in it, into the folder that is being emptied, and www-data can't remove that. What
# a command run as root left in the tree is given to www-data first, so it can't stop the way back half-way. The
# image's two marker files stay as well, and the archive then writes over them: the earlier image, started on a
# volume without .suitecrm_initialized, installs anew and drops the database.
up_remove_code() {
    sc_clear '' ! -name tmp ! -name cache ! -name logs ! -name lost+found ! -name public \
        ! -name uploads ! -name media ! -name '*.clouve-aside' ! -name .suitecrm_initialized ! -name .suitecrm_url || return 1
    if [ -L public ] || [ ! -d public ]; then
        sc_clear '' -name public
        return
    fi
    sc_clear public ! -name legacy ! -name media-upload ! -name media ! -name '*.clouve-aside' || return 1
    sc_pause remove-listed
    if [ -L public/legacy ] || [ ! -d public/legacy ]; then
        sc_clear public -name legacy
        return
    fi
    sc_clear public/legacy ! -name upload
}

# dump_whole NAME: inside the state folder. Succeeds when NAME/db.sql.gz is a whole dump from mysqldump, of as many
# tables as the stamp records: its first line turns the client's sandbox on, its last line is mysqldump's end line,
# and it makes one table per table. A dump this image wrote passes. A forged or foreign one that a person put back
# usually doesn't, and the way back then drops no table.
dump_whole() {
    local first last creates
    first=$(gzip -dc -- "$1/db.sql.gz" 2> /dev/null | head -n 1)
    last=$(gzip -dc -- "$1/db.sql.gz" 2> /dev/null | tail -n 1)
    creates=$(gzip -dc -- "$1/db.sql.gz" 2> /dev/null | grep -c '^CREATE TABLE ')
    case $first in '/*M!999999\- enable the sandbox mode */'*) ;; *) return 1 ;; esac
    case $last in '-- Dump completed'*) ;; *) return 1 ;; esac
    [ "$creates" = "$(stamp_value "$1" tables)" ]
}

# up_load_dump NAME: inside the state folder (sc_in_state), with NAME the backup's folder. Checks the dump in this
# very folder, drops every table and loads the dump. The folder stays the one that was checked from the check to
# the load, whatever www-data does to its name in tmp/ meanwhile. The client runs as www-data, with SuiteCRM's own
# database user, and with its sandbox on: a client command in the dump (system, source, tee) is refused, whoever
# wrote the dump. The image's own dumps start with the line that turns the sandbox on anyway.
up_load_dump() {
    local name=$1 status
    if ! backup_file_good "$name" db.sql.gz database_sha256; then
        why "the backup's database dump is damaged (its checksum changed)"
        return 1
    fi
    if ! dump_whole "$name"; then
        why "the backup's database dump is not a whole dump of this site (its first line, its last line or its count of tables is not what mysqldump writes and the stamp records), so no table was dropped"
        return 1
    fi
    if ! sc_db_cnf_www; then
        sc_db_cnf_www_drop
        why "the options file for the database client could not be written"
        return 1
    fi
    if ! up_drop_tables; then
        sc_db_cnf_www_drop
        why "the database's tables could not be dropped"
        return 1
    fi
    sc_pause restore
    gzip -dc -- "$name/db.sql.gz" | sc_as_www mysql --defaults-extra-file="$SC_WWW_CNF" --sandbox "$DATABASE_NAME"
    status=$((PIPESTATUS[0] + PIPESTATUS[1]))
    sc_db_cnf_www_drop
    if [ "$status" -ne 0 ]; then why "the database dump could not be loaded"; return 1; fi
    if [ "$(sc_base_table_count)" != "$(stamp_value "$name" tables)" ]; then
        why "the database has $(sc_base_table_count) tables after the dump was loaded, not $(stamp_value "$name" tables)"
        return 1
    fi
}

# up_unpack_code NAME: inside the state folder. Checks the code archive in this very folder and unpacks it into the
# install, as www-data.
up_unpack_code() {
    if ! backup_file_good "$1" code.tar.gz code_sha256; then
        why "the backup's code archive is damaged (its checksum changed)"
        return 1
    fi
    sc_as_www tar -C "$SC_ROOT" -xzpf - < "$1/code.tar.gz" || { why "the code archive could not be unpacked"; return 1; }
}

# up_restore: puts the old version back from the backup: the customer's folders when they were aside, the
# database unless it is proven unchanged, then the files. Returns 0 when the old version is back, 1 when going
# back failed (it can run again), 2 when there is no good backup, in which case nothing was touched, 3 when
# the old version is back but files of the customer's that the backup recorded are not on the volume.
up_restore() {
    local pair old new had dir step recorded now lost=''
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
        rm -f -- "$reason_file"
        if ! sc_in_state up_load_dump "${backup##*/}"; then
            take_reason "the backup's dump could not be read from ${SC_STATE_DIR#"$SC_ROOT"/}"
            return 1
        fi
    fi

    # The files. What the backup left in place stays in place. Everything else goes, as root, and comes back
    # from the archive, as www-data. The three folders the archive is unpacked into are www-data's again first.
    if ! up_remove_code; then
        reason=$(state_or "the upgraded code could not be removed")
        return 1
    fi
    sc_pause removed
    # Each of the three folders is given back to www-data from inside it, and only when it is the install's own.
    for dir in '' public public/legacy; do
        if [ -d "${dir:-.}" ] && [ ! -L "${dir:-.}" ] && [ "$(stat -c %U -- "${dir:-.}")" != www-data ]; then
            sc_in_dir "$dir" chown -h www-data:www-data .
        fi
    done
    rm -f -- "$reason_file"
    if ! sc_in_state up_unpack_code "${backup##*/}"; then
        take_reason "the code archive could not be unpacked"
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
    # The compiled cache is the newer version's. The old version compiles its own at its first use. It is emptied
    # the way the code is (sc_clear), and the folder is www-data's afterwards.
    if [ -L cache ] || { [ -e cache ] && [ ! -d cache ]; }; then sc_clear '' -name cache; fi
    [ -d cache ] || sc_as_www mkdir cache
    if ! sc_clear cache; then
        reason=$(state_or "SuiteCRM's compiled cache could not be removed, so the old code would run on the new version's cache")
        return 1
    fi
    [ "$(stat -c %U -- cache)" = www-data ] || sc_in_dir cache chown -h www-data:www-data .
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

# state_or REASON: REASON, or, when the state folder is not at its place any more, that.
state_or() {
    if sc_state_ino > /dev/null; then
        printf '%s' "$1"
    else
        printf '%s' "the state folder is not at tmp/clouve-backup any more (www-data can move tmp/ with it inside), so the way back stopped before it removed or changed anything more"
    fi
}

# go_back: the way back, and what a failure of it means for this start.
go_back() {
    local kept
    counting=0
    up_restore
    case $? in
        0) return 0 ;;
        2 | 3) needs_staff ;;
        *)
            if sc_state_dir_trusted; then
                kept="The state is kept, so the next start goes back again (README.md, \"Staff runbook\")."
            else
                kept="The state folder is not at tmp/clouve-backup any more, so the next start can't go back by itself: find it on the volume (tmp/ may have been moved with it inside), put it back in its place and restart (README.md, \"Staff runbook\")."
            fi
            up_failed "going back to $from failed: $reason. Apache is not started, because the old code would run on a half-changed database. $kept"
            exit 1
            ;;
    esac
}

# give_up WHY: two tries failed. The old version is back and runs, and this build doesn't try again.
give_up() {
    sc_state_set phase=failed "reason=$1" "failed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        printf 'The upgrade of SuiteCRM from %s to %s failed %s times on %s (image build %s).\nLast reason: %s\n\n' \
            "$from" "$to" "$max_attempts" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$build" "$1"
        printf 'SuiteCRM %s was put back from the backup in tmp/clouve-backup/%s and runs.\n' "$from" "${backup##*/}"
        printf 'This build of the image does not try again while this file exists. A newer build tries by itself.\n'
        printf 'To try again with this build, remove this file and restart the container.\n'
        printf 'The output of SuiteCRM'"'"'s commands is in tmp/clouve-backup/upgrade-console.log and logs/upgrade.log.\n'
    } | sc_state_write upgrade-failed
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
        sc_state_rm_partials
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
        sc_state_rm_partials
        sc_state_clear
        up_skip "the backup could not be made: $reason"
    fi
    sc_state_rm upgrade-skipped
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
