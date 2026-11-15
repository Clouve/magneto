#!/bin/bash
# Shared shell functions of the LimeSurvey image: logging, the test-only pause, the database client, the versions of
# the code and of the database, running console.php, copying the package onto the volume, and the state folder.
#
# Source this file, don't run it. It only defines functions and variables and changes no shell option.
#
# Who runs what. entrypoint.sh, site.sh, install.sh and upgrade.sh run as root, because the image's state folder,
# /var/www/html/clouve, is root's with mode 700: PHP code, which runs as www-data, can neither read the upgrade's
# backup nor plant a file there. Everything that reads, writes or runs a file of the web root runs as www-data,
# through ls_www: the files there are www-data's, PHP among them, and root never runs them, never reads what they
# hold and never writes into a folder that www-data could have swapped for a link. Root only renames top-level
# entries between the web root and its own folder, and a rename follows no link. configure-suitecrm-plugin.sh and
# import-demo-data.sh run as www-data from start to end.
#
# No function prints a password or puts one on a command line. The database client gets the password in MYSQL_PWD, in
# that one command's environment, and PHP reads its values from the environment.

LS_ROOT=/var/www/html
LS_PACKAGE=/clouve/limesurvey/package
LS_INSTALLER=/clouve/limesurvey/installer
# The image's state files and the upgrade's backups: root's, mode 700 (ls_secure_clouve), and never served by Apache
# (apache-clouve.conf). Root's scripts work from inside it (ls_enter_clouve) and name its files by relative paths,
# so a folder that www-data put in its place while they run is never written to.
LS_CLOUVE="$LS_ROOT/clouve"
export LS_ROOT
# entrypoint.sh makes this file when the container is asked to stop, before it passes the request on.
LS_STOP_FLAG=/run/clouve-limesurvey-stop

# ls_www CMD...: CMD as www-data, started in the web root. Called by www-data itself, it just runs CMD.
ls_www() {
    if [ "$(id -u)" != 0 ]; then
        "$@"
        return
    fi
    (
        cd "$LS_ROOT" 2>/dev/null || cd / || exit 1
        exec env HOME=/var/www USER=www-data LOGNAME=www-data \
            setpriv --reuid=www-data --regid=www-data --init-groups -- "$@"
    )
}

# ls_www_fn FUNCTION ARGS...: a function of this file, as www-data.
ls_www_fn() {
    # shellcheck disable=SC2016  # the script is for the bash that ls_www starts
    ls_www bash -c '. "$0" || exit 1; "$@"' "$LS_INSTALLER/lib.sh" "$@"
}

# ls_secure_clouve: makes sure /var/www/html/clouve is a real folder of root's with mode 700. The web root is
# www-data's, so PHP code can move the folder aside and put one of its own in its place. A folder that is not
# root's, a link or a file is therefore never used and never read: it is moved aside (a rename, which follows no
# link) and a new folder is made. Status 1 when no safe folder can be had.
ls_secure_clouve() {
    local aside
    if [ -e "$LS_CLOUVE" ] || [ -L "$LS_CLOUVE" ]; then
        if [ -L "$LS_CLOUVE" ] || [ ! -d "$LS_CLOUVE" ] || [ "$(stat -c %u -- "$LS_CLOUVE" 2>/dev/null)" != 0 ]; then
            aside="$LS_CLOUVE.untrusted-$(date -u +%Y%m%dT%H%M%SZ)"
            if ! mv -T -- "$LS_CLOUVE" "$aside"; then
                ls_error "$LS_CLOUVE is not a folder of root's, and it could not be moved aside"
                return 1
            fi
            ls_warn "$LS_CLOUVE was not a folder of root's, so nothing in it was read or used. It is now $aside," \
                "and the image keeps its state in a new folder. If $aside holds an upgrade's backup, keep it: it is" \
                "the way back to the old version."
        fi
    fi
    if [ ! -e "$LS_CLOUVE" ] && [ ! -L "$LS_CLOUVE" ]; then
        mkdir -m 700 -- "$LS_CLOUVE" || { ls_error "cannot make $LS_CLOUVE"; return 1; }
    fi
    ls_enter_clouve && chmod 700 . || { ls_error "$LS_CLOUVE can't be used as the image's state folder"; return 1; }
}

