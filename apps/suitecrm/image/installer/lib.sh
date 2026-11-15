#!/bin/bash
# Shared shell functions of the SuiteCRM image: logging, versions, the memory limit and Apache's worker limit,
# the new-disk claim, the database (an options file, never a command line), the state folder and the upgrade's
# state file, the install stamp, the stand-in for the health check, and the test-only pause.
#
# Source this file, don't run it. It defines functions and variables and changes no shell option. entrypoint.sh,
# install.sh, upgrade.sh, loops.sh and release-scheduler.sh source it.
#
# Three rules run through all of it:
#   - SuiteCRM's whole tree is www-data's, tmp/ included. Whatever writes there, or runs SuiteCRM's PHP or a
#     file www-data can write, runs as www-data (sc_as_www). Root reads text only. Root itself changes the tree
#     in two places, both in upgrade.sh: it renames the customer's upload folders out of SuiteCRM's reach and
#     back, and a way back removes the upgraded code as root, so that a file of root's can't stop it.
#   - Root's own files are the state folder (tmp/clouve-backup), the install stamp and /run/clouve. www-data
#     owns tmp/, so it can rename the state folder and put another in its place. Root therefore reads the
#     folder only when it is a real folder of root's that nobody else can write in (sc_state_dir_status), and
#     a file in it only when it is a plain file of root's (sc_state_has). Anything else at that name is moved
#     aside by the entrypoint, never adopted and never removed (sc_state_dir_vet).
#   - No password is on a command line, in the log or in a file others can read. The database clients get an
#     options file of mode 600 in /run/clouve, and PHP reads the environment.

SC_ROOT=/var/www/html
SC_PACKAGE=/clouve/suitecrm/app
SC_INSTALLER=/clouve/suitecrm/installer
SC_RUN=/run/clouve
SC_DB_CNF=$SC_RUN/db.cnf
SC_STATE_DIR=$SC_ROOT/tmp/clouve-backup
SC_STATE=$SC_STATE_DIR/state
# What else the state folder holds, each a plain file of root's unless it says otherwise:
#   aside/               a folder: the customer's upload folders while SuiteCRM's first upgrade command runs
#   upgrade-failed       why the upgrade failed twice (with phase=failed in the state file)
#   upgrade-skipped      why the last start did not try an upgrade
#   scheduler-held       while it exists the scheduler runs no job (the AI Assistant's restore writes it)
#   restore-in-progress  the AI Assistant's restore is under way: a start waits and neither loop runs
#   loops-paused         staff's own pause for both loops
#   needs-attention      why the container waits and starts no SuiteCRM, for the AI Assistant, which can't read
#                        the container's log (sc_attention_write). It is there only while the entrypoint waits.
SC_ASIDE=$SC_STATE_DIR/aside
SC_ATTENTION=$SC_STATE_DIR/needs-attention
SC_SKIPPED=$SC_STATE_DIR/upgrade-skipped
SC_SCHEDULER_HELD=$SC_STATE_DIR/scheduler-held
SC_RESTORE_MARKER=$SC_STATE_DIR/restore-in-progress
SC_LOOPS_PAUSED=$SC_STATE_DIR/loops-paused
SC_INSTALL_STAMP=$SC_ROOT/.clouve-install-in-progress
# Which page the stand-in shows (standin-router.php reads these two).
SC_STANDIN_RESTORING=/run/clouve-suitecrm-restoring
SC_STANDIN_ATTENTION=/run/clouve-suitecrm-attention

# sc_log MSG...: "[suitecrm] MSG" on stdout. sc_warn and sc_err write to stderr.
sc_log() { local IFS=' '; printf '[suitecrm] %s\n' "$*"; }
sc_warn() { local IFS=' '; printf '[suitecrm] WARNING: %s\n' "$*" >&2; }
sc_err() { local IFS=' '; printf '[suitecrm] ERROR: %s\n' "$*" >&2; }

# sc_as_www COMMAND...: runs a command as www-data, the owner of the install tree. setpriv becomes the command
# itself, so there is no process in between: the exit status and any signal are the command's own.
sc_as_www() { setpriv --reuid=www-data --regid=www-data --init-groups -- "$@"; }

