#!/bin/bash
# Entrypoint of the SuiteCRM image. It runs as root, gets the volume and SuiteCRM ready, and then becomes Apache,
# which is PID 1 from then on. In order:
#
#   0. It checks the variables it can't work without, and runs itself a second time with the database settings
#      under the names the AI Assistant's persona uses: SUITECRM_DB_HOST, _PORT, _NAME, _USER and _PASSWORD.
#      The AI Assistant reads this container's environment once, from /proc/1/environ, as soon as sshd answers,
#      and /proc/1/environ shows what a program was started with, not what it exported later. So only a new
#      exec puts the names there.
#   1. The clouve-ops sshd for the AI Assistant, when the platform set CLOUVE_OPS_PASSWORD. It answers during an
#      install and an upgrade too. Then CLOUVE_OPS_PASSWORD leaves this environment, so nothing started later
#      has it: not Apache (PHP's getenv() reads Apache's environment), not the background jobs.
#   2. Apache's worker limit follows the container's memory limit.
#   3. The volume's top folder becomes www-data's when it is root's, as on a new cluster disk.
#   4. It starts the stand-in for the health check and waits for the database, up to 5 minutes. The stand-in
#      answers the platform's probe from here until Apache takes the port, at every start, so a slow database,
#      an install or an upgrade never gets the container restarted in the middle.
#   5. It decides what the volume holds, from VERSION on the volume, the image's version, the version row in
#      the database and the state an earlier start left in root's state folder:
#        the AI Assistant's restore is under way   it waits until the restore's marker is gone
#        no SuiteCRM, no tables                    a new install (install.sh)
#        no SuiteCRM, but tables                   it stops. SuiteCRM's installer would drop that database
#        an install that was cut off               it clears what that install left and installs again
#        the image's version, finished             nothing to do
#        an older version                          the in-place upgrade (upgrade.sh)
#        an upgrade that was cut off               upgrade.sh picks it up, from its state file or its backup
#        an upgrade that failed                    the old version runs, with no new try for this build
#        a newer version                           it stops. This image can't run it
#        between two versions, nothing to go by    it waits for a person (below)
#        SuiteCRM, but a database without tables   it waits for a person
#   6. It writes the database settings and the site address from the environment into SuiteCRM's own files,
#      makes www-data an allowed cron user, removes config_si.php wherever one is left, and closes the OAuth2
#      keys, the key that encrypts stored passwords and the settings files to others.
#   7. It starts the two background loops and becomes Apache. Each loop is a small root shell that starts
#      SuiteCRM's own command as www-data: the scheduler once a minute and, from SuiteCRM 8.10 on, the
#      Messenger worker.
#
# What the image trusts. SuiteCRM's whole tree is www-data's, and SuiteCRM's own permission reset or a start
# of the earlier image gives everything in it to www-data. So the state folder is read only while it is root's
# (lib.sh, sc_state_dir_vet), and "no state" never means "nothing is under way": the site's own facts decide. A
# site that is between two versions with no backup this image can trust is never started. The container then
# stays up with the stand-in and the sshd, logs a [clouve-upgrade] FAILED line that says what it found, and
# waits for staff or the AI Assistant. To the platform such a container looks healthy, so that line is what an
# alert has to look for. When what it waits for has changed, the start goes on by itself.
#
# A stop request (SIGTERM, or SIGWINCH, which is this image's stop signal) ends the start within seconds, with
# status 0. An install or an upgrade under way is told to stop too, and the next start picks it up.
#
# This script never logs a password and never puts one on a command line.

set -u

installer=/clouve/suitecrm/installer
# shellcheck source=lib.sh
. "$installer/lib.sh" || { printf '[suitecrm] ERROR: cannot read %s\n' "$installer/lib.sh" >&2; exit 1; }

# --- 0. the variables, and the names the AI Assistant reads ----------------------------------------------------------

