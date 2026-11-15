# Custom ownCloud Docker Image
# Extends the official ownCloud image with custom initialization
#
# PINNED: owncloud/server:10.16.6, the version the listing names. A FROM with no tag would take whatever :latest is
# at each build (build.sh builds with --pull). A version bump changes this line and appVersion in
# clv-docker-compose.yml; the image's own start-up runs ownCloud's upgrade on an installed site.

FROM owncloud/server:10.16.6

# Set labels for documentation
LABEL maintainer="Clouve Team"
LABEL description="Custom ownCloud image with automatic initialization"

# Install dependencies for database connectivity and utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

# Create directory for our custom entrypoint script
RUN mkdir -p /clouve/app/installer

# Copy our custom entrypoint script
COPY installer/entrypoint.sh /clouve/app/installer/entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /clouve/app/installer/entrypoint.sh

# Set our custom entrypoint (which will call the original entrypoint at /usr/bin/entrypoint)
# We don't rename or modify the original entrypoint - it stays at its original location
ENTRYPOINT ["/clouve/app/installer/entrypoint.sh"]

# Default command (can be overridden)
CMD ["owncloud", "server"]

