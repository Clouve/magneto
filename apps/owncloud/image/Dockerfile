# Custom ownCloud Docker Image
# Extends the official ownCloud image with custom initialization

FROM owncloud/server:latest

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