for name in DATABASE_HOST DATABASE_NAME DATABASE_USER DATABASE_PASSWORD SUITECRM_URL; do
    if [ -z "${!name-}" ]; then
        sc_err "$name is not set, so SuiteCRM cannot start"
        exit 1
    fi
done
if ! sc_db_name_ok; then
    sc_err "DATABASE_NAME may hold only letters, digits, - and _"
    exit 1
fi
export DATABASE_PORT=${DATABASE_PORT:-3306}
# The second run finds every name set to its value and goes on. No marker variable is needed, so none ends up
# in PID 1's environment.
for name in HOST PORT NAME USER PASSWORD; do
    alias=SUITECRM_DB_$name
    source=DATABASE_$name
    if [ "${!alias-}" != "${!source}" ]; then
        export SUITECRM_DB_HOST=$DATABASE_HOST SUITECRM_DB_PORT=$DATABASE_PORT SUITECRM_DB_NAME=$DATABASE_NAME \
            SUITECRM_DB_USER=$DATABASE_USER SUITECRM_DB_PASSWORD=$DATABASE_PASSWORD
        exec "$0" "$@"
    fi
done

# --- a stop request ---------------------------------------------------------------------------------------------------

# Bash runs a trap only between two commands, so every wait below is a command in the background and a `wait`,
# which a signal ends at once. PID 1 gets only the signals it has a trap for. install.sh and upgrade.sh run in a
# session of their own (run_job), so a stop request can be passed on to them and to everything they started,
# and to nothing else.
stop_asked=0
job_pid=''
job_rc=0
trap 'stop_asked=1' TERM INT WINCH

# pause SECONDS: sleeps, unless a stop request comes first.
pause() {
    sleep "$1" &
    wait "$!" 2> /dev/null
}

# stopped: ends the start cleanly when a stop was asked for.
stopped() {
    [ "$stop_asked" = 1 ] || return 0
    sc_log "the container was asked to stop before SuiteCRM was started"
    if [ -n "$job_pid" ]; then
        kill -TERM -- "-$job_pid" 2> /dev/null
        while kill -0 "$job_pid" 2> /dev/null; do
            wait "$job_pid" 2> /dev/null
        done
    fi
    [ -z "$SC_STANDIN_PID" ] || kill "$SC_STANDIN_PID" 2> /dev/null
    # A container that stops is not waiting any more.
    sc_attention_clear
    sc_log "stopped"
    exit 0
}

# run_job COMMAND...: runs install.sh or upgrade.sh and waits for it. Sets job_rc to its exit status.
run_job() {
    setsid "$@" &
    job_pid=$!
    while :; do
        job_rc=0
        wait "$job_pid" 2> /dev/null || job_rc=$?
        stopped
        kill -0 "$job_pid" 2> /dev/null || break
    done
    job_pid=''
}

image_version=$(sc_image_version)
if [ -z "$image_version" ]; then
    sc_err "this image has no SuiteCRM package in $SC_PACKAGE"
    exit 1
fi
sc_log "SuiteCRM image $image_version (build $(sc_image_build))"

# --- 1. the clouve-ops sshd ------------------------------------------------------------------------------------------

if [ -n "${CLOUVE_OPS_PASSWORD-}" ]; then
    "$installer/start-clouve-ops-sshd.sh" &
else
    sc_log "CLOUVE_OPS_PASSWORD is not set, so the clouve-ops sshd is not started (a deployment without the AI Assistant)"
fi
# The sshd start has its own copy. Nothing started from here on may have it: the password signs in as clouve-ops,
# who has passwordless sudo (tests/app-ops-password.test.sh).
unset CLOUVE_OPS_PASSWORD

# --- 2. Apache's worker limit ----------------------------------------------------------------------------------------

