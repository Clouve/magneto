#!/usr/bin/env bats
load helpers/common
setup() { _test_setup; source "$MOD_DIR/credentials.sh"; }
teardown() { _test_teardown; }

@test "host-specific token overrides default" {
    export AI_STUDIO_SKILLS_GIT_TOKEN="default-tok"
    export AI_STUDIO_SKILLS_GIT_TOKEN__GITHUB_COM="gh-tok"
    _clv_resolve_credentials "github.com"
    [ "$_clv_cred_token" = "gh-tok" ]
    [ "$_clv_cred_username" = "x-access-token" ]
}

@test "default token used when no host override is set" {
    export AI_STUDIO_SKILLS_GIT_TOKEN="default-tok"
    _clv_resolve_credentials "github.com"
    [ "$_clv_cred_token" = "default-tok" ]
    [ "$_clv_cred_username" = "x-access-token" ]
}

@test "no token configured leaves credentials empty for unauthenticated clone" {
    _clv_resolve_credentials "github.com"
    [ -z "$_clv_cred_token" ]
    [ -z "$_clv_cred_username" ]
}

@test "explicit per-host username overrides the default for that host" {
    export AI_STUDIO_SKILLS_GIT_TOKEN__GITHUB_COM="tok"
    export AI_STUDIO_SKILLS_GIT_USERNAME__GITHUB_COM="my-bot"
    _clv_resolve_credentials "github.com"
    [ "$_clv_cred_username" = "my-bot" ]
}

@test "default username applies when no host override is set" {
    export AI_STUDIO_SKILLS_GIT_TOKEN="tok"
    export AI_STUDIO_SKILLS_GIT_USERNAME="default-bot"
    _clv_resolve_credentials "unknown.host.io"
    [ "$_clv_cred_username" = "default-bot" ]
}

@test "per-host username default for github.com is x-access-token" {
    export AI_STUDIO_SKILLS_GIT_TOKEN="tok"
    _clv_resolve_credentials "github.com"
    [ "$_clv_cred_username" = "x-access-token" ]
}

@test "per-host username default for gitlab.com is oauth2" {
    export AI_STUDIO_SKILLS_GIT_TOKEN="tok"
    _clv_resolve_credentials "gitlab.com"
    [ "$_clv_cred_username" = "oauth2" ]
}

@test "per-host username default for self-hosted gitlab matches by gitlab in hostname is NOT applied (only exact match)" {
    # Per spec: "gitlab.com and other GitLab instances → oauth2" — but we
    # cannot identify "GitLab instances" by host alone. Self-hosted hosts
    # default to the unknown-host fallback unless overridden explicitly.
    export AI_STUDIO_SKILLS_GIT_TOKEN="tok"
    _clv_resolve_credentials "git.internal.clouve.com"
    [ "$_clv_cred_username" = "git" ]
}

@test "per-host username default for bitbucket.org is x-token-auth" {
    export AI_STUDIO_SKILLS_GIT_TOKEN="tok"
    _clv_resolve_credentials "bitbucket.org"
    [ "$_clv_cred_username" = "x-token-auth" ]
}

@test "host-name normalisation: dots become underscores in env var lookup" {
    export AI_STUDIO_SKILLS_GIT_TOKEN__GIT_INTERNAL_CLOUVE_COM="self-tok"
    _clv_resolve_credentials "git.internal.clouve.com"
    [ "$_clv_cred_token" = "self-tok" ]
}

@test "host names are uppercased for env var lookup" {
    export AI_STUDIO_SKILLS_GIT_TOKEN__GITHUB_COM="caps-tok"
    _clv_resolve_credentials "GitHub.COM"
    [ "$_clv_cred_token" = "caps-tok" ]
}