# sc_sleep SECONDS: sleeps as a background command and waits for it, so that a signal the script has a trap for
# ends the wait at once. Bash runs a trap only between two commands.
sc_sleep() {
    sleep "$1" &
    wait "$!" 2>/dev/null
}

# sc_pause STEP: test-only. CLOUVE_TEST_PAUSE holds "step:seconds" pairs, separated by commas, and the script
# sleeps that long when it reaches a named step. The tests use it to kill the container at a known point and to
# make an upgrade outlast the health check's deadline. Nothing sets it in a deployment, and unset it does
# nothing.
sc_pause() {
    local step=$1 item seconds
    [ -n "${CLOUVE_TEST_PAUSE:-}" ] || return 0
    local IFS=,
    for item in $CLOUVE_TEST_PAUSE; do
        [ "${item%%:*}" = "$step" ] || continue
        seconds=${item#*:}
        case $seconds in '' | *[!0-9]*) continue ;; esac
        sc_log "test pause at $step for $seconds s"
        sc_sleep "$seconds"
    done
}

# --- versions ---------------------------------------------------------------------------------------------------

# sc_is_version TEXT: succeeds for a plain version such as 8.10.2.
sc_is_version() { [[ "$1" =~ ^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$ ]]; }

# sc_read_version FILE: the version in FILE (its first line, blanks removed), or nothing when FILE is not a plain
# file or holds something else.
sc_read_version() {
    local file=$1 line=''
    [ -f "$file" ] && [ ! -L "$file" ] || return 0
    IFS= read -r -n 40 line < "$file" 2>/dev/null || :
    line=${line//[[:space:]]/}
    if sc_is_version "$line"; then printf '%s\n' "$line"; fi
}

# sc_version_cmp A B: prints lt, eq or gt.
sc_version_cmp() {
    if [ "$1" = "$2" ]; then
        echo eq
    elif [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]; then
        echo lt
    else
        echo gt
    fi
}

# sc_image_version: SuiteCRM's version in this image. sc_image_build: this image's build id.
sc_image_version() { sc_read_version "$SC_PACKAGE/VERSION"; }
sc_image_build() {
    local build=''
    IFS= read -r -n 64 build < /clouve/suitecrm/BUILD 2>/dev/null || :
    printf '%s\n' "${build:-unknown}"
}

# sc_code_present: succeeds when the volume holds SuiteCRM's code, or part of it.
sc_code_present() {
    [ -e "$SC_ROOT/VERSION" ] || [ -e "$SC_ROOT/bin/console" ] || [ -e "$SC_ROOT/public/index.php" ] ||
        [ -e "$SC_ROOT/vendor" ] || [ -e "$SC_ROOT/public/legacy" ]
}

# sc_symfony_cache_drop: removes SuiteCRM's compiled cache (cache/prod and what else is in cache/), as www-data.
# The next console command or request compiles it again from the files on the volume. This is used instead of
# bin/console cache:clear wherever the cache has to be rebuilt for certain: cache:clear rebuilds nothing when
# the compiled container's file was written in the same second the command started (it takes the cache for one
# it has just built), so a change to a settings file made a moment earlier would not be compiled in. A cache
# that is a link becomes a real folder: find would not look behind the link, and the cache it points at would
# stay. Status 1 when something is left in cache/, with the first path that is left on standard output.
sc_symfony_cache_drop() {
    # shellcheck disable=SC2016  # $1 is for the inner bash
    sc_as_www bash -c '
        cd "$1" || exit 1
        if [ -L cache ] || { [ -e cache ] && [ ! -d cache ]; }; then rm -f -- cache || { echo cache; exit 1; }; fi
        mkdir -p cache || { echo cache; exit 1; }
        find cache -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2> /dev/null
        left=$(find cache -mindepth 1 -print -quit 2> /dev/null)
        if [ -n "$left" ]; then printf "%s\n" "$left"; exit 1; fi' _ "$SC_ROOT"
}

# --- memory and Apache's worker limit ------------------------------------------------------------------------------

# sc_memory_limit_mb: the container's memory limit in MB, or nothing when it has none. cgroup v2 keeps it in
# memory.max ("max" means none), cgroup v1 in memory/memory.limit_in_bytes (2^60 or more means none).
# SC_CGROUP_ROOT is for tests.
sc_memory_limit_mb() {
    local root=${SC_CGROUP_ROOT:-/sys/fs/cgroup} file value unlimited=1152921504606846976
    if [ -r "$root/memory.max" ]; then
        file=$root/memory.max
    elif [ -r "$root/memory/memory.limit_in_bytes" ]; then
        file=$root/memory/memory.limit_in_bytes
    else
        return 0
    fi
    value=$(cat "$file" 2>/dev/null) || return 0
    case $value in '' | *[!0-9]*) return 0 ;; esac
    if ! [ "$value" -lt "$unlimited" ] 2>/dev/null; then return 0; fi
    printf '%s\n' "$((10#$value / 1048576))"
}

