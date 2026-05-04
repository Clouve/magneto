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
# Optional per-plugin install hook:
#   If the staged payload contains a top-level install.sh, the stager runs it
#   after staging on every container start. This is how a plugin declares the
#   runtime apt packages, binaries, or kernel-side state it needs (e.g. a
#   plugin whose scripts shell out to mysql/ssh installs those packages here
#   instead of bloating the base AI Studio image). Contract:
#     - The hook runs as root (the entrypoint is root) with no arguments.
#     - The hook MUST be idempotent — it is invoked on every container start
#       (not just the first), since /clouve/skills/ is rebuilt each time.
#     - Errors are logged but non-fatal: a hook failure does not abort plugin
#       activation or other plugins. The plugin is still considered staged.
#     - Hooks should rely on package state in /usr and /var (both persistent
#       volumes). /etc is rebuilt from the image layer each start; runtime
#       /etc edits made by a hook only persist if entrypoint.sh's /etc-overlay
#       SIGTERM trap fires on graceful shutdown.
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

    # Run the optional install hook. See the header comment for the contract.
    local install_hook="$dest/plugin/install.sh"
    if [ -f "$install_hook" ]; then
        chmod +x "$install_hook" 2>/dev/null || true
        echo "[plugin-stager] $name: running install.sh"
        if ! ( cd "$dest/plugin" && bash "$install_hook" ); then
            echo "[plugin-stager] $name: install.sh exited non-zero — continuing" >&2
        fi
    fi

    return 0
}
