FROM ubuntu:26.04

# Mirror — same as Moodle and other Clouve siblings. en_US baseline; tenants
# add their own locales at runtime if needed.
RUN apt-get update && apt-get install -y \
        openssh-server \
        sudo \
        locales \
        ca-certificates \
        busybox-static \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen \
    && apt-get clean autoclean \
    && apt-get autoremove -y \
    && rm -rfv /var/lib/{apt,dpkg,cache,log}/

# clouve-ops operator account for the magneto-agent's Claude Code agent.
# Password is set at runtime by entrypoint.sh from CLOUVE_OPS_PASSWORD
# (same value injected on both this container and magneto-agent).
# NOPASSWD: ALL — agent is a DevOps engineer with full root; safety
# gating lives in the ai-studio skill's SKILL.md, not in sudoers.
# Identical to the Moodle sibling's clouve-ops setup.
RUN useradd --create-home --shell /bin/bash \
        --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# sshd hardening drop-in: password-only, no root login, only clouve-ops.
# Picked up automatically by /etc/ssh/sshd_config's Include directive.
COPY installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf

# Required by sshd for its privilege-separation directory at runtime.
RUN mkdir -p /run/sshd

COPY installer/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# --- Persistent-volume bootstrap ------------------------------------------
# ai-studio persists /home /usr /opt /var so apt-installed packages and user
# files survive pod restarts. Docker auto-seeds a fresh *named volume* from the
# image, but a freshly-provisioned Kubernetes PVC mounts EMPTY over the path,
# masking the image's content there. On usr-merged Ubuntu 26.04 an empty /usr
# PVC hides bash, sshd AND this very entrypoint — the container then can't exec
# its ENTRYPOINT at all (RunContainerError). The working magneto-agent sibling
# avoids this by booting from /clouve (never a mounted volume); we do the same:
# a static busybox that needs nothing from /usr restores each empty volume from
# a snapshot baked here, then hands off to entrypoint.sh. The per-volume
# .clv-seeded marker means we seed exactly once and never clobber packages the
# agent installs later. See installer/init.sh.
#
# Snapshots are created with the same busybox that extracts them at runtime, so
# the archive format is guaranteed compatible. They are baked AFTER all image
# setup above, so each captures the fully-provisioned directory.
#
# /var is special-cased: Kubernetes mounts the service-account token under
# /var/run/secrets/..., which pre-creates /var/run as a *directory* in the
# otherwise-empty PVC. The image ships /var/run as a symlink (-> /run), so a
# naive extract aborts with "tar: can't remove old file ./run: Is a directory"
# and seeding fails (set -e). /var/run is ephemeral (a symlink to tmpfs /run)
# and never needs persisting, so the /var snapshot is taken from a copy with
# the run symlink removed.
RUN mkdir -p /clouve/seed && cp /bin/busybox /clouve/busybox
COPY installer/init.sh /clouve/init.sh
RUN chmod +x /clouve/init.sh \
    && for d in usr opt home; do \
         touch "/$d/.clv-seeded"; \
         /clouve/busybox tar -cf - -C "/$d" . | /clouve/busybox gzip -9 > "/clouve/seed/$d.tar.gz"; \
       done \
    && touch /var/.clv-seeded \
    && cp -a /var /clouve/varseed \
    && rm -f /clouve/varseed/run \
    && /clouve/busybox tar -cf - -C /clouve/varseed . | /clouve/busybox gzip -9 > /clouve/seed/var.tar.gz \
    && rm -rf /clouve/varseed

EXPOSE 22
# PID 1 is the bootstrap; it seeds the volumes then exec-chains to
# entrypoint.sh -> sshd, so sshd still ends up as PID 1.
ENTRYPOINT ["/clouve/busybox", "sh", "/clouve/init.sh"]
