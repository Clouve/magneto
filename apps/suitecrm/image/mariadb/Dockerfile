# MariaDB Database Image for SuiteCRM
# This Dockerfile uses the official MariaDB image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits
#
# PINNED: mariadb:12.3, the tag the WordPress and Nextcloud database images
# use. This image was "FROM mariadb" with no tag until November 2026, so each
# rebuild took whatever :latest was that day: 12.x for the images that made
# today's installs, 13.0 by now. SuiteCRM 8.10 lists MariaDB up to 11.8. 12.3
# is one line past that list, it passed an install, an upgrade and a smoke
# test, and it is the lowest pin that is not below what existing data
# directories hold. MariaDB starts on files from a newer line without
# complaint, and that downgrade is not supported, so the entrypoint wrapper
# refuses such a data directory (entrypoint.sh). Bump this tag deliberately,
# never back to :latest, and never below the line an install's data was
# written by.

# gosu, rebuilt from source. The base image's gosu (1.19) was built with Go 1.24.6, whose standard library has a
# critical vulnerability (CVE-2025-68121), and the official entrypoint runs it to start the server as the mysql user.
# This stage builds gosu 1.20 from its upstream source, at the commit the tag names, with a current Go, statically
# (CGO off, as upstream builds it). It runs on the build machine and compiles for each target platform, so an arm64
# build needs no emulation. The COPY below puts it in the base's place, with the same path, owner and mode
# (tests/db-image-gosu.test.sh).
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine AS gosu
ARG TARGETOS TARGETARCH
RUN apk add --no-cache git \
    && git clone --depth 1 --branch 1.20 https://github.com/tianon/gosu.git /src \
    && test "$(git -C /src rev-parse HEAD)" = 29b939aa5bd4dc588af765b8248f6e39150d2565 \
    && cd /src \
    && CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" go build -trimpath -ldflags '-d -w' -o /gosu .

FROM mariadb:12.3

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MariaDB database for SuiteCRM"
LABEL version="12.3"

# Lets the entrypoint run mariadb-upgrade by itself when a newer engine starts
# on an older data directory (the installs made before this pin hold 12.x
# files). The image sets it, not the manifest, because nothing re-applies a
# newer manifest to a running deployment. Only a new image reaches it.
ENV MARIADB_AUTO_UPGRADE=1

# clouve-ops shell channel (mirrors the same setup in apps/suitecrm/image/
# Dockerfile). openssh-server lets the magneto-agent container's Claude Code
# agent `ssh clouve-ops@${SUITECRM_DB_HOST}` for OS-level operations on the
# DB host (mariadbd restart, log inspection, config tweaks, disk usage). The
# routine SQL surface is still the TCP MySQL client.
# (procps and iproute2 already ship in the base image; less/vim/diff do not.)
# openssh-server's install makes SSH host keys, and they go again at the end:
# kept, they would ship in the pushed image and every tenant would share one
# host key. Each container makes its own at start instead (ssh-keygen -A in
# start-clouve-ops-sshd.sh). tini is PID 1 (see ENTRYPOINT).
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo less vim-tiny diffutils tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops \
    && rm -f /etc/ssh/ssh_host_*

COPY --from=gosu --chmod=755 /gosu /usr/local/bin/gosu
# The base image's environment names the gosu it shipped (1.19). The one above replaced it.
ENV GOSU_VERSION=1.20
# COPY keeps the checkout's mode, which can be group-writable. The drop-in is root's alone to write.
COPY --chmod=644 clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh

# Wrap the upstream docker-entrypoint.sh so we get the data directory check
# and sshd alongside mariadbd. tini is PID 1: mariadbd doesn't reap processes
# it didn't start, such as what an SSH session leaves behind, and they would
# stay zombies. tini reaps them, and passes the stop signal on to mariadbd
# (tests/db-image-zombies.test.sh).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/clouve-entrypoint.sh"]
CMD ["mariadbd"]
