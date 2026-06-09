#!/bin/sh
# AI Studio bootstrap — PID 1, run via the static /clouve/busybox so it needs
# nothing from /usr (which may be an empty volume at this point).
#
# Why this exists
# ---------------
# The ai-studio Deployment mounts persistent volumes over /usr /var /opt /home
# so apt-installed packages and user files survive pod restarts. Docker seeds a
# fresh named volume from the image automatically; a fresh Kubernetes PVC does
# NOT — it mounts empty and masks the image's content at that path. On
# usr-merged Ubuntu 26.04 an empty /usr hides bash, sshd AND the entrypoint
# itself, so the container can't even start (RunContainerError: entrypoint.sh
# not found). The working magneto-agent sibling avoids this by booting from
# /clouve (never a mounted volume); we do the same here.
#
# This bootstrap restores each empty volume from a snapshot baked into the
# image at build time, then hands off to the real entrypoint. The per-volume
# .clv-seeded marker (baked into the snapshot) means: seed exactly once on
# first boot, and NEVER overwrite packages the agent apt-installs later. On
# Docker the marker rides in on the auto-seeded volume, so seeding is correctly
# skipped there.
set -e

BB=/clouve/busybox
PREFIX="[ai-studio:init]"

for d in usr var opt home; do
    seed="/clouve/seed/$d.tar.gz"
    # Already-seeded volume (fresh-but-restored on a prior boot, or Docker's
    # auto-seed which carries the baked marker): leave it untouched so the
    # agent's installs and files persist.
    if [ -e "/$d/.clv-seeded" ]; then
        continue
    fi
    if [ ! -f "$seed" ]; then
        echo "$PREFIX WARNING: no snapshot for /$d ($seed missing) — skipping" >&2
        continue
    fi
    echo "$PREFIX /$d is an unseeded volume — restoring from image snapshot"
    "$BB" zcat "$seed" | "$BB" tar -xf - -C "/$d"
done

echo "$PREFIX volumes ready — starting ai-studio"
exec /usr/local/bin/entrypoint.sh
