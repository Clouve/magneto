#!/bin/bash
# odoo-postgres entrypoint wrapper.
#
# Backgrounds the clouve-ops sshd bring-up (applies the per-pod password from
# CLOUVE_OPS_PASSWORD to the clouve-ops user via chpasswd, then exec's sshd -D),
# and chains to the upstream PostgreSQL docker-entrypoint.sh as PID 1's work.
#
# CRITICAL ORDER: the official postgres docker-entrypoint.sh, when started as
# root, re-execs itself as the unprivileged `postgres` user via gosu. So sshd
# MUST be backgrounded here while we are still root (chpasswd/ssh-keygen/sshd
# need root); doing it after the exec would run as the postgres user and fail.
# The background sshd inherits the container PID tree so it dies when postgres
# exits — no orphaned processes.

set -e

/usr/local/bin/start-clouve-ops-sshd.sh &

exec /usr/local/bin/docker-entrypoint.sh "$@"