mem=$(sc_memory_limit_mb)
workers=$(sc_apache_workers "$mem")
mpm_conf=/etc/apache2/conf-enabled/zz-clouve-mpm.conf
if printf '# Written by %s at every start, from the memory limit.\n<IfModule mpm_prefork_module>\n\tServerLimit %s\n\tMaxRequestWorkers %s\n</IfModule>\n' \
    "$installer/entrypoint.sh" "$workers" "$workers" > "$mpm_conf"; then
    if [ -n "$mem" ]; then limit="memory limit $mem MB"; else limit="no memory limit"; fi
    sc_log "$limit: Apache MaxRequestWorkers $workers"
else
    sc_warn "could not write $mpm_conf, so Apache keeps its default of 150 workers"
fi

# --- 3. the volume's top folder --------------------------------------------------------------------------------------

sc_claim_new_volume "$SC_ROOT" || exit 1
# The note of an earlier start that waited no longer holds: this start looks at the site anew.
sc_attention_clear

# --- 4. the stand-in and the database --------------------------------------------------------------------------------

# From here until Apache starts, the stand-in answers the health check (lib.sh, sc_standin_start). The start
# goes on without it when it can't run.
sc_standin_start || :

if ! sc_db_cnf; then
    sc_err "could not write the database options file in $SC_RUN"
    exit 1
fi
db_wait=300
db_err=$SC_RUN/db-wait.err
sc_log "waiting for the database at $DATABASE_HOST:$DATABASE_PORT (at most $db_wait s)"
deadline=$((SECONDS + db_wait))
next_log=$SECONDS
while :; do
    # In the background, with a wait: a name that doesn't resolve can keep the client busy for many seconds,
    # and a stop request must not have to wait for it.
    sc_sql 'SELECT 1' > /dev/null 2> "$db_err" &
    if wait "$!" 2> /dev/null; then
        break
    fi
    stopped
    reason=$(head -n 1 "$db_err" 2> /dev/null)
    if [ "$SECONDS" -ge "$deadline" ]; then
        sc_err "the database at $DATABASE_HOST:$DATABASE_PORT did not answer within $db_wait s, so SuiteCRM is not started: $reason"
        exit 1
    fi
    if [ "$SECONDS" -ge "$next_log" ]; then
        sc_log "the database does not answer yet: $reason"
        next_log=$((SECONDS + 30))
    fi
    pause 3
    stopped
done
rm -f -- "$db_err"
sc_log "the database answers"

# --- 5. what the volume holds ----------------------------------------------------------------------------------------

# stop MESSAGE...: this start ends here, with nothing changed. For what no repair inside the container can
# change: another image or another volume is needed.
stop() {
    sc_err "$@"
    exit 1
}

# failed_line FROM REASON: the line staff and alerts look for.
failed_line() {
    printf '[clouve-upgrade] FAILED suitecrm %s -> %s: %s\n' "$1" "$image_version" "$2" >&2
}

# restore_wait: the AI Assistant's restore writes tmp/clouve-backup/restore-in-progress before it changes anything
# and removes it when it is done. A container that starts in between must not install, upgrade or start
# SuiteCRM on a site that is half put back. It waits here, with the stand-in and the sshd up, so that the
# restore can be run again and finish. When the marker is gone, the start goes on.
restore_wait() {
    local why volume_version
    sc_state_has restore-in-progress || return 0
    sc_standin_page restoring
    why="a restore is under way ($SC_RESTORE_MARKER is there), so this start waits: nothing is installed, upgraded or started until the restore has finished and removed its marker."
    sc_log "$why The stand-in answers the health check and the sshd is up."
    # The same words for the AI Assistant, which can't read this log.
    volume_version=$(sc_read_version "$SC_ROOT/VERSION")
    sc_attention_write restore "${volume_version:-none}" "$image_version" "$why" || :
    while sc_state_has restore-in-progress; do
        pause 5
        stopped
    done
    sc_attention_clear
    sc_standin_page starting
    sc_log "the restore's marker is gone, so the start goes on"
}

