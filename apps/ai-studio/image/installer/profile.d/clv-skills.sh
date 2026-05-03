# Surface every skill from every active plugin into each AI client's
# ~/<client-home>/skills/<skill-name>/ directory.
#
# The marketplace loader (chat/skills.sh) writes /clouve/skills/.active —
# one plugin name per line. Each plugin's payload lives at
# /clouve/skills/<plugin>/plugin/, and Claude Code-style plugins typically
# expose their SKILL.md trees under plugin/skills/<skill-name>/SKILL.md.
#
# This helper symlinks each <skill-name> dir into the per-client
# ~/.{claude,gemini,codex}/skills/ tree. A plugin with no skills/ subdir
# is silently skipped — it may still contribute commands, agents, or
# context-only content via the appended '## Skill: <plugin>' section.
#
# Per-client home directories — keep this list aligned with
# CLV_CONTEXT_DIRS in chat/.bash_profile.
#
# Idempotent: runs at every login, no-ops when state is already correct.
# Broken symlinks (e.g. after a container restart that wiped /clouve/skills/
# but reused the persistent /home volume) are harmless and re-created on
# the next login after the loader has run.

[ -r /clouve/skills/.active ] || return 0
[ -n "$HOME" ] || return 0

for _clv_client_home in .claude .gemini .codex; do
    mkdir -p "$HOME/$_clv_client_home/skills" 2>/dev/null
    while IFS= read -r _clv_plugin; do
        [ -z "$_clv_plugin" ] && continue
        _clv_plugin_skills_dir="/clouve/skills/$_clv_plugin/plugin/skills"
        [ -d "$_clv_plugin_skills_dir" ] || continue
        for _clv_skill_path in "$_clv_plugin_skills_dir"/*/; do
            [ -d "$_clv_skill_path" ] || continue
            _clv_skill_name="$(basename "$_clv_skill_path")"
            ln -sfn "${_clv_skill_path%/}" "$HOME/$_clv_client_home/skills/$_clv_skill_name" 2>/dev/null
        done
    done < /clouve/skills/.active
done

unset _clv_client_home _clv_plugin _clv_plugin_skills_dir _clv_skill_path _clv_skill_name
