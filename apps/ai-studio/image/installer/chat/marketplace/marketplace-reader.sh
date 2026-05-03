#!/bin/bash
# Read .claude-plugin/marketplace.json from a cloned marketplace and emit
# the active plugins as TSV on stdout: <name>\t<version>\t<description>\t<source>
#
# Usage: _clv_read_marketplace <clone_dir> <plugins_filter>
#   plugins_filter is a comma-separated list of plugin names, or "" for all.
#
# Order:
#   - filter empty -> marketplace.json plugin order
#   - filter set   -> filter order (so the user's ?plugins=... ordering controls
#                     composition order)
#
# Returns 0 on success (even if some filter entries match nothing -- those are
# warned and skipped). Returns non-zero only when the file is missing or
# unparseable.
#
# Portability: avoids bash 4 features (no `declare -A`) so it runs on macOS
# bash 3.2 in dev as well as Ubuntu 24.04 (bash 5.x) in production. Lookup
# is implemented with a newline-separated <name>\t<line> blob and grep.

_clv_read_marketplace() {
    local clone_dir="$1" filter="$2"
    local mf="$clone_dir/.claude-plugin/marketplace.json"
    [ -f "$mf" ] || { echo "[marketplace-reader] missing $mf" >&2; return 1; }

    # Validate JSON shape: must parse and have a .plugins array.
    if ! jq -e '.plugins // empty | type == "array"' "$mf" >/dev/null 2>&1; then
        echo "[marketplace-reader] $mf: malformed or missing .plugins[] array" >&2
        return 1
    fi

    # All plugins in marketplace order, as TSV.
    local all_tsv
    all_tsv=$(jq -r '.plugins[] | [.name, (.version // ""), (.description // ""), .source] | @tsv' "$mf") || return 1

    if [ -z "$filter" ]; then
        printf '%s\n' "$all_tsv"
        return 0
    fi

    # Apply filter, preserving filter order. Iterate the comma-separated list
    # and look up each name in the all-plugins blob via grep on a tab-anchored
    # prefix (so "gibbon" doesn't accidentally match "gibbon-extra").
    local IFS=','
    local req
    for req in $filter; do
        [ -z "$req" ] && continue
        local match
        # grep a line that starts with "<req><TAB>"; -m1 stops at first hit.
        match=$(printf '%s\n' "$all_tsv" | grep -m1 "^${req}"$'\t' || true)
        if [ -n "$match" ]; then
            printf '%s\n' "$match"
        else
            echo "[marketplace-reader] plugin '$req' not in marketplace.json -- skipped" >&2
        fi
    done
    return 0
}
