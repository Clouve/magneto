#!/bin/bash
# gibbon-mysql entrypoint wrapper.
#
# Backgrounds the clouve-ops sshd bring-up (waits for the per-pod public
# key dropped by gibbon-ai-studio into /clouve/ops-keys/, installs it as
# the only authorized key, then exec's sshd -D), and chains to the
# upstream MySQL docker-entrypoint.sh as PID 1's main work.
#
# The background sshd inherits the container PID tree so it dies when
# mysqld exits — no orphaned processes.

set -e

/usr/local/bin/start-clouve-ops-sshd.sh &

exec /usr/local/bin/docker-entrypoint.sh "$@"
