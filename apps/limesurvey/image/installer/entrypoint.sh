#!/bin/bash
# Entrypoint of the LimeSurvey image. It runs as root and is PID 1 until its last line, where it becomes Apache.
# Upstream's entrypoint never runs: it passes the admin's password to console.php on a command line, and it starts
# Apache whatever the install or the database update did. In order:
#
#   1. It checks DB_PASSWORD and ADMIN_PASSWORD and stops before anything changes when one is missing. Then it runs
#      itself a second time with the settings the AI Assistant needs in its environment: LIMESURVEY_DB_USER (from
#      DB_USERNAME), the database's host, port and name with their defaults, and DB_MYSQL_ENGINE=InnoDB for new
#      installs. The assistant reads this container's environment once, from /proc/1/environ, as soon as sshd
#      answers, and /proc/1/environ shows what a program was started with, not what it exported later.
#   2. It starts the clouve-ops sshd in the background and drops CLOUVE_OPS_PASSWORD from its own environment, so
#      nothing started later has it: not the stand-in, not www-data's scripts, not Apache, whose PHP could read it.
#      Without the variable no sshd starts. The sshd is up through an install or an upgrade, because the assistant
#      gives up on an app whose port answers while its sshd doesn't.
#   3. It sets Apache's port (LISTEN_PORT, 8080).
#   4. It makes each volume's top folder usable: /var/www/html and /var/www/html/upload become www-data's when they
#      are root's, as on a new cluster disk. A working install never has them as root's, and nothing inside them is
#      changed. Then it makes sure the image's state folder, /var/www/html/clouve, is a real folder of root's with
#      mode 700 (ls_secure_clouve in lib.sh), and works from inside it.
#   5. It starts the stand-in for the health check on Apache's port (standin-router.php), which answers until Apache
#      takes over: a copy of 22,000 files to a network disk, or the database update of every response table, can
#      take longer than the health check waits before it restarts the container.
#   6. When the AI Assistant's skill is in the middle of a restore (clouve/backups/RESTORE-IN-PROGRESS), it waits
#      for the marker to go, with the stand-in and the sshd up, and decides nothing about the site until then.
#   7. It waits for the database, at most DB_WAIT_SECONDS (300), then stops with status 1.
#   8. site.sh decides what the volume holds and installs, upgrades or refuses, and then brings the settings in step
#      with the environment. When it fails, Apache never starts: LimeSurvey never runs on code and a database that
#      don't belong together. Where a person can repair the site from inside the container (status 20), the
#      container stays up for that, with the stand-in page saying that the site needs attention and the sshd
#      running. Otherwise the container stops with site.sh's status.
#   9. It stops the stand-in, waits for the port and becomes Apache.
#
# A stop request (SIGTERM, or SIGWINCH, the image's own stop signal) that comes before Apache is up ends the start
# cleanly, with status 0: the waits end at once, and an install or an upgrade ends as upgrade.sh describes.
#
# This script never logs a password and never puts one on a command line.

set -u

installer=/clouve/limesurvey/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || { printf '[limesurvey] ERROR: cannot read %s\n' "$installer/lib.sh" >&2; exit 1; }

# --- 1. the checks, and the settings in PID 1's environment ------------------------------------------------------

for var in DB_PASSWORD ADMIN_PASSWORD; do
    if [ -z "${!var-}" ]; then
        ls_error "$var is not set, so LimeSurvey can't be started"
        exit 1
    fi
done

