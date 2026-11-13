#!/bin/bash
# The in-place upgrade of a LimeSurvey install whose code is older than the image's package. site.sh runs it as
# root, before Apache starts: with new code on an old database, LimeSurvey lets anyone start the database update
# from the browser without signing in. Everything that touches the web root or runs PHP runs as www-data (ls_www).
#
# Exit status:
#   0   the site is on the package's version
#   10  the old version is in place, whole, and stays (the upgrade failed twice, or was not tried at this start)
#   11  an upgrade that an earlier image had begun is closed, and site.sh has to look at the site again
#   20  nothing safe can be started and a person has to repair the site: the state is kept as it is, Apache must
#       not start, and entrypoint.sh keeps the container up for the repair
#   1   the upgrade can't run at all (the state folder is not root's)
#   143 a stop was asked for. The next start goes on from the state file
#
# The upgrade keeps everything in one folder, clouve/upgrade-<from>-to-<to>/. Like clouve/ itself it is root's with
# mode 700 and its files 600, so PHP code can neither read nor change it, and Apache never serves it:
#   state             where the upgrade is: phase=backup, upgrade, restore, failed or done, and the step within it
#   db.sql.gz         the database dump
#   backup-complete   written once the dump is checked: its checksum, the table count, the database version
#   db-touched        written and synced before the upgrade's first write to the database, removed once the dump is
#                     loaded again. Only when it is there does a restore load the dump
#   reserve           256 KB that are given up when the volume is full, so the state can still be written
#   active-plugins    the added plugins that were switched on before the update
#   code/             the old code
#   updatedb.log      what LimeSurvey's database update printed
# Beside the folder, in clouve/: upgrade-attempts (how often this build has tried), upgrade-failed (this build gave
# up; no start tries again until the file is gone or the build differs) and upgrade-skipped (the last start did not
# try, and why; the next start checks again).
#
# A start that finds a state file does the one thing that is safe for its phase:
#   backup    the backup was cut off. Nothing in the site has changed. The partial backup goes, the upgrade starts again.
#   upgrade   the backup is complete and the upgrade was cut off. If the update had finished (the code and the database
#             are both at the version the state names as its target), it is finished off and never undone. If not,
#             the old version is put back and the upgrade runs again.
#   restore   a restore was cut off. It runs again.
#   failed    the old version is back and stays (site.sh starts it).
# A restore loads only a dump that still matches backup-complete, and only when db-touched says the upgrade wrote to
# the database. After a restore, the tables and the versions are checked, and a restore that fails stops the start.
#
# Every change of the state file is checked. One that fails, as on a full volume, stops the step before anything
# else changes, and Apache never starts while the state says backup, upgrade or restore.
#
# The steps of an upgrade, each safe to meet again:
#   backup    check the free space and the free inodes, record the active plugins, dump the database, check the dump
#   moving    move the old code's top-level entries into code/ (renames: the folder is on the same volume)
#   copying   copy the package in; put back config.php, security.php, allowed_hosts.php and the added plugins
#   updating  write db-touched, LimeSurvey's maintenance mode on, console.php updatedb, check the result
#   finishing switch the SuiteCRM plugin back on when it was on, maintenance mode as it was, flush the caches, done
# upload/ is a volume of its own and is never moved. Top-level entries that the package doesn't ship (markers, files
# an admin put there) stay where they are. tmp/ starts from the package's empty one.
#
# An image tries at most twice (clouve/upgrade-attempts counts, per build, from the moment the site is first
# changed). Then it writes clouve/upgrade-failed. A stop request that ends an attempt cleanly doesn't count.

set -u

installer=/clouve/limesurvey/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || exit 1

if ! ls_enter_clouve || [ "$(stat -c %a . 2>/dev/null)" != 700 ]; then
    ls_error "$LS_CLOUVE is not a folder of root's with mode 700, so the upgrade can't keep its state there"
    exit 1
fi

read -r PKG_VER PKG_DB _ <<< "$(ls_version "$LS_PACKAGE")"
BUILD="$(ls_image_build)"
# Paths from inside clouve/. here() gives the full path for a message.
ATTEMPTS_FILE=upgrade-attempts
FAILED_FILE=upgrade-failed
SKIPPED_FILE=upgrade-skipped
KEEP="$LS_ROOT/.clv-keep"   # www-data's copy of the files that belong to the install, while the code is swapped
MAX_ATTEMPTS=2
DIR=""          # the upgrade's folder, from inside clouve/
FROM=""         # the version the site is on
FROM_DB=""
TO=""           # the version the upgrade goes to
TO_DB=""
REASON=""       # why the last attempt failed
STARTED=$SECONDS
COUNTED=0       # 1 once this run has counted an attempt

here() { printf '%s/%s' "$LS_CLOUVE" "$1"; }

# --- a stop request -------------------------------------------------------------------------------------------------

# entrypoint.sh writes the file $LS_STOP_FLAG and then sends SIGTERM to every process of the start when the
# container is asked to stop. The commands end, and this script ends cleanly at once: the state on the disk is what
# a kill would leave, which the next start picks up, and the attempt is not counted. Two steps are shielded,
# because cutting them off costs a reload of the whole database: the database update, and a restore's emptying and
# loading of the database. While one runs, the signal is ignored by this script and by what it starts, and the
# script stops when the step is through. If the platform kills the container first, the next start finds the
# cut-off as after any kill.

