#!/usr/bin/env bats
load helpers/common
setup() {
    _test_setup
    _stub_git
    source "$MOD_DIR/credentials.sh"
    source "$MOD_DIR/git-fetcher.sh"
    source "$MOD_DIR/url-parser.sh"
    source "$MOD_DIR/plugin-stager.sh"
    export _CLV_FETCH_ROOT="$TEST_TMPDIR/fetch"
    export _CLV_SKILLS_DIR="$TEST_TMPDIR/skills"
    export _CLV_CONTEXT_DIR="$TEST_TMPDIR/context"
    mkdir -p "$_CLV_SKILLS_DIR" "$_CLV_CONTEXT_DIR"
}
teardown() { _test_teardown; }

_make_plugin_in_marketplace() {
    # $1=clone dir, $2=plugin source path (relative)
    mkdir -p "$1/$2/.claude-plugin"
    echo '{"name":"gibbon"}' > "$1/$2/.claude-plugin/plugin.json"
    mkdir -p "$1/$2/skills/gibbon-devops"
    echo "# Gibbon DevOps SKILL" > "$1/$2/skills/gibbon-devops/SKILL.md"
}

@test "relative source: copies plugin tree into /clouve/skills/<plugin>/plugin/" {
    mkdir -p "$TEST_TMPDIR/clone"
    _make_plugin_in_marketplace "$TEST_TMPDIR/clone" "plugins/gibbon"
    run _clv_stage_plugin "gibbon" "./plugins/gibbon" "$TEST_TMPDIR/clone"
    [ "$status" -eq 0 ]
    [ -f "$_CLV_SKILLS_DIR/gibbon/plugin/.claude-plugin/plugin.json" ]
    [ -f "$_CLV_SKILLS_DIR/gibbon/plugin/skills/gibbon-devops/SKILL.md" ]
}

@test "relative source without leading ./ also works" {
    mkdir -p "$TEST_TMPDIR/clone"
    _make_plugin_in_marketplace "$TEST_TMPDIR/clone" "plugins/gibbon"
    run _clv_stage_plugin "gibbon" "plugins/gibbon" "$TEST_TMPDIR/clone"
    [ "$status" -eq 0 ]
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
}

@test "missing relative source: logs and returns non-zero, no skills dir created" {
    mkdir -p "$TEST_TMPDIR/clone"
    run _clv_stage_plugin "gibbon" "./plugins/gibbon" "$TEST_TMPDIR/clone"
    [ "$status" -ne 0 ]
    [ ! -d "$_CLV_SKILLS_DIR/gibbon" ]
}

@test "external HTTPS source: recursively clones and stages" {
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir/.claude-plugin && echo '{\"name\":\"gibbon\"}' > \$clone_dir/.claude-plugin/plugin.json"
    run _clv_stage_plugin "gibbon" "https://github.com/Clouve/external-gibbon-plugin.git" "$TEST_TMPDIR/clone"
    [ "$status" -eq 0 ]
    [ -f "$_CLV_SKILLS_DIR/gibbon/plugin/.claude-plugin/plugin.json" ]
}

@test "external source clone failure: logs and returns non-zero" {
    _stub_git_response "clone" 128 ""
    run _clv_stage_plugin "gibbon" "https://github.com/Clouve/missing.git" "$TEST_TMPDIR/clone"
    [ "$status" -ne 0 ]
    [ ! -d "$_CLV_SKILLS_DIR/gibbon" ]
}

@test "copies matching context/<plugin>/CONTEXT.md.tpl when present" {
    mkdir -p "$_CLV_CONTEXT_DIR/gibbon"
    echo "Gibbon persona content" > "$_CLV_CONTEXT_DIR/gibbon/CONTEXT.md.tpl"
    mkdir -p "$TEST_TMPDIR/clone"
    _make_plugin_in_marketplace "$TEST_TMPDIR/clone" "plugins/gibbon"
    run _clv_stage_plugin "gibbon" "./plugins/gibbon" "$TEST_TMPDIR/clone"
    [ "$status" -eq 0 ]
    [ -f "$_CLV_SKILLS_DIR/gibbon/CONTEXT.md.tpl" ]
    grep -q "Gibbon persona content" "$_CLV_SKILLS_DIR/gibbon/CONTEXT.md.tpl"
}

@test "missing context/<plugin>/CONTEXT.md.tpl: warns but staging still succeeds" {
    mkdir -p "$TEST_TMPDIR/clone"
    _make_plugin_in_marketplace "$TEST_TMPDIR/clone" "plugins/gibbon"
    run _clv_stage_plugin "gibbon" "./plugins/gibbon" "$TEST_TMPDIR/clone"
    [ "$status" -eq 0 ]
    [ -d "$_CLV_SKILLS_DIR/gibbon/plugin" ]
    [ ! -f "$_CLV_SKILLS_DIR/gibbon/CONTEXT.md.tpl" ]
    _assert_grep "no context/gibbon/CONTEXT.md.tpl"
}

@test "rejects source paths that escape the marketplace (path traversal)" {
    mkdir -p "$TEST_TMPDIR/clone"
    run _clv_stage_plugin "gibbon" "../../../etc" "$TEST_TMPDIR/clone"
    [ "$status" -ne 0 ]
}
