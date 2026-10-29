# Nextcloud image for the Clouve marketplace
# Extends the official Nextcloud image, as the README's "extending official images" pattern says. Our entrypoint
# (installer/entrypoint.sh) gets the container ready and then hands over to the official /entrypoint.sh, which is
# left as it is.
#
# PINNED: nextcloud:35.0.2-apache (Debian 13, PHP 8.5, Apache prefork). An unpinned FROM lets a newer Nextcloud ship
# under existing tenant volumes on the next rebuild, and the official entrypoint upgrades the data the moment it
# starts (the drift class that CrashLooped Moodle). Nextcloud upgrades only one major version at a time. Bump this
# tag deliberately, never to :latest.

FROM nextcloud:35.0.2-apache

LABEL maintainer="Clouve Team"
LABEL description="Nextcloud with an in-container Valkey cache, settings kept in step with the environment, and the clouve-ops SSH channel"

# openssh-server and sudo for the clouve-ops channel. valkey-server for the in-container cache (Valkey 8.1 in
# Debian 13); its valkey-cli is what the entrypoint and the health check ping it with. mariadb-client for
# mariadb-dump, which the AI Assistant's backups use. openssh-server's install makes SSH host keys, and they go
# again here: kept, they would ship in the pushed image and every tenant would share one host key. Each container
# makes its own at start instead (ssh-keygen -A in start-clouve-ops-sshd.sh).
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    sudo \
    valkey-server \
    mariadb-client \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*

# Operator account used by the magneto-agent container's Claude Code agent for
# shell access into this container. The account password is set at runtime by
# /clouve/nextcloud/installer/start-clouve-ops-sshd.sh from the per-pod
# CLOUVE_OPS_PASSWORD env var (same value on all three services).
# Passwordless sudo: the agent is a DevOps engineer with full root,
# gated by the safety rules in CONTEXT.md.tpl and the Nextcloud skill
# rather than by sudoers.
RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# The installer: the entrypoint, lib.sh, the probe, Valkey, the settings script, the hooks, the clouve-ops sshd kit
# and the Apache files.
COPY installer /clouve/nextcloud/installer

# COPY keeps the modes of the checkout, so set them here: directories 755 and files 644, and the scripts 755 (lib.sh
# is sourced, not run). The official entrypoint runs the hooks from /docker-entrypoint-hooks.d/<phase>/ as www-data.
# The sshd drop-in lands where the system-wide sshd_config's Include picks it up.
RUN chmod -R u=rwX,go=rX /clouve/nextcloud/installer \
    && find /clouve/nextcloud/installer -name '*.sh' ! -name lib.sh -exec chmod 755 {} + \
    && for phase in pre-installation post-installation post-upgrade before-starting; do \
        cp /clouve/nextcloud/installer/hooks/$phase/10-clouve.sh /docker-entrypoint-hooks.d/$phase/10-clouve.sh || exit 1; \
    done \
    && cp /clouve/nextcloud/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf

# Apache: the HSTS header, and the CalDAV/CardDAV discovery redirect inside <VirtualHost *:80> (a conf-enabled file
# has no effect on it). The grep fails the build if the insert did not apply.
RUN cp /clouve/nextcloud/installer/apache-clouve.conf /etc/apache2/conf-available/clouve.conf \
    && a2enconf clouve \
    && sed -i '/<VirtualHost \*:80>/r /clouve/nextcloud/installer/apache-wellknown.inc' /etc/apache2/sites-available/000-default.conf \
    && grep -q 'remote.php/dav/ \[R=301' /etc/apache2/sites-available/000-default.conf \
    && apache2ctl -t

# The official entrypoint runs as root on /var/www/html, which www-data owns, so two of its lines change. It opens its
# init lock read-only (`9<`, where `9>` creates, truncates and follows a symlink), and it runs the volume's version.php,
# which is PHP that www-data can change, as www-data. The script fails the build when either line is not there as it
# expects, so a change upstream can't ship unpatched.
RUN /clouve/nextcloud/installer/patch-official-entrypoint.sh /entrypoint.sh

# Persona pulled at init by the Magneto Agent's sidecar-fetcher over clouve-ops SSH.
# The plugin-name subdir (`context/nextcloud/`) makes the persona self-identifying
# in the sidecar to Magneto Agent merge: tar c on /clouve/context/ emits
# ./nextcloud/CONTEXT.md.tpl.
COPY context/ /clouve/context/
RUN chmod -R u=rwX,go=rX /clouve/context

# Our entrypoint execs the official /entrypoint.sh, which stays where the image put it.
ENTRYPOINT ["/clouve/nextcloud/installer/entrypoint.sh"]
CMD ["apache2-foreground"]