# uncount: takes this run's attempt off the counter again.
uncount() {
    local count
    [ "$COUNTED" = 1 ] || return 0
    count="$(attempts)"
    if [ "${count:-0}" -le 1 ]; then
        rm -f -- "$ATTEMPTS_FILE"
    else
        printf 'build=%s\ncount=%s\n' "$BUILD" "$((count - 1))" | ls_write_file "$ATTEMPTS_FILE" 2>/dev/null || :
    fi
    COUNTED=0
}
stop_now() {
    # A clean stop is no failed attempt.
    uncount
    ls_up_log "stopped: the container was asked to stop, so the upgrade ends here. The next start goes on from the" \
        "state file, and this attempt is not counted."
    exit 143
}
shield_on() { trap '' TERM INT WINCH; }
shield_off() {
    trap stop_now TERM INT WINCH
    [ ! -e "$LS_STOP_FLAG" ] || stop_now
}
trap stop_now TERM INT WINCH

# --- the state file -------------------------------------------------------------------------------------------------

# put FILE TEXT: writes TEXT to FILE in one step, synced. On a full volume the upgrade's reserve file goes and the
# write is tried once more. Status 1 when FILE could not be written; it is then as it was.
put() {
    printf '%s' "$2" | ls_write_file "$1" 2>/dev/null && return 0
    [ -n "$DIR" ] && [ -f "$DIR/reserve" ] || return 1
    rm -f -- "$DIR/reserve"
    printf '%s' "$2" | ls_write_file "$1" 2>/dev/null
}

# reserve_make: the reserve file, when it is missing and there is room for it. It holds random bytes, so no
# filesystem can store it in less.
reserve_make() {
    [ -n "$DIR" ] && [ ! -e "$DIR/reserve" ] || return 0
    (umask 077 && head -c 262144 /dev/urandom > "$DIR/reserve") 2>/dev/null || rm -f -- "$DIR/reserve"
    return 0
}

# state_get KEY: a value of the state file, nothing when it has none.
state_get() {
    sed -n "s/^$1=//p" "$DIR/state" 2>/dev/null | head -n 1
}

# state_set KEY=VALUE...: changes values of the state file, in one step, and reads them back. Status 1 when the
# file could not be written. The caller then stops before it changes anything else.
state_set() {
    local pair key line text=""
    for pair in "$@"; do text="$text$pair"$'\n'; done
    if [ -f "$DIR/state" ]; then
        while IFS= read -r line; do
            key="${line%%=*}"
            for pair in "$@"; do
                [ "${pair%%=*}" = "$key" ] && continue 2
            done
            text="$text$line"$'\n'
        done < "$DIR/state"
    fi
    put "$DIR/state" "$text" || return 1
    for pair in "$@"; do
        [ "$(state_get "${pair%%=*}")" = "${pair#*=}" ] || return 1
    done
}

# attempts: how many times this build has started to change the site here.
attempts() {
    local count=""
    if ls_trusted "$ATTEMPTS_FILE" &&
        [ "$(sed -n 's/^build=//p' "$ATTEMPTS_FILE" 2>/dev/null | head -n 1)" = "$BUILD" ]; then
        count="$(sed -n 's/^count=\([0-9]\{1,\}\)$/\1/p' "$ATTEMPTS_FILE" | head -n 1)"
    fi
    echo "${count:-0}"
}

# attempts_reason: why the counter is full when no attempt of this start failed: the starts were cut off, or
# go-back.sh filled it so that the old version is put back and stays.
attempts_reason() {
    local reason=""
    ls_trusted "$ATTEMPTS_FILE" && reason="$(sed -n 's/^reason=//p' "$ATTEMPTS_FILE" | head -n 1 | cut -c1-200)"
    printf '%s' "${reason:-the upgrade was cut off twice}"
}

# failed MSG...: the line staff and alerts look for.
failed() {
    local IFS=' '
    REASON="$*"
    ls_up_log "FAILED limesurvey $FROM -> $TO: $*"
}

# redact TEXT: one line of a program's output for the log, cut to 300 characters, with quoted text taken out: a
# database error can quote a value, and an answer is never written to a log.
redact() {
    printf '%s' "$1" | head -n 1 | cut -c1-300 | sed "s/'[^']*'/'...'/g; s/\"[^\"]*\"/\"...\"/g"
}

# drop_backup: the upgrade's folder goes, the state file first, so that a kill halfway leaves a folder that says
# nothing. Only called when the site is whole on the old version and the database is as it was.
drop_backup() {
    [ -n "$DIR" ] || return 0
    rm -f -- "$DIR/state"
    rm -rf -- "$DIR"
    DIR=""
}

# skip: the upgrade is not tried at this start. Nothing in the site was changed. A note says why, for staff and for
# the AI Assistant. It never stops the next start from trying.
skip() {
    printf 'from=%s\nto=%s\nbuild=%s\nwhen=%s\nreason=%s\n' "$FROM" "$TO" "$BUILD" "$(ls_now)" "${REASON:-unknown}" |
        ls_write_file "$SKIPPED_FILE" 2>/dev/null ||
        ls_warn "the note $(here "$SKIPPED_FILE") could not be written"
    ls_up_log "skipped: the upgrade was not tried at this start, and nothing was changed. LimeSurvey $FROM keeps" \
        "running. The next start checks again. The reason is also in $(here "$SKIPPED_FILE")."
    exit 10
}

