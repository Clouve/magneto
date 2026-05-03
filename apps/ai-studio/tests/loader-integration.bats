#!/usr/bin/env bats
load helpers/common
setup() {
    _test_setup
    _stub_git
    export _CLV_SKILLS_DIR="$TEST_TMPDIR/skills"
    export _CLV_CONTEXT_DIR="$TEST_TMPDIR/context"
    export _CLV_FETCH_ROOT="$TEST_TMPDIR/fetch"
    mkdir -p "$_CLV_SKILLS_DIR" "$_CLV_CONTEXT_DIR"
    # Source all modules in dependency order.
    source "$MOD_DIR/url-parser.sh"
    source "$MOD_DIR/credentials.sh"
    source "$MOD_DIR/git-fetcher.sh"
    source "$MOD_DIR/marketplace-reader.sh"
    source "$MOD_DIR/plugin-stager.sh"
    source "$MOD_DIR/context-composer.sh"
    source "$MOD_DIR/loader.sh"
    # Base template the loader copies into the skills dir.
    echo "BASE TEMPLATE" > "$_CLV_CONTEXT_DIR/CONTEXT.md.tpl"
}
teardown() { _test_teardown; }

# Helper: queue a successful clone that materialises a marketplace.json
# with the given plugin definitions inside the clone dir.
# Note: the action must be a single line (the stub-git script is TSV — one
# response per line), so we write the JSON via a quoted printf rather than
# a heredoc.
_queue_clone_with_plugins() {
    local mf_json="$1"
    local plugin_dirs="$2"  # space-separated relative paths
    # Escape single quotes in the JSON for safe wrapping in single-quoted printf arg.
    local mf_escaped="${mf_json//\'/\'\\\'\'}"
    local action="mkdir -p \"\$clone_dir/.claude-plugin\"; printf '%s' '$mf_escaped' > \"\$clone_dir/.claude-plugin/marketplace.json\"; "
    # Create each plugin source dir inside the clone.
    local dir
    for dir in $plugin_dirs; do
        action+="mkdir -p \"\$clone_dir/$dir/.claude-plugin\"; "
        action+="echo '{\"name\":\"x\"}' > \"\$clone_dir/$dir/.claude-plugin/plugin.json\"; "
    done
    _stub_git_response "clone" 0 "$action"
}

@test "AI_STUDIO_SKILLS unset: base context staged, no plugins" {
    unset AI_STUDIO_SKILLS
    _clv_load_marketplaces
    [ -f "$_CLV_SKILLS_DIR/CONTEXT.md.tpl" ]
    grep -q "BASE TEMPLATE" "$_CLV_SKILLS_DIR/CONTEXT.md.tpl"
    [ ! -s "$_CLV_SKILLS_DIR/.active" ] || [ "$(wc -l < "$_CLV_SKILLS_DIR/.active")" -eq 0 ]
}

@test "single marketplace, no filter: stages all plugins from marketplace.json" {
    _queue_clone_with_plugins '{"plugins":[{"name":"gibbon","source":"./g"},{"name":"moodle","source":"./m"}]}' "g m"
    AI_STUDIO_SKILLS="https://github.com/Clouve/magneto-skills.git" _clv_load_marketplaces
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
    [ -d "$_CLV_SKILLS_DIR/moodle/plugin" ]
    [ "$(wc -l < "$_CLV_SKILLS_DIR/.active")" -eq 2 ]
}

@test "single marketplace with ?plugins= filter: only filtered plugins staged" {
    _queue_clone_with_plugins '{"plugins":[{"name":"gibbon","source":"./g"},{"name":"moodle","source":"./m"},{"name":"extra","source":"./e"}]}' "g m e"
    AI_STUDIO_SKILLS="https://github.com/Clouve/magneto-skills.git?plugins=gibbon,moodle" _clv_load_marketplaces
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
    [ -d "$_CLV_SKILLS_DIR/moodle/plugin" ]
    [ ! -d "$_CLV_SKILLS_DIR/extra" ]
}

