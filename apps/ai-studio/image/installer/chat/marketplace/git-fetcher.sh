#!/bin/bash
# Shallow-clone a git repo with credentials injected via GIT_ASKPASS.
# Reuses an existing local clone for the same (host, repo, branch).
#
# Usage: _clv_git_fetch <host> <clone_url> <branch>
# Stdout: absolute path to the clone directory on success
# Returns: 0 on success, non-zero on failure
#
# Cache layout: $_CLV_FETCH_ROOT/<host>__<org>__<repo>__<branch>/
# (default $_CLV_FETCH_ROOT = /var/lib/clouve/marketplace-fetch)
#
# Requires: credentials.sh sourced (provides _clv_resolve_credentials).

: "${_CLV_FETCH_ROOT:=/var/lib/clouve/marketplace-fetch}"

_clv_fetch_dir_for() {
    # Build a deterministic, filesystem-safe dir name.
    # github.com / Clouve/magneto-skills / main -> github.com__Clouve__magneto-skills__main
    local host="$1" clone_url="$2" branch="$3"
    local path="${clone_url#https://*/}"     # Clouve/magneto-skills.git
    path="${path%.git}"                      # Clouve/magneto-skills
    local safe="${path//\//__}"              # Clouve__magneto-skills
    local safe_branch="${branch//\//__}"     # release__2026
    printf '%s/%s__%s__%s' "$_CLV_FETCH_ROOT" "$host" "$safe" "$safe_branch"
}

_clv_git_fetch() {
    local host="$1" clone_url="$2" branch="$3"
    local target
    target="$(_clv_fetch_dir_for "$host" "$clone_url" "$branch")"

    # Reuse if already cloned.
    if [ -d "$target/.git" ]; then
        printf '%s' "$target"
        return 0
    fi

    mkdir -p "$(dirname "$target")"
    rm -rf "$target"

    # Resolve credentials. Empty token -> unauthenticated.
    _clv_resolve_credentials "$host"

    local helper="${_CLV_ASKPASS_HELPER:-$(dirname "${BASH_SOURCE[0]}")/git-askpass-helper.sh}"
    local rc=0
    if [ -n "$_clv_cred_token" ]; then
        env \
            "GIT_ASKPASS=$helper" \
            "_CLV_ASKPASS_USERNAME=$_clv_cred_username" \
            "_CLV_ASKPASS_TOKEN=$_clv_cred_token" \
            git clone \
                --depth 1 \
                --single-branch \
                --branch "$branch" \
                "$clone_url" \
                "$target" >&2
        rc=$?
    else
        git clone \
            --depth 1 \
            --single-branch \
            --branch "$branch" \
            "$clone_url" \
            "$target" >&2
        rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        printf '%s' "$target"
        return 0
    fi

    rm -rf "$target"
    return 1
}
