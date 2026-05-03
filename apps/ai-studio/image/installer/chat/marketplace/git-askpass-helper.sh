#!/bin/bash
# git invokes this script with a single argument: the prompt text.
#   "Username for '<url>': "   → echo $_CLV_ASKPASS_USERNAME
#   "Password for '<url>': "   → echo $_CLV_ASKPASS_TOKEN
#
# Both env vars are set by the caller (typically git-fetcher.sh) just before
# invoking git, and are inherited by this child process. They are NEVER
# written to disk.
#
# Returns the credential on stdout with no trailing newline (printf %s).
# Exits non-zero if the matching credential is unset, which causes git to
# fall back to its own prompt (or fail in non-interactive contexts).

prompt="${1:-}"
case "$prompt" in
    Username\ for\ *)
        [ -n "${_CLV_ASKPASS_USERNAME:-}" ] || exit 1
        printf '%s' "$_CLV_ASKPASS_USERNAME"
        ;;
    Password\ for\ *)
        [ -n "${_CLV_ASKPASS_TOKEN:-}" ] || exit 1
        printf '%s' "$_CLV_ASKPASS_TOKEN"
        ;;
    *)
        # Unknown prompt — refuse rather than leak a credential into a
        # context we don't recognise.
        exit 1
        ;;
esac
exit 0