# --- the backup -----------------------------------------------------------------------------------------------------

# enough_space [dump]: whether the code volume has the space and the inodes for the new code beside the old, and
# with "dump" for the database dump too. The database's own disk is another volume, which this container can't
# measure, so the size of the response tables is logged.
enough_space() {
    local need_kb need_in free_kb free_in total_in db_kb=0 resp_kb
    need_kb="$(ls_package_stat kb)"
    need_in="$(ls_package_stat entries)"
    free_kb="$(df -Pk "$LS_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')"
    read -r total_in free_in <<< "$(df -Pi "$LS_ROOT" 2>/dev/null | awk 'NR == 2 {print $2, $4}')"
    if [ "${1:-}" = dump ]; then
        db_kb="$(ls_sql "SELECT CEIL(COALESCE(SUM(data_length + index_length), 0) / 1024) FROM information_schema.tables
            WHERE table_schema = DATABASE()" 2>/dev/null)"
        resp_kb="$(ls_sql "SELECT CEIL(COALESCE(SUM(data_length + index_length), 0) / 1024) FROM information_schema.tables
            WHERE table_schema = DATABASE() AND table_name REGEXP '^$(ls_table '')(old_)?survey_[0-9]'" 2>/dev/null)"
        ls_up_log "backup: the response tables hold $(( ${resp_kb:-0} / 1024 )) MB. The update copies each of them once, on the database's own disk"
    fi
    case "$need_kb$free_kb$db_kb" in
        '' | *[!0-9]*) ls_warn "the free space on the code volume could not be measured, so the upgrade goes on"; return 0 ;;
    esac
    # The new code, the dump (at most the size of the tables) and a tenth more.
    need_kb=$(( (need_kb + db_kb) * 11 / 10 ))
    if [ "$free_kb" -lt "$need_kb" ]; then
        failed "the code volume has $((free_kb / 1024)) MB free and the upgrade needs about $((need_kb / 1024)) MB" \
            "(the new code beside the old code, and the database dump). Nothing was changed."
        return 1
    fi
    # One inode for every file and folder of the new code, and a tenth more. A filesystem that counts no inodes
    # reports a total of 0.
    case "$need_in${total_in:-}${free_in:-}" in
        '' | *[!0-9]*) return 0 ;;
    esac
    need_in=$(( need_in * 11 / 10 + 100 ))
    if [ "$total_in" -gt 0 ] && [ "$free_in" -lt "$need_in" ]; then
        failed "the code volume has $free_in free inodes and the upgrade needs about $need_in (one for every file and" \
            "folder of the new code). Nothing was changed. Old cache files under tmp/ are the usual cause."
        return 1
    fi
}

# backup: the folder, the state file, the list of active plugins and a checked database dump. Status 1 when it fails;
# nothing in the site has changed then.
backup() {
    local tables creates err other
    DIR="upgrade-$FROM-to-$TO"
    if [ -e "$DIR" ] || [ -L "$DIR" ]; then
        # What an earlier upgrade of the same versions left. A failed one was restored and checked, so its dump is
        # the database as it is now, or older, and a folder without a state file says nothing. Anything else is
        # kept under another name.
        if ls_trusted "$DIR" && [ -d "$DIR" ] && { [ ! -e "$DIR/state" ] || [ "$(state_get phase)" = failed ]; }; then
            rm -rf -- "$DIR" || { failed "cannot remove the earlier $(here "$DIR")"; DIR=""; return 1; }
        else
            mv -T -- "$DIR" "$DIR.$(date -u +%Y%m%d%H%M%S)" || { failed "cannot move the earlier $(here "$DIR") aside"; DIR=""; return 1; }
        fi
    fi
    mkdir -m 700 -- "$DIR" || { failed "cannot make $(here "$DIR")"; DIR=""; return 1; }
    state_set "phase=backup" "from=$FROM" "from_db=$FROM_DB" "to=$TO" "to_db=$TO_DB" "build=$BUILD" \
        "started=$(ls_now)" || { failed "cannot write $(here "$DIR/state")"; return 1; }
    reserve_make
    ls_up_log "backup: limesurvey $FROM -> $TO: saving the database to $(here "$DIR/db.sql.gz")"
    # The added plugins that are on. The update switches every one of them off.
    ls_sql "SELECT name FROM \`$(ls_table plugins)\` WHERE active = 1 AND plugin_type <> 'core' ORDER BY name" 2>/dev/null |
        ls_write_file "$DIR/active-plugins" || { failed "cannot write $(here "$DIR/active-plugins")"; return 1; }
    tables="$(ls_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'")"
    # Nothing writes to the database now: Apache is not up. The dump is written under another name first. What the
    # client says goes into a variable: a file for it could not be written on the full volume it would report.
    err="$(
        set -o pipefail
        umask 077
        { MYSQL_PWD="${DB_PASSWORD:-}" MYSQL_TCP_PORT="${DB_PORT:-3306}" mariadb-dump -h "$DB_HOST" -u "$DB_USERNAME" \
            --single-transaction --routines --triggers "$DB_NAME" | gzip > "$DIR/db.sql.gz.partial"; } 2>&1
    )" || { failed "the database dump failed: $(redact "$err")"; return 1; }
    ls_test_pause backup
    # The dump is whole: gzip's own check, mariadb-dump's last line, and one CREATE TABLE for every table.
    if ! gzip -t "$DIR/db.sql.gz.partial" 2>/dev/null; then
        failed "the database dump is not a whole gzip file"; return 1
    fi
    if ! gzip -dc "$DIR/db.sql.gz.partial" | tail -n 1 | grep -q '^-- Dump completed'; then
        failed "the database dump does not end with mariadb-dump's last line"; return 1
    fi
    creates="$(gzip -dc "$DIR/db.sql.gz.partial" | grep -c '^CREATE TABLE ')"
    if [ -z "$tables" ] || [ "$creates" != "$tables" ]; then
        failed "the database dump holds $creates tables and the database has ${tables:-an unknown number}"; return 1
    fi
    if ! sync -- "$DIR/db.sql.gz.partial" || ! mv -- "$DIR/db.sql.gz.partial" "$DIR/db.sql.gz"; then
        failed "the database dump could not be put in place"; return 1
    fi
    printf 'sha256=%s\ntables=%s\ndbversion=%s\ncode=%s\ncompleted=%s\n' \
        "$(sha256sum "$DIR/db.sql.gz" | cut -d' ' -f1)" "$tables" "$(ls_db_version)" "$FROM" "$(ls_now)" |
        ls_write_file "$DIR/backup-complete" || { failed "cannot write $(here "$DIR/backup-complete")"; return 1; }
    ls_up_log "backup: complete ($tables tables, $(du -k "$DIR/db.sql.gz" | cut -f1) KB)"
    # One backup is kept: with this one complete, the folders of earlier upgrades go.
    for other in upgrade-*-to-*; do
        [ -d "$other" ] && [ ! -L "$other" ] && [ "$other" != "$DIR" ] || continue
        rm -rf -- "$other" && ls_up_log "backup: removed the earlier backup $(here "$other")"
    done
    return 0
}