# The second run finds every value in place and goes on. No marker variable is needed, so none shows up in what the
# assistant reads.
want_engine="${DB_MYSQL_ENGINE:-InnoDB}"
want_user="${DB_USERNAME:-limesurvey}"
if [ "${DB_TYPE-}" != "${DB_TYPE:-mysql}" ] || [ "${DB_HOST-}" != "${DB_HOST:-limesurvey-mariadb}" ] ||
    [ "${DB_PORT-}" != "${DB_PORT:-3306}" ] || [ "${DB_NAME-}" != "${DB_NAME:-limesurvey}" ] ||
    [ "${DB_USERNAME-}" != "$want_user" ] || [ "${DB_TABLE_PREFIX-}" != "${DB_TABLE_PREFIX:-lime_}" ] ||
    [ "${DB_MYSQL_ENGINE-}" != "$want_engine" ] || [ "${LIMESURVEY_DB_USER-}" != "$want_user" ]; then
    export DB_TYPE="${DB_TYPE:-mysql}"
    export DB_HOST="${DB_HOST:-limesurvey-mariadb}"
    export DB_PORT="${DB_PORT:-3306}"
    export DB_NAME="${DB_NAME:-limesurvey}"
    export DB_USERNAME="$want_user"
    export DB_TABLE_PREFIX="${DB_TABLE_PREFIX:-lime_}"
    # The old entrypoint set this without exporting it, so LimeSurvey never saw it and made MyISAM tables. New
    # installs get InnoDB. An existing install keeps the engine its config.php names, and its tables stay as they are.
    export DB_MYSQL_ENGINE="$want_engine"
    export LIMESURVEY_DB_USER="$want_user"
    exec "$0" "$@"
fi

if [ "$DB_TYPE" != mysql ]; then
    ls_error "DB_TYPE is $DB_TYPE, and this image works with MySQL and MariaDB only"
    exit 1
fi
listen_port="${LISTEN_PORT:-8080}"
case "$listen_port" in
    '' | *[!0-9]*) ls_error "LISTEN_PORT is not a port number"; exit 1 ;;
esac

# --- a stop request -----------------------------------------------------------------------------------------------

# Bash runs a trap only between two commands, so every wait below is a command in the background and a `wait`,
# which a signal ends at once. PID 1 gets only the signals it has a trap for.
stop_asked=0
standin_pid=""
site_pid=""
site_rc=0
# The stand-in reads these two: which page it shows.
restoring_flag=/run/clouve-limesurvey-restoring
attention_flag=/run/clouve-limesurvey-attention
# What an earlier start of this same container left.
rm -f -- "$LS_STOP_FLAG" "$restoring_flag" "$attention_flag"
trap 'stop_asked=1' TERM INT WINCH

# pause SECONDS: sleeps, unless a stop request comes first.
pause() {
    sleep "$1" &
    wait "$!" 2>/dev/null
}

# stopped: ends the start cleanly when a stop was asked for. It tells site.sh and all it started (they are a
# process group of their own), waits for them, and ends the stand-in.
stopped() {
    [ "$stop_asked" = 1 ] || return 0
    ls_log "the container was asked to stop before LimeSurvey was started"
    if [ -n "$site_pid" ]; then
        : > "$LS_STOP_FLAG"
        kill -TERM -- "-$site_pid" 2>/dev/null
        # The database update and a restore's reload of the database run on to their end (upgrade.sh). If that
        # takes longer than the platform waits, it kills the container, and the next start picks the cut-off up.
        while kill -0 "$site_pid" 2>/dev/null; do
            wait "$site_pid" 2>/dev/null
        done
    fi
    [ -z "$standin_pid" ] || kill "$standin_pid" 2>/dev/null
    # A container that stops is not waiting any more.
    rm -f -- needs-attention 2>/dev/null
    ls_log "stopped"
    exit 0
}

# --- 2. the clouve-ops sshd -----------------------------------------------------------------------------------------

"$installer/start-clouve-ops-sshd.sh" &

# The sshd start above has its own copy of CLOUVE_OPS_PASSWORD. Nothing started from here on may have it: the
# password signs in as clouve-ops, who has passwordless sudo, and PHP under Apache reads Apache's environment.
unset CLOUVE_OPS_PASSWORD

# --- 3. Apache's port -------------------------------------------------------------------------------------------------

if [ "$listen_port" != 80 ]; then
    # The same edit as upstream's entrypoint makes.
    sed -i "s/Listen 80\$/Listen $listen_port/" /etc/apache2/ports.conf /etc/apache2/sites-available/000-default.conf
fi

# --- 4. the volumes' top folders, and the state folder ----------------------------------------------------------------

