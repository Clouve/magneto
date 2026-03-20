# Source ~/.bashrc for aliases, functions, and environment variables
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

# Ensure ~/.local/bin is in PATH (needed for clients installed via user-space
# install scripts, e.g. Claude Code which lands in ~/.local/bin/claude).
export PATH="$HOME/.local/bin:$PATH"

# Only run the AI client selector for interactive login shells (real terminal
# sessions). Non-interactive shells (e.g. bash -l invoked by a client CLI to
# inherit the login environment) skip this block entirely.
if [[ $- != *i* ]]; then
    return 0
fi

# ─── Neutralise shell injection vectors ──────────────────────────────────────
# Unset variables that cause bash to source arbitrary files in non-interactive
# subshells. Cleared early so every child process spawned from here is clean.
unset BASH_ENV ENV

# ─── Maintenance mode escape hatch ───────────────────────────────────────────
# Set AI_STUDIO_MAINTENANCE_MODE=true in the container environment to bypass
# the AI client selector entirely and drop directly to a plain shell.
if [ "${AI_STUDIO_MAINTENANCE_MODE:-}" = "true" ]; then
    echo ""
    echo "  [AI Studio] Maintenance mode — selector bypassed."
    echo ""
    return 0
fi

# ─── Client Registry ─────────────────────────────────────────────────────────
# To add a new AI client: append one entry to each array below and create the
# corresponding install script at the path listed in CLV_INSTALLS.
# No other changes are required — the selector loop is fully data-driven.

CLV_NAMES=(
    "Claude Code"
    "Gemini CLI"
    "OpenAI Codex CLI"
)
CLV_CMDS=(
    "claude"
    "gemini"
    "codex"
)
CLV_INSTALLS=(
    "/clouve/ai-studio/installer/chat/claude/install.sh"
    "/clouve/ai-studio/installer/chat/gemini/install.sh"
    "/clouve/ai-studio/installer/chat/openai/install.sh"
)
CLV_KEY_VARS=(
    "ANTHROPIC_API_KEY"
    "GEMINI_API_KEY"
    "OPENAI_API_KEY"
)
CLV_KEY_FILES=(
    ".claude_api_key"
    ".gemini_api_key"
    ".openai_api_key"
)
CLV_KEY_LABELS=(
    "Anthropic API key (sk-ant-...)"
    "Google Gemini API key (AIza...)"
    "OpenAI API key (sk-...)"
)
# Context file template paths (empty string = no context file for this client)
CLV_CONTEXT_TPLS=(
    "/clouve/ai-studio/installer/chat/claude/CLAUDE.md.tpl"
    "/clouve/ai-studio/installer/chat/gemini/GEMINI.md.tpl"
    ""
)
# Destination directory and filename for the context file (relative to $HOME)
CLV_CONTEXT_DIRS=( ".claude"  ".gemini"  "" )
CLV_CONTEXT_FILES=( "CLAUDE.md" "GEMINI.md" "" )

# Auto-accept mode flags — the flag(s) passed when the user selects auto-accept.
# Empty string means this client has no auto-accept mode; the mode prompt is
# skipped and the client always launches in standard/interactive mode.
CLV_AUTO_FLAGS=(
    "--dangerously-skip-permissions"
    "--yolo"
    ""
)
# Standard/interactive mode flags (empty string = no extra flags needed)
CLV_STD_FLAGS=(
    ""
    ""
    ""
)

# ─── Per-session state ───────────────────────────────────────────────────────
CLV_CACHE_DIR="$HOME/.ai-studio"
CLV_CACHE_FILE="$CLV_CACHE_DIR/last-client"

# ─── Signal gate ─────────────────────────────────────────────────────────────
# Ctrl+C / SIGTERM during the selector or key prompt exits the session cleanly
# rather than dropping the user into a bare shell. The trap is cleared once a
# client is launched (or "None" is chosen) so the client handles its own
# signals normally. The trap is re-armed at the start of every loop iteration.
_clv_gate_exit() {
    echo ""
    echo "+------------------------------------------------------------+"
    echo "|  Session ended. Reconnect to open a new AI Studio session. |"
    echo "+------------------------------------------------------------+"
    exit 1
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Validate an API key against its provider's API.
# Args: $1=client_index  $2=key
# Returns: 0=valid  1=rejected  2=network error
_clv_validate_key() {
    local idx="$1" key="$2" http_status
    echo -n "  Verifying key... "
    case $idx in
        0) http_status=$(curl -s -o /dev/null -w "%{http_code}" \
               "https://api.anthropic.com/v1/models" \
               -H "x-api-key: $key" \
               -H "anthropic-version: 2023-06-01" \
               --max-time 10 --connect-timeout 5 2>/dev/null)
           case "$http_status" in
               200) echo "OK.";    return 0 ;;
               000) echo "network error (could not reach api.anthropic.com)."; return 2 ;;
               *)   echo "rejected (HTTP $http_status)."; return 1 ;;
           esac ;;
        1) http_status=$(curl -s -o /dev/null -w "%{http_code}" \
               "https://generativelanguage.googleapis.com/v1beta/models?key=${key}" \
               --max-time 10 --connect-timeout 5 2>/dev/null)
           case "$http_status" in
               200) echo "OK.";    return 0 ;;
               000) echo "network error (could not reach generativelanguage.googleapis.com)."; return 2 ;;
               *)   echo "rejected (HTTP $http_status)."; return 1 ;;
           esac ;;
        2) http_status=$(curl -s -o /dev/null -w "%{http_code}" \
               "https://api.openai.com/v1/models" \
               -H "Authorization: Bearer $key" \
               --max-time 10 --connect-timeout 5 2>/dev/null)
           case "$http_status" in
               200) echo "OK.";    return 0 ;;
               000) echo "network error (could not reach api.openai.com)."; return 2 ;;
               *)   echo "rejected (HTTP $http_status)."; return 1 ;;
           esac ;;
    esac
}

