#!/bin/bash
# Background helper that brings up sshd for the clouve-ops operator account.
#
# Designed to be backgrounded from this image's entrypoint:
#
#     /clouve/gibbon/installer/start-clouve-ops-sshd.sh &
#     exec "$@"
#
# Flow on each container start:
#   1. Generate sshd host keys if missing (ssh-keygen -A is idempotent).
#   2. Wait for the per-pod public key to appear at
#      /clouve/ops-keys/id_ed25519.pub. The file is dropped there by
#      gibbon-ai-studio's entrypoint on first pod boot, via the
#      `clouve_ops_keys` volume shared between all three containers.
#   3. Install that public key as the only authorized_key for the
#      pre-created clouve-ops user (passwordless sudo).
#   4. Replace the script process with `sshd -D` so SSH is the only thing
#      running in this background tree — when the container's main process
#      (apache2-foreground / mysqld) exits, sshd is reaped along with it.
#
# Idempotent: re-running on container restart re-generates host keys
# (skipped if present), re-installs the same authorized_key, and re-execs
# sshd. No persistent state outside of /etc/ssh/ssh_host_*_key.

set -e

KEY_FILE=/clouve/ops-keys/id_ed25519.pub
AUTH_KEYS=/home/clouve-ops/.ssh/authorized_keys
TIMEOUT=120
PREFIX="[clouve-ops-sshd]"

echo "$PREFIX Generating sshd host keys if missing..."
ssh-keygen -A >/dev/null 2>&1

echo "$PREFIX Waiting for clouve-ops public key at $KEY_FILE (timeout ${TIMEOUT}s)..."
elapsed=0
while [ ! -s "$KEY_FILE" ]; do
    if [ $elapsed -ge $TIMEOUT ]; then
        echo "$PREFIX ✗ Timed out waiting for public key — sshd will not start"
        exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
done

echo "$PREFIX ✓ Public key found, installing into $AUTH_KEYS"
install -d -m 0700 -o clouve-ops -g clouve-ops /home/clouve-ops/.ssh
install -m 0600 -o clouve-ops -g clouve-ops "$KEY_FILE" "$AUTH_KEYS"

mkdir -p /run/sshd
echo "$PREFIX Starting sshd (foreground in background tree)"
exec /usr/sbin/sshd -D
