#!/bin/bash
# Resolve git credentials for a given host. Sets two output globals:
#   _clv_cred_username  — username for HTTPS Basic Auth (host-appropriate default)
#   _clv_cred_token     — token / password (or empty for unauthenticated clone)
#
# Resolution order (token):
#   1. AI_STUDIO_SKILLS_GIT_TOKEN__<HOST>   (host-specific)
#   2. AI_STUDIO_SKILLS_GIT_TOKEN           (default)
#   3. unset                                 (unauthenticated)
#
# Resolution order (username):
#   1. AI_STUDIO_SKILLS_GIT_USERNAME__<HOST> (host-specific)
#   2. AI_STUDIO_SKILLS_GIT_USERNAME         (default)
#   3. Per-host built-in default for known hosts
#   4. "git" for unknown hosts (token-as-password convention)
#
# <HOST> = host uppercased, dots replaced with underscores.
# Unauthenticated clones leave both globals empty so the caller can skip
# GIT_ASKPASS setup entirely.

_clv_normalise_host_for_env() {
    # github.com -> GITHUB_COM, git.internal.clouve.com -> GIT_INTERNAL_CLOUVE_COM
    # Uses tr for portability (bash 3.2 on macOS lacks ${var^^}).
    local h="$1"
    h="$(printf '%s' "$h" | tr '[:lower:]' '[:upper:]')"
    h="${h//./_}"
    h="${h//-/_}"
    printf '%s' "$h"
}

_clv_default_username_for_host() {
    local h
    h="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$h" in
        github.com)              printf 'x-access-token' ;;
        gitlab.com)              printf 'oauth2' ;;
        bitbucket.org)           printf 'x-token-auth' ;;
        *)                       printf 'git' ;;
    esac
}

_clv_resolve_credentials() {
    local host="$1"
    _clv_cred_username=""
    _clv_cred_token=""

    local host_key
    host_key="$(_clv_normalise_host_for_env "$host")"

    # Token: host-specific → default → empty
    local host_tok_var="AI_STUDIO_SKILLS_GIT_TOKEN__${host_key}"
    local def_tok_var="AI_STUDIO_SKILLS_GIT_TOKEN"
    if [ -n "${!host_tok_var:-}" ]; then
        _clv_cred_token="${!host_tok_var}"
    elif [ -n "${!def_tok_var:-}" ]; then
        _clv_cred_token="${!def_tok_var}"
    fi

    # No token → no username (unauthenticated clone)
    [ -z "$_clv_cred_token" ] && return 0

    # Username: host-specific → default → per-host built-in → "git"
    local host_user_var="AI_STUDIO_SKILLS_GIT_USERNAME__${host_key}"
    local def_user_var="AI_STUDIO_SKILLS_GIT_USERNAME"
    if [ -n "${!host_user_var:-}" ]; then
        _clv_cred_username="${!host_user_var}"
    elif [ -n "${!def_user_var:-}" ]; then
        _clv_cred_username="${!def_user_var}"
    else
        _clv_cred_username="$(_clv_default_username_for_host "$host")"
    fi

    return 0
}
