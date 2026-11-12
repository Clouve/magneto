#!/bin/bash
# wordpress-mariadb entrypoint wrapper. tini, PID 1, runs it.
#
# Starts the clouve-ops sshd in the background (start-clouve-ops-sshd.sh
# applies the per-pod password from CLOUVE_OPS_PASSWORD to the clouve-ops user
# with chpasswd, then execs sshd -D), then execs the upstream MariaDB
# docker-entrypoint.sh, so this shell becomes mariadbd, tini's child. mariadbd
# doesn't reap processes it didn't start, such as what an SSH session leaves
# behind; tini does, and passes docker stop's signal on to mariadbd.
#
# CLOUVE_OPS_PASSWORD doesn't go on to mariadbd (see below).

set -e

# The subshell exits at once, so sshd's parent becomes tini (PID 1) rather
# than the shell that turns into mariadbd below.
( /usr/local/bin/start-clouve-ops-sshd.sh & )

# The sshd start above has its own copy of CLOUVE_OPS_PASSWORD, and PID 1
# (tini) keeps it, in an environment only root can read. mariadbd doesn't get
# it: anything that runs as the mysql user can read mariadbd's environment, and
# the password signs in as clouve-ops, who has passwordless sudo.
unset CLOUVE_OPS_PASSWORD

exec /usr/local/bin/docker-entrypoint.sh "$@"
