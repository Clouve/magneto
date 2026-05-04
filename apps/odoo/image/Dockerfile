# Custom Odoo Docker Image
# Extends the base Odoo image with bundled initialization scripts and automatic setup

FROM odoo:19.0

# Set labels for documentation
LABEL maintainer="Clouve Team"
LABEL description="Custom Odoo image with automatic initialization and database setup"
LABEL version="19.0"

# Switch to root to install packages
USER root

# Install dependencies for database connectivity and health checks
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    curl \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Create directory for installer scripts
RUN mkdir -p /clouve/odoo/installer

# Copy installer scripts
COPY installer/entrypoint.sh /clouve/odoo/installer/
COPY installer/install.sh /clouve/odoo/installer/
COPY installer/update-config.sh /clouve/odoo/installer/

# Make installer scripts executable
RUN chmod +x /clouve/odoo/installer/*.sh

# Rename the original Odoo entrypoint so we can call it from our custom entrypoint
RUN if [ -f /entrypoint.sh ]; then \
        mv /entrypoint.sh /entrypoint-original.sh; \
    fi

# Set our custom entrypoint
ENTRYPOINT ["/clouve/odoo/installer/entrypoint.sh"]

# Default command (starts Odoo server)
CMD ["odoo"]