# sc_apache_workers MEM_MB: Apache's MaxRequestWorkers for the memory limit. One worker holds 75 to 90 MB, and
# 450 MB stay free for the scheduler, the Messenger worker (256 MB at most), Apache's parent and sshd. So it is
# (limit - 450) / 90, at least 4 and at most 150: 6 at the Customer Kit's 1 GB, 17 at 2 GB. No limit gives
# Apache's own default of 150.
sc_apache_workers() {
    local mem=${1-} workers
    case $mem in '' | *[!0-9]*) echo 150; return 0 ;; esac
    [ "${#mem}" -le 9 ] || { echo 150; return 0; }
    workers=$(((10#$mem - 450) / 90))
    if [ "$workers" -lt 4 ]; then workers=4; fi
    if [ "$workers" -gt 150 ]; then workers=150; fi
    echo "$workers"
}

# --- the volume ---------------------------------------------------------------------------------------------------

# sc_claim_new_volume [DIR]: a new cluster disk's top folder is root's, mode 755, with lost+found in it, and
# www-data could make nothing there. When DIR (default the install root) is a folder of root's, it becomes
# www-data's. Only the folder itself changes, never anything in it, and a folder that already belongs to someone
# else is left as it is, so a working install is never touched. Status 1 when it could not be changed.
sc_claim_new_volume() {
    local dir=${1:-$SC_ROOT}
    if [ -L "$dir" ] || [ ! -d "$dir" ] || [ "$(stat -c %u -- "$dir" 2>/dev/null)" != 0 ]; then
        return 0
    fi
    if chown -h www-data:www-data -- "$dir"; then
        sc_log "$dir was root's, as on a new disk, so it is now www-data's"
        return 0
    fi
    sc_err "could not give $dir to www-data"
    return 1
}

# --- the database -------------------------------------------------------------------------------------------------

# sc_db_cnf: writes the options file the database clients read (host, port, user, password), mode 600, in
# /run/clouve, which only root can enter. The password is quoted the way an options file wants it.
sc_db_cnf() {
    local value
    install -d -m 700 "$SC_RUN" || return 1
    (
        umask 077
        value=${DATABASE_PASSWORD//\\/\\\\}
        value=${value//\"/\\\"}
        printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' \
            "$DATABASE_HOST" "${DATABASE_PORT:-3306}" "$DATABASE_USER" "$value" > "$SC_DB_CNF"
    ) || return 1
    chmod 600 "$SC_DB_CNF"
}

# sc_sql QUERY: runs a query as the app's database user, with no database selected, and prints the rows
# tab-separated without a header.
sc_sql() { mysql --defaults-extra-file="$SC_DB_CNF" --connect-timeout=10 -N -B -e "$1"; }

# sc_db_name_ok: the database name is used in SQL text, so it has to be a plain one.
sc_db_name_ok() { [[ "${DATABASE_NAME:-}" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }

# sc_table_count: how many tables and views the app's database holds. Status 1 when the database didn't answer.
sc_table_count() {
    sc_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME'"
}

# sc_base_table_count: the tables alone, which is what a dump writes CREATE TABLE for.
sc_base_table_count() {
    sc_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME' AND table_type = 'BASE TABLE'"
}

# sc_has_config_table: status 0 when the app's database has SuiteCRM's config table, 1 when it has none, 2 when
# the database didn't answer. Every SuiteCRM database has that table.
sc_has_config_table() {
    local has
    has=$(sc_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME' AND table_name = 'config'") || return 2
    [ "$has" = 1 ]
}

# sc_db_version: SuiteCRM's version as the database records it (config row info / suitecrm_version), or nothing.
# 8.10 writes the row as the last step of an install and of an upgrade; 8.9 has no such row. Status 1 when the
# database didn't answer.
sc_db_version() {
    local has value
    has=$(sc_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DATABASE_NAME' AND table_name = 'config'") || return 1
    [ "$has" = 1 ] || return 0
    value=$(sc_sql "SELECT value FROM \`$DATABASE_NAME\`.config WHERE category = 'info' AND name = 'suitecrm_version' LIMIT 1") || return 1
    value=${value//[[:space:]]/}
    if sc_is_version "$value"; then printf '%s\n' "$value"; fi
}

# --- the state folder and the upgrade's state file ------------------------------------------------------------------

# sc_state_dir_status: prints what is at tmp/clouve-backup:
#   absent     nothing
#   trusted    a real folder of root's that neither its group nor others can write in, in a real tmp/
#   untrusted  anything else: a link, a file, a folder of someone else's or one that others can write in, or
#              a tmp/ that is itself a link or a file
# Only root can make a folder of root's, and nobody else can put a file into one that only root can write in.
# The mode's other bits don't matter for that: a folder made inside tmp/, which has the set-group-ID bit on a
# volume this image installed, gets that bit too.
sc_state_dir_status() {
    local tmp=$SC_ROOT/tmp
    if [ -L "$tmp" ] || { [ -e "$tmp" ] && [ ! -d "$tmp" ]; }; then echo untrusted; return 0; fi
    if [ ! -e "$SC_STATE_DIR" ] && [ ! -L "$SC_STATE_DIR" ]; then echo absent; return 0; fi
    if [ -L "$SC_STATE_DIR" ] || [ ! -d "$SC_STATE_DIR" ] || [ "$(stat -c %u -- "$SC_STATE_DIR" 2> /dev/null)" != 0 ] ||
        [ -n "$(find "$SC_STATE_DIR" -maxdepth 0 -perm /g=w,o=w 2> /dev/null)" ]; then
        echo untrusted
        return 0
    fi
    echo trusted
}
sc_state_dir_trusted() { [ "$(sc_state_dir_status)" = trusted ]; }

# sc_untrusted_dirs: the folders an earlier sc_state_dir_vet moved aside, one per line.
sc_untrusted_dirs() {
    local dir
    for dir in "$SC_STATE_DIR".untrusted-*; do
        if [ -e "$dir" ] || [ -L "$dir" ]; then printf '%s\n' "$dir"; fi
    done
}

# sc_state_dir_vet: for the entrypoint, before anything reads the state. A trusted folder is closed to everyone
# but root (mode 700). An untrusted one is never read and never adopted: it is renamed to
# tmp/clouve-backup.untrusted-<UTC time>, and the log says how staff put it back after a look. It may hold the
# only backup of a site that an upgrade left half-way, and the customer's upload folders. Status 0 when the
# folder is absent or trusted, 1 when it was moved aside or could not be.
sc_state_dir_vet() {
    local aside n=0 owner
    case $(sc_state_dir_status) in
        absent) return 0 ;;
        trusted)
            [ "$(stat -c %a -- "$SC_STATE_DIR" 2> /dev/null)" = 700 ] || chmod 00700 -- "$SC_STATE_DIR"
            return 0
            ;;
    esac
    if [ ! -d "$SC_ROOT/tmp" ] || [ -L "$SC_ROOT/tmp" ]; then
        sc_err "$SC_ROOT/tmp is not a folder, so the state folder in it can't be read or kept. Make it a folder of www-data's again."
        return 1
    fi
    owner=$(stat -c %U -- "$SC_STATE_DIR" 2> /dev/null)
    aside=$SC_STATE_DIR.untrusted-$(date -u +%Y%m%dT%H%M%SZ)
    while [ -e "$aside" ] || [ -L "$aside" ]; do
        n=$((n + 1))
        aside=$SC_STATE_DIR.untrusted-$(date -u +%Y%m%dT%H%M%SZ)-$n
    done
    if ! mv -T -- "$SC_STATE_DIR" "$aside"; then
        sc_err "$SC_STATE_DIR is not a folder that only root can change, and it could not be moved aside"
        return 1
    fi
    sc_warn "$SC_STATE_DIR is not a folder that only root can change (it is ${owner:-someone else}'s), so nothing in it was read. It was moved to ${aside#"$SC_ROOT"/} and nothing in it was changed. It may hold the backup of an upgrade and the customer's upload folders, so don't remove it. To put it back: look at what is in it, then run, in $SC_ROOT/tmp: chown -hR root:root ${aside##*/} && chmod -R go= ${aside##*/} && mv ${aside##*/} clouve-backup (README.md, \"Staff runbook\")."
    return 1
}

# sc_state_dir_make: makes tmp/ (www-data's) and the state folder (root's, mode 700, without the set-group-ID
# bit that tmp/ hands down). Status 1 when something untrusted is in the way.
sc_state_dir_make() {
    case $(sc_state_dir_status) in
        trusted) return 0 ;;
        untrusted) return 1 ;;
    esac
    if [ ! -d "$SC_ROOT/tmp" ]; then
        sc_as_www mkdir "$SC_ROOT/tmp" || return 1
    fi
    mkdir -- "$SC_STATE_DIR" && chmod 00700 -- "$SC_STATE_DIR" && sc_state_dir_trusted
}

# sc_state_has NAME: succeeds when the trusted state folder holds NAME as a plain file of root's.
sc_state_has() {
    local file=$SC_STATE_DIR/$1
    sc_state_dir_trusted && [ -f "$file" ] && [ ! -L "$file" ] && [ "$(stat -c %u -- "$file" 2> /dev/null)" = 0 ]
}

# sc_state_get KEY: the value of KEY in the state file, or nothing.
sc_state_get() {
    local key=$1 line
    sc_state_has state || return 0
    while IFS= read -r line; do
        if [ "${line%%=*}" = "$key" ]; then printf '%s\n' "${line#*=}"; return 0; fi
    done < "$SC_STATE"
}

# sc_state_set KEY=VALUE...: writes the pairs into the state file, keeping the others. The new file is written
# next to the old one, checked (every pair is in it, and the phase is not lost), synced and renamed over it, and
# the folder is synced, so a start finds the old file or the new one, never half of one. Status 1, with the
# old file in place, when any of that fails: a full disk must not cost the phase.
sc_state_set() {
    local pair line keys tmp=$SC_STATE.new status had_phase=no
    sc_state_dir_make || return 1
    if [ -e "$SC_STATE" ] || [ -L "$SC_STATE" ]; then
        sc_state_has state || return 1
        if grep -q '^phase=' "$SC_STATE"; then had_phase=yes; fi
    fi
    rm -f -- "$tmp"
    # Every write is checked by hand: set -e does nothing in a function that is called before || or in an if.
    (
        umask 077
        keys=' '
        {
            for pair in "$@"; do
                printf '%s\n' "${pair//$'\n'/ }" || exit 1
                keys="$keys${pair%%=*} "
            done
            if [ -f "$SC_STATE" ]; then
                while IFS= read -r line; do
                    case $keys in *" ${line%%=*} "*) ;; *) printf '%s\n' "$line" || exit 1 ;; esac
                done < "$SC_STATE"
            fi
        } > "$tmp"
    )
    status=$?
    if [ "$status" -eq 0 ] && [ "$had_phase" = yes ] && ! grep -q '^phase=' "$tmp"; then status=1; fi
    if [ "$status" -eq 0 ]; then
        for pair in "$@"; do
            grep -qxF -- "${pair//$'\n'/ }" "$tmp" || status=1
        done
    fi
    if [ "$status" -ne 0 ]; then
        rm -f -- "$tmp"
        return 1
    fi
    sync "$tmp" 2> /dev/null || :
    mv -f -- "$tmp" "$SC_STATE" || return 1
    sync "$SC_STATE_DIR" 2> /dev/null || :
}

# sc_state_clear: no upgrade is under way any more.
sc_state_clear() {
    rm -f -- "$SC_STATE" "$SC_STATE.new"
    sync "$SC_STATE_DIR" 2> /dev/null || :
}

# sc_attention_write KIND FROM TO REASON...: the note that says why the container waits and starts no SuiteCRM:
# tmp/clouve-backup/needs-attention, root's, mode 600, with one key=value per line. The LimeSurvey image writes
# the same five keys to its clouve/needs-attention:
#   reason  what was found, in the words of the [clouve-upgrade] FAILED line (kind repair) or of the log line
#           about the restore (kind restore). It never holds a password.
#   since   when the wait began, in UTC
#   from    the version on the volume, as the FAILED line names it
#   to      this image's version
#   kind    repair: a person has to repair the site. restore: the AI Assistant's restore is under way.
# The file is written next to the old one and renamed over it, so a reader never sees half of it. While a state
# folder that was moved aside is on the volume and no state folder is there, none is made for the note, and the
# note is left out: staff put that folder back with mv, and a new folder of its name would turn that step into a
# move into it. The folder's own name then says why the container waits. Status 1 when no note was written.
sc_attention_write() {
    local kind=$1 from=$2 to=$3 tmp=$SC_ATTENTION.new IFS=' '
    shift 3
    if ! sc_state_dir_trusted; then
        [ -z "$(sc_untrusted_dirs)" ] || return 1
        sc_state_dir_make || return 1
    fi
    rm -f -- "$tmp"
    if (
        umask 077
        printf 'reason=%s\nsince=%s\nfrom=%s\nto=%s\nkind=%s\n' "${*//$'\n'/ }" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "${from//$'\n'/ }" "${to//$'\n'/ }" "$kind" > "$tmp"
    ) && mv -f -- "$tmp" "$SC_ATTENTION"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# sc_attention_clear: the wait is over, or a new start looks at the site anew. The note goes. A state folder that
# held nothing but the note goes with it, because a site that never upgraded has no state folder.
sc_attention_clear() {
    sc_state_dir_trusted || return 0
    rm -f -- "$SC_ATTENTION.new"
    if [ -e "$SC_ATTENTION" ] || [ -L "$SC_ATTENTION" ]; then
        rm -f -- "$SC_ATTENTION"
        rmdir -- "$SC_STATE_DIR" 2> /dev/null || :
    fi
}

# sc_backup_from_for TO: the version a complete backup in the state folder was made of, when the folder holds
# exactly one backup <version>-to-<TO> with a stamp, both root's. It prints nothing otherwise. upgrade.sh checks
# the backup's checksums before it uses it.
sc_backup_from_for() {
    local to=$1 dir from found='' n=0
    sc_state_dir_trusted || return 0
    for dir in "$SC_STATE_DIR"/*-to-"$to"; do
        [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(stat -c %u -- "$dir" 2> /dev/null)" = 0 ] || continue
        [ -f "$dir/complete" ] && [ ! -L "$dir/complete" ] && [ "$(stat -c %u -- "$dir/complete" 2> /dev/null)" = 0 ] || continue
        from=${dir##*/}
        from=${from%-to-"$to"}
        sc_is_version "$from" && [ "$(sc_version_cmp "$from" "$to")" = lt ] || continue
        found=$from
        n=$((n + 1))
    done
    if [ "$n" = 1 ]; then printf '%s\n' "$found"; fi
}

# --- the install stamp ------------------------------------------------------------------------------------------

# The stamp is there from the moment an install starts until it has finished. It names the database the install
# writes to. It is root's: www-data can't make one, so a file that is not root's is never taken for it.
# sc_install_stamp_write / sc_install_stamp_database (prints "host/name", or nothing without a stamp of root's).
# The stamp sits in www-data's top folder. So whatever has that name goes first, and the write then fails on
# anything that exists (set -C), a link included: root never writes through a link put there in between.
sc_install_stamp_write() {
    rm -f -- "$SC_INSTALL_STAMP" || return 1
    ( umask 077; set -C; printf 'database=%s/%s\nstarted=%s\n' "$DATABASE_HOST" "$DATABASE_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$SC_INSTALL_STAMP" )
}
sc_install_stamp_database() {
    local line
    [ -f "$SC_INSTALL_STAMP" ] && [ ! -L "$SC_INSTALL_STAMP" ] && [ "$(stat -c %u -- "$SC_INSTALL_STAMP")" = 0 ] || return 0
    while IFS= read -r line; do
        if [ "${line%%=*}" = database ]; then printf '%s\n' "${line#*=}"; return 0; fi
    done < "$SC_INSTALL_STAMP"
}

# --- the stand-in for the health check ----------------------------------------------------------------------------

# The platform's probe asks GET / on port 80 and restarts a container that doesn't answer for about 105 seconds.
# A database that starts slowly, an install or an upgrade on a network disk can take longer. From before the
# wait for the database until Apache starts, PHP's built-in server answers on port 80 with one router file
# from the image (standin-router.php): 200 for GET / and HEAD /, 503 for everything else, each with the header
# X-Clouve-Standin: suitecrm. It is not Apache, because stopping a temporary Apache signals every process in
# the container, sshd included. It runs as nobody, with only the right to bind a low port, and with an empty
# environment: it answers the network and needs none of the passwords. Where the container can't grant the
# right, it runs as root.
#
# sc_standin_start: starts it unless it runs already. sc_standin_stop: stops it by PID and waits until port 80
# is free, so that Apache can bind it. Both are called by entrypoint.sh, which is the stand-in's parent.
# sc_standin_page starting|restoring|attention: which page GET / shows.
SC_STANDIN_PID=''

sc_standin_page() {
    rm -f -- "$SC_STANDIN_RESTORING" "$SC_STANDIN_ATTENTION"
    case ${1:-} in
        restoring) : > "$SC_STANDIN_RESTORING" ;;
        attention) : > "$SC_STANDIN_ATTENTION" ;;
    esac
}

sc_port_open() { (exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null; }

sc_standin_answers() {
    local i
    for ((i = 0; i < 50; i++)); do
        kill -0 "$SC_STANDIN_PID" 2>/dev/null || return 1
        if sc_port_open; then return 0; fi
        sleep 0.1
    done
    return 1
}

sc_standin_start() {
    local as php
    [ -z "$SC_STANDIN_PID" ] || return 0
    php=$(command -v php) || return 1
    sc_standin_page starting
    if sc_port_open; then
        sc_warn "port 80 is taken already, so no stand-in was started"
        return 1
    fi
    for as in nobody root; do
        if [ "$as" = nobody ]; then
            setpriv --reuid=nobody --regid=nogroup --clear-groups --inh-caps=+net_bind_service \
                --ambient-caps=+net_bind_service -- \
                env -i "$php" -n -d display_errors=0 -d log_errors=0 -t /clouve/suitecrm/standin -S 0.0.0.0:80 \
                "$SC_INSTALLER/standin-router.php" > /dev/null 2>&1 &
        else
            env -i "$php" -n -d display_errors=0 -d log_errors=0 -t /clouve/suitecrm/standin -S 0.0.0.0:80 \
                "$SC_INSTALLER/standin-router.php" > /dev/null 2>&1 &
        fi
        SC_STANDIN_PID=$!
        if sc_standin_answers; then
            sc_log "the stand-in answers the health check on port 80 until Apache starts (pid $SC_STANDIN_PID, as $as)"
            return 0
        fi
        kill "$SC_STANDIN_PID" 2>/dev/null
        wait "$SC_STANDIN_PID" 2>/dev/null
        SC_STANDIN_PID=''
    done
    sc_warn "the stand-in could not start, so the health check gets no answer until Apache starts"
    return 1
}

sc_standin_stop() {
    local i
    [ -n "$SC_STANDIN_PID" ] || return 0
    kill "$SC_STANDIN_PID" 2>/dev/null
    for ((i = 0; i < 100; i++)); do
        kill -0 "$SC_STANDIN_PID" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$SC_STANDIN_PID" 2>/dev/null; then
        kill -KILL "$SC_STANDIN_PID" 2>/dev/null
    fi
    wait "$SC_STANDIN_PID" 2>/dev/null
    SC_STANDIN_PID=''
    for ((i = 0; i < 100; i++)); do
        if ! sc_port_open; then
            sc_log "the stand-in has stopped and port 80 is free"
            return 0
        fi
        sleep 0.1
    done
    sc_err "port 80 is still taken after the stand-in stopped"
    return 1
}
