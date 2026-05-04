# MariaDB Database Image for SuiteCRM
# This Dockerfile uses the official MariaDB latest image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

FROM mariadb:latest

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MariaDB database for SuiteCRM CRM"
LABEL version="latest"

# The official MariaDB image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

