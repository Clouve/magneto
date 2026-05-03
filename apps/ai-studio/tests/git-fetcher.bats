#!/usr/bin/env bats
load helpers/common
setup() {
    _test_setup
    _stub_git
    source "$MOD_DIR/credentials.sh"
    source "$MOD_DIR/git-fetcher.sh"
    export _CLV_FETCH_ROOT="$TEST_TMPDIR/fetch"
}
teardown() { _test_teardown; }

@test "successful clone returns the local path on stdout" {
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir/.claude-plugin && echo '{}' > \$clone_dir/.claude-plugin/marketplace.json"
    run _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "main"
    [ "$status" -eq 0 ]
    [ -d "$output" ]
    [ -f "$output/.claude-plugin/marketplace.json" ]
}

@test "deterministic clone path: same host+repo+branch reuses the same dir" {
    # Stub creates .git/ inside the clone dir so the dedup check sees a real clone.
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir/.git"
    run _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "main"
    local first="$output"
    run _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "main"
    [ "$output" = "$first" ]
    # And the second call should NOT have re-invoked git clone.
    [ "$(grep -c "git clone" "$_STUB_GIT_LOG")" -eq 1 ]
}

@test "different branches produce different clone dirs" {
    # Stub creates .git/ inside the clone dir so each call is detected as a real clone.
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir/.git"
    run _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "main"
    local main_dir="$output"
    run _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "release"
    [ "$output" != "$main_dir" ]
    [ "$(grep -c "git clone" "$_STUB_GIT_LOG")" -eq 2 ]
}

@test "clone uses --depth 1 --single-branch --branch <branch>" {
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir"
    _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "release/2026"
    grep -q -- "--depth 1" "$_STUB_GIT_LOG"
    grep -q -- "--single-branch" "$_STUB_GIT_LOG"
    grep -q -- "--branch release/2026" "$_STUB_GIT_LOG"
}

@test "clone failure returns non-zero and removes the partial dir" {
    _stub_git_response "clone" 128 "mkdir -p \$clone_dir/.partial"
    run _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "main"
    [ "$status" -ne 0 ]
    # Should have cleaned up the partial directory
    [ ! -d "$_CLV_FETCH_ROOT/github.com__Clouve__magneto-skills__main" ]
}

@test "GIT_ASKPASS is set from credential resolver when token is configured" {
    export AI_STUDIO_SKILLS_GIT_TOKEN__GITHUB_COM="ghp_test"
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir; echo \"ASKPASS=\$GIT_ASKPASS USER=\$_CLV_ASKPASS_USERNAME TOK=\$_CLV_ASKPASS_TOKEN\" > \$clone_dir/.askpass-trace"
    _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "main"
    grep -q "ASKPASS=" "$_CLV_FETCH_ROOT/github.com__Clouve__magneto-skills__main/.askpass-trace"
    grep -q "USER=x-access-token" "$_CLV_FETCH_ROOT/github.com__Clouve__magneto-skills__main/.askpass-trace"
    grep -q "TOK=ghp_test" "$_CLV_FETCH_ROOT/github.com__Clouve__magneto-skills__main/.askpass-trace"
}

@test "no GIT_ASKPASS export when no credentials are configured" {
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir; echo \"ASKPASS=\${GIT_ASKPASS:-UNSET}\" > \$clone_dir/.askpass-trace"
    _clv_git_fetch "github.com" "https://github.com/Clouve/public-skills.git" "main"
    grep -q "ASKPASS=UNSET" "$_CLV_FETCH_ROOT/github.com__Clouve__public-skills__main/.askpass-trace"
}

@test "credentials are not persisted to .git/config (no embedded URL)" {
    export AI_STUDIO_SKILLS_GIT_TOKEN="tok"
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir/.git && echo \"\$@\" > \$clone_dir/.git/clone-args"
    _clv_git_fetch "github.com" "https://github.com/Clouve/magneto-skills.git" "main"
    # The clone URL passed to git must not contain credentials inline.
    ! grep -E "https://[^/@]+:[^/@]+@" "$_CLV_FETCH_ROOT/github.com__Clouve__magneto-skills__main/.git/clone-args"
}
