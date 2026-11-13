#!/bin/bash
# suitecrm-mariadb entrypoint wrapper. tini, PID 1, runs it.
#
# Before anything starts, it reads which MariaDB last used the data directory
# and stops when that was a newer release line than this image's. Then it
# starts the clouve-ops sshd in the background (start-clouve-ops-sshd.sh
# applies the per-pod password from CLOUVE_OPS_PASSWORD to the clouve-ops user
# with chpasswd, then execs sshd -D), and execs the upstream MariaDB
# docker-entrypoint.sh, so this shell becomes mariadbd, tini's child. mariadbd
# doesn't reap processes it didn't start, such as what an SSH session leaves
# behind; tini does, and passes docker stop's signal on to mariadbd.
#
# CLOUVE_OPS_PASSWORD doesn't go on to mariadbd (see below).

set -e

# The data directory records the MariaDB that created it, or last ran
# mariadb-upgrade on it, in mariadb_upgrade_info (mysql_upgrade_info in older
# releases): one line such as 12.1.2-MariaDB. MariaDB starts on files from a
# newer release line without complaint, but going back a line is not supported
# and can damage the data, so this wrapper refuses instead. An older line is
# fine: MARIADB_AUTO_UPGRADE=1 (set in the image) upgrades it. A new disk has
# no such file. CLV_DATADIR is for tests; nothing sets it in a deployment.
datadir="${CLV_DATADIR:-/var/lib/mysql}"

# line_of VERSION: "12.3" for 12.3.3-MariaDB, nothing for anything else.
line_of() {
    if [[ "$1" =~ ^([0-9]{1,4})\.([0-9]{1,4})\. ]]; then
        echo "$((10#${BASH_REMATCH[1]})).$((10#${BASH_REMATCH[2]}))"
    fi
}

case "${1:-}" in
    mariadbd | mysqld | mariadbd-safe | mysqld_safe)
        recorded=""
        for info in "$datadir/mariadb_upgrade_info" "$datadir/mysql_upgrade_info"; do
            if [ -f "$info" ] && [ ! -L "$info" ]; then
                IFS= read -r -n 64 recorded < "$info" || true
                break
            fi
        done
        data_line="$(line_of "$recorded")"
        image_version="$(mariadbd --version 2>/dev/null | sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p')"
        image_line="$(line_of "$image_version")"
        if [ -n "$data_line" ] && [ -n "$image_line" ]; then
            if [ "${data_line%%.*}" -gt "${image_line%%.*}" ] ||
                { [ "${data_line%%.*}" -eq "${image_line%%.*}" ] && [ "${data_line##*.}" -gt "${image_line##*.}" ]; }; then
                echo "[suitecrm-mariadb] ERROR: the data directory $datadir was last used by MariaDB $recorded, which is newer than this image's MariaDB $image_version. MariaDB can't go back to an older release line, so this container is refusing to start and has changed nothing. Run the image this deployment had before, or one with MariaDB $data_line or newer." >&2
                exit 1
            fi
        elif [ -n "$recorded" ] && [ -z "$data_line" ]; then
            echo "[suitecrm-mariadb] WARNING: can't read a MariaDB version from the data directory's upgrade info, so the check for a newer release line was skipped" >&2
        fi
        ;;
esac

# The subshell exits at once, so sshd's parent becomes tini (PID 1) rather
# than the shell that turns into mariadbd below.
( /usr/local/bin/start-clouve-ops-sshd.sh & )

# The sshd start above has its own copy of CLOUVE_OPS_PASSWORD, and PID 1
# (tini) keeps it, in an environment only root can read. mariadbd doesn't get
# it: anything that runs as the mysql user can read mariadbd's environment, and
# the password signs in as clouve-ops, who has passwordless sudo.
unset CLOUVE_OPS_PASSWORD

exec /usr/local/bin/docker-entrypoint.sh "$@"
