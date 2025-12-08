# MySQL 8.4 Database Image for Moodle Learning Management System
# This Dockerfile uses the official MySQL 8.4 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

FROM mysql:8.4

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MySQL 8.4 database for Moodle Learning Management System"
LABEL version="8.4"

# The official MySQL image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

