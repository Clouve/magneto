#!/bin/bash
# Keeps Valkey, the in-container cache, running.
#
# The entrypoint starts this as root, in the background, before it hands over to the official
# Nextcloud entrypoint, with SIGHUP ignored and without CLOUVE_OPS_PASSWORD in its environment:
#
#     (
#         trap '' HUP
#         unset CLOUVE_OPS_PASSWORD
#         exec /clouve/nextcloud/installer/start-valkey.sh
#     ) &
#
# Not as a plain "start-valkey.sh &". Apache, once it is PID 1, sends an ungraceful restart's SIGHUP
# to every process in the container, and this loop would die of it (entrypoint.sh, step 4, says
# why). valkey-server runs as www-data, which can read its environment, so it must not hold the
# clouve-ops password.
#
# It makes /run/clouve/valkey, owned by www-data with mode 700, so only www-data and root can reach
# the socket inside it, and runs valkey-server as www-data. Whenever Valkey exits, for any reason
# and with any status, the script logs one line on stderr, waits a second and starts it again. It
# stops only when it can't make the directory. It says so then, and the entrypoint's wait for
# Valkey fails the start.
#
# valkey.conf asks for a unix socket and no TCP port, so nothing outside the container can reach
# Valkey. It turns off snapshots and the append-only file, caps memory at 128 MB and drops the least
# recently used key when that fills up. Valkey holds only cache entries and short-lived file locks,
# so nothing needs to survive a restart. valkey.conf has no comments:
# tests/nextcloud-image.test.sh compares it with the planned text byte for byte.

set -u

sock_dir=/run/clouve/valkey
conf=/clouve/nextcloud/installer/valkey.conf

# install -d also puts right a directory that an earlier run left with another owner or mode.
if ! install -d -o www-data -g www-data -m 700 "$sock_dir"; then
    echo "[valkey] cannot make $sock_dir" >&2
    exit 1
fi

while true; do
    runuser -u www-data -- valkey-server "$conf"
    rc=$?
    echo "[valkey] exited with $rc; restarting in 1 s" >&2
    sleep 1
done
