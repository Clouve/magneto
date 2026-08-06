# Custom WordPress Docker Image
# Extends the official WordPress image with pre-installed wp-cli and custom initialization

FROM wordpress:6.9.0

# Set labels for documentation
LABEL maintainer="Clouve Team"
LABEL description="Custom WordPress image with wp-cli and automatic initialization"

# Install dependencies for wp-cli and database connectivity, plus the
# clouve-ops SSH channel (openssh-server + sudo)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    default-mysql-client \
    openssh-server \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Operator account used by the magneto-agent container's Claude Code agent for
# shell access into this container. The account password is set at runtime by
# /clouve/wordpress/installer/start-clouve-ops-sshd.sh from the per-pod
# CLOUVE_OPS_PASSWORD env var (same value on all three services).
# Passwordless sudo: the agent is a DevOps engineer with full root,
# gated by the safety rules in CONTEXT.md.tpl and the WordPress DevOps Skill
# rather than by sudoers.
RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# Install wp-cli
RUN curl -s -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# Verify wp-cli installation (using --allow-root since we're running as root in the container)
RUN wp --version --allow-root

# Configure PHP settings for WordPress
RUN { \
    echo 'upload_max_filesize = 100M'; \
    echo 'post_max_size = 100M'; \
    echo 'memory_limit = 512M'; \
} > /usr/local/etc/php/conf.d/wordpress.ini

# Copy the installer scripts (entrypoint + clouve-ops sshd helper/config)
COPY installer /clouve/wordpress/installer

# Make the installer scripts executable
RUN chmod +x /clouve/wordpress/installer/*.sh

# Persona pulled at init by Magneto Agent's sidecar-fetcher over clouve-ops SSH.
# The plugin-name subdir (`context/wordpress/`) makes the persona self-identifying
# in the sidecar→Magneto-Agent merge: tar c on /clouve/context/ emits
# ./wordpress/CONTEXT.md.tpl.
COPY context/ /clouve/context/

# clouve-ops sshd hardening drop-in (installer/clouve-ops-sshd.conf is
# part of the COPY above). Lands as a sshd_config.d snippet that the
# system-wide sshd_config Include picks up.
RUN cp /clouve/wordpress/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf

# Set our custom entrypoint (which will call the original entrypoint at /usr/local/bin/docker-entrypoint.sh)
# We don't rename or modify the original entrypoint - it stays at its original location
ENTRYPOINT ["/clouve/wordpress/installer/entrypoint.sh"]

# Default command (can be overridden)
CMD []

