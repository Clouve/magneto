# MySQL 8.0 Database Image for Gibbon Education Platform
# This Dockerfile uses the official MySQL 8.0 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

FROM mysql:8.0

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MySQL 8.0 database for Gibbon Education Platform"
LABEL version="8.0"

# The official MySQL image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

