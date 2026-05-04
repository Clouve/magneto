# PostgreSQL Database Image for Odoo
# This Dockerfile uses the official PostgreSQL 18 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

FROM postgres:18

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="PostgreSQL database for Odoo ERP"
LABEL version="18"

# The official PostgreSQL image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