# claim_volume DIR: DIR becomes www-data's when it is a folder of root's. On a new cluster disk the top folder is
# root's, mode 755, with lost+found in it, and www-data could make nothing there. Only the folder itself changes,
# never anything in it. It is a mount point, which nobody can swap for a link, and a link, a folder of anyone else's
# and anything that isn't a folder are left alone.
claim_volume() {
    local dir="$1"
    if [ -L "$dir" ] || [ ! -d "$dir" ] || [ "$(stat -c %u -- "$dir" 2>/dev/null)" != 0 ]; then
        return 0
    fi
    if chown -h www-data:www-data -- "$dir"; then
        ls_log "$dir was root's, as on a new disk, so it is now www-data's"
    else
        ls_warn "could not give $dir to www-data"
    fi
}
claim_volume "$LS_ROOT"
claim_volume "$LS_ROOT/upload"

# The state folder is root's with mode 700, and from here this script's working directory. PHP code can neither
# read the upgrade's backup nor put a state file or a link where root's scripts would act on it.
if ! ls_secure_clouve; then
    ls_error "LimeSurvey is not started: the image has no safe place for its state"
    exit 1
fi
# The note of an earlier start that waited no longer holds: this start looks at the site anew.
rm -f -- needs-attention

# --- 5. the stand-in for the health check ---------------------------------------------------------------------------

# It runs as www-data with an empty environment and serves one file of the image. setpriv becomes php itself, so
# $! is the server's own process.
(cd / && exec env -i PATH="$PATH" setpriv --reuid=www-data --regid=www-data --init-groups -- \
    php -S "0.0.0.0:$listen_port" -t /clouve/limesurvey/standin "$installer/standin-router.php" >/dev/null 2>&1) &
standin_pid=$!

# stop_standin: ends the stand-in and waits until its port is free, so that Apache can take it.
stop_standin() {
    kill "$standin_pid" 2>/dev/null
    wait "$standin_pid" 2>/dev/null
    for _ in $(seq 1 50); do
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$listen_port") 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    ls_warn "port $listen_port is still taken after the stand-in was stopped"
}

# --- 6. a restore that the AI Assistant's skill has under way -------------------------------------------------------

# The skill's restore.sh writes clouve/backups/RESTORE-IN-PROGRESS before it changes the database and removes it
# when the restore is whole. A container that restarts in between finds a half-loaded database. Nothing here could
# decide anything from that, and a refusal would end the container and with it the sshd that the restore needs. So
# the start waits, for as long as it takes, and goes on by itself when the marker is gone.
restore_marker=backups/RESTORE-IN-PROGRESS

# restore_under_way: whether the skill's marker is there, as a file of root's.
restore_under_way() {
    { [ -e "$restore_marker" ] || [ -L "$restore_marker" ]; } && ls_trusted "$restore_marker"
}

# wait_for_restore: returns at once without the marker. With it, the page says "being restored" until it is gone.
wait_for_restore() {
    local why
    restore_under_way || return 0
    : > "$restoring_flag"
    why="a restore from a backup is under way (the AI Assistant's skill wrote $LS_CLOUVE/$restore_marker), so nothing is installed, upgraded or started."
    ls_log "$why The page says so and the clouve-ops sshd is up. To finish," \
        "run the skill's restore.sh for the same backup again. To give the restore up, remove the marker as root:" \
        "the start then goes on with whatever the database and the volume hold. This start waits until the marker is gone."
    restore_note "$why"
    while restore_under_way; do
        pause 2
        stopped
    done
    rm -f -- "$restoring_flag" needs-attention
    ls_log "the restore's marker is gone: the start goes on"
}

# restore_note REASON: the note for the AI Assistant, which can't read this log, while the start waits for a
# restore (lib.sh, ls_attention_note).
restore_note() {
    local from to
    from="$(ls_version "$LS_ROOT" | cut -d' ' -f1)"
    to="$(ls_version "$LS_PACKAGE" | cut -d' ' -f1)"
    ls_attention_note restore "${from:-no code}" "$to" "$1" || :
}

# --- 7. the database --------------------------------------------------------------------------------------------------

db_wait="${DB_WAIT_SECONDS:-300}"
case "$db_wait" in
    '' | *[!0-9]*) db_wait=300 ;;
esac