# backup_whole: whether the folder holds the dump that was stamped complete.
backup_whole() {
    local want
    ls_trusted "$DIR/backup-complete" && ls_trusted "$DIR/db.sql.gz" && [ -f "$DIR/backup-complete" ] &&
        [ -f "$DIR/db.sql.gz" ] || return 1
    want="$(sed -n 's/^sha256=//p' "$DIR/backup-complete" | head -n 1)"
    [ -n "$want" ] && [ "$(sha256sum "$DIR/db.sql.gz" | cut -d' ' -f1)" = "$want" ] && gzip -t "$DIR/db.sql.gz" 2>/dev/null
}

# --- the upgrade ----------------------------------------------------------------------------------------------------

# target_in_place: the success test. The code on the volume and the database are both at the version the upgrade
# goes to, and the database has no mark of an update that failed.
target_in_place() {
    local ver db
    [ -n "$TO" ] && [ -n "$TO_DB" ] || return 1
    read -r ver db _ <<< "$(ls_version "$LS_ROOT")"
    [ "${ver:-}" = "$TO" ] && [ "${db:-}" = "$TO_DB" ] && [ "$(ls_db_version)" = "$TO_DB" ] &&
        [ -z "$(ls_db_setting DBUpdateIncomplete)" ]
}

# unchanged MSG...: an attempt could not even begin, because the volume takes no write. The site is whole on the
# old version and the database is as it was, so the backup goes and the upgrade is skipped at this start.
unchanged() {
    failed "$@"
    uncount
    drop_backup
    skip
}

# stash_keep: www-data's copy, in the web root, of what belongs to the install and not to the release: config.php,
# security.php, allowed_hosts.php and the plugins an admin added. Root never copies a file out of the old code: a
# link planted there would make it read for www-data what www-data may not read.
stash_keep() {
    # shellcheck disable=SC2016  # the script is for the bash that ls_www starts
    ls_www bash -c '
        root="$1" keep="$2" package="$3"
        rm -rf -- "$keep" && mkdir -m 700 -- "$keep" "$keep/config" "$keep/plugins" || exit 1
        for file in config.php security.php allowed_hosts.php; do
            if [ -f "$root/application/config/$file" ] && [ ! -L "$root/application/config/$file" ]; then
                cp -p -- "$root/application/config/$file" "$keep/config/$file" || exit 1
            fi
        done
        for plugin in "$root/plugins"/*/; do
            [ -d "$plugin" ] && [ ! -L "${plugin%/}" ] || continue
            name="$(basename "$plugin")"
            if [ ! -e "$package/plugins/$name" ]; then
                cp -a -- "${plugin%/}" "$keep/plugins/$name" || exit 1
            fi
        done' _ "$LS_ROOT" "$KEEP" "$LS_PACKAGE"
}

# unstash_keep: puts stash_keep's files into the new code, as www-data, and prints the names of the plugins.
unstash_keep() {
    # shellcheck disable=SC2016  # the script is for the bash that ls_www starts
    ls_www bash -c '
        root="$1" keep="$2"
        for file in config.php security.php allowed_hosts.php; do
            if [ -f "$keep/config/$file" ]; then
                install -m 600 -- "$keep/config/$file" "$root/application/config/$file" || exit 1
            fi
        done
        for plugin in "$keep/plugins"/*/; do
            [ -d "$plugin" ] || continue
            name="$(basename "$plugin")"
            cp -aT -- "${plugin%/}" "$root/plugins/$name" || exit 1
            printf "%s\n" "$name"
        done
        rm -rf -- "$keep"' _ "$LS_ROOT" "$KEEP"
}

