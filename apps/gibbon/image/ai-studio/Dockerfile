# AI Studio image pre-bundled for the Gibbon app.
#
# Layers on top of the stock ai-studio image (built from apps/ai-studio/) and
# bakes in the three Gibbon-specific assets that used to be side-loaded via
# read-only volume mounts:
#   1. the Gibbon DevOps Skill tree           → /clouve/skills/gibbon-devops/
#   2. the login-time symlink drop-in         → /etc/profile.d/clv-gibbon-skill.sh
#   3. the Gibbon-flavoured Claude Code tpl   → /clouve/ai-studio/installer/chat/claude/CLAUDE.md.tpl
#
# Build context is the apps/gibbon/ root (see AI_STUDIO_CONTEXT in
# image/build.config), so the COPY paths below resolve against the app dir
# rather than this subdirectory. apps/ai-studio/ is the upstream parent
# image — built first via `./build.sh apps/ai-studio` — and is unmodified;
# this Dockerfile is the only place where Gibbon-specific assets land in
# the AI Studio image.

FROM r.clv.zone/e2eorg/ai-studio:latest

LABEL maintainer="Clouve Platform"
LABEL description="AI Studio with the Gibbon DevOps Skill pre-bundled and a Gibbon-flavoured CLAUDE.md"

# MySQL client (mysql, mysqldump) — the Gibbon DevOps Skill's playbooks and
# scripts (notably scripts/backup.sh and the diagnose / restore flows) shell
# out to these. The upstream ai-studio image is intentionally minimal, so we
# install them in this derived layer.
#
# openssh-client + sshpass — the agent ssh's into the gibbon and
# gibbon-mysql containers as clouve-ops, authenticating with the per-pod
# password from CLOUVE_OPS_PASSWORD via `sshpass -e ssh …`.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends default-mysql-client openssh-client sshpass \
    && rm -rf /var/lib/apt/lists/*

# Skill tree — discovered by Claude Code via the /etc/profile.d/ symlink below.
COPY skill/ /clouve/skills/gibbon-devops/

# Login-time symlink that bridges the static skill mount into the dynamic
# per-tenant $HOME/.claude/skills/. Sourced by AI Studio's existing
# /etc/profile.d/ mechanism on every interactive shell.
COPY image/profile.d/clv-gibbon-skill.sh /etc/profile.d/clv-gibbon-skill.sh

# Gibbon-flavoured Claude Code system prompt — overwrites the generic
# AI Studio template that the upstream image ships at this path. Rendered
# into ~/.claude/CLAUDE.md by AI Studio's existing .bash_profile flow at
# session start. .bash_profile invokes envsubst with no SHELL-FORMAT
# whitelist, so every ${VAR} reference in this template — including our
# ${GIBBON_HOST}, ${GIBBON_DB_HOST}, ${GIBBON_DB_NAME}, ${GIBBON_DB_USER},
# ${GIBBON_DB_PASSWORD} — is substituted from the container env without
# any per-app shim.
COPY image/ai-studio/CLAUDE.md.tpl /clouve/ai-studio/installer/chat/claude/CLAUDE.md.tpl

# No ENTRYPOINT override and no per-app env-propagation shim. The upstream
# chat/install.sh snapshots the entire entrypoint env into
# /etc/profile.d/clouve-env.sh (denylist-based, not allowlist), so any
# vars docker-compose / Kubernetes set on this service — including
# GIBBON_HOST, GIBBON_DB_*, CLOUVE_OPS_PASSWORD — automatically survive
# the `su -` that ttyd's clv-session wrapper runs for each user shell,
# and envsubst over CLAUDE.md.tpl picks them up at login time without
# any gibbon-side wiring.