# facts FILE: writes to FILE what a waiting start waits for: the state folder and what was moved aside, the
# restore's marker, the install stamp, VERSION, and the database's version row and tables. Two calls write the
# same text as long as none of that has changed.
facts() {
    {
        stat -c '%n %i %u %a %Y' -- "$SC_ROOT/tmp" "$SC_STATE_DIR" "$SC_STATE" "$SC_RESTORE_MARKER" \
            "$SC_INSTALL_STAMP" "$SC_ROOT/VERSION"
        sc_untrusted_dirs
        sc_read_version "$SC_ROOT/VERSION"
        sc_db_version
        sc_table_count
    } > "$1" 2>&1
}

# wait_for_staff: the start found a site that it must not start and that a person has to repair. Its FAILED
# line says what. The container stays up, and the start looks again as soon as something has changed. Every
# read here runs in the background with a wait, so that a stop request never has to wait for the database.
wait_for_staff() {
    sc_standin_page attention
    sc_log "SuiteCRM is not started. The container stays up so that the site can be repaired: the page says that it needs attention, and the clouve-ops sshd is up. The line above says what was found, and README.md, \"Staff runbook\", says what to do. The start goes on by itself once that is done. A restart does the same."
    facts "$SC_RUN/facts.seen" &
    wait "$!" 2> /dev/null
    stopped
    while :; do
        pause 10
        stopped
        if sc_state_has restore-in-progress; then break; fi
        # A command staff run by hand (upgrade.sh --finish-as-is) holds this lock until it is done.
        if ! flock -n "$SC_RUN/upgrade.lock" true 2> /dev/null; then continue; fi
        facts "$SC_RUN/facts.now" &
        wait "$!" 2> /dev/null
        stopped
        cmp -s "$SC_RUN/facts.seen" "$SC_RUN/facts.now" || break
    done
    rm -f -- "$SC_RUN/facts.seen" "$SC_RUN/facts.now"
    sc_attention_clear
    sc_standin_page starting
    sc_log "the volume or the database has changed, so the start looks at the site again"
}

