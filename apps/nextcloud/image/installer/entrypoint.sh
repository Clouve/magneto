#!/bin/bash
# Entrypoint of the Nextcloud image. It runs as root, gets the container ready and then hands over to the official
# image's /entrypoint.sh, which copies the code onto the volume, installs or upgrades Nextcloud (running our hooks in
# /docker-entrypoint-hooks.d/) and starts Apache. In order:
#
#   0. It runs itself a second time, with the cleaned admin login in NEXTCLOUD_ADMIN_USER and the decoded admin email
#      in NEXTCLOUD_ADMIN_EMAIL. The AI Assistant reads this container's environment once, from /proc/1/environ, as
#      soon as sshd answers (step 5), and this script is PID 1 until its last line. /proc/1/environ shows the
#      environment a program was started with, not what it exported later, so only a new exec puts the cleaned values
#      there. CLV_NC_ENTRYPOINT_REEXEC marks the second run, which removes it again.
#   1. Before the first install only (no version.php on the volume yet), it stops when NEXTCLOUD_ADMIN_PASSWORD is
#      missing, and gives the official entrypoint the database settings as MYSQL_HOST, MYSQL_DATABASE, MYSQL_USER and
#      MYSQL_PASSWORD, so later starts don't carry copies of them in PID 1's environment.
#   2. PHP's limits go into conf.d/zz-clouve.ini as plain values. The official nextcloud.ini reads them from the
#      environment, and occ run through sudo has none, so it would run at 128 MB with a warning on stdout.
#   3. Apache's worker count and the preview concurrency follow the container's memory limit (the sizing is in lib.sh).
#   4. Valkey, the in-container cache, has to answer before the official entrypoint starts: once the cache settings
#      are in config.php, occ fails without it. /run/clouve/tmp is the private folder for files that carry a secret.
#      When a restore was cut off, a note in /run/clouve says so, for the hooks, which can't see the restore marker.
#   5. The clouve-ops sshd for the AI Assistant. Its script starts sshd only when CLOUVE_OPS_PASSWORD is set. Then
#      CLOUVE_OPS_PASSWORD leaves this environment, so nothing started later (www-data's processes above all) has it.
#   6. It waits up to 5 minutes for the database, then exits 1, so that nothing after it runs occ against a database
#      that is not up yet. Then, when config.php exists, it makes config.php's database settings match NEXTCLOUD_DB_*.
#      A cloned deployment's config.php still names the database it was copied from, and the official entrypoint's
#      own occ upgrade would fail on it.
#   7. A backup that the old container cut off: it turns maintenance mode off and removes the backup's marker.
#   8. The init lock file belongs to www-data, so that the hooks (run as www-data) can lock it too. www-data makes it
#      (nc_make_init_lock): root never creates anything at that path, it only opens it read-only.
#   9. Cron starts once config.php says Nextcloud is installed and the volume's version.php is the image's.
#  10. exec /entrypoint.sh apache2-foreground. While a restore is cut off and the code on the volume is not this image's,
#      it starts Apache on the volume's code instead (nc_hold_upgrade_for_restore), so no upgrade runs on a half-restored
#      database and the AI Assistant can still reach Nextcloud to finish or undo the restore. The build changed two lines
#      of the official entrypoint (patch-official-entrypoint.sh): it opens the init lock read-only, and it runs the
#      volume's version.php as www-data.
#
# This script never logs or echoes a password and never puts one on a command line: PHP reads the database
# credentials from the environment.

set -eu

installer=/clouve/nextcloud/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || { printf '[nextcloud] ERROR: cannot read %s\n' "$installer/lib.sh" >&2; exit 1; }

# --- 0. the admin login and email, in PID 1's environment ------------------------------------------------------------

