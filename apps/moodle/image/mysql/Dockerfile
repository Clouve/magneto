# MySQL 8.4 Database Image for Moodle Learning Management System
# This Dockerfile uses the official MySQL 8.4 image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits

# tini, PID 1 (see ENTRYPOINT below). Oracle Linux, the MySQL image's base, has
# no tini package, so the static build comes from Debian's. buildx builds this
# stage for each platform, so amd64 and arm64 each get their own.
FROM debian:trixie-slim AS tini
RUN apt-get update && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

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

FROM mysql:8.4

# Metadata
LABEL maintainer="Clouve Platform"
LABEL description="MySQL 8.4 database for Moodle Learning Management System"
LABEL version="8.4"

# The official MySQL image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

# clouve-ops shell channel (mirrors the same setup in apps/moodle/image/
# Dockerfile). openssh-server lets the magneto-agent container's Claude Code
# agent `ssh clouve-ops@${MOODLE_DB_HOST}` for OS-level operations on the
# DB host (mysqld restart, log inspection, my.cnf tweaks, disk usage). The
# routine SQL surface is still the TCP MySQL client.
RUN microdnf install -y openssh-server sudo shadow-utils \
        procps-ng hostname iproute diffutils less vim-minimal \
    && microdnf clean all \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops

# MySQL Shell bundles its own Python with a certifi that has a critical advisory, and nothing here runs mysqlsh. No
# package needs it; mysql and mysqldump come with the server. rpm leaves what the shell wrote when the base was built
# (its Python caches, its log, empty folders), so those go too (tests/mysql-image-shell.test.sh).
RUN rpm -e mysql-shell && rm -rf /usr/lib/mysqlsh /usr/libexec/mysqlsh /usr/share/mysqlsh /root/.mysqlsh

COPY --from=tini /usr/bin/tini-static /usr/bin/tini
COPY --from=gosu --chmod=755 /gosu /usr/local/bin/gosu
COPY clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh

# Wrap the upstream docker-entrypoint.sh so we get sshd alongside mysqld.
# tini is PID 1: mysqld doesn't reap processes it didn't start, such as what an
# SSH session leaves behind, and they would stay zombies. tini reaps them, and
# passes the stop signal on to mysqld (tests/db-image-zombies.test.sh).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/clouve-entrypoint.sh"]
CMD ["mysqld"]
