# Bluesky PDS (Personal Data Server) Docker Image
# This Dockerfile extends the official Bluesky PDS image with:
# 1. Custom entrypoint script for auto-generating secrets
# 2. OpenSSL for cryptographic key generation
# 3. Automatic initialization of required environment variables

FROM ghcr.io/bluesky-social/pds:0.4

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="Bluesky PDS (Personal Data Server) for AT Protocol federation with auto-generated secrets"
LABEL version="0.4"

# Install OpenSSL and bash for generating cryptographic keys and running the entrypoint script
# The base image is based on Node.js Alpine, so we use apk
RUN apk add --no-cache openssl bash

# Copy our custom entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Make the entrypoint script executable
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Expose the PDS port
EXPOSE 3000

# Set the entrypoint to our custom script
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]

# Default command (can be overridden)
CMD []