if [ "${CLV_NC_ENTRYPOINT_REEXEC-}" != 1 ]; then
    NEXTCLOUD_ADMIN_USER=$(nc_clean_admin_user "${NEXTCLOUD_ADMIN_USER:-admin}")
    NEXTCLOUD_ADMIN_EMAIL=$(nc_decode_entities "${NEXTCLOUD_ADMIN_EMAIL:-}")
    export NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_EMAIL
    export CLV_NC_ENTRYPOINT_REEXEC=1
    nc_log "admin login: $NEXTCLOUD_ADMIN_USER"
    exec "$0" "$@"
fi
unset CLV_NC_ENTRYPOINT_REEXEC

# --- 1. the database settings ----------------------------------------------------------------------------------------

for var in NEXTCLOUD_DB_HOST NEXTCLOUD_DB_NAME NEXTCLOUD_DB_USER NEXTCLOUD_DB_PASSWORD; do
    if [ -z "${!var-}" ]; then
        printf '[nextcloud] ERROR: %s is not set, so Nextcloud cannot reach its database\n' "$var" >&2
        exit 1
    fi
done

if [ ! -f /var/www/html/version.php ]; then
    # Without an admin password the official entrypoint copies the code and version.php but skips the install, and
    # every later start finds version.php and never installs. So the first start stops here instead, with the volume
    # still empty.
    if [ -z "${NEXTCLOUD_ADMIN_PASSWORD-}" ]; then
        printf '[nextcloud] ERROR: NEXTCLOUD_ADMIN_PASSWORD is not set, so the first install cannot run\n' >&2
        exit 1
    fi
    export MYSQL_HOST=$NEXTCLOUD_DB_HOST MYSQL_DATABASE=$NEXTCLOUD_DB_NAME MYSQL_USER=$NEXTCLOUD_DB_USER \
        MYSQL_PASSWORD=$NEXTCLOUD_DB_PASSWORD
fi

# --- 2. PHP's limits -------------------------------------------------------------------------------------------------

php_ini=/usr/local/etc/php/conf.d/zz-clouve.ini
if ! printf '; Written by %s at every start.\nmemory_limit=%s\nupload_max_filesize=%s\npost_max_size=%s\napc.shm_size=64M\n' \
        "$installer/entrypoint.sh" "${PHP_MEMORY_LIMIT:-512M}" "${PHP_UPLOAD_LIMIT:-512M}" "${PHP_UPLOAD_LIMIT:-512M}" \
        >"$php_ini"; then
    nc_warn "could not write $php_ini, so occ run through sudo gets PHP's default limits"
fi

# --- 3. Apache workers and previews ----------------------------------------------------------------------------------

mem=$(nc_memory_limit_mb)
workers=$(nc_apache_workers "$mem")
read -r preview_new preview_all <<<"$(nc_preview_concurrency "$mem")"
export CLV_PREVIEW_CONCURRENCY_NEW=$preview_new CLV_PREVIEW_CONCURRENCY_ALL=$preview_all

mpm_conf=/etc/apache2/conf-enabled/zz-clouve-mpm.conf
if ! printf '# Written by %s at every start, from the memory limit.\n<IfModule mpm_prefork_module>\n\tServerLimit %s\n\tMaxRequestWorkers %s\n</IfModule>\n' \
        "$installer/entrypoint.sh" "$workers" "$workers" >"$mpm_conf"; then
    nc_warn "could not write $mpm_conf, so Apache keeps its default of 150 workers"
fi
if [ -n "$mem" ]; then limit="memory limit $mem MB"; else limit="no memory limit"; fi
nc_log "$limit: Apache MaxRequestWorkers $workers, preview_concurrency_new $preview_new," \
    "preview_concurrency_all $preview_all"

# --- 4. the private folder, the restore note and Valkey ---------------------------------------------------------------

if ! install -d -o www-data -g www-data -m 700 /run/clouve/tmp; then
    printf '[nextcloud] ERROR: cannot make /run/clouve/tmp\n' >&2
    exit 1
fi