# Resolve the API key for the selected client.
# Resolution order: env var → stored key file → interactive prompt.
# On success, the key is exported into the current environment.
_clv_resolve_key() {
    local idx="$1"
    local key_var="${CLV_KEY_VARS[$idx]}"
    local key_file="$HOME/${CLV_KEY_FILES[$idx]}"
    local key_label="${CLV_KEY_LABELS[$idx]}"

    # 1. Already set via environment (injected at container start via /etc/profile.d/)
    if [ -n "${!key_var}" ]; then
        return 0
    fi

    # 2. Stored key file from a previous session
    if [ -f "$key_file" ] && [ -s "$key_file" ]; then
        local stored_key
        stored_key="$(cat "$key_file")"
        _clv_validate_key "$idx" "$stored_key"
        case $? in
            0) export "${key_var}"="$stored_key"; return 0 ;;
            2) echo "  Could not verify saved key — network error. Check connectivity."
               _clv_gate_exit ;;
            *) echo "  Saved key is no longer valid."
               rm -f "$key_file" ;;
        esac
    fi

    # 3. Interactive prompt
    echo ""
    echo "  +-----------------------------------------------------------+"
    echo "  |              API Key Required                             |"
    echo "  +-----------------------------------------------------------+"
    printf "  |  %-57s|\n" "$key_label"
    echo "  +-----------------------------------------------------------+"
    echo ""
    while true; do
        read -r -p "  Enter key: " user_key
        echo ""
        if [ -z "$user_key" ]; then
            _clv_gate_exit
        fi
        _clv_validate_key "$idx" "$user_key"
        case $? in
            0) mkdir -p "$CLV_CACHE_DIR"
               echo "$user_key" > "$key_file"
               chmod 600 "$key_file"
               export "${key_var}"="$user_key"
               echo "  Key saved for future sessions."
               return 0 ;;
            2) echo "  Network error. Check connectivity and reconnect."
               _clv_gate_exit ;;
            *) echo "  Invalid key. Please check it and try again." ;;
        esac
    done
}

# Install the selected client if its command is not already on $PATH.
_clv_install() {
    local idx="$1"
    local script="${CLV_INSTALLS[$idx]}"
    if [ -f "$script" ]; then
        . "$script"
    else
        echo "  Install script not found: $script"
    fi
}

# Write the client's context/instructions file from its template.
# Uses envsubst so the template can reference ${USERNAME}, ${ROOT_PASSWORD},
# and ${HOSTNAME} — all of which are available in the login environment.
_clv_write_context() {
    local idx="$1"
    local tpl="${CLV_CONTEXT_TPLS[$idx]}"
    local dir="$HOME/${CLV_CONTEXT_DIRS[$idx]}"
    local file="${CLV_CONTEXT_FILES[$idx]}"
    [ -z "$tpl" ] && return 0
    mkdir -p "$dir"
    HOSTNAME=$(hostname) USERNAME="$(whoami)" \
        envsubst '${USERNAME} ${ROOT_PASSWORD} ${HOSTNAME}' \
        < "$tpl" > "$dir/$file"
    chmod 600 "$dir/$file"
}

# Prompt the user to choose between auto-accept and standard launch mode.
# Sets _clv_launch_flags to the appropriate value (may be empty string).
# If the client has no auto-accept mode (empty CLV_AUTO_FLAGS entry), the
# prompt is skipped and _clv_launch_flags is set to the standard flags.
_clv_ask_mode() {
    local idx="$1"
    local auto_flag="${CLV_AUTO_FLAGS[$idx]}"
    local std_flag="${CLV_STD_FLAGS[$idx]}"
    local name="${CLV_NAMES[$idx]}"

    # Default to standard mode
    _clv_launch_flags="$std_flag"

    # No auto-accept mode for this client — skip the prompt
    [ -z "$auto_flag" ] && return 0

    echo ""
    echo "  $name is ready."
    echo "  Would you like to run in auto-accept mode?"
    echo ""
    echo "    1)  Yes — run in auto-accept mode"
    echo "    2)  No  — run in standard/interactive mode"
    echo ""
    while true; do
        read -r -p "  Select [1-2]: " _clv_mode
        case "$_clv_mode" in
            1) _clv_launch_flags="$auto_flag"; break ;;
            2) _clv_launch_flags="$std_flag";  break ;;
            *) echo "  Enter 1 or 2." ;;
        esac
    done
}

