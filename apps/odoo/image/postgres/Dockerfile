# PostgreSQL Database Image for Odoo
# This Dockerfile uses the official PostgreSQL 18 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

# gosu, built from upstream's source with a current Go. postgres:18's own
# entrypoint drops from root to the postgres user with gosu, and the image
# ships gosu 1.19 built with Go 1.24.6, whose standard library has
# CVE-2025-68121 (critical). This stage builds gosu 1.20, the release whose
# github.com/moby/sys/user (v0.4.1) also has CVE-2026-61801's fix, and the
# one the MySQL and MariaDB images build, at a pinned commit (the build stops
# if the tag points anywhere else; the Go modules are checked against gosu's
# go.sum), static and without cgo, as upstream builds it. It runs on the build
# machine's platform and cross-compiles for each target platform.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine AS gosu
ARG TARGETOS
ARG TARGETARCH
ARG GOSU_VERSION=1.20
ARG GOSU_COMMIT=29b939aa5bd4dc588af765b8248f6e39150d2565
RUN apk add --no-cache git \
    && git clone --quiet --depth 1 --branch "$GOSU_VERSION" https://github.com/tianon/gosu.git /src \
    && test "$(git -C /src rev-parse HEAD)" = "$GOSU_COMMIT"
WORKDIR /src
RUN CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
        go build -trimpath -ldflags '-d -w' -buildvcs=true -o /out/gosu . \
    && chmod 755 /out/gosu

FROM postgres:18

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="PostgreSQL database for Odoo ERP"
LABEL version="18"

# The official PostgreSQL image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

# clouve-ops shell channel (mirrors apps/odoo/image/Dockerfile and the moodle
# mysql image). openssh-server lets the Magneto Agent container's Claude Code
# `ssh clouve-ops@${ODOO_DB_HOST}` for OS-level DB ops (postgres restart, log
# inspection, postgresql.conf tweaks, disk usage). Routine SQL stays on TCP psql.
# Debian package names (vs the mysql image's Oracle-Linux/microdnf): procps,
# iproute2, vim-tiny; gosu/useradd/chpasswd are already in the postgres image.
# Installing openssh-server makes SSH host keys, and they're deleted again at
# the end: kept, they would ship in the pushed image and every tenant would
# have the same host key. Each container makes its own when its sshd starts
# (ssh-keygen -A in start-clouve-ops-sshd.sh). apt-get -y upgrade takes the
# base image's packages to their latest Debian security fixes at each build.
RUN apt-get update && apt-get -y upgrade && apt-get install -y --no-install-recommends \
        openssh-server sudo procps iproute2 less vim-tiny tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops \
    && rm -f /etc/ssh/ssh_host_*

# The gosu built above, at the base image's path, root's, mode 755. The build
# stops unless it runs and can drop to another user.
COPY --from=gosu /out/gosu /usr/local/bin/gosu
RUN gosu --version && gosu nobody true

COPY clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh

# Wrap the upstream docker-entrypoint.sh so we get sshd alongside postgres.
# No USER line: must stay root for sshd setup and the upstream entrypoint's
# root-time initdb/chown before it gosu-drops to the postgres user.
# tini is PID 1, so PostgreSQL never sees processes it didn't start: when one
# of those ends with an error or a signal, PostgreSQL takes it for a crashed
# server process and ends every connection to restart. tini reaps them, and
# passes the stop signal (SIGINT, from the postgres image) on to PostgreSQL.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/clouve-entrypoint.sh"]
CMD ["postgres"]
