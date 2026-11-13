# LimeSurvey for Clouve
#
# The runtime (PHP, Apache on 8080) is upstream's Docker image. The LimeSurvey code is upstream's own release zip,
# checked against its published SHA-256, because upstream's Docker image trails each release by about a week. The code
# is kept in /clouve/limesurvey/package, outside the volume path, and the entrypoint copies it onto the volume at the
# first start and upgrades an older install in place (installer/entrypoint.sh, installer/upgrade.sh).
#
# To move to the next LimeSurvey release, change the three ARG lines below. When upstream's image for that release
# exists, change the FROM tag too. The zip stays the source of the code either way.
ARG LIMESURVEY_VERSION=7.10.0
ARG LIMESURVEY_BUILD=261109
ARG LIMESURVEY_SHA256=05b72d1d424a7a6b8ac5ae86f240e14aabe121c3c4e83295d4e64a928786f9db

FROM martialblog/limesurvey:7.9.1-261102-apache AS base

# --- the code -----------------------------------------------------------------------------------------------------
FROM base AS package
ARG LIMESURVEY_VERSION
ARG LIMESURVEY_BUILD
ARG LIMESURVEY_SHA256
USER root
RUN apt-get update && apt-get install -y --no-install-recommends patch unzip \
    && rm -rf /var/lib/apt/lists/*

# The release zip. The build stops when the checksum differs.
RUN curl -fsSL --retry 3 -o /tmp/limesurvey.zip \
        "https://download.limesurvey.org/latest-master/limesurvey${LIMESURVEY_VERSION}+${LIMESURVEY_BUILD}.zip" \
    && echo "${LIMESURVEY_SHA256}  /tmp/limesurvey.zip" | sha256sum -c - \
    && unzip -q /tmp/limesurvey.zip -d /tmp/unpacked \
    && mv /tmp/unpacked/limesurvey /package \
    && rm -rf /tmp/limesurvey.zip /tmp/unpacked

# Upstream's fix 6487164b for the 6-to-7 database update (Update_700.php). Without it the update drops the answers of
# one question, and still reports success, when a ranking question's old column names collide with another question's.
# 7.10.0 doesn't have it. A release that has it skips the patch. The build stops when the package neither has the fix
# nor takes the patch.
COPY Update_700-fix-6487164b.patch /tmp/Update_700-fix-6487164b.patch
# shellcheck disable=SC2016  # PHP code, for grep
RUN set -e; \
    file=/package/application/helpers/update/updates/Update_700.php; \
    fixed='function compactLegacyRankingValues(string $tableName, array $columnNames, array $fieldMap): void'; \
    if grep -qF "$fixed" "$file"; then \
        echo "Update_700.php already has upstream's fix 6487164b"; \
    else \
        patch -d /package -p1 --forward --no-backup-if-mismatch < /tmp/Update_700-fix-6487164b.patch; \
    fi; \
    grep -qF "$fixed" "$file"; \
    grep -qF 'compactLegacyRankingValues($TABLE_NAME, $allColumnNames, $fields);' "$file"

# The zip carries a build number, which turns the in-app updater (ComfortUpdate) on. It would put code on the volume
# that is newer than the image, so it is off. The same step checks that the zip is the version the ARGs name.
# shellcheck disable=SC2016  # PHP code
RUN set -e; \
    file=/package/application/config/version.php; \
    sed -i "s/^\\(\\\$config\\['updatable'\\] = \\)true;/\\1false;/" "$file"; \
    php -r '$c = include $argv[1]; \
        exit($c["updatable"] === false && $c["versionnumber"] === $argv[2] && (string) $c["buildnumber"] === $argv[3] ? 0 : 1);' \
        "$file" "$LIMESURVEY_VERSION" "$LIMESURVEY_BUILD"

# --- the image ----------------------------------------------------------------------------------------------------
FROM base
ARG LIMESURVEY_VERSION
ARG LIMESURVEY_BUILD

LABEL maintainer="Clouve Team"
LABEL description="LimeSurvey with a first install and an in-place upgrade done by the entrypoint, and the clouve-ops SSH channel"

USER root

# The database client (mariadb, mariadb-dump) for the upgrade's backup, wget for the health check, and openssh-server
# and sudo for the clouve-ops channel. The upgrade takes the base image's own packages to their newest versions in the
# same Debian release. Installing openssh-server makes SSH host keys, and they go again at the end: kept, they would
# ship in the pushed image and every tenant would share one host key. Each container makes its own at start
# (ssh-keygen -A in start-clouve-ops-sshd.sh).
RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends \
    default-mysql-client \
    wget \
    openssh-server \
    sudo \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*

# The operator account that the AI Assistant's Claude Code signs in with over SSH. Its password is set at each start
# by start-clouve-ops-sshd.sh, from CLOUVE_OPS_PASSWORD. Passwordless sudo: the assistant works as a DevOps engineer
# with full root, held by the safety rules in its persona and its skill, not by sudoers.
RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# The base image's own copy of LimeSurvey goes: /var/www/html is the volume, and the entrypoint fills it from the
# package below.
RUN rm -rf /var/www/html && install -d -o www-data -g www-data -m 755 /var/www/html

# The package is root's, like everything else under /clouve. The entrypoint copies it onto the volume as www-data,
# which only has to read it, and PHP code (www-data) must not be able to change what a later start copies or runs.
COPY --from=package --chown=root:root /package /clouve/limesurvey/package

# Clouve's SuiteCRM plugin for LimeSurvey. It is part of the package, so it is on every volume, and it is registered
# only when ENABLE_SUITECRM_INTEGRATION is true.
COPY --chown=root:root installer/SuiteCRMIntegration /clouve/limesurvey/package/plugins/SuiteCRMIntegration

# The installer: the entrypoint and its parts, the stand-in for the health check, the plugin and demo scripts, the
# clouve-ops sshd files and the Apache drop-in.
COPY installer /clouve/limesurvey/installer

# The persona that the Magneto Agent pulls over clouve-ops SSH. The folder name (context/limesurvey/) tells the agent
# whose persona it is.
COPY context/ /clouve/context/

# - The sshd drop-in lands where the system-wide sshd_config's Include picks it up.
# - The Apache drop-in denies web access to the upgrade's backups (clouve/) and to the package's node_modules/ and
#   installer/ folders, keeps PHP files in upload/ from being run or served, and keeps query strings and the Referer
#   out of the log. It is the image's, so it holds whichever LimeSurvey code is on the volume.
# - Apache's configuration becomes root's. The base image gives it to www-data so that its entrypoint can change the
#   port without root. This image's entrypoint is root, and PHP code must not be able to change what Apache denies.
# - Apache's log, run and lock folders become root's too, with the log links in them. Apache's parent process is
#   root and opens the logs again at each graceful reload, so a link that www-data could swap would make root write
#   to a file of www-data's choice.
# - /clouve, /clouve/limesurvey and the stand-in's folder are root's. The stand-in only reads its folder.
# - image-build names this build: the LimeSurvey version and build number, and a hash of every file of the installer
#   and of the package (installer/build-id.sh). A failed upgrade is tried again only by an image whose build differs,
#   so a rebuilt image with a fix to the installer or to LimeSurvey's own code tries again.
# - package-stats holds the package's number of files and folders and its size in KB. The upgrade checks the
#   volume's free inodes and space against them before it copies the package.
RUN chmod +x /clouve/limesurvey/installer/*.sh \
    && cp /clouve/limesurvey/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf \
    && cp /clouve/limesurvey/installer/apache-clouve.conf /etc/apache2/conf-available/zz-clouve.conf \
    && a2enconf zz-clouve \
    && chown -R root:root /etc/apache2 \
    && chown -hR root:root /var/log/apache2 /var/run/apache2 /var/lock/apache2 \
    && find /var/log/apache2 /var/run/apache2 /var/lock/apache2 -type d -exec chmod 755 {} + \
    && chown root:root /clouve /clouve/limesurvey \
    && chmod 755 /clouve /clouve/limesurvey \
    && install -d -o root -g root -m 755 /clouve/limesurvey/standin \
    && /clouve/limesurvey/installer/build-id.sh > /clouve/limesurvey/image-build \
    && entries="$(find /clouve/limesurvey/package | wc -l)" \
    && kb="$(du -sk /clouve/limesurvey/package | cut -f1)" \
    && [ "$entries" -gt 0 ] && [ "$kb" -gt 0 ] \
    && printf 'entries=%s\nkb=%s\n' "$entries" "$kb" > /clouve/limesurvey/package-stats \
    && chmod 644 /clouve/limesurvey/image-build /clouve/limesurvey/package-stats

# The base image's environment names the LimeSurvey that it shipped. The AI Assistant reads this container's
# environment, so the variable names the LimeSurvey in the package. It comes after the last RUN, where the name
# still means the ARG.
ENV LIMESURVEY_VERSION=${LIMESURVEY_VERSION}+${LIMESURVEY_BUILD}

# This image's own entrypoint. Upstream's (/usr/local/bin/entrypoint.sh) stays where it is and never runs: it passes
# the admin's password to console.php on a command line and starts Apache whatever the install or update did.
ENTRYPOINT ["/clouve/limesurvey/installer/entrypoint.sh"]
CMD ["apache2-foreground"]
