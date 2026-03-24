# Custom n8n Docker Image
# Extends the base n8n image with bundled initialization scripts and automatic setup
#
# n8n 2.x uses Docker Hardened Alpine which has no package manager (apk removed).
# We use a multi-stage build to copy required binaries from a standard Alpine image.

# Stage 1: Build dependencies from standard Alpine
FROM alpine:3.22 AS deps

RUN apk add --no-cache \
    postgresql17-client \
    curl \
    bash \
    su-exec

# Stage 2: Final n8n image
FROM docker.n8n.io/n8nio/n8n:2.14.0

# Set labels for documentation
LABEL maintainer="Clouve Team"
LABEL description="Custom n8n image with automatic initialization and database setup"
LABEL version="2.12.3"

# Switch to root to install packages and configure
USER root

# Copy required binaries and libraries from deps stage
COPY --from=deps /usr/bin/psql /usr/bin/psql
COPY --from=deps /usr/bin/pg_isready /usr/bin/pg_isready
COPY --from=deps /usr/bin/curl /usr/bin/curl
COPY --from=deps /bin/bash /bin/bash
COPY --from=deps /sbin/su-exec /sbin/su-exec

# Copy shared libraries needed by psql and curl
COPY --from=deps /usr/lib/libpq.so* /usr/lib/
COPY --from=deps /usr/lib/libcurl.so* /usr/lib/
COPY --from=deps /usr/lib/libreadline.so* /usr/lib/
COPY --from=deps /usr/lib/libncursesw.so* /usr/lib/
COPY --from=deps /usr/lib/libbrotlidec.so* /usr/lib/
COPY --from=deps /usr/lib/libbrotlicommon.so* /usr/lib/
COPY --from=deps /usr/lib/libnghttp2.so* /usr/lib/
COPY --from=deps /usr/lib/libidn2.so* /usr/lib/
COPY --from=deps /usr/lib/libpsl.so* /usr/lib/
COPY --from=deps /usr/lib/libunistring.so* /usr/lib/
COPY --from=deps /usr/lib/libzstd.so* /usr/lib/
COPY --from=deps /usr/lib/liblz4.so* /usr/lib/
COPY --from=deps /usr/lib/libldap.so* /usr/lib/
COPY --from=deps /usr/lib/liblber.so* /usr/lib/
COPY --from=deps /usr/lib/libsasl2.so* /usr/lib/

# Create directory for installer scripts
RUN mkdir -p /clouve/n8n/installer

# Copy installer scripts
COPY installer/entrypoint.sh /clouve/n8n/installer/
COPY installer/install.sh /clouve/n8n/installer/
COPY installer/update-config.sh /clouve/n8n/installer/

# Copy PostgreSQL init script for non-root user creation
COPY installer/init-data.sh /clouve/n8n/installer/

# Make installer scripts executable
RUN chmod +x /clouve/n8n/installer/*.sh

# Set our custom entrypoint
ENTRYPOINT ["/clouve/n8n/installer/entrypoint.sh"]

# Default command (starts n8n)
CMD ["n8n"]
