#!/bin/bash
# odoo-postgres entrypoint wrapper. tini, PID 1, runs it.
#
# Starts the clouve-ops sshd in the background (start-clouve-ops-sshd.sh
# applies the per-pod password from CLOUVE_OPS_PASSWORD to the clouve-ops user
# with chpasswd, then execs sshd -D), then execs the upstream PostgreSQL
# docker-entrypoint.sh, so this shell becomes PostgreSQL, tini's child.
#
# CRITICAL ORDER: the official postgres docker-entrypoint.sh, when started as
# root, re-execs itself as the unprivileged `postgres` user via gosu. So sshd
# MUST be started here while we are still root (chpasswd/ssh-keygen/sshd
# need root); doing it after the exec would run as the postgres user and fail.
# sshd stops with the container: when PostgreSQL exits, tini exits too, and
# the container's other processes end with it.

set -e

# The subshell exits at once, so sshd's parent becomes tini (PID 1) rather
# than the shell that turns into postgres below: sshd is never a child of
# PostgreSQL's postmaster.
( /usr/local/bin/start-clouve-ops-sshd.sh & )

exec /usr/local/bin/docker-entrypoint.sh "$@"
