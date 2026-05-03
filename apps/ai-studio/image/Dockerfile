FROM ubuntu:24.04

LABEL maintainer="Clouve Team"
LABEL description="AI Studio — multi-client AI coding assistant environment with web terminal"

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
# Developer tools (git, vim, nano, etc.) and AI client CLIs are deferred to
# first container start so the image stays lean and seed tarballs stay small.
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    gettext-base \
    curl \
    sudo \
    bash \
    ca-certificates \
    jq \
    busybox-static \
    python3 \
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

# Copy entrypoint and static template files
RUN mkdir -p /clouve/ai-studio/installer
COPY installer/ /clouve/ai-studio/installer/

# Bake the repo-local context/ tree into the image. Loader at runtime copies
# /clouve/context/CONTEXT.md.tpl to /clouve/skills/CONTEXT.md.tpl and uses
# /clouve/context/<plugin>/CONTEXT.md.tpl as the source for per-plugin
# context sections. Staged into the build context by image/prebuild.sh.
COPY context-bundled/ /clouve/context/

RUN chmod +x /clouve/ai-studio/installer/entrypoint.sh \
             /clouve/ai-studio/installer/init.sh \
             /clouve/ai-studio/installer/chat/install.sh \
             /clouve/ai-studio/installer/chat/skills.sh \
             /clouve/ai-studio/installer/chat/claude/install.sh \
             /clouve/ai-studio/installer/chat/gemini/install.sh \
             /clouve/ai-studio/installer/chat/openai/install.sh \
             /clouve/ai-studio/installer/chat/marketplace/loader.sh \
             /clouve/ai-studio/installer/chat/marketplace/url-parser.sh \
             /clouve/ai-studio/installer/chat/marketplace/credentials.sh \
             /clouve/ai-studio/installer/chat/marketplace/git-fetcher.sh \
             /clouve/ai-studio/installer/chat/marketplace/git-askpass-helper.sh \
             /clouve/ai-studio/installer/chat/marketplace/marketplace-reader.sh \
             /clouve/ai-studio/installer/chat/marketplace/plugin-stager.sh \
             /clouve/ai-studio/installer/chat/marketplace/context-composer.sh \
             /clouve/ai-studio/installer/files/install.sh \
             /clouve/ai-studio/installer/auth/server.py \
    && cp /clouve/ai-studio/installer/nginx-default.conf /etc/nginx/sites-available/default \
    && cp /clouve/ai-studio/installer/profile.d/clv-skills.sh /etc/profile.d/clv-skills.sh \
    && chmod 644 /etc/profile.d/clv-skills.sh \
    && mkdir -p /opt/filebrowser \
    && cp /clouve/ai-studio/installer/files/filebrowser-config.yaml /opt/filebrowser/config.yaml \
    && cp /clouve/ai-studio/installer/files/pam-filebrowser /etc/pam.d/filebrowser

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
        var && \
    tar czf /clouve/opt-seed.tar.gz -C / opt

EXPOSE 80

ENTRYPOINT ["/clouve/busybox", "sh", "/clouve/ai-studio/installer/init.sh"]
CMD []
