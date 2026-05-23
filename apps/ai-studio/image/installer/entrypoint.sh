#!/bin/bash
# AI Studio entrypoint — PID 1.
#
# Unlike Moodle and other siblings where sshd runs in a background tree
# alongside the main workload (apache/mysql), here sshd IS the workload.
# Exec it directly as PID 1 — when sshd exits, the container exits and
# Kubernetes restarts it. Failing loudly is preferred over a
# "running-but-unreachable" zombie.
#
# Flow on each container start:
#   1. Refuse to start if CLOUVE_OPS_PASSWORD is unset (agent can't reach
#      us without it; failing fast surfaces the misconfiguration in pod logs).
#   2. Generate sshd host keys if missing (ssh-keygen -A is idempotent).
#      Stored under /etc/ssh — not under any persistent volume — so they
#      regenerate per pod. The agent disables StrictHostKeyChecking by
#      convention; persisting host keys offers no security benefit here.
#   3. Apply the per-pod operator password via chpasswd.
#   4. exec sshd -D so it becomes PID 1.

set -e

PREFIX="[ai-studio]"

if [ -z "${CLOUVE_OPS_PASSWORD:-}" ]; then
    echo "$PREFIX CLOUVE_OPS_PASSWORD is unset — refusing to start" >&2
    exit 1
fi

echo "$PREFIX Generating sshd host keys if missing..."
ssh-keygen -A >/dev/null 2>&1

echo "$PREFIX Applying clouve-ops password from CLOUVE_OPS_PASSWORD"
echo "clouve-ops:$CLOUVE_OPS_PASSWORD" | chpasswd

echo "$PREFIX Starting sshd (PID 1) on :22"
exec /usr/sbin/sshd -D -e