# upgrade: from a complete backup to the new version. Status 1 when a step fails (REASON says which); the caller
# then puts the old version back.
upgrade() {
    local name file out rc=0 count maint kept
    count="$(attempts)"
    # The attempt counts from here: the next lines are the first that change the site.
    put "$ATTEMPTS_FILE" "build=$BUILD"$'\n'"count=$((count + 1))"$'\n' ||
        unchanged "$(here "$ATTEMPTS_FILE") can't be written (is the code volume full?), so the upgrade was not started"
    COUNTED=1
    state_set "phase=upgrade" "step=moving" "to=$TO" "to_db=$TO_DB" "build=$BUILD" ||
        unchanged "$(here "$DIR/state") can't be written (is the code volume full?), so the upgrade was not started"
    rm -f -- "$SKIPPED_FILE"
    ls_up_log "upgrade: limesurvey $FROM -> $TO, attempt $((count + 1)) of $MAX_ATTEMPTS (image build $BUILD)"
    ls_up_log "upgrade: moving the LimeSurvey $FROM code into $(here "$DIR/code")"
    for file in config.php security.php; do
        if [ ! -f "$LS_ROOT/application/config/$file" ]; then
            failed "the install has no application/config/$file"; return 1
        fi
    done
    stash_keep || { failed "the install's own files (config.php, security.php, added plugins) could not be set aside"; return 1; }
    [ -d "$DIR/code" ] || mkdir -m 700 -- "$DIR/code" || { failed "cannot make $(here "$DIR/code")"; return 1; }
    while IFS= read -r name; do
        if [ -e "$LS_ROOT/$name" ] || [ -L "$LS_ROOT/$name" ]; then
            mv -T -- "$LS_ROOT/$name" "$DIR/code/$name" || { failed "cannot move $name aside"; return 1; }
        fi
    done < <(ls_package_names)
    ls_test_pause upgrade-move

    state_set "step=copying" || { failed "$(here "$DIR/state") can't be written, so the new code was not copied"; return 1; }
    ls_up_log "upgrade: copying LimeSurvey $TO onto the volume"
    ls_copy_package || { failed "the copy of the new code failed (a full code volume is the usual cause)"; return 1; }
    # What belongs to the install, not to the release.
    kept="$(unstash_keep)" || { failed "cannot put config.php, security.php or an added plugin back"; return 1; }
    while IFS= read -r name; do
        [ -n "$name" ] && ls_up_log "upgrade: kept the added plugin plugins/$name"
    done <<< "$kept"
    ls_upload_skeleton || { failed "the upload volume could not be given the package's skeleton"; return 1; }
    ls_test_pause upgrade-copy

    # From here the upgrade writes to the database. The marker is on the disk first: a restore loads the dump only
    # when it is there, and never because of what a state file says.
    maint="$(ls_db_setting maintenancemode)"
    case "$maint" in soft | hard) ;; *) maint=off ;; esac
    state_set "step=updating" "maint=$maint" ||
        { failed "$(here "$DIR/state") can't be written, so the database update was not started"; return 1; }
    put "$DIR/db-touched" "since=$(ls_now)"$'\n' ||
        { failed "$(here "$DIR/db-touched") can't be written, so the database update was not started"; return 1; }
    # A stop request doesn't reach the update: see "a stop request" above.
    shield_on
    # hard-cli also locks the admin pages, RemoteControl and the REST API until it is switched off from here.
    ls_console_shielded setmaintenancemode hard-cli >/dev/null 2>&1 ||
        ls_warn "LimeSurvey's maintenance mode could not be switched on. Apache is not up, so the update goes on."
    ls_up_log "upgrade: updating the database from version $FROM_DB to $TO_DB"
    ls_test_pause updatedb shielded
    out="$(ls_console_shielded updatedb 2>&1)" || rc=$?
    printf '%s\n' "$out" | ls_write_file "$DIR/updatedb.log" 2>/dev/null ||
        ls_warn "what the database update printed could not be saved to $(here "$DIR/updatedb.log")"
    shield_off
    ls_test_pause upgrade-updatedb
    if [ "$rc" -ne 0 ]; then
        failed "console.php updatedb ended with status $rc: $(redact "$(printf '%s\n' "$out" | grep -m1 -E 'Exception|rror' || printf '%s' "$out")")." \
            "Its full output is in $(here "$DIR/updatedb.log")"
        return 1
    fi
    if ! target_in_place; then
        failed "console.php updatedb ended with status 0, but the database is at version '$(ls_db_version)', not $TO_DB," \
            "or has a DBUpdateIncomplete row"
        return 1
    fi
    finish
}

# not_closed: the upgrade is complete, but the state file could not be made to say so. Nothing is started: a later
# start would otherwise take a site that has run since for an upgrade that was cut off.
not_closed() {
    ls_attention "$FROM" "$TO" "$(here "$DIR/state") can't be written (is the code volume full?). The" \
        "upgrade itself is complete, and the next start only has to record that. Free some space on the code volume," \
        "then restart the container."
    exit 20
}