@test "duplicate plugin name across two marketplaces: first wins, second logged as duplicate" {
    # First marketplace defines gibbon; second one also defines gibbon.
    _stub_git_response "magneto-skills" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin"; echo '"'"'{"plugins":[{"name":"gibbon","source":"./g"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; echo "from-magneto" > "$clone_dir/g/marker"; echo "{}" > "$clone_dir/g/.claude-plugin/plugin.json"'
    _stub_git_response "partner-skills" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin"; echo '"'"'{"plugins":[{"name":"gibbon","source":"./g"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; echo "from-partner" > "$clone_dir/g/marker"; echo "{}" > "$clone_dir/g/.claude-plugin/plugin.json"'
    AI_STUDIO_SKILLS="https://github.com/Clouve/magneto-skills.git,https://github.com/Partner/partner-skills.git" \
        run _clv_load_marketplaces
    [ "$status" -eq 0 ]
    grep -q "from-magneto" "$_CLV_SKILLS_DIR/gibbon/plugin/marker"
    [[ "$output" == *"duplicate"* ]] || [[ "$output" == *"already loaded"* ]]
}

@test "first-wins dedup also applies to context composition" {
    # Both marketplaces define gibbon. The local context/gibbon/CONTEXT.md.tpl
    # is shared — only one '## Skill: gibbon' section should appear.
    mkdir -p "$_CLV_CONTEXT_DIR/gibbon"
    echo "Gibbon persona" > "$_CLV_CONTEXT_DIR/gibbon/CONTEXT.md.tpl"
    _stub_git_response "clone" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin"; echo '"'"'{"plugins":[{"name":"gibbon","source":"./g"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; echo "{}" > "$clone_dir/g/.claude-plugin/plugin.json"'
    AI_STUDIO_SKILLS="https://github.com/A/a.git,https://github.com/B/b.git" _clv_load_marketplaces
    # Only one line in .active for gibbon
    [ "$(grep -c '^gibbon$' "$_CLV_SKILLS_DIR/.active")" -eq 1 ]
}

@test "invalid URL entry skipped, valid entries still loaded" {
    _stub_git_response "clone" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin"; echo '"'"'{"plugins":[{"name":"gibbon","source":"./g"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; echo "{}" > "$clone_dir/g/.claude-plugin/plugin.json"'
    AI_STUDIO_SKILLS="not-a-url,https://github.com/Clouve/magneto-skills.git" run _clv_load_marketplaces
    [ "$status" -eq 0 ]
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
    [[ "$output" == *"not-a-url"* ]]
}

@test "clone failure on one marketplace: error logged, others continue" {
    _stub_git_response "broken" 128 ""
    _stub_git_response "clone" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin"; echo '"'"'{"plugins":[{"name":"gibbon","source":"./g"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; echo "{}" > "$clone_dir/g/.claude-plugin/plugin.json"'
    AI_STUDIO_SKILLS="https://github.com/x/broken.git,https://github.com/x/working.git" run _clv_load_marketplaces
    [ "$status" -eq 0 ]
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
}

@test "summary line logs n plugins from m marketplaces" {
    _queue_clone_with_plugins '{"plugins":[{"name":"gibbon","source":"./g"}]}' "g"
    AI_STUDIO_SKILLS="https://github.com/Clouve/magneto-skills.git" run _clv_load_marketplaces
    [[ "$output" == *"1 plugins loaded from 1 marketplaces"* ]]
}

@test "deduplicated plugin count is reflected in summary" {
    _stub_git_response "clone" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin"; echo '"'"'{"plugins":[{"name":"gibbon","source":"./g"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; echo "{}" > "$clone_dir/g/.claude-plugin/plugin.json"'
    AI_STUDIO_SKILLS="https://github.com/A/a.git,https://github.com/B/b.git" run _clv_load_marketplaces
    [[ "$output" == *"1 plugins loaded from 2 marketplaces"* ]]
    [[ "$output" == *"skipped"* ]]
}

@test "multi-marketplace with ?plugins= on first URL: both marketplaces processed" {
    _stub_git_response "magneto" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin"; printf %s '"'"'{"plugins":[{"name":"gibbon","source":"./g"},{"name":"moodle","source":"./m"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; printf %s "{}" > "$clone_dir/g/.claude-plugin/plugin.json"; mkdir -p "$clone_dir/m/.claude-plugin"; printf %s "{}" > "$clone_dir/m/.claude-plugin/plugin.json"'
    _stub_git_response "partner" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/h/.claude-plugin"; printf %s '"'"'{"plugins":[{"name":"helpdesk","source":"./h"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; printf %s "{}" > "$clone_dir/h/.claude-plugin/plugin.json"'
    AI_STUDIO_SKILLS="https://github.com/Clouve/magneto-skills.git?plugins=gibbon,https://gitlab.com/somepartner/their-skills.git?plugins=helpdesk" run _clv_load_marketplaces
    [ "$status" -eq 0 ]
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
    [ -d "$_CLV_SKILLS_DIR/helpdesk/plugin" ]
    [ ! -d "$_CLV_SKILLS_DIR/moodle" ]
    [[ "$output" == *"2 plugins loaded from 2 marketplaces"* ]]
}

@test "multi-marketplace with ?plugins= on both URLs: both marketplaces processed independently" {
    _stub_git_response "magneto" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin" "$clone_dir/m/.claude-plugin"; printf %s '"'"'{"plugins":[{"name":"gibbon","source":"./g"},{"name":"moodle","source":"./m"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; printf %s "{}" > "$clone_dir/g/.claude-plugin/plugin.json"; printf %s "{}" > "$clone_dir/m/.claude-plugin/plugin.json"'
    _stub_git_response "partner" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/h/.claude-plugin"; printf %s '"'"'{"plugins":[{"name":"helpdesk","source":"./h"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; printf %s "{}" > "$clone_dir/h/.claude-plugin/plugin.json"'
    AI_STUDIO_SKILLS="https://github.com/Clouve/magneto-skills.git?plugins=gibbon,moodle,https://gitlab.com/somepartner/their-skills.git?plugins=helpdesk" _clv_load_marketplaces
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
    [ -d "$_CLV_SKILLS_DIR/moodle/plugin" ]
    [ -d "$_CLV_SKILLS_DIR/helpdesk/plugin" ]
}

@test "comma inside ?plugins= filter is preserved" {
    # Verifies that ?plugins=a,b,c stays as a single filter, not three entries.
    _stub_git_response "clone" 0 'mkdir -p "$clone_dir/.claude-plugin" "$clone_dir/g/.claude-plugin" "$clone_dir/m/.claude-plugin"; printf %s '"'"'{"plugins":[{"name":"gibbon","source":"./g"},{"name":"moodle","source":"./m"},{"name":"extra","source":"./e"}]}'"'"' > "$clone_dir/.claude-plugin/marketplace.json"; mkdir -p "$clone_dir/e/.claude-plugin"; printf %s "{}" > "$clone_dir/g/.claude-plugin/plugin.json"; printf %s "{}" > "$clone_dir/m/.claude-plugin/plugin.json"; printf %s "{}" > "$clone_dir/e/.claude-plugin/plugin.json"'
    AI_STUDIO_SKILLS="https://github.com/Clouve/magneto-skills.git?plugins=gibbon,moodle" run _clv_load_marketplaces
    [ "$status" -eq 0 ]
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
    [ -d "$_CLV_SKILLS_DIR/moodle/plugin" ]
    [ ! -d "$_CLV_SKILLS_DIR/extra" ]
    [[ "$output" == *"1 plugins loaded from 1 marketplaces"* ]] || [[ "$output" == *"2 plugins loaded from 1 marketplaces"* ]]
}
