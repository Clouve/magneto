#!/bin/bash
# AI Studio entrypoint.
#
# Invoked by the /clouve/init.sh bootstrap once it has seeded the persistent
# volumes (see installer/init.sh). The bootstrap exec's us and we exec
# supervisord, so supervisord ends up as PID 1 — when it exits the container
# exits and Kubernetes restarts it. Failing loudly is preferred over a
# "running-but-unreachable" zombie.
#
# Unlike Moodle and other siblings where one workload process is THE app,
# this workspace runs a whole supervised stack: sshd (the Magneto Agent's
# path in), mongod, the seed MERN project's backend + frontend dev servers,
# and mongo-express. supervisord starts them all on every boot and restarts
# any that die — see /etc/supervisor/supervisord.conf. There is no systemd
# in this container.
#
# Flow on each container start:
#   1. Refuse to start if CLOUVE_OPS_PASSWORD is unset (agent can't reach
#      us without it; failing fast surfaces the misconfiguration in pod logs).
#   2. Generate sshd host keys if missing (ssh-keygen -A is idempotent).
#      Stored under /etc/ssh — not under any persistent volume — so they
#      regenerate per pod. The agent disables StrictHostKeyChecking by
#      convention; persisting host keys offers no security benefit here.
#   3. Apply the per-pod operator password via chpasswd.
#   4. exec supervisord -n so it becomes PID 1 and brings up the stack.

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

# sshd's privilege-separation dir lives under /run (tmpfs on some platforms);
# recreate it in case the image-baked one didn't survive the mount.
mkdir -p /run/sshd

echo "$PREFIX Starting supervisord (PID 1) — sshd, mongod, backend, frontend, mongo-express"
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