# ls_enter_clouve: makes the state folder the working directory, and checks that it is the real folder of root's.
# From then on a relative path names a file in that very folder, whatever www-data does to the name clouve.
ls_enter_clouve() {
    cd -P -- "$LS_CLOUVE" 2>/dev/null && [ "$(pwd -P)" = "$LS_CLOUVE" ] && [ "$(stat -c '%u:%F' . 2>/dev/null)" = "0:directory" ]
}

# ls_trusted PATH: whether PATH, given from inside the state folder, and every folder on the way to it are root's
# and no link. The image trusts a state file, a dump or the old code folder only then.
ls_trusted() {
    local part cur="" IFS=/
    for part in $1; do
        case "$part" in
            '' | .) continue ;;
            ..) return 1 ;;
        esac
        cur="${cur:+$cur/}$part"
        [ ! -L "$cur" ] && [ -e "$cur" ] && [ "$(stat -c %u -- "$cur" 2>/dev/null)" = 0 ] || return 1
    done
    [ -n "$cur" ]
}

# ls_log MSG...: "[limesurvey] MSG" on stdout.
ls_log() {
    local IFS=' '
    printf '[limesurvey] %s\n' "$*"
}

# ls_warn MSG...: "[limesurvey] WARNING: MSG" on stderr.
ls_warn() {
    local IFS=' '
    printf '[limesurvey] WARNING: %s\n' "$*" >&2
}

# ls_error MSG...: "[limesurvey] ERROR: MSG" on stderr.
ls_error() {
    local IFS=' '
    printf '[limesurvey] ERROR: %s\n' "$*" >&2
}

# ls_up_log MSG...: one line of the upgrade's own log, "[clouve-upgrade] MSG", for staff and for alerts.
ls_up_log() {
    local IFS=' '
    printf '[clouve-upgrade] %s\n' "$*"
}

# ls_test_pause STEP [shielded]: for the tests only. When CLV_LS_TEST_PAUSE is "<STEP>:<seconds>", it says so and
# sleeps that long, so a test can kill the container at a known step or make an upgrade outlast the health check's
# patience. With "shielded" the sleep is out of reach of a stop request, like the step it stands in for. Nothing
# sets the variable in a deployment, and without it this does nothing.
ls_test_pause() {
    local want="${CLV_LS_TEST_PAUSE:-}"
    [ -n "$want" ] && [ "${want%%:*}" = "$1" ] || return 0
    case "${want#*:}" in
        '' | *[!0-9]*) return 0 ;;
    esac
    ls_up_log "test pause at $1 for ${want#*:} s"
    if [ "${2:-}" = shielded ]; then
        setsid -w sleep "${want#*:}"
    else
        sleep "${want#*:}"
    fi
}

# ls_mysql ARGS...: the database client on the site's database, with the password in MYSQL_PWD. The port goes in
# MYSQL_TCP_PORT: given a --port option, this client stops checking the server's certificate and says so on every
# call.
ls_mysql() {
    MYSQL_PWD="${DB_PASSWORD:-}" MYSQL_TCP_PORT="${DB_PORT:-3306}" mariadb -h "${DB_HOST:-}" -u "${DB_USERNAME:-}" "$@"
}

# ls_sql QUERY: rows of a query on the site's database, tab-separated, no header.
ls_sql() {
    ls_mysql "${DB_NAME:-}" -N -B -e "$1"
}

# ls_table NAME: NAME with the site's table prefix.
ls_table() {
    printf '%s%s' "${DB_TABLE_PREFIX:-lime_}" "$1"
}

# ls_db_tables: how many tables and views the site's database holds. Status 1 when the database can't be asked.
ls_db_tables() {
    ls_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()"
}

# ls_db_setting NAME: one row of LimeSurvey's global settings, or nothing when it has none or no such table.
ls_db_setting() {
    ls_sql "SELECT stg_value FROM \`$(ls_table settings_global)\` WHERE stg_name = '$1'" 2>/dev/null
}

# ls_db_version: DBVersion, the version of the database's layout. Nothing when LimeSurvey isn't installed there.
ls_db_version() {
    ls_db_setting DBVersion
}

