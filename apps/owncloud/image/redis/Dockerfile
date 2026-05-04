# Redis Cache Image for ownCloud
# This Dockerfile uses the official Redis 6 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

FROM redis:6

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="Redis cache for ownCloud"
LABEL version="6"

# The official Redis image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

