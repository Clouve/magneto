FROM ubuntu:26.04

# Slug of the pre-seeded MERN starter project at /home/clouve-ops/projects/<slug>/.
# Override with --build-arg SEED_SLUG=<name> to rename the project directory;
# every baked reference to it (supervisor program confs, backend .env, project
# README/NOTES, the agent persona) is rewritten to match at build time via the
# @SLUG@ token. The seed sources themselves live in seed/.
ARG SEED_SLUG=starter

# Mirror — same as Moodle and other Clouve siblings. en_US baseline; tenants
# add their own locales at runtime if needed.
# curl + gnupg serve the apt-repo setup below and stay for the runtime agent.
# git is a dev-workspace staple (project checkouts per the ai-studio skill)
# and a build-time need: mongo-express has a github: dependency npm can only
# fetch with git on PATH.
# supervisor is the workspace's process manager and PID 1 — there is no
# systemd in this container (see installer/supervisord.conf).
# NOTE: cleanup removes only the apt list cache — /var/lib/dpkg must stay
# intact because the runtime agent apt-installs packages on the live server.
RUN apt-get update && apt-get install -y \
        openssh-server \
        sudo \
        locales \
        ca-certificates \
        busybox-static \
        curl \
        git \
        gnupg \
        supervisor \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen \
    && apt-get clean autoclean \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# --- MERN runtime: Node.js 22 LTS + MongoDB 7.0 -------------------------------
# Version pins per the mern skill (magneto-skills/plugins/mern). NodeSource's
# "nodistro" suite installs on any apt distro. The mongodb-org 7.0 repo's
# newest published suite is jammy (noble starts at 8.0; there is no 26.04
# suite at all), so we pin jammy — the mern skill's documented codename
# fallback; its packages resolve cleanly on 26.04. Binaries land in
# /usr (persistent volume); mongod's data dir is the package default
# /var/lib/mongodb (under persistent /var), so databases survive pod restarts.
# The mongodb user is pre-created with a PINNED uid/gid: /etc/passwd is
# image-owned and resets to the *current* image's users each boot, while the
# seeded volumes carry numeric uid/gid from whatever image first seeded them.
# Letting the package postinst allocate the uid dynamically would let a
# routine rebuild shift it and strand mongod without write access to its own
# /var/lib/mongodb on already-seeded volumes. (clouve-ops is pinned below for
# the same reason.) The postinst adopts a pre-existing mongodb user as-is.
#
# mongod's file log (systemLog: in the package /etc/mongod.conf) is removed
# so mongod logs to stdout and supervisord captures it with built-in
# rotation — there is no cron/systemd-timer in this container to ever run
# logrotate, and an append-only file on the persistent /var volume would
# grow without bound across pod restarts.
RUN groupadd --system --gid 990 mongodb \
    && useradd --system --uid 990 --gid mongodb --home-dir /var/lib/mongodb \
        --no-create-home --shell /usr/sbin/nologin mongodb \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
        > /etc/apt/sources.list.d/mongodb-org-7.0.list \
    && apt-get update \
    && apt-get install -y nodejs mongodb-org \
    && sed -i '/^systemLog:/,+3d' /etc/mongod.conf \
    && ! grep -q '^systemLog:' /etc/mongod.conf \
    && ! grep -q 'logpath' /etc/mongod.conf \
    && apt-get clean autoclean \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# mongo-express — browser access to the seeded MongoDB. It is an HTTP app, so
# it rides clv-proxy like any other dev-server port (the raw MongoDB wire
# protocol cannot — no Host header to route on; native clients use the SSH
# tunnel instead). Built from the GitHub tag because the npm tarballs are
# unusable for direct install: every published version omits both src/ and
# the webpack dist/ + build-assets.json the app needs at startup, and 1.0.2
# (the last stable) additionally carries a github:-hosted dependency whose
# resolution crashes npm 10 with no error output. v1.1.0-rc-4 is the npm
# `latest` dist-tag. Lives under /opt (persistent) — the runtime supervisord
# program runs `node app.js` with this directory as CWD (build-assets.json
# is resolved relative to CWD).
RUN git clone --depth 1 --branch v1.1.0-rc-4 \
        https://github.com/mongo-express/mongo-express.git /opt/clouve/mongo-express \
    && cd /opt/clouve/mongo-express \
    && npm install --ignore-scripts --no-audit --no-fund \
    && npm run build \
    && npm prune --omit=dev --no-audit --no-fund \
    && npm cache clean --force \
    && rm -rf /opt/clouve/mongo-express/.git

# clouve-ops operator account for the magneto-agent's Claude Code agent.
# Password is set at runtime by entrypoint.sh from CLOUVE_OPS_PASSWORD
# (same value injected on both this container and magneto-agent).
# NOPASSWD: ALL — agent is a DevOps engineer with full root; safety
# gating lives in the ai-studio skill's SKILL.md, not in sudoers.
# Identical to the Moodle sibling's clouve-ops setup, except the uid/gid is
# pinned: /home rides a volume seeded with numeric ownership, and the uid
# must not drift between image rebuilds (see the mongodb note above).
RUN groupadd --gid 1001 clouve-ops && \
    useradd --uid 1001 --gid clouve-ops --create-home --shell /bin/bash \
        --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# sshd hardening drop-in: password-only, no root login, only clouve-ops.
# Picked up automatically by /etc/ssh/sshd_config's Include directive.
COPY installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf

# Required by sshd for its privilege-separation directory at runtime.
RUN mkdir -p /run/sshd

