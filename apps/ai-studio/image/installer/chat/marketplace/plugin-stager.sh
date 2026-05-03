#!/bin/bash
# Stage one plugin into /clouve/skills/<plugin-name>/.
#
# Usage: _clv_stage_plugin <plugin_name> <source> <marketplace_clone_dir>
# Where:
#   source = relative path inside the marketplace (./plugins/foo or plugins/foo)
#          | absolute https:// URL pointing at a repo containing the plugin tree
#
# Layout produced:
#   $_CLV_SKILLS_DIR/<plugin-name>/plugin/         — full plugin payload
#   $_CLV_SKILLS_DIR/<plugin-name>/CONTEXT.md.tpl  — copied from local context/, if present
#
# Requires: git-fetcher.sh and url-parser.sh sourced.
# Env vars (caller-overridable for tests):
#   _CLV_SKILLS_DIR  — default /clouve/skills
#   _CLV_CONTEXT_DIR — default /clouve/context

: "${_CLV_SKILLS_DIR:=/clouve/skills}"
: "${_CLV_CONTEXT_DIR:=/clouve/context}"

_clv_stage_plugin() {
    local name="$1" src_spec="$2" mp_clone="$3"
    local plugin_src=""

    if [[ "$src_spec" == https://* ]]; then
        # External git source — recursively clone.
        if ! _clv_parse_marketplace_url "$src_spec"; then
            echo "[plugin-stager] $name: invalid external source URL: $src_spec" >&2
            return 1
        fi
        if ! plugin_src="$(_clv_git_fetch "$_clv_url_host" "$_clv_url_clone" "$_clv_url_branch")"; then
            echo "[plugin-stager] $name: failed to clone external source $src_spec" >&2
            return 1
        fi
    else
        # Repo-relative path. Reject escape attempts.
        local rel="${src_spec#./}"
        case "$rel" in
            /*|*..*) echo "[plugin-stager] $name: rejected source path '$src_spec'" >&2; return 1 ;;
        esac
        plugin_src="$mp_clone/$rel"
        if [ ! -d "$plugin_src" ]; then
            echo "[plugin-stager] $name: source path does not exist: $plugin_src" >&2
            return 1
        fi
    fi

    local dest="$_CLV_SKILLS_DIR/$name"
    rm -rf "$dest"
    mkdir -p "$dest/plugin"
    cp -R "$plugin_src/." "$dest/plugin/"
    chmod -R a+rwX "$dest/plugin" 2>/dev/null || true

    # Copy the local persona section if present.
    local context_src="$_CLV_CONTEXT_DIR/$name/CONTEXT.md.tpl"
    if [ -f "$context_src" ]; then
        cp "$context_src" "$dest/CONTEXT.md.tpl"
        chmod a+r "$dest/CONTEXT.md.tpl"
    else
        echo "[plugin-stager] $name: no context/$name/CONTEXT.md.tpl — context section will be omitted" >&2
    fi

    return 0
}