# ls_drop_all_tables: drops every table and view of the site's database. A dump only drops the tables it holds, and
# a database update that failed leaves new ones behind, so a restore starts from an empty database.
ls_drop_all_tables() {
    local name kind sql="SET FOREIGN_KEY_CHECKS = 0;"
    while IFS=$'\t' read -r name kind; do
        [ -n "$name" ] || continue
        case "$name" in *'`'*) ls_error "the table name $name can't be quoted, so nothing is dropped"; return 1 ;; esac
        if [ "$kind" = VIEW ]; then sql="$sql DROP VIEW IF EXISTS \`$name\`;"; else sql="$sql DROP TABLE IF EXISTS \`$name\`;"; fi
    done < <(ls_sql "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = DATABASE()") || return 1
    # On stdin: an install with thousands of response tables makes a statement list longer than one argument can be.
    printf '%s\n' "$sql" | ls_mysql "${DB_NAME:-}" || return 1
    [ "$(ls_db_tables)" = 0 ]
}

# ls_version DIR: "<versionnumber> <dbversionnumber> <buildnumber>" of the LimeSurvey code in DIR, nothing when
# there is none. The volume's version file is PHP that www-data can change, so it is read as www-data.
ls_version() {
    ls_www php -d display_errors=0 "$LS_INSTALLER/tool.php" version "$1" 2>/dev/null
}

