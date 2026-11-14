FROM php:8.3-apache

ENV GIBBON_VERSION=30.0.01
ENV GIBBON_PATH=gibbon/gibbon-${GIBBON_VERSION}

# Setup server. Installing openssh-server makes SSH host keys, and they go
# again at the end: kept, they would ship in the pushed image and every tenant
# would share one host key. Each container makes its own at start
# (ssh-keygen -A in start-clouve-ops-sshd.sh).
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y gettext-base locales git default-mysql-client cron \
        openssh-server sudo && \
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen && \
    rm -f /etc/ssh/ssh_host_*

# Operator account used by gibbon-magneto-agent's Claude Code agent for shell
# access into this container. The account password is set at runtime by
# /clouve/gibbon/installer/start-clouve-ops-sshd.sh from the per-pod
# CLOUVE_OPS_PASSWORD env var (same value on all three services).
# Passwordless sudo: the agent is a DevOps engineer with full root,
# gated by the safety rules in CLAUDE.md and the Gibbon DevOps Skill
# rather than by sudoers.
RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions pdo_mysql gd opcache zip gettext intl

RUN apt-get clean autoclean && \
    apt-get autoremove -y && \
    rm -rfv /var/lib/{apt,dpkg,cache,log}/

RUN a2enmod rewrite &&\
    a2enmod headers

RUN sed -i "s/Options Indexes FollowSymLinks/Options FollowSymLinks/g" /etc/apache2/apache2.conf
RUN echo "ServerTokens Prod\n" >> /etc/apache2/apache2.conf
RUN echo "ServerSignature Off\n" >> /etc/apache2/apache2.conf

RUN echo 'Header set X-Content-Type-Options: "nosniff"' >> /etc/apache2/conf-enabled/security.conf
RUN echo 'Header set X-Frame-Options: "sameorigin"' >> /etc/apache2/conf-enabled/security.conf
RUN echo 'Header set X-XSS-Protection "1; mode=block"' >> /etc/apache2/conf-enabled/security.conf
# clouve/ on the site is Clouve's own state (the installed versions, the libraries' marker and file list), never
# served (tests/php-vendor.test.sh).
RUN printf '<Directory /var/www/html/clouve>\n    Require all denied\n</Directory>\n' > /etc/apache2/conf-available/clouve-state.conf \
    && a2enconf clouve-state

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
RUN printf "expose_php=Off\nupload_max_filesize = 20M\npost_max_size = 20M\nmemory_limit = 512M\nmax_input_vars=8000" >> "$PHP_INI_DIR/php.ini"

WORKDIR /clouve
COPY installer ./gibbon/installer
RUN chmod +x ./gibbon/installer/*.sh

# Persona pulled at init by Magneto Agent's sidecar-fetcher over clouve-ops SSH.
# The plugin-name subdir (`context/gibbon/`) makes the persona self-identifying
# in the sidecar→AI-Studio merge: tar c on /clouve/context/ emits ./gibbon/CONTEXT.md.tpl.
COPY context/ /clouve/context/

# clouve-ops sshd hardening drop-in (installer/clouve-ops-sshd.conf is
# part of the COPY above). Lands as a sshd_config.d snippet that the
# system-wide sshd_config Include picks up.
RUN cp /clouve/gibbon/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
ADD https://github.com/GibbonEdu/core/releases/download/v${GIBBON_VERSION}/GibbonEduCore-InstallBundle.tar.gz ./gibbon/installer/

#Extract Gibbon
RUN mkdir -p ./${GIBBON_PATH}
RUN tar -xzf ./gibbon/installer/GibbonEduCore-InstallBundle.tar.gz -C ./${GIBBON_PATH}/
RUN tar -xzf ./gibbon/installer/i18n.tar.gz -C ./${GIBBON_PATH}/
RUN tar -xzf ./gibbon/installer/modules.tar.gz -C ./${GIBBON_PATH}/

# twig/twig and phpoffice/phpspreadsheet: the bundle's 3.11.3 and 1.30.0 have critical advisories. These versions are
# the newest at least 14 days old in Gibbon's own ranges (twig ^3.3, phpspreadsheet ^1.29), and the build checks each
# one's release commit too. The bundle's composer.json resolves for PHP 8.0, and twig 3.21 and later need 8.1; this
# image runs PHP 8.3. The bundle's moneyphp/money (Gibbon's payment library) asks for the bcmath extension, which this
# image has never had; Composer is told so, and the update leaves that package as it is. Twig 3.30 no longer needs
# symfony/polyfill-php81 (PHP 8.3 has those functions), so Composer removes it. Upstream's id and file list are
# recorded first, so that refresh-vendor.sh can put the new libraries on sites the bundle installed
# (tests/php-vendor.test.sh).
ARG TWIG_VERSION=v3.30.0
ARG TWIG_COMMIT=8c737079b726af72ff8ef3c595be9f6a810ea1ef
ARG PHPSPREADSHEET_VERSION=1.30.7
ARG PHPSPREADSHEET_COMMIT=f5dd9c1f084d336ea63cf53099533e061a9c157a
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
RUN cd /clouve/${GIBBON_PATH} \
    && /clouve/gibbon/installer/refresh-vendor.sh --id vendor > /clouve/gibbon/vendor-upstream.id \
    && grep -qE '^[0-9a-f]{64}$' /clouve/gibbon/vendor-upstream.id \
    && /clouve/gibbon/installer/refresh-vendor.sh --sums vendor > /clouve/gibbon/vendor-upstream.sums \
    && test -s /clouve/gibbon/vendor-upstream.sums \
    && export COMPOSER_ALLOW_SUPERUSER=1 \
    && composer config platform.php 8.3 \
    && composer update --no-dev --no-interaction --no-scripts --no-plugins --optimize-autoloader --ignore-platform-req=ext-bcmath \
        --with "twig/twig:${TWIG_VERSION}" --with "phpoffice/phpspreadsheet:${PHPSPREADSHEET_VERSION}" twig/twig phpoffice/phpspreadsheet \
    && php -n -r '$p = []; foreach (json_decode(file_get_contents("vendor/composer/installed.json"), true)["packages"] as $x) \
          $p[$x["name"]] = $x["version"] . "@" . ($x["dist"]["reference"] ?? ""); \
        exit(($p["twig/twig"] ?? "") === getenv("TWIG_VERSION") . "@" . getenv("TWIG_COMMIT") \
          && ($p["phpoffice/phpspreadsheet"] ?? "") === getenv("PHPSPREADSHEET_VERSION") . "@" . getenv("PHPSPREADSHEET_COMMIT") ? 0 : 1);'

#Gibbon Settings
RUN echo "" >> ./${GIBBON_PATH}/.htaccess &&  \
    echo "php_value max_input_vars 8000" >> ./${GIBBON_PATH}/.htaccess &&  \
    echo "" >> ./${GIBBON_PATH}/.htaccess
RUN cp ./gibbon/installer/auto.php ./${GIBBON_PATH}/installer/auto.php

ENTRYPOINT ["/clouve/gibbon/installer/entrypoint.sh"]
CMD ["apache2-foreground"]