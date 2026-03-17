#!/clouve/busybox sh
# Bootstrap: seed empty volumes from image snapshots before starting the server.
# Uses /clouve/busybox (a static binary) so this runs even when /usr is mounted
# as an empty PVC or bind-mount. On first start it unpacks the seeds; on
# subsequent starts the volumes are non-empty so it skips straight to exec.

seed() {
    if [ -z "$(/clouve/busybox ls -A "$1" 2>/dev/null)" ]; then
        printf '[init] Seeding %s ...\n' "$1"
        /clouve/busybox tar xzf "$2" -C /
        printf '[init] %s ready.\n' "$1"
    fi
}

seed /usr          /clouve/usr-seed.tar.gz
seed /var/lib/dpkg /clouve/dpkg-seed.tar.gz

exec /clouve/claude/installer/entrypoint.sh