# finish: what follows a database update that succeeded. Every step can run twice. It returns only when the state
# says done.
finish() {
    local name left="" maint
    state_set "step=finishing" || not_closed
    if ls_trusted "$DIR/active-plugins"; then
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            if [ "$name" = SuiteCRMIntegration ]; then
                # The update switches every added plugin off. Clouve's own was on before, so it goes back on.
                if ls_sql "UPDATE \`$(ls_table plugins)\` SET active = 1 WHERE name = 'SuiteCRMIntegration'"; then
                    ls_up_log "upgrade: the SuiteCRM plugin was on before the update and is on again"
                else
                    ls_warn "the SuiteCRM plugin could not be switched back on"
                fi
            else
                left="$left${left:+, }$name"
            fi
        done < "$DIR/active-plugins"
    fi
    if [ -n "$left" ]; then
        printf '%s\n' "$left" | tr -d ' ' | tr ',' '\n' | ls_write_file "$DIR/plugins-left-off" 2>/dev/null || :
        ls_up_log "upgrade: left off: $left. LimeSurvey's update switches every added plugin off. Switch each one on" \
            "again in the plugin manager once it supports LimeSurvey ${TO%%.*}. The list is in $(here "$DIR/plugins-left-off")"
    fi
    # Maintenance mode goes back to what the admin had chosen before the upgrade.
    maint="$(state_get maint)"
    case "$maint" in soft | hard) ls_up_log "upgrade: maintenance mode is '$maint' again, as it was before the upgrade" ;; *) maint=off ;; esac
    ls_console setmaintenancemode "$maint" >/dev/null 2>&1 ||
        ls_warn "LimeSurvey's maintenance mode could not be set back to '$maint'"
    ls_console flushassets >/dev/null 2>&1 || ls_warn "LimeSurvey's asset caches could not be flushed"
    printf '%s+%s upgraded from %s %s\n' "$TO" "$(ls_version "$LS_ROOT" | cut -d' ' -f3)" "$FROM" "$(ls_now)" |
        ls_write_file version 2>/dev/null || :
    state_set "phase=done" "finished=$(ls_now)" || not_closed
    # Only now: until the state says done, the marker is what makes a restore load the dump.
    rm -f -- "$ATTEMPTS_FILE" "$FAILED_FILE" "$SKIPPED_FILE" "$DIR/db-touched" "$DIR/reserve"
    ls_up_log "done: limesurvey $FROM -> $TO in $((SECONDS - STARTED)) s. The old code and the database dump stay" \
        "in $(here "$DIR") until someone removes the folder."
}

# --- the way back ---------------------------------------------------------------------------------------------------

# database_as_backed_up: whether the database has the table count and the version that backup-complete recorded,
# and no mark of an update that failed.
database_as_backed_up() {
    local got
    ls_trusted "$DIR/backup-complete" || return 1
    got="$(ls_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'")"
    [ -n "$got" ] && [ "$got" = "$(sed -n 's/^tables=//p' "$DIR/backup-complete" | head -n 1)" ] &&
        [ "$(ls_db_version)" = "$(sed -n 's/^dbversion=//p' "$DIR/backup-complete" | head -n 1)" ] &&
        [ -z "$(ls_db_setting DBUpdateIncomplete)" ]
}

# database_at_old_version: whether the database is at the version it had when the backup was made, with no mark of
# an update that failed. Asked up to three times, so that one lost connection doesn't decide it.
database_at_old_version() {
    local want try
    ls_trusted "$DIR/backup-complete" || return 1
    want="$(sed -n 's/^dbversion=//p' "$DIR/backup-complete" | head -n 1)"
    for try in 1 2 3; do
        if [ -n "$want" ] && [ "$(ls_db_version)" = "$want" ] && [ -z "$(ls_db_setting DBUpdateIncomplete)" ]; then
            return 0
        fi
        [ "$try" = 3 ] || sleep 2
    done
    return 1
}

# restore_failed MSG...: a restore that can't go on. The state is kept, and nothing may be started.
restore_failed() {
    ls_attention "$FROM" "$TO" "$@"
}

