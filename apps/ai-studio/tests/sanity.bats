#!/usr/bin/env bats
load helpers/common
setup() { _test_setup; }
teardown() { _test_teardown; }

@test "bats runner is wired up" {
    [ -d "$TEST_TMPDIR" ]
    [ -d "$MOD_DIR" ] || mkdir -p "$MOD_DIR"  # MOD_DIR doesn't exist yet — that's fine
    [ -n "$REPO_ROOT" ]
}

@test "git stub records calls and exits with scripted code" {
    _stub_git
    _stub_git_response "clone" 0 "mkdir -p \$clone_dir"
    run git clone https://example.com/foo "$TEST_TMPDIR/dest"
    [ "$status" -eq 0 ]
    [ -d "$TEST_TMPDIR/dest" ]
    grep -q "git clone https://example.com/foo" "$_STUB_GIT_LOG"
}
