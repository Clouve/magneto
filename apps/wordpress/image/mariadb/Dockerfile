# MariaDB Database Image for WordPress
# This Dockerfile uses the official MariaDB image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits
#
# PINNED: mariadb:12.3 (what :latest resolved to on 2026-08-05 — 12.3.2).
# An unpinned FROM lets a newer engine ship under existing tenant data
# volumes on the next rebuild (the exact drift class that CrashLooped
# Moodle). Bump this tag deliberately, never back to :latest.

FROM mariadb:12.3

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MariaDB database for WordPress CMS"
LABEL version="12.3"

# The official MariaDB image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

# clouve-ops shell channel (mirrors the same setup in apps/wordpress/image/
# Dockerfile). openssh-server lets the magneto-agent container's Claude Code
# agent `ssh clouve-ops@${WORDPRESS_DB_HOST}` for OS-level operations on the
# DB host (mariadbd restart, log inspection, config tweaks, disk usage). The
# routine SQL surface is still the TCP MySQL client.
# (procps and iproute2 already ship in the base image; less/vim/diff do not.)
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo less vim-tiny diffutils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops

COPY clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh

# Wrap the upstream docker-entrypoint.sh so we get sshd alongside mariadbd.
ENTRYPOINT ["/usr/local/bin/clouve-entrypoint.sh"]
CMD ["mariadbd"]