# restore: the old version, from a complete backup: the database from the dump when the upgrade wrote to it, then
# the code. Status 1 when a step or a check fails. The state is kept then, nothing may be started, and the caller
# ends with status 20.
#
# The database is loaded only when db-touched is there. The upgrade writes and syncs that marker before its first
# write to the database, so without it nothing of ours has changed the database: it is left alone whatever else is
# found, and tables are never dropped. When the dump is damaged or no longer matches the database in that case, the
# way back doesn't need it. The code goes back, the folder goes, and the caller makes a new backup.
restore() {
    local rstep name entry ver err rc names=() stale=0
    # The plan, from what is on the disk. It stays in this variable from here on and is never read back from a
    # state file that may not have been written.
    if [ "$(state_get phase)" = restore ]; then
        rstep="$(state_get rstep)"
    else
        # While the old code was still being moved aside, nothing new was copied: the entries only go back. From the
        # copy on, every entry on the volume with a package name is new code, and goes first.
        case "$(state_get step)" in
            moving) rstep=moving-back ;;
            *) rstep=removing-new ;;
        esac
    fi
    case "$rstep" in moving-back | removing-new) ;; *) rstep=removing-new ;; esac
    ls_up_log "restore: putting LimeSurvey $FROM back from $(here "$DIR")"

    if [ -e "$DIR/db-touched" ] || [ -L "$DIR/db-touched" ]; then
        # The upgrade wrote to the database. Nothing is changed before the state says restore.
        if [ "$(state_get phase)" != restore ] && ! state_set "phase=restore" "rstep=$rstep"; then
            restore_failed "$(here "$DIR/state") can't be written (is the code volume full?), so the restore was not" \
                "started. The database and the code are as the upgrade left them. Free some space on the code volume," \
                "then restart the container."
            return 1
        fi
        if ! backup_whole; then
            restore_failed "$(here "$DIR/db.sql.gz") is not the backup that was stamped complete, so" \
                "nothing is loaded over the database. The state is kept."
            return 1
        fi
        # Emptied first, because the update made tables that the dump doesn't know. The emptying and the load run in
        # a session of their own, and what the client says goes into a variable, not into a file on a volume that
        # may be full.
        shield_on
        rc=0
        # shellcheck disable=SC2016  # the script is for the bash that setsid starts
        err="$(setsid -w bash -c '
            . "$1" || exit 4
            ls_drop_all_tables || exit 3
            set -o pipefail
            gzip -dc "$2" | ls_mysql "$DB_NAME"' _ "$LS_INSTALLER/lib.sh" "$DIR/db.sql.gz" 2>&1)" || rc=$?
        if [ "$rc" -eq 3 ]; then
            restore_failed "the restore could not empty the database: $(redact "$err")"
            return 1
        elif [ "$rc" -ne 0 ]; then
            restore_failed "the restore could not load the dump: $(redact "$err")"
            return 1
        fi
        if ! database_as_backed_up; then
            restore_failed "after the restore the database is at version" \
                "'$(ls_db_version)' and doesn't have the tables the backup recorded"
            return 1
        fi
        # The database is the dump again. Without the marker, a restore that runs again leaves it alone.
        rm -f -- "$DIR/db-touched"
        sync -- "$DIR" 2>/dev/null || :
        ls_up_log "restore: the database is as it was before the upgrade (loaded from the dump)"
        shield_off
    else
        # The marker is the image's own word that the database was not changed. The database's own word counts as
        # well: it has to be at the old version. If it is not (the marker was removed by hand, or the state folder
        # is not the one this upgrade wrote), the old code must not be started on it.
        if ! database_at_old_version; then
            restore_failed "the database is at version '$(ls_db_version)', not at the version it had before the upgrade, or" \
                "it has a DBUpdateIncomplete row, and $(here "$DIR/db-touched") is not there, so the image loads nothing" \
                "over it. Put the database back from a backup taken before the upgrade, then restart the container."
            return 1
        fi
        if database_as_backed_up && backup_whole; then
            ls_up_log "restore: the database was not changed by the upgrade, so it stays as it is"
        else
            ls_up_log "restore: the database was not changed by the upgrade, so it stays as it is. The dump in" \
                "$(here "$DIR") no longer matches its stamp or the database, and the way back doesn't need it"
            stale=1
        fi
        if [ "$(state_get phase)" != restore ] && ! state_set "phase=restore" "rstep=$rstep"; then
            # The volume is full. When the state on the disk says the upgrade was moving or copying code, it already
            # asks for the very steps below, so they are safe to take without it, and removing the new code is
            # what frees the space. At any later step the state has to say restore first.
            case "$(state_get step)" in
                moving | copying)
                    ls_warn "$(here "$DIR/state") can't be written (is the code volume full?). The code is put back first"
                    ;;
                *)
                    restore_failed "$(here "$DIR/state") can't be written (is the code volume full?), so the restore" \
                        "was not started. The database and the code are as the upgrade left them. Free some space on" \
                        "the code volume, then restart the container."
                    return 1
                    ;;
            esac
        fi
    fi
    ls_test_pause restore

    # The code. First the new code goes, and the old entries are still all in code/, so their names are new code
    # on the volume too, whatever this image's package calls its own.
    if [ "$rstep" = removing-new ]; then
        if ls_trusted "$DIR/code" && [ -d "$DIR/code" ]; then
            while IFS= read -r -d '' entry; do names+=("$(basename "$entry")"); done < <(find "$DIR/code" -mindepth 1 -maxdepth 1 -print0)
        fi
        ls_www rm -rf -- "$KEEP"
        if ! ls_remove_package_names ${names[@]+"${names[@]}"}; then
            restore_failed "the restore could not remove the new code from the volume"
            return 1
        fi
        rstep=moving-back
        if ! state_set "phase=restore" "rstep=moving-back"; then
            restore_failed "$(here "$DIR/state") can't be written (is the code volume full?), so the old code was not" \
                "moved back. Free some space on the code volume, then restart the container."
            return 1
        fi
        reserve_make
    else
        ls_www rm -rf -- "$KEEP"
    fi
    if [ -e "$DIR/code" ] || [ -L "$DIR/code" ]; then
        if ! ls_trusted "$DIR/code" || [ ! -d "$DIR/code" ]; then
            restore_failed "$(here "$DIR/code") is not a folder of root's, so nothing is moved back from it"
            return 1
        fi
        while IFS= read -r -d '' entry; do
            name="$(basename "$entry")"
            if [ -e "$LS_ROOT/$name" ] || [ -L "$LS_ROOT/$name" ]; then
                restore_failed "the restore found $name both on the volume and in $(here "$DIR/code")"
                return 1
            fi
            mv -T -- "$entry" "$LS_ROOT/$name" || { restore_failed "the restore could not move $name back"; return 1; }
        done < <(find "$DIR/code" -mindepth 1 -maxdepth 1 -print0)
        rmdir -- "$DIR/code" 2>/dev/null || :
    fi
    read -r ver _ <<< "$(ls_version "$LS_ROOT")"
    if [ "${ver:-}" != "$FROM" ] || [ ! -f "$LS_ROOT/application/config/security.php" ]; then
        restore_failed "after the restore the code on the volume is '${ver:-none}', not $FROM"
        return 1
    fi
    ls_up_log "restore: LimeSurvey $FROM is back, with its database at version $(ls_db_version)"
    if [ "$stale" = 1 ]; then
        ls_up_log "restore: the folder $(here "$DIR") goes, and a new backup is made"
        drop_backup
    fi
    return 0
}

