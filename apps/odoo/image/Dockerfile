# Custom Odoo Docker Image
# Extends the base Odoo image with bundled initialization scripts and automatic setup

FROM odoo:19.0

# Set labels for documentation
LABEL maintainer="Clouve Team"
LABEL description="Custom Odoo image with automatic initialization and database setup"
LABEL version="19.0"

# Switch to root to install packages
USER root

# Install dependencies for database connectivity, health checks, the
# clouve-ops shell channel (openssh-server + sudo) used by the Magneto Agent,
# and tini, which runs as PID 1 (see ENTRYPOINT below). Installing
# openssh-server makes SSH host keys, and they're deleted again here: kept,
# they would ship in the pushed image and every tenant would have the same
# host key. Each container makes its own when its sshd starts (ssh-keygen -A
# in start-clouve-ops-sshd.sh).
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    curl \
    netcat-openbsd \
    openssh-server \
    sudo \
    tini \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*

# Operator account used by the Magneto Agent container's Claude Code agent for
# shell access into this container. Password is set at runtime by
# /clouve/odoo/installer/start-clouve-ops-sshd.sh from the per-pod
# CLOUVE_OPS_PASSWORD env var (same value on all three services). Passwordless
# sudo: the agent is a DevOps engineer with full root, gated by the safety rules
# in CONTEXT.md.tpl and the Odoo DevOps Skill rather than by sudoers.
RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# Create directory for installer scripts
RUN mkdir -p /clouve/odoo/installer

# Copy installer scripts
COPY installer/entrypoint.sh /clouve/odoo/installer/
COPY installer/install.sh /clouve/odoo/installer/
COPY installer/update-config.sh /clouve/odoo/installer/
COPY installer/clouve-ops-sshd.conf /clouve/odoo/installer/
COPY installer/start-clouve-ops-sshd.sh /clouve/odoo/installer/

# Make installer scripts executable
RUN chmod +x /clouve/odoo/installer/*.sh

# clouve-ops sshd hardening drop-in (the system sshd_config Include picks it up).
RUN cp /clouve/odoo/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf

# Persona pulled at init by the Magneto Agent's sidecar-fetcher over clouve-ops
# SSH. The plugin-name subdir (context/odoo/) makes the persona self-identifying
# in the sidecar->agent merge.
COPY context/ /clouve/context/

# Rename the original Odoo entrypoint so we can call it from our custom entrypoint
RUN if [ -f /entrypoint.sh ]; then \
        mv /entrypoint.sh /entrypoint-original.sh; \
    fi

# tini is PID 1 and runs our entrypoint, which ends by exec'ing Odoo. Odoo never
# reaps a process it didn't start, so while it was PID 1 every finished process
# whose parent had gone stayed a zombie (each clouve-ops SSH session left one).
# tini reaps them and passes signals on to Odoo: docker stop's SIGTERM, and the
# SIGHUP that restarts Odoo in place. PID 1's command line still holds "odoo",
# which the AI Assistant's restart command checks first
# (grep -q odoo /proc/1/cmdline && sudo kill -HUP 1).
ENTRYPOINT ["/usr/bin/tini", "--", "/clouve/odoo/installer/entrypoint.sh"]

# Default command (starts Odoo server)
CMD ["odoo"]