# ─── Main session loop ────────────────────────────────────────────────────────
# The selector runs in a persistent loop. After any client exits — whether the
# user quits normally, the client crashes, or the session is interrupted — the
# loop restarts and presents the selection menu again. The only ways to leave
# this loop are:
#   • Choosing "None" from the menu (drops to a plain shell via return 0)
#   • Ctrl+C / SIGTERM during selection or key-resolution (exits via _clv_gate_exit)
#   • AI_STUDIO_MAINTENANCE_MODE=true (bypassed entirely above, before the loop)

while true; do

    # Re-arm the gate trap at the start of every iteration. This ensures that
    # Ctrl+C during the selection menu or API key prompt exits the session
    # cleanly rather than dropping to a bare shell.
    trap '_clv_gate_exit' INT TERM

    selected_idx=""

    # ── Check for a cached selection from the previous session ────────────────
    if [ -f "$CLV_CACHE_FILE" ]; then
        cached_idx=$(cat "$CLV_CACHE_FILE" 2>/dev/null)
        if [[ "$cached_idx" =~ ^[0-9]+$ ]] && [ "$cached_idx" -lt "${#CLV_NAMES[@]}" ]; then
            cached_name="${CLV_NAMES[$cached_idx]}"
            echo ""
            printf "  Last session: %s\n" "$cached_name"
            read -r -p "  Use $cached_name again? [Y/n]: " _clv_reuse
            case "${_clv_reuse,,}" in
                n|no) : ;;            # fall through to full menu
                *)    selected_idx="$cached_idx" ;;
            esac
        fi
    fi

    # ── Show the full menu if no cached choice was accepted ───────────────────
    if [ -z "$selected_idx" ]; then
        echo ""
        echo "  ╔═══════════════════════════════════════════════╗"
        echo "  ║           Welcome to AI Studio                ║"
        echo "  ╚═══════════════════════════════════════════════╝"
        echo ""
        echo "  Which AI coding assistant would you like to use?"
        echo ""
        for i in "${!CLV_NAMES[@]}"; do
            printf "    %d)  %s\n" "$((i + 1))" "${CLV_NAMES[$i]}"
        done
        echo ""
        while true; do
            read -r -p "  Select [1-${#CLV_NAMES[@]}]: " _clv_choice
            if [[ "$_clv_choice" =~ ^[0-9]+$ ]] && \
               [ "$_clv_choice" -ge 1 ] && [ "$_clv_choice" -le "${#CLV_NAMES[@]}" ]; then
                selected_idx=$((_clv_choice - 1))
                break
            fi
            echo "  Invalid choice. Enter a number between 1 and ${#CLV_NAMES[@]}."
        done
    fi

    # ── AI client selected — resolve key, install, configure ─────────────────

    # Save the selection so next session can offer to reuse it
    mkdir -p "$CLV_CACHE_DIR"
    echo "$selected_idx" > "$CLV_CACHE_FILE"

    client_name="${CLV_NAMES[$selected_idx]}"
    client_cmd="${CLV_CMDS[$selected_idx]}"

    echo ""
    echo "  Selected: $client_name"

    # Resolve (or prompt for) the API key
    _clv_resolve_key "$selected_idx"

    # Install the client if not already present
    if ! command -v "$client_cmd" &>/dev/null; then
        echo ""
        echo "  $client_name is not installed. Installing now..."
        _clv_install "$selected_idx"
        if ! command -v "$client_cmd" &>/dev/null; then
            echo ""
            echo "  Installation failed — '$client_cmd' not found after install."
            _clv_gate_exit
        fi
        echo ""
    fi

    # Write the client's context/instructions file from template
    _clv_write_context "$selected_idx"

    # ── Ask for launch mode (auto-accept vs standard) ─────────────────────────
    _clv_ask_mode "$selected_idx"

    # ── Gate passed — clear trap and launch the client ────────────────────────
    # Restore default signal handling so the client process receives and handles
    # its own signals normally. The gate trap is re-armed at the top of the next
    # iteration once the client exits and the menu is presented again.
    trap - INT TERM

    echo ""
    echo "  Starting $client_name..."
    echo ""

    # Launch as a regular foreground child (not exec) so this loop resumes
    # after the client exits and can present the selection menu again.
    # Word splitting on $_clv_launch_flags is intentional — values are
    # controlled constants from the registry, never user input.
    # shellcheck disable=SC2086
    $client_cmd $_clv_launch_flags

    echo ""
    echo "  ─────────────────────────────────────────────────────────────"
    printf "  %s session ended.\n" "$client_name"
    echo "  ─────────────────────────────────────────────────────────────"
    echo ""

    unset selected_idx cached_idx cached_name _clv_reuse _clv_choice \
          client_name client_cmd _clv_launch_flags _clv_mode

done
