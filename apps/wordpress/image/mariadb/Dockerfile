# MariaDB Database Image for WordPress
# This Dockerfile uses the official MariaDB image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits
#
# PINNED: mariadb:12.3 (what :latest resolved to on 2026-08-05 — 12.3.2).
# An unpinned FROM lets a newer engine ship under existing tenant data
# volumes on the next rebuild (the exact drift class that CrashLooped
# Moodle). Bump this tag deliberately, never back to :latest.

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
LABEL description="MariaDB database for WordPress CMS"
LABEL version="12.3"

# The official MariaDB image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

# clouve-ops shell channel (mirrors the same setup in apps/wordpress/image/
# Dockerfile). openssh-server lets the magneto-agent container's Claude Code
# agent `ssh clouve-ops@${WORDPRESS_DB_HOST}` for OS-level operations on the
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
COPY clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh

# Wrap the upstream docker-entrypoint.sh so we get sshd alongside mariadbd.
# tini is PID 1: mariadbd doesn't reap processes it didn't start, such as what
# an SSH session leaves behind, and they would stay zombies. tini reaps them,
# and passes the stop signal on to mariadbd (tests/db-image-zombies.test.sh).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/clouve-entrypoint.sh"]
CMD ["mariadbd"]