# --- Supervision: supervisord is PID 1 ----------------------------------------
# entrypoint.sh exec's supervisord, which starts and restarts the whole stack
# on every boot: sshd (the agent's path in), mongod, the seed project's
# backend and frontend dev servers, and mongo-express. Two include dirs:
#   /etc/supervisor/conf.d/      image-owned (sshd only). /etc resets to image
#                                state every boot, so the agent's SSH lifeline
#                                can't be lost to a bad persistent-side edit.
#   /opt/clouve/supervisord.d/   the seeded app stack + anything the agent adds
#                                later. /opt is a persistent volume, so agent
#                                changes here survive pod restarts.
COPY installer/supervisord.conf /etc/supervisor/supervisord.conf
COPY installer/supervisor-sshd.conf /etc/supervisor/conf.d/sshd.conf
COPY installer/supervisord.d/ /opt/clouve/supervisord.d/
RUN mkdir -p /var/log/supervisor \
    && sed -i "s|@SLUG@|${SEED_SLUG}|g" /opt/clouve/supervisord.d/*.conf

# --- Seed MERN project ---------------------------------------------------------
# A minimal but real full-stack app (Express API + Vite React frontend + one
# Mongo collection) so the workspace boots with something running for the
# Magneto Agent to iterate on. npm install happens here, at build time, so the
# node_modules ride the /home snapshot and first boot needs no cold install.
# Layout follows the mern skill: backend/ + frontend/ + README.md + NOTES.md.
COPY seed/ /home/clouve-ops/projects/${SEED_SLUG}/
RUN sed -i "s|@SLUG@|${SEED_SLUG}|g" \
        "/home/clouve-ops/projects/${SEED_SLUG}/backend/.env" \
        "/home/clouve-ops/projects/${SEED_SLUG}/README.md" \
        "/home/clouve-ops/projects/${SEED_SLUG}/NOTES.md" \
    && cd "/home/clouve-ops/projects/${SEED_SLUG}/backend" \
    && npm install --no-audit --no-fund \
    && cd "/home/clouve-ops/projects/${SEED_SLUG}/frontend" \
    && npm install --no-audit --no-fund \
    && npm cache clean --force \
    && chmod 600 "/home/clouve-ops/projects/${SEED_SLUG}/backend/.env" \
    && chown -R clouve-ops:clouve-ops /home/clouve-ops

# Per-tenant persona pulled by the Magneto Agent at init over clouve-ops SSH
# (sidecar-fetcher.sh) and appended to its CLAUDE.md as "## Skill: ai-studio".
# The plugin-name subdir (context/ai-studio/) makes the persona
# self-identifying in the sidecar→agent merge — same pattern as Moodle.
COPY context/ /clouve/context/
RUN sed -i "s|@SLUG@|${SEED_SLUG}|g" /clouve/context/ai-studio/CONTEXT.md.tpl

# --- Persistent-volume bootstrap ------------------------------------------
# ai-studio persists /home /usr /opt /var so apt-installed packages and user
# files survive pod restarts. Docker auto-seeds a fresh *named volume* from the
# image, but a freshly-provisioned Kubernetes PVC mounts EMPTY over the path,
# masking the image's content there. On usr-merged Ubuntu 26.04 an empty /usr
# PVC hides bash, sshd AND this very entrypoint — the container then can't exec
# its ENTRYPOINT at all (RunContainerError). The working magneto-agent sibling
# avoids this by booting from /clouve (never a mounted volume); we do the same:
# a static busybox that needs nothing from /usr restores each empty volume from
# a snapshot baked here, then hands off to entrypoint.sh. The per-volume
# .clv-seeded marker means we seed exactly once and never clobber packages the
# agent installs later. See installer/init.sh.
#
# Snapshots are created with the same busybox that extracts them at runtime, so
# the archive format is guaranteed compatible. They are baked AFTER all image
# setup above — Node, MongoDB, supervisor confs and the npm-installed seed
# project included — so each captures the fully-provisioned directory.
#
# /var is special-cased: Kubernetes mounts the service-account token under
# /var/run/secrets/..., which pre-creates /var/run as a *directory* in the
# otherwise-empty PVC. The image ships /var/run as a symlink (-> /run), so a
# naive extract aborts with "tar: can't remove old file ./run: Is a directory"
# and seeding fails (set -e). /var/run is ephemeral (a symlink to tmpfs /run)
# and never needs persisting, so the /var snapshot is taken from a copy with
# the run symlink removed.
RUN mkdir -p /clouve/seed && cp /bin/busybox /clouve/busybox
COPY installer/init.sh /clouve/init.sh
COPY installer/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /clouve/init.sh /usr/local/bin/entrypoint.sh \
    && for d in usr opt home; do \
         touch "/$d/.clv-seeded"; \
         /clouve/busybox tar -cf - -C "/$d" . | /clouve/busybox gzip -9 > "/clouve/seed/$d.tar.gz"; \
       done \
    && touch /var/.clv-seeded \
    && cp -a /var /clouve/varseed \
    && rm -f /clouve/varseed/run \
    && /clouve/busybox tar -cf - -C /clouve/varseed . | /clouve/busybox gzip -9 > /clouve/seed/var.tar.gz \
    && rm -rf /clouve/varseed

# 22 sshd (agent-internal + raw-TCP SSH tunnel) · 4000 Express API ·
# 5173 Vite dev server · 8081 mongo-express. The HTTP ports are reached
# through clv-proxy at https://<port>-<workspace-id>.<base>/ — the workspace
# itself exposes no public :80 and runs no nginx.
EXPOSE 22 4000 5173 8081
# PID 1 chain: busybox init.sh seeds the volumes, exec's entrypoint.sh, which
# exec's supervisord — so supervisord ends up as PID 1 supervising sshd,
# mongod, backend, frontend and mongo-express. When supervisord exits, the
# container exits and Kubernetes restarts it.
ENTRYPOINT ["/clouve/busybox", "sh", "/clouve/init.sh"]
