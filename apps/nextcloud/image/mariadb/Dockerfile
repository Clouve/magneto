# MariaDB Database Image for Nextcloud
# This Dockerfile uses the official MariaDB image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits
#
# PINNED: mariadb:12.3, the newest MariaDB that Nextcloud 35 supports (10.11
# to 12.3). An unpinned FROM lets a newer engine ship under existing tenant
# data volumes on the next rebuild (the exact drift class that CrashLooped
# Moodle). Bump this tag deliberately, never back to :latest.

FROM mariadb:12.3

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MariaDB database for Nextcloud"
LABEL version="12.3"

# Lets the entrypoint run mariadb-upgrade by itself when a newer engine starts
# on an older data directory. The image sets it, not the manifest, because
# nothing re-applies a newer manifest to a running deployment. Only a new image
# reaches it.
ENV MARIADB_AUTO_UPGRADE=1

# clouve-ops shell channel (mirrors the same setup in apps/nextcloud/image/
# Dockerfile). openssh-server lets the magneto-agent container's Claude Code
# agent `ssh clouve-ops@${NEXTCLOUD_DB_HOST}` for OS-level operations on the
# DB host (mariadbd restart, log inspection, config tweaks, disk usage). The
# routine SQL surface is still the TCP MySQL client.
# (procps and iproute2 already ship in the base image; less/vim/diff do not.)
# openssh-server's install makes SSH host keys, and they go again at the end:
# kept, they would ship in the pushed image and every tenant would share one
# host key. Each container makes its own at start instead (ssh-keygen -A in
# start-clouve-ops-sshd.sh).
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo less vim-tiny diffutils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops \
    && rm -f /etc/ssh/ssh_host_*

COPY clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
# Nextcloud's database settings: isolation level, utf8mb4, redo log size and
# connection limit.
COPY nextcloud.cnf /etc/mysql/conf.d/nextcloud.cnf
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh \
    && chmod 0644 /etc/mysql/conf.d/nextcloud.cnf

# Wrap the upstream docker-entrypoint.sh so we get the buffer pool sizing and
# sshd alongside mariadbd.
ENTRYPOINT ["/usr/local/bin/clouve-entrypoint.sh"]
CMD ["mariadbd"]
