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

# Install core system packages and ttyd.
# Developer tools (git, vim, nano, etc.) and Claude Code are deferred to
# entrypoint.sh so they are installed lazily on first container start,
# keeping this image lean and the seed tarballs small.
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    gettext-base \
    curl \
    sudo \
    bash \
    ca-certificates \
    jq \
    busybox-static \
    libnginx-mod-http-auth-pam \
    libpam-runtime \
    && rm -rf /var/lib/apt/lists/* \
    && TTYD_VERSION=1.7.7 \
    && if [ "$TARGETARCH" = "arm64" ]; then TTYD_ARCH="aarch64"; else TTYD_ARCH="x86_64"; fi \
    && curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
        -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd

# Allow nginx PAM auth to read /etc/shadow
RUN usermod -aG shadow www-data

# Download FileBrowser Quantum binary
RUN if [ "$TARGETARCH" = "arm64" ]; then FB_ARCH="arm64"; else FB_ARCH="amd64"; fi \
    && FB_URL=$(curl -fsSL https://api.github.com/repos/gtsteffaniak/filebrowser/releases/latest \
        | jq -r --arg arch "$FB_ARCH" \
          '.assets[] | select(.name | test("linux-" + $arch + "-filebrowser$")) | .browser_download_url') \
    && curl -fsSL "$FB_URL" -o /usr/local/bin/filebrowser \
    && chmod +x /usr/local/bin/filebrowser

# Create FileBrowser directories
RUN mkdir -p /opt/filebrowser /srv/files

# Copy entrypoint and static template files
RUN mkdir -p /clouve/claude/installer
COPY installer/ /clouve/claude/installer/
RUN chmod +x /clouve/claude/installer/entrypoint.sh \
             /clouve/claude/installer/init.sh \
             /clouve/claude/installer/chat/install.sh \
             /clouve/claude/installer/files/install.sh \
    && cp /clouve/claude/installer/nginx-default.conf /etc/nginx/sites-available/default \
    && cp /clouve/claude/installer/index.html /var/www/html/index.html \
    && cp /clouve/claude/installer/files/filebrowser-config.yaml /opt/filebrowser/config.yaml \
    && cp /clouve/claude/installer/files/pam-filebrowser /etc/pam.d/filebrowser

# Remove Ubuntu's "use sudo" login hint from /etc/bash.bashrc
RUN sed -i '/To run a command as administrator/d; /See "man sudo_root"/d' /etc/bash.bashrc

# Place the static busybox binary outside /usr so the bootstrap entrypoint
# (init.sh) remains executable even when /usr is mounted as an empty volume.
RUN cp /usr/bin/busybox /clouve/busybox

# Snapshot /usr and /var into tarballs stored in /clouve/.
# init.sh extracts these on first start when the volumes are empty (e.g. a
# fresh Kubernetes PVC), then skips extraction on all subsequent starts.
# Snapshots are taken last so they capture every package installed above.
RUN tar czf /clouve/usr-seed.tar.gz -C / usr && \
    tar czf /clouve/var-seed.tar.gz -C / \
        --exclude=var/run \
        --exclude=var/lock \
        var

EXPOSE 80

ENTRYPOINT ["/clouve/busybox", "sh", "/clouve/claude/installer/init.sh"]
CMD []
