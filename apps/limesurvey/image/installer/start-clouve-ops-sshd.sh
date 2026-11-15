#!/bin/bash
# Starts the sshd for the clouve-ops operator account. The entrypoint runs it in the background:
#
#     /clouve/limesurvey/installer/start-clouve-ops-sshd.sh &
#
# At each container start it:
#   1. makes the SSH host keys when they are missing (the image ships none, so each container has its own);
#   2. gives the clouve-ops user the password in CLOUVE_OPS_PASSWORD (the platform sets the same value on this
#      service, on limesurvey-mariadb and on the magneto-agent container);
#   3. becomes sshd -D, so sshd is the only process of this background tree.
# Without CLOUVE_OPS_PASSWORD it says so and exits: a deployment without the AI Assistant has no sshd.
# It never prints the password.

set -e

PREFIX="[clouve-ops-sshd]"

if [ -z "${CLOUVE_OPS_PASSWORD:-}" ]; then
    echo "$PREFIX CLOUVE_OPS_PASSWORD is not set, so sshd is not started" >&2
    exit 1
fi

echo "$PREFIX Making the SSH host keys if they are missing"
ssh-keygen -A >/dev/null 2>&1

echo "$PREFIX Setting the clouve-ops password from CLOUVE_OPS_PASSWORD"
echo "clouve-ops:$CLOUVE_OPS_PASSWORD" | chpasswd

mkdir -p /run/sshd
echo "$PREFIX Starting sshd"
exec /usr/sbin/sshd -D
