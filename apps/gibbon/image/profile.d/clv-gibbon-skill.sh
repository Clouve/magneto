# Symlink the Gibbon DevOps Skill into the user's Claude Code skill search path.
#
# The skill folder is mounted read-only at /clouve/skills/gibbon-devops/ at pod
# start. Claude Code only discovers user-scoped skills under ~/.claude/skills/,
# and $HOME is dynamic per tenant (derived from AI_STUDIO_USERNAME), so we
# bridge the static mount point and the dynamic home with a symlink created on
# the first login of each shell session.
#
# Sourced by AI Studio's /etc/profile.d/ mechanism (see chat/install.sh:60),
# which loads every *.sh drop-in at login. Mounted as a single-file bind from
# apps/gibbon/image/profile.d/clv-gibbon-skill.sh → /etc/profile.d/clv-gibbon-skill.sh.
#
# Idempotent: re-runs on every terminal open with no side effects if the link
# is already correct. Uses `ln -sfn` so a stale symlink from a previous skill
# version is transparently replaced.

if [ -d /clouve/skills/gibbon-devops ] && [ -n "$HOME" ]; then
    mkdir -p "$HOME/.claude/skills" 2>/dev/null
    ln -sfn /clouve/skills/gibbon-devops "$HOME/.claude/skills/gibbon-devops" 2>/dev/null
fi

# clouve-ops SSH access is password-based: CLOUVE_OPS_PASSWORD is set
# identically on all three services and is already in the agent's
# environment, so the agent invokes `sshpass -e ssh clouve-ops@…`
# directly. Nothing to materialise in $HOME — see CLAUDE.md.tpl.
