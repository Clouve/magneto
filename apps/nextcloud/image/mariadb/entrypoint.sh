#!/bin/bash
# nextcloud-mariadb entrypoint wrapper. tini, PID 1, runs it.
#
# Sizes the InnoDB buffer pool from the container's memory limit, then
# starts the clouve-ops sshd in the background (it applies the per-pod
# password from CLOUVE_OPS_PASSWORD to the clouve-ops user via chpasswd, then
# execs sshd -D), drops CLOUVE_OPS_PASSWORD from its own environment, and
# execs the upstream MariaDB docker-entrypoint.sh, so this shell becomes
# mariadbd, tini's child. mariadbd doesn't reap processes it didn't start,
# such as what an SSH session leaves behind; tini does, and passes docker
# stop's signal on to mariadbd.

set -e

# The buffer pool is a quarter of the memory limit, between 128 MB and 4096 MB,
# or 256 MB when the container has no limit. The wrapper works this out at
# every start, so a plan change that raises the limit takes effect when the pod
# restarts. The file name sorts after nextcloud.cnf, so MariaDB uses this value.
#
# NC_CGROUP_ROOT is for tests/nextcloud-mariadb.test.sh, which points it at
# made-up cgroup trees. Nothing sets it in a deployment.
cgroup_root="${NC_CGROUP_ROOT:-/sys/fs/cgroup}"
memory_cnf=/etc/mysql/conf.d/zz-clouve-memory.cnf

# Prints the container's memory limit in bytes, or nothing when it has none.
# cgroup v2 keeps the limit in memory.max, and "max" means none. cgroup v1
# keeps it in memory/memory.limit_in_bytes, and a number of 2^60 or more means
# none (the kernel reports 9223372036854771712). The v1 file is read only when
# the v2 file doesn't exist.
memory_limit_bytes() {
    local file value unlimited=1152921504606846976    # 2^60
    if [ -r "$cgroup_root/memory.max" ]; then
        file="$cgroup_root/memory.max"
    elif [ -r "$cgroup_root/memory/memory.limit_in_bytes" ]; then
        file="$cgroup_root/memory/memory.limit_in_bytes"
    else
        return 0
    fi
    value=$(cat "$file" 2>/dev/null) || return 0
    case "$value" in
        '' | *[!0-9]*) return 0 ;;   # "max", or anything else that isn't a number
    esac
    # 2^60 or more is no limit. [ also fails on a number too big for the
    # shell's integers, and that is no limit too.
    if ! [ "$value" -lt "$unlimited" ] 2>/dev/null; then return 0; fi
    echo $((10#$value))
}

limit=$(memory_limit_bytes)
if [ -n "$limit" ]; then
    pool_mb=$((limit / 4 / 1048576))
    if [ "$pool_mb" -lt 128 ]; then pool_mb=128; fi
    if [ "$pool_mb" -gt 4096 ]; then pool_mb=4096; fi
    note="Memory limit $((limit / 1048576)) MB"
else
    pool_mb=256
    note="No memory limit"
fi

# A pool that can't be sized must not stop the database from starting.
if { printf '[mysqld]\ninnodb_buffer_pool_size = %sM\n' "$pool_mb" > "$memory_cnf" && chmod 644 "$memory_cnf"; }; then
    echo "[nextcloud-mariadb] $note: innodb_buffer_pool_size = ${pool_mb}M"
else
    echo "[nextcloud-mariadb] WARNING: could not write $memory_cnf, so MariaDB keeps its default buffer pool" >&2
fi

# The subshell exits at once, so sshd's parent becomes tini (PID 1) rather
# than the shell that turns into mariadbd below.
( /usr/local/bin/start-clouve-ops-sshd.sh & )

# The kit was forked with CLOUVE_OPS_PASSWORD and has its own copy, which it
# gives to chpasswd. mariadbd must not carry it: any process that runs as mysql
# can read mariadbd's environment, and the password logs in as clouve-ops, who
# has passwordless sudo. PID 1 (tini) keeps it, in an environment only root can
# read. The official entrypoint already drops its own passwords before it
# starts mariadbd.
unset CLOUVE_OPS_PASSWORD

exec /usr/local/bin/docker-entrypoint.sh "$@"