# decide: sets action (install, reinstall, upgrade, hold, ready or wait) from the state folder and the site's
# own facts. For wait it sets wait_from and wait_why. It changes nothing but a backup that was cut off.
decide() {
    local stamp_database phase tables volume_version database_version untrusted from
    action=''
    wait_from=''
    wait_why=''
    stamp_database=$(sc_install_stamp_database)
    untrusted=$(sc_untrusted_dirs | head -n 1)
    untrusted=${untrusted#"$SC_ROOT"/}
    phase=$(sc_state_get phase)
    if [ -n "$stamp_database" ]; then
        if [ "$stamp_database" != "$DATABASE_HOST/$DATABASE_NAME" ]; then
            stop "an install into another database ($stamp_database) was cut off on this volume, and this container is set to $DATABASE_HOST/$DATABASE_NAME. Nothing was changed. Start it with the database it was installing into, or remove $SC_INSTALL_STAMP once you are sure this database may be dropped and made again."
        fi
        action=reinstall
        return 0
    fi
    if [ -e "$SC_INSTALL_STAMP" ] || [ -L "$SC_INSTALL_STAMP" ]; then
        stop "$SC_INSTALL_STAMP is not a file of root's, so it is not this image's install stamp. Nothing was changed. Remove it to go on."
    fi
    case $phase in
        backup)
            # Nothing in the site had changed yet, whichever image wrote the state. So the unfinished backup and
            # the state go, and the site's own facts decide, as at any start.
            sc_log "an upgrade had begun, and the backup was cut off before it was complete. Nothing in the site had changed, so the unfinished backup and its state are removed."
            rm -rf -- "$SC_STATE_DIR"/*.partial
            sc_state_clear
            ;;
        upgrade | restore | as-is)
            action=upgrade
            return 0
            ;;
        failed)
            if ! sc_state_has upgrade-failed; then
                sc_log "$SC_STATE_DIR/upgrade-failed was removed, so the upgrade may run again"
                sc_state_clear
            elif [ "$(sc_state_get build)" != "$(sc_image_build)" ]; then
                sc_log "the upgrade failed on another build of this image ($(sc_state_get build)), so this build tries again"
                rm -f -- "$SC_STATE_DIR/upgrade-failed"
                sc_state_clear
            else
                action=hold
                return 0
            fi
            ;;
    esac

    if ! sc_code_present; then
        if ! tables=$(sc_table_count); then
            stop "could not read the database's table list, so it is not safe to install. Nothing was changed."
        fi
        if [ "$tables" != 0 ]; then
            stop "the volume holds no SuiteCRM, but the database $DATABASE_NAME already has $tables table(s). SuiteCRM's installer would drop that database, so this container is not installing and has changed nothing. If the volume was lost or swapped, put it back or restore it from a backup. If the database really is to be made again, empty it first."
        fi
        action=install
        return 0
    fi
    volume_version=$(sc_read_version "$SC_ROOT/VERSION")
    if [ -z "$volume_version" ]; then
        stop "the volume holds SuiteCRM's files but no readable VERSION, so this image can't tell which SuiteCRM it is. Nothing was changed."
    fi
    sc_has_config_table
    case $? in
        0) ;;
        1)
            tables=$(sc_table_count) || tables='?'
            action='wait'
            wait_from=$volume_version
            wait_why="the volume holds SuiteCRM $volume_version, but the database $DATABASE_NAME has no SuiteCRM tables ($tables table(s) in it). The database is empty, was lost or is another one, and nothing was changed. Restore the database from a backup of this deployment, or point the container at the right one."
            return 0
            ;;
        *) stop "could not read the database's table list. Nothing was changed." ;;
    esac
    if ! database_version=$(sc_db_version); then
        stop "could not read SuiteCRM's version from the database. Nothing was changed."
    fi
    case $(sc_version_cmp "$volume_version" "$image_version") in
        gt)
            stop "the volume holds SuiteCRM $volume_version, which is newer than this image's $image_version. An older SuiteCRM can't run a newer one's database, so this container is not starting and has changed nothing. Run the image this deployment had before, or a newer one."
            ;;
        lt)
            if [ -n "$untrusted" ]; then
                # An upgrade may have been under way: its state can't be read, and the customer's upload folders
                # may be in that folder. Neither the old version nor a new upgrade is started on a guess.
                action='wait'
                wait_from=$volume_version
                wait_why="$untrusted is on the volume: a state folder that was not root's any more and was moved aside. An upgrade may have been under way, with its backup and the customer's upload folders in that folder, so SuiteCRM $volume_version is neither started nor upgraded. Nothing was changed. Look at the folder and put it back: in $SC_ROOT/tmp, chown -hR root:root ${untrusted##*/} && chmod -R go= ${untrusted##*/} && mv ${untrusted##*/} clouve-backup."
                return 0
            fi
            action=upgrade
            ;;
        eq)
            if [ "$database_version" = "$image_version" ]; then
                action=ready
                if [ -n "$untrusted" ]; then
                    sc_warn "$untrusted is on the volume: a state folder that was not root's any more and was moved aside. SuiteCRM $image_version is whole and starts. The scheduler stays held while that folder is there, because a hold file in it can't be read. Look at the folder, then put it back or remove it (README.md, \"Staff runbook\")."
                fi
            elif [ -n "$database_version" ] && [ "$(sc_version_cmp "$database_version" "$image_version")" = gt ]; then
                stop "the database was last used by SuiteCRM $database_version, which is newer than this image's $image_version. This container is not starting and has changed nothing."
            else
                # VERSION changes early in an upgrade, so it never proves that one finished. The row does.
                from=$(sc_backup_from_for "$image_version")
                if [ -n "$from" ]; then
                    sc_log "VERSION says $image_version but the database has no finished-upgrade record for it (${database_version:-none}): an upgrade was cut off. Its state file is gone, but the complete backup $from-to-$image_version is there."
                    action=upgrade
                else
                    action='wait'
                    wait_from=unfinished
                    wait_why="VERSION says $image_version but the database has no finished-upgrade record for it (${database_version:-none}): an upgrade was cut off, and the volume holds no backup that this image can trust. The site is between two versions, so it is not started, and nothing was changed."
                    if [ -n "$untrusted" ]; then
                        wait_why="$wait_why $untrusted was moved aside because it was not root's any more, and the backup may be in it. Look at that folder and put it back: in $SC_ROOT/tmp, chown -hR root:root ${untrusted##*/} && chmod -R go= ${untrusted##*/} && mv ${untrusted##*/} clouve-backup."
                    else
                        wait_why="$wait_why Restore the deployment from a backup, or finish the upgrade on the site as it is with $installer/upgrade.sh --finish-as-is (README.md, \"Staff runbook\")."
                    fi
                fi
            fi
            ;;
    esac
}

