# SuiteCRM image for the Clouve marketplace
# PHP 8.3 with Apache, SuiteCRM's release package, an entrypoint that installs a new site or upgrades an
# existing one in place, and the clouve-ops SSH channel for the AI Assistant.
#
# PINNED: php:8.3-apache. PHP 8.2 loses security support on 2026-12-31, and 8.3 is the one version that both
# SuiteCRM 8.9 and 8.10 support: an upgrade's first half runs the old version's code. Move to 8.4 once no 8.9
# volume is left.

FROM php:8.3-apache

# SuiteCRM's version and the SHA-256 of its release zip (the digest GitHub shows next to the asset). A version
# bump changes these two lines. An existing install then upgrades itself at its first start on the new image
# (installer/upgrade.sh).
ARG SUITECRM_VERSION=8.10.2
ARG SUITECRM_SHA256=ac4693d10ea2d6cd20b3256098781d134599d88878fb24e8dc127038d624f5a8

LABEL maintainer="Clouve Team"
LABEL description="SuiteCRM with an in-place upgrade, its scheduled jobs and the clouve-ops SSH channel"

# The database client is for the entrypoint's checks and the upgrade's dump. unzip unpacks the package here.
# wget is the Compose health check's. procps gives ps to whoever looks into the container. openssh-server and
# sudo are the clouve-ops channel. Installing openssh-server makes SSH host keys, and they go again at the end:
# kept, they would ship in the pushed image and every tenant would share one host key. Each container makes
# its own at start (ssh-keygen -A in start-clouve-ops-sshd.sh). The upgrade takes the base image's own packages
# to their newest versions in the same Debian release.
RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends \
    default-mysql-client \
    locales \
    unzip \
    curl \
    wget \
    procps \
    openssh-server \
    sudo \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*

