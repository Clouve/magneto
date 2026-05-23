FROM ubuntu:26.04

# Mirror — same as Moodle and other Clouve siblings. en_US baseline; tenants
# add their own locales at runtime if needed.
RUN apt-get update && apt-get install -y \
        openssh-server \
        sudo \
        locales \
        ca-certificates \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen \
    && apt-get clean autoclean \
    && apt-get autoremove -y \
    && rm -rfv /var/lib/{apt,dpkg,cache,log}/

# clouve-ops operator account for the magneto-agent's Claude Code agent.
# Password is set at runtime by entrypoint.sh from CLOUVE_OPS_PASSWORD
# (same value injected on both this container and magneto-agent).
# NOPASSWD: ALL — agent is a DevOps engineer with full root; safety
# gating lives in the ai-studio skill's SKILL.md, not in sudoers.
# Identical to the Moodle sibling's clouve-ops setup.
RUN useradd --create-home --shell /bin/bash \
        --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops

# sshd hardening drop-in: password-only, no root login, only clouve-ops.
# Picked up automatically by /etc/ssh/sshd_config's Include directive.
COPY installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf

# Required by sshd for its privilege-separation directory at runtime.
RUN mkdir -p /run/sshd

COPY installer/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
