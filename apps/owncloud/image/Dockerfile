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

# Copy our custom entrypoint script, the helper it sources for its reads and writes on the data volume, and the one
# that ends what occ, run as www-data, left running (www-data.sh, the Gibbon and Moodle images' functions)
COPY installer/entrypoint.sh /clouve/app/installer/entrypoint.sh
COPY installer/root-paths.sh /clouve/app/installer/root-paths.sh
COPY installer/www-data.sh /clouve/app/installer/www-data.sh

# Make the entrypoint script executable
RUN chmod +x /clouve/app/installer/entrypoint.sh

# ownCloud's /etc/owncloud.d/25-chown.sh, which `owncloud server` sources as root at every start, gives the code tree
# and the data volume to www-data:root with `find ... | xargs chown www-data:root`. chown without -h follows a link,
# and the volume is www-data's, so a link there gave its target (any file of root's in the container) to www-data.
# Clouve's installer/25-chown.sh does the same work with `find -P ... -execdir chown -h`, which never follows a link
# (installer/25-chown.sh says how). The checksum stops the build when a new base image changes upstream's script, so
# that Clouve's copy is compared with it again before it replaces it. Upstream's file stays in the image, never run,
# at /clouve/app/upstream/25-chown.sh (tests/owncloud-domain-marker.test.sh runs both on the same made-up volume).
ARG UPSTREAM_CHOWN_SHA256=469b27f2a660298c6610c7dc8c1d435692bc2bc107d981fe0e5eaec1eed37bf3
RUN if ! echo "${UPSTREAM_CHOWN_SHA256}  /etc/owncloud.d/25-chown.sh" | sha256sum -c --status -; then \
        echo "ERROR: the base image's /etc/owncloud.d/25-chown.sh is not the one installer/25-chown.sh was written from." >&2; \
        echo "Compare it with installer/25-chown.sh, carry its changes over, then set UPSTREAM_CHOWN_SHA256 to its sha256." >&2; \
        exit 1; \
    fi \
    && mkdir -p /clouve/app/upstream \
    && mv /etc/owncloud.d/25-chown.sh /clouve/app/upstream/25-chown.sh \
    && chmod 644 /clouve/app/upstream/25-chown.sh
COPY installer/25-chown.sh /etc/owncloud.d/25-chown.sh
RUN chmod 755 /etc/owncloud.d/25-chown.sh

# ownCloud's 20-config.sh and 45-php.sh, sourced as root at every start, write overwrite.config.php and
# objectstore.config.php into the volume's config folder with `gomplate -o`, which writes through a link that www-data
# put at either name (a file of root's anywhere then held the rendered config). Clouve's copies render to stdout and
# put the result in place with safe_put (root-paths.sh), from inside the checked folder, never through a link. The same
# checksum gate as for 25-chown.sh, and upstream's files stay at /clouve/app/upstream/, never run.
ARG UPSTREAM_CONFIG_SHA256=9016c44196a93e7eced87ccc408431f13329921fc71ff720e4743cf15f5c3d04
ARG UPSTREAM_PHP_SHA256=cb97f5b8734040aa04c78d91c2b1b3ccb5023135cab6b7c03356a2f018810fe8
RUN if ! echo "${UPSTREAM_CONFIG_SHA256}  /etc/owncloud.d/20-config.sh" | sha256sum -c --status -; then \
        echo "ERROR: the base image's /etc/owncloud.d/20-config.sh is not the one installer/20-config.sh was written from." >&2; \
        echo "Compare it with installer/20-config.sh, carry its changes over, then set UPSTREAM_CONFIG_SHA256 to its sha256." >&2; \
        exit 1; \
    fi
RUN if ! echo "${UPSTREAM_PHP_SHA256}  /etc/owncloud.d/45-php.sh" | sha256sum -c --status -; then \
        echo "ERROR: the base image's /etc/owncloud.d/45-php.sh is not the one installer/45-php.sh was written from." >&2; \
        echo "Compare it with installer/45-php.sh, carry its changes over, then set UPSTREAM_PHP_SHA256 to its sha256." >&2; \
        exit 1; \
    fi \
    && mv /etc/owncloud.d/20-config.sh /clouve/app/upstream/20-config.sh \
    && mv /etc/owncloud.d/45-php.sh /clouve/app/upstream/45-php.sh \
    && chmod 644 /clouve/app/upstream/20-config.sh /clouve/app/upstream/45-php.sh
COPY installer/20-config.sh /etc/owncloud.d/20-config.sh
COPY installer/45-php.sh /etc/owncloud.d/45-php.sh
RUN chmod 755 /etc/owncloud.d/20-config.sh /etc/owncloud.d/45-php.sh

# Set our custom entrypoint (which will call the original entrypoint at /usr/bin/entrypoint)
# We don't rename or modify the original entrypoint - it stays at its original location
ENTRYPOINT ["/clouve/app/installer/entrypoint.sh"]

# Default command (can be overridden)
CMD ["owncloud", "server"]

