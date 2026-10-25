#!/bin/sh
# Kubernetes probe for the nextcloud container. The platform uses this one command for both the
# liveness and the readiness probe and runs it as
#
#     /bin/sh -c /clouve/nextcloud/installer/healthcheck.sh
#
# where sh is dash, so the script has to stay POSIX. It runs as root. Exit 0 means healthy and 1
# means not. The checks, in order:
#
#   1. A restore that was cut off: it is healthy whatever else is true. The AI Assistant's restore
#      marker says so, when it passes the test of nc_marker_trusted in lib.sh (a plain file of
#      root's, in a folder of root's that nobody else can write to). The root entrypoint's note in
#      /run/clouve doesn't count: it is for the hooks, and it stays until the next start, also after
#      a restore that the assistant finished without one. Nextcloud can't work while a restore is cut
#      off, but a restart can't help, and a pod that is not Ready has no address, so the assistant
#      could not reach it to finish or undo the restore.
#   2. If Nextcloud's init lock is held, it is healthy whatever else is true. The official
#      entrypoint holds the lock during an install and an upgrade, and lets go before its
#      before-starting hooks run. So the recovery of an interrupted upgrade is covered only
#      because our before-starting hook takes the lock itself. Apache isn't running yet during
#      any of those. The assistant's long jobs take the same lock (backups, restores and the
#      skill's occ.sh --init-lock), and then Apache can be up, in maintenance mode. Either way, a
#      container killed halfway through is worse off than one that waits.
#   3. Valkey must answer PING.
#   4. status.php, fetched from localhost, must answer HTTP 200 with JSON that says
#      "installed":true. Maintenance mode and a pending upgrade answer 200 too, so they count as
#      healthy and the pod stays reachable for the assistant that fixes them.
#
# The lock is tested the safe way. The lock file and its folder are www-data's, so www-data can
# swap the file for a symlink or a named pipe at any moment, and flock creates a file that is
# missing. So the test runs as www-data, looks only at a plain file, and gives up after 3 s. It
# takes a shared lock: liveness and readiness run at the same moment, and two shared locks never
# conflict, while every holder that counts (an install, an upgrade, a backup, a restore) holds it
# exclusively. Only flock's own "held" (exit 75) counts as held; any other failure goes on to the
# real checks. Every call has a limit (the lock 3 s, Valkey 3 s, curl 8 s), so a run ends inside
# the 15 s the manifest allows. When it says no, it says why on stderr, and kubelet shows that text
# in the probe-failed event.
#
# NC_HEALTH_LOCK, NC_HEALTH_SOCK, NC_HEALTH_URL and NC_HEALTH_MARKER move the things it looks at.
# They are for tests/nextcloud-image.test.sh; nothing sets them in a deployment.

lock=${NC_HEALTH_LOCK:-/var/www/html/nextcloud-init-sync.lock}
sock=${NC_HEALTH_SOCK:-/run/clouve/valkey/valkey.sock}
url=${NC_HEALTH_URL:-http://127.0.0.1/status.php}
marker=${NC_HEALTH_MARKER:-/var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS}

# marker_trusted FILE: succeeds when FILE is a plain file of root's (not a symlink) in a folder of root's (not a
# symlink) that its group and others can't write to, as nc_marker_trusted in lib.sh.
marker_trusted() {
    dir=${1%/*}
    [ -f "$1" ] && [ ! -L "$1" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(stat -c %u -- "$1" 2>/dev/null)" = 0 ] && [ "$(stat -c %u -- "$dir" 2>/dev/null)" = 0 ] || return 1
    mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 1
    case $mode in
        '' | *[!0-7]*) return 1 ;;
    esac
    [ $((0$mode & 022)) -eq 0 ]
}

if marker_trusted "$marker"; then
    exit 0
fi

# shellcheck disable=SC2016  # the single-quoted text is the script for the inner sh, which gets the path as $1
timeout 3 runuser -u www-data -- sh -c '[ -f "$1" ] && [ ! -L "$1" ] || exit 11; exec flock -n -s -E 75 "$1" true' _ "$lock"
if [ $? -eq 75 ]; then
    exit 0
fi

reply=$(timeout 3 valkey-cli -s "$sock" ping)
if [ "$reply" != PONG ]; then
    printf '%s\n' "[healthcheck] Valkey did not answer PING on $sock" >&2
    exit 1
fi

body=$(curl -fsS -m 8 -H 'Host: localhost' "$url")
rc=$?
if [ "$rc" -ne 0 ]; then
    printf '%s\n' "[healthcheck] $url failed (curl exit $rc)" >&2
    exit 1
fi

case $body in
    *'"installed":true'*) exit 0 ;;
esac
printf '%s\n' '[healthcheck] status.php does not say "installed":true' >&2
exit 1