# wait_for_database: returns once the database answers. Ends the container with status 1 when it doesn't in time.
wait_for_database() {
    local deadline next_log db_err reason rc
    ls_log "waiting for the database at $DB_HOST:$DB_PORT (at most $db_wait s)"
    deadline=$((SECONDS + db_wait))
    next_log=$SECONDS
    db_err="$(mktemp /run/clouve-limesurvey-db.XXXXXX)" || { ls_error "cannot make a file in /run"; exit 1; }
    while :; do
        rc=0
        # The password is in the environment of timeout and of the client it starts, never among their arguments.
        # What the client says goes to a file of root's in /run.
        MYSQL_PWD="$DB_PASSWORD" MYSQL_TCP_PORT="$DB_PORT" timeout 10 mariadb -h "$DB_HOST" -u "$DB_USERNAME" \
            "$DB_NAME" -e 'SELECT 1' >/dev/null 2>"$db_err" &
        wait "$!" 2>/dev/null || rc=$?
        stopped
        [ "$rc" -eq 0 ] && break
        reason="$(head -n 1 "$db_err" | cut -c1-200)"
        [ "$rc" -eq 124 ] && reason="no answer within 10 s"
        if [ "$SECONDS" -ge "$deadline" ]; then
            ls_error "the database at $DB_HOST:$DB_PORT did not answer within $db_wait s, so LimeSurvey is not started: $reason"
            rm -f -- "$db_err"
            stop_standin
            exit 1
        fi
        if [ "$SECONDS" -ge "$next_log" ]; then
            ls_log "the database does not answer yet: $reason"
            next_log=$((SECONDS + 30))
        fi
        pause 3
        stopped
    done
    rm -f -- "$db_err"
    ls_log "the database answers"
}

# --- 8. the site ------------------------------------------------------------------------------------------------------

# run_site: site.sh, in a session of its own, so a stop request can be passed to it and everything it started, and
# to nothing else. Sets site_rc.
run_site() {
    setsid bash "$installer/site.sh" &
    site_pid=$!
    while :; do
        site_rc=0
        wait "$site_pid" 2>/dev/null || site_rc=$?
        stopped
        kill -0 "$site_pid" 2>/dev/null || break
    done
    site_pid=""
}

# wait_for_repair: site.sh found a site that it must not start and that a person has to repair (its
# [clouve-upgrade] FAILED line says what). The container stays up: the page says that the site needs attention, and
# the sshd is there for staff and for the AI Assistant. To the platform the container looks healthy, so the FAILED
# line is what an alert has to look for. It returns only when the skill's restore has come and gone: then the site
# may be whole again, and the start begins anew. Anything else ends with a restart of the container.
wait_for_repair() {
    local restoring=0
    : > "$attention_flag"
    ls_log "LimeSurvey is not started. The container stays up so that the site can be repaired: the page says that" \
        "it needs attention, and the clouve-ops sshd is up. The [clouve-upgrade] FAILED line above says what was" \
        "found. Restart the container when the repair is done."
    while :; do
        pause 5
        stopped
        if restore_under_way; then
            if [ "$restoring" = 0 ]; then
                restoring=1
                : > "$restoring_flag"
                ls_log "a restore from a backup has begun (the AI Assistant's skill wrote $LS_CLOUVE/$restore_marker)"
                restore_note "a restore from a backup has begun (the AI Assistant's skill wrote $LS_CLOUVE/$restore_marker), so nothing is installed, upgraded or started."
            fi
        elif [ "$restoring" = 1 ]; then
            rm -f -- "$restoring_flag" "$attention_flag" needs-attention
            ls_log "the restore's marker is gone: the start begins again"
            return 0
        fi
    done
}

while :; do
    wait_for_restore
    wait_for_database
    run_site
    case "$site_rc" in
        0) break ;;
        20) wait_for_repair ;;
        *)
            ls_error "LimeSurvey is not started (status $site_rc). The lines above say why, and apps/limesurvey/README.md in the magneto repository has the runbook."
            stop_standin
            exit "$site_rc"
            ;;
    esac
done

# --- 9. Apache --------------------------------------------------------------------------------------------------------

ls_log "the site is ready: the stand-in hands port $listen_port over to Apache"
stop_standin
stopped
# Apache takes its own signals from here. It starts in the web root, as it always has.
cd "$LS_ROOT" 2>/dev/null || cd / || exit 1
ls_log "starting Apache on port $listen_port"
if [ "$#" -eq 0 ]; then
    set -- apache2-foreground
fi
exec "$@"
