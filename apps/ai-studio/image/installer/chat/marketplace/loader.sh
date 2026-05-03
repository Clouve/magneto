#!/bin/bash
# Top-level orchestrator. Drives the marketplace -> plugin pipeline:
#
#   1. Wipe and recreate $_CLV_SKILLS_DIR.
#   2. Wipe $_CLV_FETCH_ROOT (so cached clones from a previous container
#      start are refreshed -- matches the original chat/skills.sh behavior).
#   3. Stage the base CONTEXT.md.tpl from $_CLV_CONTEXT_DIR.
#   4. For each entry in AI_STUDIO_SKILLS (comma-separated):
#        a. Parse URL -> host, clone URL, branch, plugin filter
#        b. Fetch (or reuse) the marketplace clone
#        c. Read marketplace.json; apply plugin filter
#        d. For each selected plugin (first-wins dedup across marketplaces):
#             - Stage payload + per-plugin CONTEXT.md.tpl
#             - Append plugin name to .active
#   5. Log a summary line.
#
# Output state (consumer-visible):
#   $_CLV_SKILLS_DIR/CONTEXT.md.tpl       -- base (always staged)
#   $_CLV_SKILLS_DIR/<plugin>/plugin/      -- payload (per active plugin)
#   $_CLV_SKILLS_DIR/<plugin>/CONTEXT.md.tpl -- section template (if context/<plugin>/ exists)
#   $_CLV_SKILLS_DIR/.active               -- newline-separated active plugin names
#
# All errors are logged and skipped -- never fatal.
#
# Portability: avoids bash 4 features (no `declare -A`) so the orchestrator
# runs on macOS bash 3.2 in dev as well as Ubuntu 24.04 (bash 5.x) in
# production. The "seen plugins" set is tracked as a newline-delimited string
# blob with sentinel newlines on both ends so membership tests are unambiguous.
# A parallel blob records the source URL of each first-seen plugin so the
# duplicate warning can name the original marketplace.

: "${_CLV_SKILLS_DIR:=/clouve/skills}"
: "${_CLV_CONTEXT_DIR:=/clouve/context}"
: "${_CLV_FETCH_ROOT:=/var/lib/clouve/marketplace-fetch}"

_clv_log()  { echo -e "${GREEN:-}[skills]${NC:-} $*"; }
_clv_warn() { echo -e "${YELLOW:-}[skills]${NC:-} $*" >&2; }
_clv_err()  { echo -e "${RED:-}[skills]${NC:-} $*" >&2; }

