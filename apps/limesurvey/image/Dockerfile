# Custom LimeSurvey Docker Image
# Extends the official martialblog/limesurvey image with custom initialization logic

FROM martialblog/limesurvey:6-apache

# Set labels for documentation
LABEL maintainer="Clouve Team"
LABEL description="Custom LimeSurvey image with automatic initialization and Clouve-specific features"
LABEL version="6-apache"

# Switch to root to install additional packages and setup scripts
USER root

# Install additional dependencies for our custom initialization
RUN apt-get update && apt-get install -y --no-install-recommends \
    default-mysql-client \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Create directories for our custom scripts and bundled LimeSurvey package
RUN mkdir -p /clouve/limesurvey/installer /clouve/limesurvey/package

# Bundle LimeSurvey files from /var/www/html to /clouve/limesurvey/package
# This preserves the application files before volume mounts overwrite them
# Similar to how Moodle bundles its files at /clouve/moodle/package
RUN cp -a /var/www/html/. /clouve/limesurvey/package/ && \
    chown -R www-data:www-data /clouve/limesurvey/package

# Copy SuiteCRM Integration Plugin to package directory (not to /var/www/html yet)
# The plugin will be installed at runtime by the entrypoint script if ENABLE_SUITECRM_INTEGRATION=true
COPY installer/SuiteCRMIntegration /clouve/limesurvey/package/plugins/SuiteCRMIntegration
RUN chown -R www-data:www-data /clouve/limesurvey/package/plugins/SuiteCRMIntegration && \
    chmod -R 755 /clouve/limesurvey/package/plugins/SuiteCRMIntegration

# Copy our custom entrypoint script
COPY installer/entrypoint.sh /clouve/limesurvey/installer/entrypoint.sh

# Copy SuiteCRM plugin configuration script
COPY installer/configure-suitecrm-plugin.sh /clouve/limesurvey/installer/configure-suitecrm-plugin.sh

# Copy demo data import script and demo survey file
# The demo data will be imported at runtime by the entrypoint script if INSTALL_DEMO_DATA=true
COPY installer/import-demo-data.sh /clouve/limesurvey/installer/import-demo-data.sh
COPY installer/demo_data.lss /clouve/limesurvey/installer/demo_data.lss
RUN chown www-data:www-data /clouve/limesurvey/installer/demo_data.lss && \
    chmod 644 /clouve/limesurvey/installer/demo_data.lss

# Make scripts executable
RUN chmod +x /clouve/limesurvey/installer/entrypoint.sh && \
    chmod +x /clouve/limesurvey/installer/configure-suitecrm-plugin.sh && \
    chmod +x /clouve/limesurvey/installer/import-demo-data.sh

# Set our custom entrypoint (which will call the original entrypoint at /usr/local/bin/entrypoint.sh)
# We don't rename or modify the original entrypoint - it stays at its original location
ENTRYPOINT ["/clouve/limesurvey/installer/entrypoint.sh"]

# Default command (starts Apache)
CMD ["apache2-foreground"]

