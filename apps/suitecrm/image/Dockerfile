# Custom SuiteCRM 8 Docker Image
# Extends the official PHP Apache image with SuiteCRM 8 and automatic initialization

FROM php:8.2-apache

# SuiteCRM version - using latest stable version
ENV SUITECRM_VERSION=8.9.1
ENV SUITECRM_PACKAGE=SuiteCRM-${SUITECRM_VERSION}

# Set labels for documentation
LABEL maintainer="Clouve Team"
LABEL description="Custom SuiteCRM 8 image with automatic initialization and database setup"
LABEL version="8.9.1"

# Install system dependencies
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
    libcurl4-openssl-dev \
    cron \
    unzip \
    curl \
    wget \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen

# Install Composer (required for SuiteCRM 8 dependencies)
COPY --from=composer:latest /usr/bin/composer /usr/local/bin/composer

# Install PHP extensions required by SuiteCRM 8
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
    mbstring \
    exif \
    ldap \
    curl \
    bcmath

# Configure PHP settings for SuiteCRM
RUN { \
    echo 'memory_limit = 512M'; \
    echo 'upload_max_filesize = 20M'; \
    echo 'post_max_size = 20M'; \
    echo 'max_execution_time = 300'; \
    echo 'max_input_time = 300'; \
    echo 'date.timezone = UTC'; \
    echo 'display_errors = Off'; \
    echo 'log_errors = On'; \
    echo 'error_log = /var/log/php_errors.log'; \
} > /usr/local/etc/php/conf.d/suitecrm.ini

# Clean up apt cache
RUN apt-get clean autoclean && \
    apt-get autoremove -y && \
    rm -rfv /var/lib/{apt,dpkg,cache,log}/

# Enable Apache modules required by SuiteCRM
RUN a2enmod rewrite && \
    a2enmod headers && \
    a2enmod ssl && \
    a2enmod expires

# Configure Apache DocumentRoot to point to /var/www/html/public
# SuiteCRM 8 uses /public as the web root for security
RUN sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/public|g' /etc/apache2/sites-available/000-default.conf && \
    sed -i 's|<Directory /var/www/>|<Directory /var/www/html/public/>|g' /etc/apache2/apache2.conf

# Set proper AllowOverride for .htaccess
RUN sed -i '/<Directory \/var\/www\/html\/public\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

# Create working directory
WORKDIR /clouve

# Copy installer scripts
COPY installer ./suitecrm/installer

# Make installer scripts executable
RUN chmod +x ./suitecrm/installer/*.sh

# Download and extract SuiteCRM 8.9.1
# The zip file extracts directly into the target directory without creating a subdirectory
RUN curl -L -o ./suitecrm/installer/${SUITECRM_PACKAGE}.zip \
    https://github.com/salesagility/SuiteCRM-Core/releases/download/v${SUITECRM_VERSION}/${SUITECRM_PACKAGE}.zip && \
    unzip -q ./suitecrm/installer/${SUITECRM_PACKAGE}.zip -d ./suitecrm/app && \
    rm ./suitecrm/installer/${SUITECRM_PACKAGE}.zip && \
    echo "✓ SuiteCRM ${SUITECRM_VERSION} downloaded and extracted successfully"

# Install Composer dependencies for SuiteCRM 8
# The files are extracted directly into ./suitecrm/app/
RUN cd ./suitecrm/app && \
    composer install --no-dev --no-interaction --optimize-autoloader && \
    echo "✓ Composer dependencies installed successfully"

# Create necessary directories with proper permissions
RUN mkdir -p /var/www/html && \
    chown -R www-data:www-data /var/www/html && \
    chmod -R 755 /var/www/html

# Set entrypoint
ENTRYPOINT ["/clouve/suitecrm/installer/entrypoint.sh"]
CMD ["apache2-foreground"]

