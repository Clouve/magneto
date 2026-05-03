#!/bin/bash
# ============================================================================
# Skill loader entry point — sourced from chat/install.sh at container init.
# ============================================================================
# This is a thin shim over the modular marketplace loader. The real logic
# lives in marketplace/ — see loader.sh for the orchestrator and the other
# *.sh files for individual stages.
#
# Output contract (consumed by .bash_profile and profile.d/clv-skills.sh):
#   /clouve/skills/CONTEXT.md.tpl          — base context (always)
#   /clouve/skills/<plugin>/plugin/         — plugin payload (per active plugin)
#   /clouve/skills/<plugin>/CONTEXT.md.tpl  — section template (if context/<plugin>/ exists)
#   /clouve/skills/.active                  — newline-separated active plugin names
#
# Driven by AI_STUDIO_SKILLS — see ../README.md and the AI Skills section
# for the format.
# ============================================================================

_CLV_MOD_DIR="/clouve/ai-studio/installer/chat/marketplace"

# shellcheck source=/dev/null
. "$_CLV_MOD_DIR/url-parser.sh"
. "$_CLV_MOD_DIR/credentials.sh"
. "$_CLV_MOD_DIR/git-fetcher.sh"
. "$_CLV_MOD_DIR/marketplace-reader.sh"
. "$_CLV_MOD_DIR/plugin-stager.sh"
. "$_CLV_MOD_DIR/loader.sh"

# git is required for the marketplace pipeline; the dev-tools install in
# install.sh runs before us so it should be present, but on a brand-new
# container that hasn't run install.sh yet (shouldn't happen in practice)
# we degrade gracefully.
if ! command -v git >/dev/null 2>&1; then
    echo -e "${YELLOW:-}[skills]${NC:-} git not installed — marketplace loader cannot run." >&2
    mkdir -p /clouve/skills
    : > /clouve/skills/.active
    return 0 2>/dev/null || exit 0
fi

_clv_load_marketplaces

unset _CLV_MOD_DIR
