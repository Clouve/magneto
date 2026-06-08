FROM php:8.3-apache

# Moodle version - using latest stable version
ENV MOODLE_VERSION=502
ENV MOODLE_RELEASE=5.2
ENV MOODLE_PATH=moodle/moodle-${MOODLE_RELEASE}

# Setup server and install dependencies
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y \
    gettext-base \
    locales \
    git \
    default-mysql-client \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libicu-dev \
    libxml2-dev \
    libzip-dev \
    libldap2-dev \
    libonig-dev \
    cron \
    unzip \
    openssh-server \
    sudo \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen

# Operator account used by the magneto-agent container's Claude Code agent for shell
# access into this container. The account password is set at runtime by
# /clouve/moodle/installer/start-clouve-ops-sshd.sh from the per-pod
# CLOUVE_OPS_PASSWORD env var (same value on all three services).
# Passwordless sudo: the agent is a DevOps engineer with full root,
# gated by the safety rules in CONTEXT.md.tpl and the Moodle DevOps Skill
# rather than by sudoers.
RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# Install Composer (required for Moodle 5.1+ dependencies)
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

# Install PHP extensions required by Moodle
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions \
    pdo_mysql \
    mysqli \
    gd \
    opcache \
    zip \
    gettext \
    intl \
    soap \
    xmlrpc \
    mbstring \
    exif \
    ldap

# Clean up apt cache
RUN apt-get clean autoclean && \
    apt-get autoremove -y && \
    rm -rfv /var/lib/{apt,dpkg,cache,log}/

# Enable Apache modules
RUN a2enmod rewrite && \
    a2enmod headers && \
    a2enmod ssl

# Apache security hardening
RUN sed -i "s/Options Indexes FollowSymLinks/Options FollowSymLinks/g" /etc/apache2/apache2.conf
RUN echo "ServerTokens Prod\n" >> /etc/apache2/apache2.conf
RUN echo "ServerSignature Off\n" >> /etc/apache2/apache2.conf

RUN echo 'Header set X-Content-Type-Options: "nosniff"' >> /etc/apache2/conf-enabled/security.conf
RUN echo 'Header set X-Frame-Options: "sameorigin"' >> /etc/apache2/conf-enabled/security.conf
RUN echo 'Header set X-XSS-Protection "1; mode=block"' >> /etc/apache2/conf-enabled/security.conf

# PHP configuration for Moodle
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
RUN printf "expose_php=Off\n\
upload_max_filesize = 100M\n\
post_max_size = 100M\n\
memory_limit = 512M\n\
max_input_vars = 5000\n\
max_execution_time = 300\n\
opcache.enable = 1\n\
opcache.memory_consumption = 128\n\
opcache.max_accelerated_files = 10000\n\
opcache.revalidate_freq = 60\n\
opcache.use_cwd = 1\n\
opcache.validate_timestamps = 1\n\
opcache.save_comments = 1\n\
opcache.enable_file_override = 0\n" >> "$PHP_INI_DIR/php.ini"

# Configure Apache to use /public directory as document root for Moodle 5.1+
# This is the secure deployment model recommended by Moodle 5.1
# The /public directory contains the web-accessible files, while sensitive files remain in parent directory
# Note: SSL proxy configuration ($CFG->sslproxy = true) is added by install.sh for reverse proxy environments
RUN sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/public|g' /etc/apache2/sites-available/000-default.conf && \
    sed -i 's|<Directory /var/www/>|<Directory /var/www/html/public/>|g' /etc/apache2/apache2.conf

# Create working directory
WORKDIR /clouve

# Copy installer scripts
COPY installer ./moodle/installer

# Make installer scripts executable
RUN chmod +x ./moodle/installer/*.sh

# Persona pulled at init by Magneto Agent's sidecar-fetcher over clouve-ops SSH.
# The plugin-name subdir (`context/moodle/`) makes the persona self-identifying
# in the sidecar→Magneto-Agent merge: tar c on /clouve/context/ emits ./moodle/CONTEXT.md.tpl.
COPY context/ /clouve/context/

# clouve-ops sshd hardening drop-in (installer/clouve-ops-sshd.conf is
# part of the COPY above). Lands as a sshd_config.d snippet that the
# system-wide sshd_config Include picks up.
RUN cp /clouve/moodle/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf

# Note: Cron configuration is done dynamically at runtime in entrypoint.sh
# based on the MOODLE_CRON_INTERVAL environment variable

# Download and extract Moodle.
# PINNED BUILD: the stable${MOODLE_VERSION} URL serves a *rolling* "latest 5.2.x"
# tarball, so the sha256 below pins this image to ONE exact build —
# 5.2 (Build: 20260420) / version 2026042000. If upstream publishes a newer 5.2.x
# the build fails here (checksum mismatch) instead of silently shipping newer code
# than tenant databases expect. To adopt a new build, bump MOODLE_VERSION/
# MOODLE_RELEASE above and update this checksum in the same commit.
ADD --checksum=sha256:48f0f521375006be84c227e6a595313ebcc9dc55455499b5150dcfe865782cfe \
    https://download.moodle.org/download.php/direct/stable${MOODLE_VERSION}/moodle-${MOODLE_RELEASE}.tgz ./moodle/installer/
RUN tar -xzf ./moodle/installer/moodle-${MOODLE_RELEASE}.tgz -C ./moodle/ && \
    mv ./moodle/moodle ./moodle/moodle-${MOODLE_RELEASE}

# Install Composer dependencies for Moodle 5.1+
# This is required as the Moodle download does not include the vendor directory
# The vendor directory contains third-party PHP libraries managed by Composer
RUN cd ./moodle/moodle-${MOODLE_RELEASE} && \
    composer install --no-dev --classmap-authoritative && \
    echo "✓ Composer dependencies installed successfully"

# Create moodledata directory with proper permissions
RUN mkdir -p /var/moodledata && \
    chown -R www-data:www-data /var/moodledata && \
    chmod -R 0777 /var/moodledata

# Set entrypoint
ENTRYPOINT ["/clouve/moodle/installer/entrypoint.sh"]
CMD ["apache2-foreground"]