# ls_vercmp A B: -1, 0 or 1 as version A is older than, the same as or newer than version B.
ls_vercmp() {
    if [ "$1" = "$2" ]; then echo 0
    elif [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$1" ]; then echo -1
    else echo 1
    fi
}

# ls_console ARGS...: LimeSurvey's console.php in the volume's code, as www-data, with its output passed through.
ls_console() {
    (cd "$LS_ROOT" && ls_www php application/commands/console.php "$@")
}

# ls_console_shielded ARGS...: the same in a session of its own, so a stop request that ends everything else of the
# start doesn't reach it. For the database update, which must not be cut off halfway when it can be helped.
ls_console_shielded() {
    (cd "$LS_ROOT" && ls_www setsid -w php application/commands/console.php "$@")
}

# ls_package_names: the top-level names of the package, one per line, without upload (a volume of its own).
ls_package_names() {
    (cd "$LS_PACKAGE" && find . -mindepth 1 -maxdepth 1 ! -name upload -printf '%f\n')
}

# ls_copy_package: copies the package onto the volume as www-data, one top-level entry at a time, so the volume's
# top folder keeps its owner and mode. upload/ is left out. Status 1 when a copy fails.
ls_copy_package() {
    local name
    while IFS= read -r name; do
        ls_www cp -aT -- "$LS_PACKAGE/$name" "$LS_ROOT/$name" || return 1
    done < <(ls_package_names)
}

# ls_remove_package_names [NAME...]: removes from the web root, as www-data, every top-level entry that has a name
# of the package's (upload/ is left out) or one of the NAMEs. Status 1 when one can't be removed.
ls_remove_package_names() {
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        ls_www rm -rf -- "${LS_ROOT:?}/$name" || return 1
    done < <({ ls_package_names; [ "$#" -eq 0 ] || printf '%s\n' "$@"; } | grep -vx -e upload -e clouve | sort -u)
}

# ls_upload_skeleton: adds what the package's upload/ folder has and the upload volume lacks: a new disk starts
# empty, and a newer LimeSurvey can bring new folders. Nothing that is there is changed, the top folder least of all.
ls_upload_skeleton() {
    local path
    # Without a volume of its own, upload/ is a plain folder of the code volume, and a new one doesn't have it yet.
    [ -d "$LS_ROOT/upload" ] || ls_www mkdir -- "$LS_ROOT/upload" || return 1
    while IFS= read -r -d '' path; do
        if [ -e "$LS_ROOT/upload/$path" ] || [ -L "$LS_ROOT/upload/$path" ]; then
            continue
        fi
        if [ -d "$LS_PACKAGE/upload/$path" ] && [ ! -L "$LS_PACKAGE/upload/$path" ]; then
            ls_www mkdir -- "$LS_ROOT/upload/$path" || return 1
        else
            ls_www cp -a -- "$LS_PACKAGE/upload/$path" "$LS_ROOT/upload/$path" || return 1
        fi
    done < <(cd "$LS_PACKAGE/upload" && find . -mindepth 1 -print0)
}

# ls_own_private FILE: makes FILE a file of the caller's with mode 600. Only www-data calls it (ls_www_fn). Installs
# made by the old image have config.php and security.php as root's, mode 644, in a folder that is www-data's. See
# README.md, "Who owns config.php and security.php". A file that is already the caller's only gets its mode. Status
# 1 when it can't.
ls_own_private() {
    local file="$1"
    [ -f "$file" ] && [ ! -L "$file" ] || return 0
    if [ -O "$file" ]; then
        [ "$(stat -c %a -- "$file")" = 600 ] || chmod 600 -- "$file"
        return
    fi
    rm -f -- "$file.clv-own"
    (umask 077 && cat -- "$file" > "$file.clv-own") && mv -f -- "$file.clv-own" "$file"
}

# ls_write_file FILE: writes stdin to FILE in one step (a reader never sees half of it), mode 600, and has it on
# the disk before it returns. Status 1 when any part fails, as on a full volume; FILE is then as it was.
ls_write_file() {
    if (umask 077 && cat > "$1.clv-tmp") && sync -- "$1.clv-tmp" && mv -f -- "$1.clv-tmp" "$1"; then
        sync -- "$(dirname -- "$1")" 2>/dev/null || :
        return 0
    fi
    rm -f -- "$1.clv-tmp"
    return 1
}

# ls_attention_note KIND FROM TO REASON...: the note clouve/needs-attention, which says why the container waits and
# starts no LimeSurvey, for the AI Assistant, which can't read the container's log. Root's, mode 600, with one
# key=value per line. The SuiteCRM image writes the same five keys to its tmp/clouve-backup/needs-attention:
#   reason  what was found, in the words of the [clouve-upgrade] FAILED line (kind repair) or of the log line about
#           the restore (kind restore). It never holds a password.
#   since   when the wait began, in UTC
#   from    the version on the volume, as the FAILED line names it
#   to      the package's version
#   kind    repair: a person has to repair the site. restore: the AI Assistant's restore is under way.
# Call it from inside the state folder. Status 1 when the note could not be written, as on a full volume.
ls_attention_note() {
    local kind="$1" from="$2" to="$3" IFS=' '
    shift 3
    printf 'reason=%s\nsince=%s\nfrom=%s\nto=%s\nkind=%s\n' "$*" "$(ls_now)" "$from" "$to" "$kind" |
        ls_write_file needs-attention 2>/dev/null
}

# ls_attention FROM TO MSG...: the start can't go on, and a person has to repair the site. It prints the line that
# staff and alerts look for and leaves the note clouve/needs-attention for the AI Assistant. The caller then ends
# with status 20, and entrypoint.sh keeps the container up, with the stand-in page and the sshd, instead of
# stopping it: a container that stops and starts in a loop leaves nobody a way in. Call it from inside the state
# folder.
ls_attention() {
    local from="$1" to="$2" aside note="" IFS=' '
    shift 2
    aside="$(find "$LS_ROOT" -maxdepth 1 -name 'clouve.untrusted-*' -printf '%p ' 2>/dev/null)"
    if [ -n "$aside" ]; then
        note=" A state folder that was not root's was moved aside at a start (${aside% }). If it holds an upgrade's backup, that backup is the way back, so keep it."
    fi
    ls_up_log "FAILED limesurvey $from -> $to: $*" \
        "LimeSurvey is not started, and the container stays up so that the site can be repaired: see \"When a start" \
        "waits for repair\" in apps/limesurvey/README.md.$note"
    ls_attention_note repair "$from" "$to" "$@" || :
}

# ls_now: the time in UTC, as 2026-11-12T20:41:07Z.
ls_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ls_image_build: this image's build: the LimeSurvey version and build number and a hash of the installer folder
# and the package.
ls_image_build() {
    head -n 1 /clouve/limesurvey/image-build 2>/dev/null
}

# ls_package_stat NAME: "entries" (how many files and folders the package has) or "kb" (its size), as the build
# wrote them to /clouve/limesurvey/package-stats. An image without that file measures the package.
ls_package_stat() {
    local value
    value="$(sed -n "s/^$1=\([0-9]\{1,\}\)\$/\1/p" /clouve/limesurvey/package-stats 2>/dev/null | head -n 1)"
    if [ -z "$value" ]; then
        case "$1" in
            entries) value="$(find "$LS_PACKAGE" 2>/dev/null | wc -l)" ;;
            kb) value="$(du -sk "$LS_PACKAGE" 2>/dev/null | cut -f1)" ;;
        esac
    fi
    printf '%s' "$value"
}
