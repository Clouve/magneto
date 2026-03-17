FROM ubuntu:24.04

LABEL maintainer="Clouve Team"
LABEL description="Custom Ubuntu Linux server image with web terminal and Claude Code"

ARG TARGETARCH

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Prevent apt-get from hanging trying to start services (no systemd in containers).
# policy-rc.d covers invoke-rc.d based starts; the systemctl no-op covers packages
# that call systemctl directly (common in Ubuntu 24.04), which otherwise hang
# indefinitely waiting for a systemd socket that does not exist in containers.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && \
    chmod +x /usr/sbin/policy-rc.d && \
    printf '#!/bin/sh\nexit 0\n' > /usr/bin/systemctl && \
    chmod +x /usr/bin/systemctl

# Install system packages, Node.js 22, and ttyd in a single layer to minimise image size.
# apt lists and the NodeSource setup script are removed in the same RUN step so they
# never land in a committed layer.
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    gettext-base \
    curl \
    wget \
    git \
    vim \
    nano \
    htop \
    unzip \
    sudo \
    bash \
    ca-certificates \
    net-tools \
    iputils-ping \
    procps \
    less \
    jq \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* /tmp/nodesource_setup* \
    && TTYD_VERSION=1.7.7 \
    && if [ "$TARGETARCH" = "arm64" ]; then TTYD_ARCH="aarch64"; else TTYD_ARCH="x86_64"; fi \
    && curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
        -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

# Install Claude Code globally and immediately purge the npm cache
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# Copy entrypoint and static template files
RUN mkdir -p /clouve/claude/installer
COPY installer/ /clouve/claude/installer/
RUN chmod +x /clouve/claude/installer/entrypoint.sh \
    && cp /clouve/claude/installer/nginx-default.conf /etc/nginx/sites-available/default \
    && cp /clouve/claude/installer/index.html /var/www/html/index.html

EXPOSE 80

ENTRYPOINT ["/clouve/claude/installer/entrypoint.sh"]
CMD []
