# MySQL 8.4 Database Image for Moodle Learning Management System
# This Dockerfile uses the official MySQL 8.4 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

FROM mysql:8.4

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MySQL 8.4 database for Moodle Learning Management System"
LABEL version="8.4"

# The official MySQL image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

# clouve-ops shell channel (mirrors the same setup in apps/moodle/image/
# Dockerfile). openssh-server lets the magneto-agent container's Claude Code
# agent `ssh clouve-ops@${MOODLE_DB_HOST}` for OS-level operations on the
# DB host (mysqld restart, log inspection, my.cnf tweaks, disk usage). The
# routine SQL surface is still the TCP MySQL client.
RUN microdnf install -y openssh-server sudo shadow-utils \
        procps-ng hostname iproute diffutils less vim-minimal \
    && microdnf clean all \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops

COPY clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh

# Wrap the upstream docker-entrypoint.sh so we get sshd alongside mysqld.
ENTRYPOINT ["/usr/local/bin/clouve-entrypoint.sh"]
CMD ["mysqld"]
