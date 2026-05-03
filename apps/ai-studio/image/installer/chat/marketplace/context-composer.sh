#!/bin/bash
# Compose the rendered AI-client context file from:
#   1. The base template (always, even if .active is empty)
#   2. One '## Skill: <plugin>' section per plugin in .active, drawn from
#      $_CLV_SKILLS_DIR/<plugin>/CONTEXT.md.tpl
#   3. envsubst interpolation pass over the concatenated result
#
# Usage: _clv_compose_context <base_tpl> <active_file> <output_path>
#
# Returns 0 even when the base template is missing (writes whatever
# per-plugin content resolved). Per-plugin sections with no template are
# warned-and-skipped.

: "${_CLV_SKILLS_DIR:=/clouve/skills}"

_clv_compose_context() {
    local base_tpl="$1" active="$2" out="$3"
    local tmp
    tmp="$(mktemp)"

    if [ -f "$base_tpl" ]; then
        cat "$base_tpl" >> "$tmp"
    else
        echo "[context-composer] base template missing: $base_tpl" >&2
    fi

    if [ -r "$active" ]; then
        local plugin section_tpl
        while IFS= read -r plugin; do
            [ -z "$plugin" ] && continue
            section_tpl="$_CLV_SKILLS_DIR/$plugin/CONTEXT.md.tpl"
            if [ ! -f "$section_tpl" ]; then
                echo "[context-composer] $plugin: no CONTEXT.md.tpl — section omitted" >&2
                continue
            fi
            {
                printf '\n\n---\n\n## Skill: %s\n\n' "$plugin"
                cat "$section_tpl"
            } >> "$tmp"
        done < "$active"
    fi

    # envsubst over the whole composed file. USERNAME falls back to whoami
    # if the env doesn't carry it (preserves existing _clv_write_context
    # behavior).
    USERNAME="${USERNAME:-$(whoami)}" envsubst < "$tmp" > "$out"
    rm -f "$tmp"
    chmod 600 "$out"
    return 0
}
