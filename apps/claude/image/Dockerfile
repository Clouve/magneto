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

# Install system packages
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
    tree \
    jq

# Install Node.js 22 (LTS) via NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install ttyd (web terminal) for the appropriate architecture
RUN TTYD_VERSION=1.7.7 && \
    if [ "$TARGETARCH" = "arm64" ]; then \
        TTYD_ARCH="aarch64"; \
    else \
        TTYD_ARCH="x86_64"; \
    fi && \
    curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
        -o /usr/local/bin/ttyd && \
    chmod +x /usr/local/bin/ttyd

# Copy entrypoint and static template files
RUN mkdir -p /clouve/linux/installer
COPY installer/ /clouve/linux/installer/
RUN chmod +x /clouve/linux/installer/entrypoint.sh

# Configure nginx: proxy /chat to ttyd (127.0.0.1:7890) over HTTP
RUN cp /clouve/linux/installer/nginx-default.conf /etc/nginx/sites-available/default

# Deploy landing page to nginx web root
RUN cp /clouve/linux/installer/index.html /var/www/html/index.html

EXPOSE 80

ENTRYPOINT ["/clouve/linux/installer/entrypoint.sh"]
CMD []