# Operator account used by the magneto-agent container's Claude Code agent for shell access into this
# container. The account password is set at runtime by start-clouve-ops-sshd.sh from the per-pod
# CLOUVE_OPS_PASSWORD. Passwordless sudo: the agent is a DevOps engineer with full root. What limits it is the
# safety rules in the persona and the SuiteCRM skill, and sudoers leaves it free.
RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# The imap extension needs the c-client library, which Debian 13 no longer ships. Left alone, the extension
# installer below fetches Debian 12's three packages over plain HTTP and installs them unchecked. So they are
# fetched here over HTTPS, each is checked against the SHA-256 that Debian 12's package index names for it, and
# they are installed first: the installer then finds them and fetches nothing. The image is built for amd64 and
# for arm64, and each has its own files. A version bump of these packages changes one branch below.
ARG TARGETARCH
RUN set -eu; cd /tmp; arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64) v='2007f~dfsg-7+b2'; s_mlock=84910cef9e203488b040c99ef9c84a96653acff87d05492b23b738cde3d6e4b6; s_lib=46bd59ac3b824f0e31d313d395b076b6072cb03747b9db377e2f4b452fc148be; s_dev=d02d4da9af469b33fc86db103997108e5de4f41ac9234be30294328dae07c49a ;; \
      arm64) v='2007f~dfsg-7+b1'; s_mlock=2963eca9058e88d520b43fbea94bcfab5f774f76cdc1f5b990b27a7c538a338b; s_lib=31740e4aee1d841a0bb4a55f501c20369bde6df27c785a401bb7136b92bef8bd; s_dev=93ff2e696dc88202e217aa9bfc078b95d306b5b81e3026b3018b697d1be7336d ;; \
      *) echo "no checksums for the c-client packages on $arch" >&2; exit 1 ;; \
    esac; \
    for p in "mlock $s_mlock" "libc-client2007e $s_lib" "libc-client2007e-dev $s_dev"; do \
      f="${p%% *}_${v}_${arch}.deb"; \
      curl -fsSL -o "$f" "https://deb.debian.org/debian/pool/main/u/uw-imap/$f"; \
      echo "${p##* }  $f" | sha256sum -c -; \
    done; \
    apt-get update; \
    apt-get install -y --no-install-recommends ./mlock_*.deb ./libc-client2007e_*.deb ./libc-client2007e-dev_*.deb; \
    rm -f ./*.deb; rm -rf /var/lib/apt/lists/*

# PHP extensions. The installer script is pinned to a release and checked against its SHA-256. imap is for
# SuiteCRM's inbound mailboxes, which one of its scheduled jobs checks. Once the extensions are built, the
# c-client headers and the compilers the base image built PHP with go: nothing in a running container builds
# anything. The base's layers still hold them, so the image doesn't get smaller, but no container has them.
ADD --checksum=sha256:27fa8d80bd4e22feb9ddcadff1ca40c8f3e8ea942eb2dd8f446ed1afd2f2f0ab --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/download/2.13.2/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
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
    bcmath \
    imap \
    && apt-get purge -y --auto-remove libc-client2007e-dev \
    && apt-get purge -y --auto-remove $(dpkg-query -W -f='${Package}\n' | grep -E \
       '^(gcc|g\+\+|cpp)(-[0-9]+)?(-[a-z0-9_]+-linux-gnu)?$|^binutils(-|$)|^libc6-dev$|^linux-libc-dev$|^lib(stdc\+\+|gcc)-[0-9]+-dev$|^pkgconf(-bin)?$|^(autoconf|dpkg-dev|file|make|re2c|pkg-config|m4|patch)$') \
    && rm -rf /var/lib/apt/lists/* \
    && php -m | grep -qx imap

# PHP settings for SuiteCRM. No error_log: PHP then writes its errors to the container's log, for Apache and for
# the console alike. The earlier image named a file that only root could write. The two session settings give
# the session cookie that SuiteCRM's older pages set the flags its newer pages already set.
RUN { \
    echo 'memory_limit = 512M'; \
    echo 'upload_max_filesize = 20M'; \
    echo 'post_max_size = 20M'; \
    echo 'max_execution_time = 300'; \
    echo 'max_input_time = 300'; \
    echo 'date.timezone = UTC'; \
    echo 'display_errors = Off'; \
    echo 'log_errors = On'; \
    echo 'session.cookie_httponly = On'; \
    echo 'session.cookie_samesite = Lax'; \
} > /usr/local/etc/php/conf.d/suitecrm.ini

# Apache serves /var/www/html/public, SuiteCRM 8's web root, and reads its .htaccess. The greps fail the build
# when an edit did not apply.
RUN a2enmod rewrite headers expires remoteip \
    && sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/public|g' /etc/apache2/sites-available/000-default.conf \
    && sed -i 's|<Directory /var/www/>|<Directory /var/www/html/public/>|g' /etc/apache2/apache2.conf \
    && sed -i '/<Directory \/var\/www\/html\/public\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf \
    && grep -q 'DocumentRoot /var/www/html/public$' /etc/apache2/sites-available/000-default.conf \
    && sed -n '/<Directory \/var\/www\/html\/public\/>/,/<\/Directory>/p' /etc/apache2/apache2.conf | grep -q 'AllowOverride All'

# Apache's parent process is root, and it opens its logs, its PID file and its lock files at every start and
# reload. The base image gives these folders to www-data with mode 1777, so that it can run as any user. This
# image starts as root, so the folders and the links in them are root's, and SuiteCRM's code can't choose which
# file root opens. The two log links still point at the container's output.
RUN chown -hR root:root /var/log/apache2 /var/run/apache2 /var/lock/apache2 \
    && find /var/log/apache2 /var/run/apache2 /var/lock/apache2 -type d -exec chmod 755 {} +

# SuiteCRM's release zip, checked against its SHA-256. It is kept twice over: unpacked at /clouve/suitecrm/app,
# where a new install copies it from, and as the zip, because SuiteCRM's own upgrade command takes the package
# as a zip. The zip holds vendor/ and the built front end, so the build needs no Composer and no git. Both are
# root's and closed to writing by anyone else: root reads the image's version from the package, and www-data,
# which runs SuiteCRM's own code, must not be able to change it. A new install copies the package as www-data
# and sets the modes SuiteCRM's install guide asks for on the volume (install.sh).
RUN mkdir -p /clouve/suitecrm /clouve/suitecrm/standin \
    && curl -fsSL -o "/clouve/suitecrm/SuiteCRM-${SUITECRM_VERSION}.zip" \
        "https://github.com/SuiteCRM/SuiteCRM-Core/releases/download/v${SUITECRM_VERSION}/SuiteCRM-${SUITECRM_VERSION}.zip" \
    && echo "${SUITECRM_SHA256}  /clouve/suitecrm/SuiteCRM-${SUITECRM_VERSION}.zip" | sha256sum -c - \
    && unzip -q "/clouve/suitecrm/SuiteCRM-${SUITECRM_VERSION}.zip" -d /clouve/suitecrm/app \
    && test "$(cat /clouve/suitecrm/app/VERSION)" = "${SUITECRM_VERSION}" \
    && chown -hR root:root /clouve \
    && find /clouve/suitecrm/app -type d -exec chmod 0755 {} + \
    && find /clouve/suitecrm/app -type f -exec chmod 0644 {} + \
    && chmod 0755 /clouve/suitecrm/app/bin/console \
    && chmod 0644 "/clouve/suitecrm/SuiteCRM-${SUITECRM_VERSION}.zip"

# The installer: the entrypoint, its library, the install and upgrade scripts, the background jobs, the
# stand-in for the health check, the clouve-ops sshd kit and the Apache drop-in. This Dockerfile goes in too:
# the build id below covers it.
COPY installer /clouve/suitecrm/installer
COPY Dockerfile /clouve/suitecrm/Dockerfile

# COPY keeps the modes of the checkout, so set them here: files 644, and the scripts 755 (lib.sh is sourced, not
# run). The sshd drop-in lands where the system-wide sshd_config's Include picks it up, and the Apache drop-in
# is enabled and checked. Then the package's keep-list gets the image's own entries, so that SuiteCRM's upgrade
# leaves them on a volume this image installed. Last, the build id is recorded (installer/build-id.sh): an
# upgrade that failed twice is tried again only by another build, so the id changes with everything a fix can
# be in.
RUN chmod -R u=rwX,go=rX /clouve/suitecrm/installer /clouve/suitecrm/Dockerfile \
    && find /clouve/suitecrm/installer -name '*.sh' ! -name lib.sh -exec chmod 755 {} + \
    && cp /clouve/suitecrm/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf \
    && cp /clouve/suitecrm/installer/apache-clouve.conf /etc/apache2/conf-available/clouve.conf \
    && a2enconf clouve \
    && apache2ctl -t \
    && keep=/clouve/suitecrm/app/config/services/system/upgrades.yaml \
    && /clouve/suitecrm/installer/patch-keep-list.sh "$keep" clouve .suitecrm_initialized .suitecrm_url lost+found \
    && chmod 0644 "$keep" \
    && chown -hR root:root /clouve /etc/apache2 \
    && /clouve/suitecrm/installer/build-id.sh > /clouve/suitecrm/BUILD \
    && grep -qE '^[0-9a-f]{16}$' /clouve/suitecrm/BUILD

# Persona pulled at init by the Magneto Agent's sidecar-fetcher over clouve-ops SSH. The plugin-name subdir
# (context/suitecrm/) makes the persona self-identifying in the sidecar to Magneto Agent merge: tar c on
# /clouve/context/ emits ./suitecrm/CONTEXT.md.tpl.
COPY context/ /clouve/context/
RUN chmod -R u=rwX,go=rX /clouve/context

# The volume's mount point. On a cluster the volume replaces it with an empty disk of root's, which the
# entrypoint gives to www-data. The base image leaves it open to everyone (mode 1777), and a Docker volume
# copies that mode.
RUN mkdir -p /var/www/html && chown www-data:www-data /var/www/html && chmod 755 /var/www/html

WORKDIR /var/www/html
ENTRYPOINT ["/clouve/suitecrm/installer/entrypoint.sh"]
CMD ["apache2-foreground"]