# give_up: the old version stays. Nothing tries again until clouve/upgrade-failed is gone or the build differs. The
# note is written first and the state after it: Apache never starts while the state says restore.
give_up() {
    if ! put "$FAILED_FILE" "$(printf 'build=%s\nfrom=%s\nto=%s\nwhen=%s\nbackup=%s\nreason=%s\n' "$BUILD" "$FROM" "$TO" \
        "$(ls_now)" "${DIR:+$(here "$DIR")}" "${REASON:-$(attempts_reason)}")"$'\n' ||
        { [ -n "$DIR" ] && [ -f "$DIR/state" ] && ! state_set "phase=failed" "failed=$(ls_now)"; }; then
        ls_attention "$FROM" "$TO" "gave up after $MAX_ATTEMPTS attempts, and LimeSurvey $FROM is back with" \
            "its data, but $(here "$FAILED_FILE") or the state file can't be written (is the code volume full?). Free" \
            "some space on the code volume, then restart the container."
        exit 20
    fi
    rm -f -- "$ATTEMPTS_FILE" "$SKIPPED_FILE"
    ls_up_log "FAILED limesurvey $FROM -> $TO: gave up after $MAX_ATTEMPTS attempts. LimeSurvey $FROM keeps running" \
        "with its data. No start tries again until $(here "$FAILED_FILE") is removed or the image's build differs."
    exit 10
}

# --- what this start does ---------------------------------------------------------------------------------------------

# An upgrade that was cut off. Only a folder and a state file that are root's and no link count.
for state in upgrade-*-to-*/state; do
    ls_trusted "$state" && [ -f "$state" ] || continue
    case "$(sed -n 's/^phase=//p' "$state" | head -n 1)" in
        backup | upgrade | restore) DIR="$(dirname "$state")"; break ;;
    esac
done

if [ -n "$DIR" ]; then
    # The values are compared and printed, never run. Anything but a version's own characters is taken out.
    FROM="$(state_get from | tr -cd '0-9A-Za-z.+-')"
    FROM_DB="$(state_get from_db | tr -cd '0-9')"
    TO="$(state_get to | tr -cd '0-9A-Za-z.+-')"
    TO_DB="$(state_get to_db | tr -cd '0-9')"
    case "$(state_get phase)" in
        backup)
            ls_up_log "backup: the backup was cut off, and nothing in the site had changed. The partial backup goes and the upgrade starts again"
            drop_backup
            ;;
        upgrade)
            case "$(state_get step)" in
                updating | finishing)
                    # The copy of the code was complete. If the database update finished as well, the upgrade
                    # succeeded, whatever this image's package is, and it is never undone.
                    if target_in_place; then
                        ls_up_log "upgrade: the upgrade was cut off, but the database update had finished: finishing it off"
                        finish
                        if [ "$TO" = "$PKG_VER" ] && [ "$TO_DB" = "$PKG_DB" ]; then
                            exit 0
                        fi
                        ls_up_log "upgrade: that upgrade went to LimeSurvey $TO and this image holds $PKG_VER, so the start looks at the site again"
                        exit 11
                    fi
                    ;;
            esac
            ls_up_log "upgrade: the upgrade was cut off at the step '$(state_get step)'"
            restore || exit 20
            ;;
        restore)
            ls_up_log "restore: the restore was cut off"
            restore || exit 20
            ;;
    esac
    if [ "$TO" != "$PKG_VER" ] || [ "$TO_DB" != "$PKG_DB" ]; then
        # The upgrade that was cut off went to another version than this image's. The old version is back and the
        # database is as the dump has it, so the folder goes and site.sh decides anew what this image does.
        ls_up_log "upgrade: that upgrade went to LimeSurvey ${TO:-?} and this image holds $PKG_VER, so the start looks at the site again"
        drop_backup
        exit 11
    fi
fi

if [ -z "$FROM" ]; then
    read -r FROM FROM_DB _ <<< "$(ls_version "$LS_ROOT")"
fi
if [ -z "${FROM:-}" ]; then
    ls_error "the volume has no LimeSurvey code to upgrade"
    exit 1
fi
TO="$PKG_VER"
TO_DB="$PKG_DB"

while :; do
    if [ "$(attempts)" -ge "$MAX_ATTEMPTS" ]; then
        give_up
    fi
    # Too little space is no attempt: nothing was changed, and the next start checks again. A backup that is
    # already there (the old version was just put back) is not needed then.
    if [ -z "$DIR" ]; then
        enough_space dump || skip
        if ! backup; then
            # Nothing in the site has changed. The partial backup goes.
            drop_backup
            skip
        fi
    elif ! enough_space; then
        drop_backup
        skip
    fi
    if upgrade; then
        exit 0
    fi
    restore || exit 20
done
