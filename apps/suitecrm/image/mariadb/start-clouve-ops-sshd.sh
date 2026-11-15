#!/bin/bash
# Brings up sshd for the clouve-ops operator account. This image's entrypoint
# runs it in the background:
#
#     ( /usr/local/bin/start-clouve-ops-sshd.sh & )
#
# At each container start it:
#   1. Makes the sshd host keys when they are missing (ssh-keygen -A). The
#      image ships none, so every container has its own.
#   2. Reads the per-pod operator password from CLOUVE_OPS_PASSWORD and applies
#      it to the clouve-ops user with chpasswd. This service, suitecrm and
#      the magneto-agent container get the same value: a fixed one in the
#      local compose file, one the platform makes on Clouve.
#   3. Becomes `sshd -D`, so sshd is the only process in this background
#      tree. It ends with the container, when mariadbd exits.
#
# Running it again at a restart does the same again. It keeps no state other
# than /etc/ssh/ssh_host_*_key.

set -e

PREFIX="[clouve-ops-sshd]"

if [ -z "$CLOUVE_OPS_PASSWORD" ]; then
    echo "$PREFIX CLOUVE_OPS_PASSWORD is not set, so sshd is not started" >&2
    exit 1
fi

echo "$PREFIX Generating sshd host keys if missing..."
ssh-keygen -A >/dev/null 2>&1

echo "$PREFIX Applying clouve-ops password from CLOUVE_OPS_PASSWORD"
echo "clouve-ops:$CLOUVE_OPS_PASSWORD" | chpasswd

mkdir -p /run/sshd
echo "$PREFIX Starting sshd (foreground in background tree)"
exec /usr/sbin/sshd -D
