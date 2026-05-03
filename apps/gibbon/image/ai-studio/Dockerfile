# AI Studio image for the Gibbon app.
#
# Layers on top of the stock ai-studio image (built from apps/ai-studio/) and
# adds only the runtime binaries the Gibbon DevOps Skill shells out to. The
# skill payload itself — reference docs, playbooks, scripts — is delivered at
# container start by the upstream skill loader (chat/skills.sh), which clones
# the magneto-skills Claude Code marketplace named in AI_STUDIO_SKILLS
# (https://github.com/Clouve/magneto-skills.git?plugins=gibbon) and stages
# the gibbon plugin at /clouve/skills/gibbon/. The per-skill context section
# is loaded from context/gibbon/CONTEXT.md.tpl baked into the AI Studio
# image. See ../../clv-docker-compose.yml.

FROM r.clv.zone/e2eorg/ai-studio:latest

LABEL maintainer="Clouve Platform"
LABEL description="AI Studio with Gibbon DevOps runtime dependencies pre-installed"

# default-mysql-client (mysql, mysqldump) — the Gibbon DevOps Skill's playbooks
# and scripts (notably scripts/backup.sh and the diagnose / restore flows)
# shell out to these. The upstream ai-studio image is intentionally minimal,
# so we install them here.
#
# openssh-client + sshpass — the agent ssh's into the gibbon and gibbon-mysql
# containers as clouve-ops, authenticating with the per-pod password from
# CLOUVE_OPS_PASSWORD via `sshpass -e ssh …`.
#
# After installing, the /usr and /var seed tarballs the parent image bakes
# at /clouve/usr-seed.tar.gz and /clouve/var-seed.tar.gz are regenerated.
# init.sh extracts these onto the persistent /usr and /var volumes on a
# fresh deploy, so the new binaries (and the dpkg metadata that tracks
# them) only reach Kubernetes PVCs if the snapshots are refreshed here.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         default-mysql-client openssh-client sshpass \
    && rm -rf /var/lib/apt/lists/* \
    && tar czf /clouve/usr-seed.tar.gz -C / usr \
    && tar czf /clouve/var-seed.tar.gz -C / \
        --exclude=var/run --exclude=var/lock var