# The AI Assistant's restore.sh keeps a marker in data/clouve-backups while it works, and the hooks must then leave
# maintenance mode and any upgrade alone. The skill keeps that folder root's alone, so www-data, which runs the hooks,
# can't see the marker. Root writes a note in /run/clouve that the hooks read, or removes an old one
# (nc_note_restore_marker and nc_restore_cut_off in lib.sh).
nc_note_restore_marker

# Valkey's restart loop and cron (step 9) ignore SIGHUP. Apache, once it is PID 1, passes an ungraceful restart's
# SIGHUP (apache2ctl restart, kill -HUP 1) on with killpg(1), and for PID 1 that is every process in the container.
# Both would end for good, and a session of their own does not help. valkey-server ignores SIGHUP itself, and sshd
# reloads on it. An ignored signal stays ignored across exec.
#
# Valkey starts before step 5 drops CLOUVE_OPS_PASSWORD from this environment, so it drops it itself: valkey-server
# runs as www-data, and www-data can read the environment of its own processes.
valkey_sock=/run/clouve/valkey/valkey.sock
(
    trap '' HUP
    unset CLOUVE_OPS_PASSWORD
    exec "$installer/start-valkey.sh"
) &
deadline=$((SECONDS + 30))
until [ "$(timeout 3 valkey-cli -s "$valkey_sock" ping 2>/dev/null)" = PONG ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        printf '[nextcloud] ERROR: Valkey did not answer PING on %s within 30 s\n' "$valkey_sock" >&2
        exit 1
    fi
    sleep 1
done
nc_log "Valkey answers on $valkey_sock"

# --- 5. the clouve-ops sshd ------------------------------------------------------------------------------------------

"$installer/start-clouve-ops-sshd.sh" &

# The kit was forked with CLOUVE_OPS_PASSWORD and has its own copy, which it gives to chpasswd. Nothing started from
# here on may have it: every www-data process (Apache's PHP, the hooks, cron jobs) inherits this environment, and the
# password logs in as clouve-ops, who has passwordless sudo. The AI Assistant does not read it from this container
# (its env fetcher drops it), and sshd does not need it once the account's password is set.
unset CLOUVE_OPS_PASSWORD

# --- 6. the database -------------------------------------------------------------------------------------------------

# One try: a plain PDO connection with the credentials from the environment. It prints only the error message, never
# the stack trace, whose arguments would include the password. PDO::ATTR_TIMEOUT bounds only the TCP connect: the
# server's greeting is read under mysqlnd.net_read_timeout (86400 s in this image), so a server that accepts and never
# greets would hold a try past the deadline. timeout 10 bounds the whole try.
IFS= read -r -d '' db_check <<'PHP' || :
try {
    new PDO("mysql:host=" . getenv('NEXTCLOUD_DB_HOST') . ";dbname=" . getenv('NEXTCLOUD_DB_NAME'),
        getenv('NEXTCLOUD_DB_USER'), getenv('NEXTCLOUD_DB_PASSWORD'), [PDO::ATTR_TIMEOUT => 5]);
} catch (Throwable $e) {
    echo $e->getMessage(), "\n";
    exit(1);
}
PHP

db_wait=300
nc_log "waiting for the database at $NEXTCLOUD_DB_HOST (at most $db_wait s)"
deadline=$((SECONDS + db_wait))
next_log=$SECONDS
while :; do
    rc=0
    reason=$(timeout 10 php -d display_errors=stderr -r "$db_check" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        break
    fi
    if [ "$rc" -eq 124 ]; then
        reason='no answer within 10 s'
    elif [ -z "$reason" ]; then
        reason="php exited with status $rc and printed nothing"
    else
        reason=$(nc_first_lines "$reason")
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        printf '[nextcloud] ERROR: the database at %s did not answer within %s s, so Nextcloud is not started: %s\n' \
            "$NEXTCLOUD_DB_HOST" "$db_wait" "$reason" >&2
        exit 1
    fi
    # One line every 30 s is enough to see what is wrong.
    if [ "$SECONDS" -ge "$next_log" ]; then
        nc_log "the database does not answer yet: $reason"
        next_log=$((SECONDS + 30))
    fi
    sleep 5
done
nc_log "the database answers"

# The repair runs as www-data, which owns config.php: PHP includes config.php to read it, and config.php is code that
# www-data can change, so root must not run it. It needs no database. Its status is 0 when it changed config.php (it
# logs that), 1 when there was nothing to change and 2 when it could not (it warns). None of them stops the start.
if [ -f /var/www/html/config/config.php ]; then
    rc=0
    # shellcheck disable=SC2016  # $1 is for the inner bash, which gets the path of lib.sh as its first argument.
    runuser -u www-data -- bash -c '. "$1" && nc_repair_db_config' _ "$installer/lib.sh" || rc=$?
    case $rc in
        0 | 1 | 2) ;;
        *) nc_warn "the check of the database settings in config.php failed (exit status $rc)" ;;
    esac
