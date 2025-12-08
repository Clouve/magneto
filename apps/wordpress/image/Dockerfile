# Custom WordPress Docker Image
# Extends the official WordPress image with pre-installed wp-cli and custom initialization

FROM wordpress

# Set labels for documentation
LABEL maintainer="Clouve Team"
LABEL description="Custom WordPress image with wp-cli and automatic initialization"

# Install dependencies for wp-cli and database connectivity
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

# Install wp-cli
RUN curl -s -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# Verify wp-cli installation (using --allow-root since we're running as root in the container)
RUN wp --version --allow-root

# Create directory for our custom entrypoint script
RUN mkdir -p /clouve/wordpress/installer

# Copy our custom entrypoint script
COPY installer/entrypoint.sh /clouve/wordpress/installer/entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /clouve/wordpress/installer/entrypoint.sh

# Set our custom entrypoint (which will call the original entrypoint at /usr/local/bin/docker-entrypoint.sh)
# We don't rename or modify the original entrypoint - it stays at its original location
ENTRYPOINT ["/clouve/wordpress/installer/entrypoint.sh"]

# Default command (can be overridden)
CMD []

