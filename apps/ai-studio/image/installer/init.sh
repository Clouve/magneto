#!/clouve/busybox sh
# Bootstrap: seed empty volumes from image snapshots before starting the server.
# Uses /clouve/busybox (a static binary) so this runs even when /usr is mounted
# as an empty PVC or bind-mount. On first start it unpacks the seeds and writes
# a sentinel file (.clouve-seeded) inside the PVC; on subsequent starts the
# sentinel is present so seeding is skipped, preserving any user data.

seed() {
    SENTINEL="$1/.clouve-seeded"
    if [ ! -f "$SENTINEL" ]; then
        /clouve/busybox printf '[init] Seeding %s ...\n' "$1"
        if /clouve/busybox tar xzf "$2" -C /; then
            /clouve/busybox touch "$SENTINEL"
            /clouve/busybox printf '[init] %s ready.\n' "$1"
        else
            /clouve/busybox printf '[init] ERROR: failed to seed %s — will retry on next start.\n' "$1"
        fi
    fi
}

seed /usr /clouve/usr-seed.tar.gz
seed /var /clouve/var-seed.tar.gz

exec /clouve/ai-studio/installer/entrypoint.sh
