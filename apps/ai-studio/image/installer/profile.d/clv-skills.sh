# Surface each activated skill into every supported AI client's
# ~/<client-home>/skills/<slug>/ directory.
#
# Reads /clouve/skills/.active (TSV: <slug>\t<Category>/<Name>) written
# at container init by chat/skills.sh. Idempotent: runs at every
# login, no-ops when state is already correct.
#
# Per-client home directories — keep this list aligned with
# CLV_CONTEXT_DIRS in chat/.bash_profile.
#
# Note on coverage: Claude Code natively auto-loads ~/.claude/skills/<name>/
# at startup. Gemini CLI and OpenAI Codex CLI don't (yet) have a built-in
# skills-directory convention, so for those clients the skill content is
# what reaches the agent via the rendered ~/.gemini/GEMINI.md and
# ~/.codex/AGENTS.md (the "## Skill: …" sections appended by
# _clv_write_context). Mirroring the symlinks here anyway gives the agent
# a stable per-client path to reference scripts/ and reference/ files
# from, and future-proofs the layout if those clients add native skill
# discovery later.
#
# /clouve/skills/ is rebuilt on every container start and is not on the
# persistent path list, but the client home dirs are on /home (persistent),
# so the symlinks here may outlive the targets across a restart that
# happens between login and the loader writing .active. The `[ -d ]`
# guard handles that race — broken symlinks are simply skipped this
# round and re-created on the next login after the loader has run.

[ -r /clouve/skills/.active ] || return 0
[ -n "$HOME" ] || return 0

for _clv_client_home in .claude .gemini .codex; do
    mkdir -p "$HOME/$_clv_client_home/skills" 2>/dev/null
    while IFS=$'\t' read -r slug _id; do
        [ -z "$slug" ] && continue
        src="/clouve/skills/$slug/skill"
        [ -d "$src" ] || continue
        ln -sfn "$src" "$HOME/$_clv_client_home/skills/$slug" 2>/dev/null
    done < /clouve/skills/.active
done

unset _clv_client_home slug _id src
