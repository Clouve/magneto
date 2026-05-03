#!/usr/bin/env bats
load helpers/common
setup() { _test_setup; }
teardown() { _test_teardown; }

@test "askpass returns username when prompt asks for username" {
    export _CLV_ASKPASS_USERNAME="x-access-token"
    export _CLV_ASKPASS_TOKEN="ghp_secret"
    run "$MOD_DIR/git-askpass-helper.sh" "Username for 'https://github.com': "
    [ "$status" -eq 0 ]
    [ "$output" = "x-access-token" ]
}

@test "askpass returns token when prompt asks for password" {
    export _CLV_ASKPASS_USERNAME="x-access-token"
    export _CLV_ASKPASS_TOKEN="ghp_secret"
    run "$MOD_DIR/git-askpass-helper.sh" "Password for 'https://x-access-token@github.com': "
    [ "$status" -eq 0 ]
    [ "$output" = "ghp_secret" ]
}

@test "askpass exits non-zero when no credentials are configured" {
    run "$MOD_DIR/git-askpass-helper.sh" "Username for 'https://github.com': "
    [ "$status" -ne 0 ]
}

@test "askpass output contains no extra lines" {
    export _CLV_ASKPASS_USERNAME="user"
    export _CLV_ASKPASS_TOKEN="tok"
    run "$MOD_DIR/git-askpass-helper.sh" "Password for 'foo': "
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | wc -l)" -eq 0 ]
}
