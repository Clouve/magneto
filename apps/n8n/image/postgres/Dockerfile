# PostgreSQL Database Image for n8n
# This Dockerfile uses the official PostgreSQL 18 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits
#
# Includes init-data.sh to create a non-root database user
# per official n8n installation recommendations

FROM postgres:18

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="PostgreSQL database for n8n workflow automation"
LABEL version="18"

# Copy the initialization script that creates the non-root user
# PostgreSQL will execute scripts in /docker-entrypoint-initdb.d/ on first run
COPY init-data.sh /docker-entrypoint-initdb.d/init-data.sh
RUN chmod +x /docker-entrypoint-initdb.d/init-data.sh
