#!/usr/bin/env bats
load helpers/common
setup() { _test_setup; source "$MOD_DIR/url-parser.sh"; }
teardown() { _test_teardown; }

@test "parses bare github URL with default branch and no filter" {
    _clv_parse_marketplace_url "https://github.com/Clouve/magneto-skills.git"
    [ "$_clv_url_host" = "github.com" ]
    [ "$_clv_url_clone" = "https://github.com/Clouve/magneto-skills.git" ]
    [ "$_clv_url_branch" = "main" ]
    [ "$_clv_url_plugins_filter" = "" ]
}

@test "parses URL without .git suffix and appends it to the clone URL" {
    _clv_parse_marketplace_url "https://github.com/Clouve/magneto-skills"
    [ "$_clv_url_clone" = "https://github.com/Clouve/magneto-skills.git" ]
}

@test "parses ?plugins= filter into a comma-separated list" {
    _clv_parse_marketplace_url "https://github.com/Clouve/magneto-skills.git?plugins=gibbon,moodle"
    [ "$_clv_url_plugins_filter" = "gibbon,moodle" ]
    [ "$_clv_url_branch" = "main" ]
}

@test "parses #branch into the branch field" {
    _clv_parse_marketplace_url "https://github.com/Clouve/magneto-skills.git#release/2026-q2"
    [ "$_clv_url_branch" = "release/2026-q2" ]
    [ "$_clv_url_plugins_filter" = "" ]
}

@test "parses ?plugins= and #branch together (plugins before branch)" {
    _clv_parse_marketplace_url "https://github.com/Clouve/magneto-skills.git?plugins=gibbon#release/2026-q2"
    [ "$_clv_url_plugins_filter" = "gibbon" ]
    [ "$_clv_url_branch" = "release/2026-q2" ]
}

@test "extracts host from self-hosted GitLab URL" {
    _clv_parse_marketplace_url "https://git.internal.clouve.com/devops/skills.git"
    [ "$_clv_url_host" = "git.internal.clouve.com" ]
    [ "$_clv_url_clone" = "https://git.internal.clouve.com/devops/skills.git" ]
}

@test "rejects non-HTTPS URLs" {
    run _clv_parse_marketplace_url "git@github.com:Clouve/magneto-skills.git"
    [ "$status" -ne 0 ]
}

@test "rejects malformed URL with no host" {
    run _clv_parse_marketplace_url "https:///foo/bar"
    [ "$status" -ne 0 ]
}

@test "rejects empty input" {
    run _clv_parse_marketplace_url ""
    [ "$status" -ne 0 ]
}
