#!/bin/bash
# gibbon-mysql entrypoint wrapper.
#
# Backgrounds the clouve-ops sshd bring-up (applies the per-pod password
# from CLOUVE_OPS_PASSWORD to the clouve-ops user via chpasswd, then
# exec's sshd -D), and chains to the upstream MySQL docker-entrypoint.sh
# as PID 1's main work.
#
# The background sshd inherits the container PID tree so it dies when
# mysqld exits — no orphaned processes.

set -e

/usr/local/bin/start-clouve-ops-sshd.sh &

exec /usr/local/bin/docker-entrypoint.sh "$@"