# The decision runs again whenever a wait ends: after the restore's marker has gone, and after a person changed
# what the start was waiting for.
while :; do
    restore_wait
    sc_state_dir_vet || :
    decide

    # config_si.php holds the admin's and the database's passwords in clear text. It goes wherever one is left,
    # before a backup can copy it.
    if sc_code_present; then
        sc_as_www find "$SC_ROOT" -maxdepth 3 \( -path "$SC_ROOT/vendor" -o -path "$SC_ROOT/tmp" -o -path "$SC_ROOT/cache" \
            -o -path "$SC_ROOT/lost+found" \) -prune -o -name config_si.php -type f -exec rm -f -- {} + 2> /dev/null
    fi

    case $action in
        install)
            run_job "$installer/install.sh"
            [ "$job_rc" -eq 0 ] || exit 1
            break
            ;;
        reinstall)
            run_job "$installer/install.sh" --clear-first
            [ "$job_rc" -eq 0 ] || exit 1
            break
            ;;
        upgrade)
            # The database settings first: SuiteCRM's own upgrade commands read them from its files.
            sc_as_www php "$installer/settings.php" database "$SC_ROOT" > /dev/null || :
            # Status 0: SuiteCRM is ready to start, upgraded or on the version it had. 3: it must not start, and
            # a person has to repair the site (upgrade.sh has logged what it found and left the note for the AI
            # Assistant). Anything else: it must not start, and a restart tries again.
            run_job "$installer/upgrade.sh"
            case $job_rc in
                0) break ;;
                3) wait_for_staff ;;
                *) exit 1 ;;
            esac
            ;;
        hold)
            why=$(sc_state_get reason)
            printf '[clouve-upgrade] suitecrm stays on %s: the upgrade to %s failed with this build%s. Remove %s/upgrade-failed to try again (README.md, "Staff runbook").\n' \
                "$(sc_read_version "$SC_ROOT/VERSION")" "$(sc_state_get to)" "${why:+ ($why)}" "$SC_STATE_DIR"
            break
            ;;
        ready) break ;;
        wait)
            failed_line "$wait_from" "$wait_why"
            # The same words for the AI Assistant, which can't read this log (lib.sh, sc_attention_write).
            sc_attention_write repair "$wait_from" "$image_version" "$wait_why" || :
            wait_for_staff
            ;;
    esac
done

# --- 6. settings kept in step ----------------------------------------------------------------------------------------

installed_version=$(sc_read_version "$SC_ROOT/VERSION")
cd "$SC_ROOT" || exit 1

