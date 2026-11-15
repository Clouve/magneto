# MariaDB Database Image for ownCloud
# This Dockerfile uses the official MariaDB image as the base
# and is built as a multi-platform image to avoid Docker Hub rate limits
#
# PINNED: mariadb:12.3, the LTS the other apps use. :latest was 12.3 from at least 2026-08-05 until MariaDB 13.0 took
# it on 2026-11-12, so no tenant's data was written by a newer server, and MARIADB_AUTO_UPGRADE (the manifest) upgrades
# older data at start. Bump this tag deliberately, never back to :latest.

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
LABEL description="MariaDB database for ownCloud"
LABEL version="12.3"

COPY --from=gosu --chmod=755 /gosu /usr/local/bin/gosu

# The official MariaDB image already includes all necessary configuration
# We're simply re-packaging it to push to our own registry
# This avoids Docker Hub rate limits when creating multi-platform manifests

