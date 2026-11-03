# PostgreSQL Database Image for Odoo
# This Dockerfile uses the official PostgreSQL 18 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

FROM postgres:18

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="PostgreSQL database for Odoo ERP"
LABEL version="18"

# The official PostgreSQL image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

# clouve-ops shell channel (mirrors apps/odoo/image/Dockerfile and the moodle
# mysql image). openssh-server lets the Magneto Agent container's Claude Code
# `ssh clouve-ops@${ODOO_DB_HOST}` for OS-level DB ops (postgres restart, log
# inspection, postgresql.conf tweaks, disk usage). Routine SQL stays on TCP psql.
# Debian package names (vs the mysql image's Oracle-Linux/microdnf): procps,
# iproute2, vim-tiny; gosu/useradd/chpasswd are already in the postgres image.
# Installing openssh-server makes SSH host keys, and they're deleted again at
# the end: kept, they would ship in the pushed image and every tenant would
# have the same host key. Each container makes its own when its sshd starts
# (ssh-keygen -A in start-clouve-ops-sshd.sh).
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo procps iproute2 less vim-tiny tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops \
    && rm -f /etc/ssh/ssh_host_*

COPY clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh

# Wrap the upstream docker-entrypoint.sh so we get sshd alongside postgres.
# No USER line: must stay root for sshd setup and the upstream entrypoint's
# root-time initdb/chown before it gosu-drops to the postgres user.
# tini is PID 1, so PostgreSQL never sees processes it didn't start: when one
# of those ends with an error or a signal, PostgreSQL takes it for a crashed
# server process and ends every connection to restart. tini reaps them, and
# passes the stop signal (SIGINT, from the postgres image) on to PostgreSQL.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/clouve-entrypoint.sh"]
CMD ["postgres"]