if changed=$(sc_as_www php "$installer/settings.php" sync "$SC_ROOT"); then
    case $changed in
        *database*) sc_log "the database settings in SuiteCRM's files now match the environment" ;;
    esac
    case $changed in
        *address*)
            sc_log "the site address in SuiteCRM's settings is now $SUITECRM_URL"
            # What SuiteCRM compiled with the old address. These folders hold nothing else, and SuiteCRM makes them
            # again. public/legacy/cache also holds files of the customer's (inline images of emails), so it is
            # never emptied as a whole.
            sc_as_www rm -rf "$SC_ROOT/public/legacy/cache/smarty" "$SC_ROOT/public/legacy/cache/jsLanguage" \
                "$SC_ROOT/public/legacy/cache/themes" "$SC_ROOT/public/legacy/cache/modules"
            sc_symfony_cache_drop
            sc_as_www php bin/console cache:warmup -n > /dev/null 2>&1 ||
                sc_warn "could not rebuild SuiteCRM's cache after the address change; SuiteCRM builds it at its first request"
            ;;
    esac
fi
sc_as_www bash -c 'printf "%s\n" "$2" > "$1/.suitecrm_url"' _ "$SC_ROOT" "$SUITECRM_URL" 2> /dev/null || :

# www-data has to be an allowed cron user, or SuiteCRM refuses to run a scheduled job for it. The earlier image's
# installer ran as root and left only a placeholder there, so no scheduled job ever ran on an install it made.
# This only makes the jobs possible. Whether the scheduler runs them is another setting (loops.sh).
if [ "$(sc_as_www php "$installer/settings.php" cron "$SC_ROOT" 2> /dev/null)" = no ]; then
    if sc_as_www php "$installer/cron-user.php" "$SC_ROOT"; then
        sc_log "www-data is now an allowed cron user, so SuiteCRM's scheduled jobs can run once the scheduler is released"
    fi
fi

# The OAuth2 keys and the files that hold the database password are closed to others. The earlier image reset
# every file to 755 at each start.
for file in public/legacy/Api/V8/OAuth2/private.key public/legacy/Api/V8/OAuth2/public.key; do
    if [ -f "$file" ] && [ ! -L "$file" ] && [ "$(stat -c %a "$file")" != 600 ]; then sc_as_www chmod 600 "$file"; fi
done
for file in .env.local public/legacy/config.php public/legacy/config_override.php; do
    if [ -f "$file" ] && [ ! -L "$file" ]; then sc_as_www chmod o-rwx "$file"; fi
done
# The key that encrypts the mail passwords SuiteCRM stores. The earlier image's chmod -R 755 opened it to everyone.
if [ -d public/legacy/custom/blowfish ] && [ ! -L public/legacy/custom/blowfish ]; then
    sc_as_www chmod -R o-rwx public/legacy/custom/blowfish
fi

# --- 7. the background jobs and Apache -----------------------------------------------------------------------------

stopped
sc_standin_stop || exit 1
rm -f "$SC_DB_CNF"

# Each loop is a small shell of root's, because it reads root's state folder. What it starts is SuiteCRM's own
# command, as www-data.
"$installer/loops.sh" scheduler &
if [ "$(sc_as_www php "$installer/settings.php" scheduler "$SC_ROOT" 2> /dev/null)" = on ]; then
    sc_log "the scheduler loop is started: a small root loop that runs SuiteCRM's scheduled jobs once a minute as www-data"
else
    sc_log "the scheduler loop is started, and it is held: no scheduled job ever ran on this install, so none runs until someone releases the scheduler (README.md, \"Staff runbook\")"
fi
if [ -n "$installed_version" ] && [ "$(sc_version_cmp "$installed_version" 8.10.0)" != lt ]; then
    "$installer/loops.sh" worker &
    sc_log "the Messenger worker loop is started: a small root loop that keeps SuiteCRM's worker running as www-data"
else
    sc_log "SuiteCRM ${installed_version:-?} has no Messenger worker (8.10 brought it), so none is started"
fi

sc_log "SuiteCRM ${installed_version:-?} at $SUITECRM_URL: starting Apache"
trap - TERM INT WINCH
exec "$@"
