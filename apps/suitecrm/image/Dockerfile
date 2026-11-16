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
# the console alike. The earlier image named a file that only root could write. The two cookie settings give
# the session cookie that SuiteCRM's older pages set the flags its newer pages already set (Secure comes from the
# Apache drop-in, behind the ingress's HTTPS). Strict mode makes PHP refuse a session id it didn't make, so a
# cookie planted from a sibling host can't fix someone's session. PHP doesn't name its version in a header, and
# a stack trace in the log carries no arguments, which can be passwords.
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
    echo 'session.use_strict_mode = 1'; \
    echo 'expose_php = Off'; \
    echo 'zend.exception_ignore_args = On'; \
} > /usr/local/etc/php/conf.d/suitecrm.ini

# Apache serves /var/www/html/public, SuiteCRM 8's web root, and reads its .htaccess. It names no version in its
# Server header and signs no error page: Debian's security.conf says otherwise, and it loads after the image's
# own drop-in (clouve.conf), so the edit is made there. The greps fail the build when an edit did not apply.
RUN a2enmod rewrite headers expires remoteip \
    && sed -i 's/^ServerTokens .*/ServerTokens Prod/; s/^ServerSignature .*/ServerSignature Off/' /etc/apache2/conf-available/security.conf \
    && grep -qx 'ServerTokens Prod' /etc/apache2/conf-available/security.conf \
    && grep -qx 'ServerSignature Off' /etc/apache2/conf-available/security.conf \
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

# PHP libraries in the package that have published advisories with a fix in the same line. Each moves to the newest
# release of its line that was at least 14 days old on 2026-11-16, in the unpacked package and in the kept zip, which
# SuiteCRM's own upgrade command unpacks. The build has no Composer, so it takes each release as Composer installs
# it: the archive GitHub makes of the release commit that Packagist names. Each archive is checked against its
# SHA-256 here, and patch-vendor.php checks that GitHub's comment in it names that commit, that the release declares
# the same classes in the same files (the package's class map is not rebuilt), and records the new versions where
# Composer\InstalledVersions reads them. jmespath leaves its 2.8 line, as Moodle's did: 2.8 has no fixed release.
# Left as SuiteCRM ships them, with no fix in their line: zbateson/mail-mime-parser 2.4.1 (fixed in 3.0.6),
# tinymce/tinymce 8.5.1 (fixed in 8.9.3, and also built into SuiteCRM's front end), and the advisories that only
# guzzlehttp/guzzle 7.14 and 7.15 fix. A SuiteCRM version bump checks each line here against its new package.
#   mtdowling/jmespath.php 2.8.0 -> 2.9.2     GHSA-pcw8-m77r-2528 (CVE-2026-54133)
#   symfony/http-foundation 6.4.41 -> 6.4.49  GHSA-r925-mgvr-h9cc (CVE-2026-108082)
#   symfony/yaml 6.4.40 -> 6.4.49             GHSA-2v3c-qxhr-7vpv (CVE-2026-109413)
#   smarty/smarty 4.5.6 -> 4.5.8              GHSA-cq55-c7wv-pxmq, GHSA-f6wf-28g6-769x
#   guzzlehttp/guzzle 7.12.1 -> 7.12.3        GHSA-g446-98w2-8p5w (CVE-2026-59883)
#   guzzlehttp/psr7 2.12.1 -> 2.12.5          GHSA-c2w2-prh8-qm98 (CVE-2026-59882)
#   phpseclib/phpseclib 3.0.54 -> 3.0.58      GHSA-q97c-8qh3-fpc6 (CVE-2026-84308)
COPY installer/patch-vendor.php /clouve/suitecrm/installer/patch-vendor.php
RUN set -eu; mkdir /tmp/vendor-fix; cd /tmp/vendor-fix; specs=''; \
    for p in \
      "mtdowling/jmespath.php 2.9.2 jmespath/jmespath.php 2157c5e50e813ec6a96c1eed3be7f64a20fb32a8 b86091fecc7a19fa299692ce31ee3132c6c9abb265da4aa12b1b2d0e62fe6baa" \
      "symfony/http-foundation v6.4.49 symfony/http-foundation aed9ac2fe4eefa1d1b7fba04604db3a62a5f150b 9bebccf73424da68d3c5a5133d1d8e9393adca78065b9a67a80330fdc244ec8d" \
      "symfony/yaml v6.4.49 symfony/yaml bbefb7d9cd1bf804148bd1c306a9acc87f335196 7a0dbf80760cebb5b9542b9037d229d198b10713b27036d4145686696e8d4fc3" \
      "smarty/smarty v4.5.8 smarty-php/smarty 042d310bdfbc67aa9138418d838d689b34f4c87e d003bdf3dda03ee09df177d02b859959b8b8d7b0cd5f41f57ad7ac675790ed4c" \
      "guzzlehttp/guzzle 7.12.3 guzzle/guzzle 9aa17bcdd777ee31df9fc83c337ca4ca2340def3 d18b6d04dd409b67d5a7ec386e17d5f173517f9f78356babb5a7c5fe71c8b6a0" \
      "guzzlehttp/psr7 2.12.5 guzzle/psr7 9365d578a9fd1552ad6ca9c3cb530708526feb09 8ab323f73334717cbc898b11829bec899e2e4418af2e08fdde8534241808ff19" \
      "phpseclib/phpseclib 3.0.58 phpseclib/phpseclib 91f3a6436bb84040ac0cf49e761977f17d16a39b 6ad0e8055704ea1713ef316d095dc6a168a5cc5b92e32aa99e7ec9453e735f8a"; do \
      set -- $p; \
      curl -fsSL -o "$4.zip" "https://codeload.github.com/$3/zip/$4"; \
      echo "$5  $4.zip" | sha256sum -c -; \
      specs="$specs $1=$2@$4"; \
    done; \
    php /clouve/suitecrm/installer/patch-vendor.php /clouve/suitecrm/app "/clouve/suitecrm/SuiteCRM-${SUITECRM_VERSION}.zip" \
      /tmp/vendor-fix $specs; \
    cd /; rm -rf /tmp/vendor-fix; \
    chown -hR root:root /clouve/suitecrm; \
    find /clouve/suitecrm/app/vendor -type d -exec chmod 0755 {} +; \
    find /clouve/suitecrm/app/vendor -type f -exec chmod 0644 {} +; \
    chmod 0644 "/clouve/suitecrm/SuiteCRM-${SUITECRM_VERSION}.zip"

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

# Programs with the set-user-ID or set-group-ID bit are where a local privilege bug pays off, for code that runs
# as www-data. This image uses two: sudo, for clouve-ops, and unix_chkpwd, which PAM runs to check a password.
# The others (su, mount, passwd and the like) lose the bit. The build fails when anything else keeps one.
RUN find / -xdev -perm /6000 -type f ! -path /usr/bin/sudo ! -path /usr/sbin/unix_chkpwd -exec chmod ug-s {} + \
    && test "$(find / -xdev -perm /6000 -type f | sort | xargs)" = "/usr/bin/sudo /usr/sbin/unix_chkpwd"

WORKDIR /var/www/html
ENTRYPOINT ["/clouve/suitecrm/installer/entrypoint.sh"]
CMD ["apache2-foreground"]
