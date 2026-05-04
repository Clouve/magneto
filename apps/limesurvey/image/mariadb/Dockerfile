# MariaDB Database Image for LimeSurvey
# This Dockerfile uses the official MariaDB 11 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

FROM mariadb:11

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MariaDB 11 database for LimeSurvey"
LABEL version="11"

# The official MariaDB image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

