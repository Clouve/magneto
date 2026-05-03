# Shared bats helpers. Source from each *.bats setup() with:
#   load helpers/common
#
# Provides:
#   $TEST_TMPDIR       — fresh per-test temp dir (auto-cleaned)
#   $REPO_ROOT         — path to the magneto repo root
#   $MOD_DIR           — path to the marketplace/ module dir under test
#   _stub_git          — install a stub `git` on PATH that records calls
#   _stub_git_response — queue a response for the next git invocation
#   _assert_grep       — bats helper: $output contains a substring
#   _reset_clv_env     — wipe all AI_STUDIO_SKILLS_* env vars

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
MOD_DIR="$REPO_ROOT/apps/ai-studio/image/installer/chat/marketplace"

_test_setup() {
    TEST_TMPDIR="$(mktemp -d -t aistudio-test-XXXXXX)"
    export TEST_TMPDIR
    _reset_clv_env
}

_test_teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"
}

_reset_clv_env() {
    local var
    while IFS='=' read -r var _; do
        [[ "$var" == AI_STUDIO_SKILLS* ]] && unset "$var"
    done < <(env)
    return 0
}

_stub_git() {
    mkdir -p "$TEST_TMPDIR/bin"
    cp "$BATS_TEST_DIRNAME/helpers/git-stub.sh" "$TEST_TMPDIR/bin/git"
    chmod +x "$TEST_TMPDIR/bin/git"
    export PATH="$TEST_TMPDIR/bin:$PATH"
    export _STUB_GIT_LOG="$TEST_TMPDIR/git-calls.log"
    export _STUB_GIT_SCRIPT="$TEST_TMPDIR/git-script.sh"
    : > "$_STUB_GIT_LOG"
    : > "$_STUB_GIT_SCRIPT"
}

# Queue a behaviour for the next matching git command.
# Args: $1 = pattern (substring match against full cmd line)
#       $2 = exit code
#       $3 = optional action (shell snippet run with $clone_dir set)
_stub_git_response() {
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$_STUB_GIT_SCRIPT"
}

_assert_grep() {
    [[ "$output" == *"$1"* ]] || {
        echo "expected output to contain: $1" >&2
        echo "actual output: $output" >&2
        return 1
    }
}
