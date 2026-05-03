#!/usr/bin/env bash
# Fake `git` binary used by bats tests. Records every invocation to
# $_STUB_GIT_LOG and consults $_STUB_GIT_SCRIPT (TSV: pattern\texit\taction)
# for the response. The `clone` action receives $clone_dir = the final argv,
# which it can populate to simulate a successful clone.
set -u

cmdline="git $*"
echo "$cmdline" >> "$_STUB_GIT_LOG"

# Default: echo cmdline + exit 0 (so unscripted calls don't accidentally pass)
default_exit=99
if [ -s "${_STUB_GIT_SCRIPT:-/dev/null}" ]; then
    while IFS=$'\t' read -r pattern exit_code action; do
        if [[ "$cmdline" == *"$pattern"* ]]; then
            # Side effect: if cloning, the clone dir is the last positional arg.
            if [[ "$1" == "clone" || "$cmdline" == *"clone"* ]]; then
                clone_dir="${@: -1}"
                eval "$action" || true
            else
                eval "$action" || true
            fi
            exit "$exit_code"
        fi
    done < "$_STUB_GIT_SCRIPT"
fi
echo "git-stub: unscripted call: $cmdline" >&2
exit "$default_exit"