fi

# --- 7. a backup that the old container cut off ----------------------------------------------------------------------

# The AI Assistant's backup.sh keeps a marker in data/clouve-backups, and holds a flock on it, while it holds maintenance
# mode on. A marker that nobody holds a lock on now means that the backup died with the old container, and maintenance
# mode stayed on. A locked one belongs to a backup the assistant started in this container (its sshd is up already), and
# is left alone. It is cleared here, by root: the hooks run as www-data, which can neither see nor remove a file in that
# folder, and the official entrypoint's own occ upgrade, which comes next, would keep a maintenance mode it finds on. occ
# runs as www-data, which owns config.php, and needs the database, so this comes after the wait (nc_clear_cut_off_backup
# in lib.sh).
if [ -f /var/www/html/config/config.php ]; then
    OCC='runuser -u www-data -- php /var/www/html/occ' nc_clear_cut_off_backup
fi

# --- 8. the init lock ------------------------------------------------------------------------------------------------

# The official entrypoint opens this file as root, read-only, and the before-starting hook locks it as www-data. The
# folder is www-data's, so www-data makes the file a plain file of its own (nc_make_init_lock in lib.sh), and root never
# creates anything here. A failure is a warning: a missing file then stops the official entrypoint at its open, and
# anything else left here opens, but the probe never counts the lock as held.
nc_make_init_lock /var/www/html/nextcloud-init-sync.lock || :

# --- 9. cron ---------------------------------------------------------------------------------------------------------

# BusyBox crond runs the image's root-owned crontab for www-data (*/5 * * * * php -f /var/www/html/cron.php), and its
# jobs inherit this environment. SIGHUP: see step 4.
#
# Cron also waits until the volume's version.php is the image's. On a start that upgrades, config.php already says
# installed while the official entrypoint is still copying the new code over the old, and cron.php must not run on
# that mix. version.php is the last file the copy writes. From then on cron.php itself skips until occ upgrade is done.
(
    trap '' HUP
    until grep -q "'installed' => true" /var/www/html/config/config.php 2>/dev/null &&
        cmp -s /var/www/html/version.php /usr/src/nextcloud/version.php; do
        sleep 10
    done
    exec busybox crond -f -L /dev/stdout
) &

# --- 10. the official entrypoint -------------------------------------------------------------------------------------

# While a restore is cut off, an upgrade to this image waits. The official entrypoint would copy the new code over the
# old and run occ upgrade on a half-restored database, and a failure there would stop the container at every start.
# Apache starts on the code that is on the volume instead, and the start after the restore upgrades as usual. Cron waits
# meanwhile (step 9 needs the image's version.php).
if nc_hold_upgrade_for_restore; then
    nc_warn "A restore was cut off ($(nc_marker_path restore) is there), and the code on the volume is not this image's, so the upgrade waits until the AI Assistant finishes or undoes the restore. Apache starts on the code that is there, without the official entrypoint."
    exec "$@"
fi
exec /entrypoint.sh "$@"
