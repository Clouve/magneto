#!/bin/bash
# Parse a single AI_STUDIO_SKILLS entry into four output globals:
#   _clv_url_host             — e.g. "github.com"
#   _clv_url_clone            — clone URL (always ends in .git)
#   _clv_url_branch           — branch name (default "main")
#   _clv_url_plugins_filter   — comma-separated plugin names, or "" for all
#
# Returns 0 on success, non-zero on malformed input.
#
# Accepted shape: https://<host>/<path>(.git)?(?plugins=…)?(#branch)?
# Other transports (ssh, git://) are rejected — the loader is HTTPS-only.

_clv_parse_marketplace_url() {
    local raw="${1:-}"
    _clv_url_host=""
    _clv_url_clone=""
    _clv_url_branch="main"
    _clv_url_plugins_filter=""

    [ -z "$raw" ] && return 1

    # Must start with https://
    [[ "$raw" =~ ^https:// ]] || return 1

    # Strip the scheme so we can tease apart host/path/query/fragment.
    local rest="${raw#https://}"

    # Split off fragment (#branch). Bash parameter expansion is sufficient.
    local fragment=""
    if [[ "$rest" == *"#"* ]]; then
        fragment="${rest##*#}"
        rest="${rest%%#*}"
    fi

    # Split off query string (?plugins=…).
    local query=""
    if [[ "$rest" == *"?"* ]]; then
        query="${rest#*\?}"
        rest="${rest%%\?*}"
    fi

    # rest is now <host>/<path>. Host must contain at least one dot OR be a
    # valid hostname token; reject empty host (e.g. "https:///foo").
    local host="${rest%%/*}"
    local path="${rest#*/}"
    [ -z "$host" ] && return 1
    [ "$host" = "$rest" ] && return 1   # no slash -> no path component
    [ -z "$path" ] && return 1

    _clv_url_host="$host"

    # Normalise clone URL: strip trailing .git if present, then re-append.
    path="${path%.git}"
    _clv_url_clone="https://${host}/${path}.git"

    # Branch from fragment, default main.
    [ -n "$fragment" ] && _clv_url_branch="$fragment"

    # Plugin filter from ?plugins=…
    if [ -n "$query" ]; then
        # Iterate query params; only ?plugins= matters today.
        local pair key val
        while IFS='&' read -ra _q_pairs <<< "$query"; do
            for pair in "${_q_pairs[@]}"; do
                key="${pair%%=*}"
                val="${pair#*=}"
                [ "$key" = "plugins" ] && _clv_url_plugins_filter="$val"
            done
            break
        done
    fi

    return 0
}