_clv_load_marketplaces() {
    rm -rf "$_CLV_SKILLS_DIR"
    mkdir -p "$_CLV_SKILLS_DIR"

    # Wipe the fetch cache so a previous container start's clones don't
    # mask new commits on the marketplace branches.
    rm -rf "$_CLV_FETCH_ROOT"

    # Stage the base template (always).
    if [ -f "$_CLV_CONTEXT_DIR/CONTEXT.md.tpl" ]; then
        cp "$_CLV_CONTEXT_DIR/CONTEXT.md.tpl" "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
        chmod a+r "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    else
        _clv_err "base context $_CLV_CONTEXT_DIR/CONTEXT.md.tpl not found -- composer will warn at render time"
    fi

    : > "$_CLV_SKILLS_DIR/.active"

    if [ -z "${AI_STUDIO_SKILLS:-}" ]; then
        _clv_log "AI_STUDIO_SKILLS unset -- base context only, no plugins."
        return 0
    fi

    local total_loaded=0 total_skipped=0 total_marketplaces=0
    # Bash 3.2-portable "set" for first-wins dedup.
    # seen_plugins:  $'\nname1\nname2\n...'  -- membership via *$'\n'name$'\n'*
    # seen_sources:  $'\nname<TAB>url\nname<TAB>url\n...' -- looked up via grep
    local seen_plugins=$'\n'
    local seen_sources=$'\n'

    # Split AI_STUDIO_SKILLS on top-level commas only. Commas inside the
    # query string of a URL (e.g. ?plugins=a,b) must be preserved -- a naive
    # IFS=',' split would shred them. Strategy: walk the string and replace
    # top-level commas (those outside a `?...` query) with newlines, which
    # never appear in URLs. Then split the resulting blob on newlines.
    local _i _ch _in_query=0 _entries=""
    for (( _i=0; _i<${#AI_STUDIO_SKILLS}; _i++ )); do
        _ch="${AI_STUDIO_SKILLS:$_i:1}"
        case "$_ch" in
            '?')      _in_query=1; _entries+="$_ch" ;;
            ',')      if [ "$_in_query" -eq 1 ]; then _entries+="$_ch"; else _entries+=$'\n'; _in_query=0; fi ;;
            $'\n')    _entries+=$'\n'; _in_query=0 ;;
            *)        _entries+="$_ch" ;;
        esac
    done

    local IFS=$'\n'
    local entry
    for entry in $_entries; do
        # Trim whitespace.
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [ -z "$entry" ] && continue

        total_marketplaces=$((total_marketplaces + 1))

        if ! _clv_parse_marketplace_url "$entry"; then
            _clv_err "invalid marketplace URL: '$entry' -- skipped"
            total_skipped=$((total_skipped + 1))
            continue
        fi

        local mp_clone
        if ! mp_clone="$(_clv_git_fetch "$_clv_url_host" "$_clv_url_clone" "$_clv_url_branch")"; then
            _clv_err "failed to clone $_clv_url_clone@$_clv_url_branch -- skipped"
            total_skipped=$((total_skipped + 1))
            continue
        fi

        local plugins_tsv
        if ! plugins_tsv="$(_clv_read_marketplace "$mp_clone" "$_clv_url_plugins_filter")"; then
            _clv_err "failed to read marketplace.json from $_clv_url_clone -- skipped"
            total_skipped=$((total_skipped + 1))
            continue
        fi

        local line name version description source orig_src rest
        # NB: `read` with IFS=$'\t' collapses consecutive tabs (because tab
        # is bash whitespace), which would shift fields rightward when the
        # marketplace.json omits version/description. Parse with parameter
        # expansion to preserve empty fields.
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            name="${line%%$'\t'*}"; rest="${line#*$'\t'}"
            version="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
            description="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
            source="$rest"
            [ -z "$name" ] && continue
            if [[ "$seen_plugins" == *$'\n'"$name"$'\n'* ]]; then
                # Look up the original source URL for the warning.
                orig_src="$(printf '%s' "$seen_sources" | grep -m1 $'^'"$name"$'\t' | cut -f2-)"
                _clv_warn "duplicate plugin '$name' -- already loaded from ${orig_src:-unknown}, skipping"
                total_skipped=$((total_skipped + 1))
                continue
            fi
            if _clv_stage_plugin "$name" "$source" "$mp_clone"; then
                printf '%s\n' "$name" >> "$_CLV_SKILLS_DIR/.active"
                seen_plugins+="$name"$'\n'
                seen_sources+="$name"$'\t'"$_clv_url_clone"$'\n'
                _clv_log "loaded $name (version=${version:-?}) from $_clv_url_clone"
                total_loaded=$((total_loaded + 1))
            else
                total_skipped=$((total_skipped + 1))
            fi
        done <<< "$plugins_tsv"
    done

    # Count composed sections for the summary (plugins with a per-plugin tpl).
    local composed=0
    if [ -r "$_CLV_SKILLS_DIR/.active" ]; then
        local p
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            [ -f "$_CLV_SKILLS_DIR/$p/CONTEXT.md.tpl" ] && composed=$((composed + 1))
        done < "$_CLV_SKILLS_DIR/.active"
    fi

    _clv_log "$total_loaded plugins loaded from $total_marketplaces marketplaces, $total_skipped skipped; $composed context sections composed"
    return 0
}
