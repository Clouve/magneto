# Source ~/.bashrc for aliases, functions, and environment variables
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

# Ensure ~/.local/bin is in PATH. Ubuntu's .bashrc skips this for non-interactive
# shells, but we need it here for both the interactive Claude launch and for any
# login-shell invocations by Claude Code itself (which uses bash -l).
export PATH="$HOME/.local/bin:$PATH"

# Auto-launch Claude Code only for interactive login shells (real terminal sessions).
# Guard required because Claude Code itself invokes bash with -l to inherit the login
# environment when running commands — without this check, every such invocation would
# launch a nested claude session instead of executing the intended command.
if [[ $- == *i* ]]; then
    # API key resolution — applies only to interactive user terminal sessions.
    # Claude Code's own bash -l invocations are non-interactive and skip this block.
    #
    # Resolution order:
    #   1. ANTHROPIC_API_KEY env var (injected at container startup via /etc/profile.d/)
    #   2. Locally stored key (~/.claude_api_key, saved from a previous session)
    #   3. Prompt user to enter key, save it, then proceed
    #   4. User provides nothing or presses Ctrl+C → exit session, no shell access

    # Neutralise environment variables that cause bash to source arbitrary files in
    # non-interactive subshells. Unset early so Claude Code's child shells are also clean.
    unset BASH_ENV ENV

    # Trap SIGINT and SIGTERM so Ctrl+C cannot escape the gate into a bare shell.
    # The trap is cleared before launching Claude Code so it gets normal signal handling.
    _clv_gate_exit() {
        echo ""
        echo "+------------------------------------------------------------+"
        echo "|  Session closed. An Anthropic API key is required.         |"
        echo "|  Reconnect and enter your key to proceed.                  |"
        echo "+------------------------------------------------------------+"
        exit 1
    }
    trap '_clv_gate_exit' INT TERM

    # Validates a key against the Anthropic API. Prints status inline.
    # Returns 0 = valid, 1 = rejected (bad key), 2 = network/timeout error.
    _clv_validate_key() {
        local key="$1"
        local http_status
        echo -n "Verifying key... "
        http_status=$(curl -s -o /dev/null -w "%{http_code}" \
            https://api.anthropic.com/v1/models \
            -H "x-api-key: $key" \
            -H "anthropic-version: 2023-06-01" \
            --max-time 10 --connect-timeout 5 2>/dev/null)
        case "$http_status" in
            200) echo "OK.";      return 0 ;;
            000) echo "network error (could not reach api.anthropic.com)."; return 2 ;;
            401) echo "rejected (invalid or revoked key).";                 return 1 ;;
            *)   echo "rejected (HTTP $http_status).";                      return 1 ;;
        esac
    }

    if [ -z "$ANTHROPIC_API_KEY" ]; then
        STORED_KEY_FILE="$HOME/.claude_api_key"

        # If a stored key exists, validate it before trusting it. A previously
        # saved key may have been revoked; clear it and re-prompt if so.
        if [ -f "$STORED_KEY_FILE" ] && [ -s "$STORED_KEY_FILE" ]; then
            stored_key="$(cat "$STORED_KEY_FILE")"
            _clv_validate_key "$stored_key"
            case $? in
                0) export ANTHROPIC_API_KEY="$stored_key" ;;
                2) echo "Could not verify saved key due to a network error."
                   echo "Please check connectivity and reconnect."
                   _clv_gate_exit ;;
                *) echo "Saved key is no longer valid. Please enter a new one."
                   rm -f "$STORED_KEY_FILE" ;;
            esac
        fi

        # No key available (never stored, or stored key was invalid) — prompt.
        if [ -z "$ANTHROPIC_API_KEY" ]; then
            echo ""
            echo "+-----------------------------------------------------------+"
            echo "|              Anthropic API Key Required                   |"
            echo "+-----------------------------------------------------------+"
            echo "|  Claude Code requires an Anthropic API key to run.        |"
            echo "|                                                           |"
            echo "|  Get your key at: https://console.anthropic.com/settings  |"
            echo "+-----------------------------------------------------------+"
            echo ""
            echo ""
            while true; do
                read -r -p "Enter your Anthropic API key (sk-ant-...): " user_key
                echo ""
                if [ -z "$user_key" ]; then
                    _clv_gate_exit
                fi
                _clv_validate_key "$user_key"
                case $? in
                    0) echo "$user_key" > "$STORED_KEY_FILE"
                       chmod 600 "$STORED_KEY_FILE"
                       export ANTHROPIC_API_KEY="$user_key"
                       echo "API key saved. Starting Claude Code..."
                       echo ""
                       break ;;
                    2) echo "Network error: could not reach api.anthropic.com."
                       echo "Please check connectivity and reconnect."
                       _clv_gate_exit ;;
                    *) echo "Invalid key. Please check it and try again." ;;
                esac
            done
        fi
    fi

    # Gate passed — restore default signal handling before launching Claude Code.
    trap - INT TERM
    unset -f _clv_gate_exit _clv_validate_key

    # Ask whether to skip Claude Code permission prompts.
    # Default is yes (Enter) for convenience; answer is not persisted.
    read -r -p "Skip Claude Code permission prompts? [Y/n]: " _clv_skip_perms
    case "${_clv_skip_perms,,}" in
        n|no) claude ;;
        *)    claude --dangerously-skip-permissions ;;
    esac
    exit $?
fi
