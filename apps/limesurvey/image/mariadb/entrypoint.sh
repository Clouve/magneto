#!/bin/bash
# limesurvey-mariadb entrypoint wrapper. tini, PID 1, runs it.
#
# 1. It refuses a data directory that a newer MariaDB line wrote. MariaDB
#    starts on newer files without complaint, but going back to an older line
#    is not supported and can damage the data. mariadb-upgrade records the
#    version it last ran for in mariadb_upgrade_info (mysql_upgrade_info in
#    older data directories), and that is what the check reads.
# 2. It starts the clouve-ops sshd in the background (start-clouve-ops-sshd.sh
#    gives the clouve-ops user the password in CLOUVE_OPS_PASSWORD, then
#    becomes sshd -D).
# 3. It becomes the upstream MariaDB docker-entrypoint.sh, so this shell turns
#    into mariadbd, tini's child. mariadbd doesn't reap processes it didn't
#    start, such as what an SSH session leaves behind; tini does, and passes
#    docker stop's signal on to mariadbd.
#
# CLOUVE_OPS_PASSWORD doesn't go on to mariadbd (see below).

set -e

datadir=/var/lib/mysql

# line_of VERSION: "11.8" for "11.8.9-MariaDB", nothing for anything that doesn't start with two numbers.
line_of() {
    printf '%s\n' "$1" | sed -n 's/^\([0-9]\{1,\}\)\.\([0-9]\{1,\}\).*/\1.\2/p' | head -n 1
}

case "${1:-}" in
    mariadbd | mysqld | -*)
        info=""
        for file in "$datadir/mariadb_upgrade_info" "$datadir/mysql_upgrade_info"; do
            if [ -f "$file" ]; then info="$file"; break; fi
        done
        if [ -n "$info" ]; then
            data_line="$(line_of "$(head -n 1 "$info" 2>/dev/null)")"
            image_line="$(line_of "$(mariadbd --version 2>/dev/null | sed -n 's/.* Ver \([0-9][0-9.]*\).*/\1/p')")"
            if [ -n "$data_line" ] && [ -n "$image_line" ] && [ "$data_line" != "$image_line" ] &&
                [ "$(printf '%s\n%s\n' "$data_line" "$image_line" | sort -V | tail -n 1)" = "$data_line" ]; then
                echo "[limesurvey-mariadb] ERROR: the data directory $datadir was written by MariaDB $data_line, which is newer than this image's MariaDB $image_line. MariaDB can't go back to an older line, so the database is not started and the data is left as it is. Start it with an image whose MariaDB is $data_line or newer." >&2
                exit 1
            fi
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
