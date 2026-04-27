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

# ─── Forced client assignment (AI_STUDIO_CLIENT) ─────────────────────────────
# When AI_STUDIO_CLIENT is set at container start, the selection menu is skipped
# entirely and the user is locked into the specified client for the lifetime of
# the session. The variable and the resolved index are marked readonly so they
# cannot be changed or unset from within the shell.
#
# Accepted values match the CLV_IDS registry below (e.g. claude-code, gemini-cli,
# codex-cli). An unrecognised value prints an error and falls back to the
# interactive menu.
#
# Resolution happens here — before the registry arrays are defined — so we
# defer the actual lookup to a post-registry block further below.
# We capture the raw value now and will validate it once CLV_IDS is available.
_CLV_FORCED_RAW="${AI_STUDIO_CLIENT:-}"

# ─── Client Registry ─────────────────────────────────────────────────────────
# To add a new AI client: append one entry to each array below and create the
# corresponding install script at the path listed in CLV_INSTALLS.
# No other changes are required — the selector loop is fully data-driven.

CLV_NAMES=(
    "Claude Code"
    "Gemini CLI"
    "OpenAI Codex CLI"
)
# Canonical identifiers accepted by AI_STUDIO_CLIENT (one per client, same order)
CLV_IDS=(
    "claude-code"
    "gemini-cli"
    "codex-cli"
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
CLV_KEY_URLS=(
    "https://console.anthropic.com/settings/keys"
    "https://aistudio.google.com/apikey"
    "https://platform.openai.com/api-keys"
)
# Context file template paths (empty string = no context file for this client)
CLV_CONTEXT_TPLS=(
    "/clouve/ai-studio/installer/chat/claude/CLAUDE.md.tpl"
    "/clouve/ai-studio/installer/chat/gemini/GEMINI.md.tpl"
    "/clouve/ai-studio/installer/chat/openai/AGENTS.md.tpl"
)
# Destination directory and filename for the context file (relative to $HOME)
CLV_CONTEXT_DIRS=( ".claude"  ".gemini"  ".codex" )
CLV_CONTEXT_FILES=( "CLAUDE.md" "GEMINI.md" "AGENTS.md" )

# Auto-accept mode flags — the flag(s) passed when the user selects auto-accept.
# Empty string means this client has no auto-accept mode; the mode prompt is
# skipped and the client always launches in standard/interactive mode.
CLV_AUTO_FLAGS=(
    "--dangerously-skip-permissions"
    "--yolo"
    "--dangerously-bypass-approvals-and-sandbox"
)
# Standard/interactive mode flags (empty string = no extra flags needed)
CLV_STD_FLAGS=(
    ""
    ""
    ""
)

# ─── Resolve AI_STUDIO_CLIENT → forced index ─────────────────────────────────
# Now that CLV_IDS is defined we can validate the raw value captured above.
_CLV_FORCED_IDX=""
if [ -n "$_CLV_FORCED_RAW" ]; then
    _clv_found_forced=0
    for _clv_i in "${!CLV_IDS[@]}"; do
        if [ "${CLV_IDS[$_clv_i]}" = "$_CLV_FORCED_RAW" ]; then
            _CLV_FORCED_IDX="$_clv_i"
            _clv_found_forced=1
            break
        fi
    done
    if [ "$_clv_found_forced" -eq 0 ]; then
        echo ""
        echo "  [AI Studio] ERROR: Unrecognised AI_STUDIO_CLIENT value: '$_CLV_FORCED_RAW'"
        echo "  Supported values:"
        for _clv_i in "${!CLV_IDS[@]}"; do
            printf "    • %s  (%s)\n" "${CLV_IDS[$_clv_i]}" "${CLV_NAMES[$_clv_i]}"
        done
        echo "  Falling back to the interactive selection menu."
        echo ""
    fi
    unset _clv_found_forced _clv_i
fi

# Lock both variables so the user cannot change or unset them from within
# the session. readonly fails silently if the variable is already readonly.
readonly _CLV_FORCED_IDX 2>/dev/null || true
readonly AI_STUDIO_CLIENT 2>/dev/null || true

# ─── Per-session state ───────────────────────────────────────────────────────
CLV_CACHE_DIR="$HOME/.ai-studio"
CLV_CACHE_FILE="$CLV_CACHE_DIR/last-client"
CLV_PREFS_FILE="$CLV_CACHE_DIR/preferences.json"

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

# Interactive arrow-key menu selector.
# Args: "$@" = menu item labels
# Sets _clv_menu_result to the 0-based index of the chosen item.
_clv_menu_select() {
    local items=("$@")
    local count=${#items[@]}
    local current=0
    local key esc seq i

    tput civis 2>/dev/null   # hide cursor

    # Initial draw
    for i in "${!items[@]}"; do
        if [ "$i" -eq "$current" ]; then
            printf "     \033[7m  %-40s  \033[0m\n" "${items[$i]}"
        else
            printf "       %-40s\n" "${items[$i]}"
        fi
    done

    while true; do
        IFS= read -r -s -n1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -r -s -n1 -t 0.1 esc
            IFS= read -r -s -n1 -t 0.1 seq
            case "$esc$seq" in
                '[A') ((current > 0)) && ((current--)) ;;           # Up
                '[B') ((current < count - 1)) && ((current++)) ;;   # Down
            esac
        elif [[ "$key" == '' || "$key" == $'\n' ]]; then
            break   # Enter
        fi

        # Redraw in place
        tput cuu "$count" 2>/dev/null
        for i in "${!items[@]}"; do
            tput el 2>/dev/null
            if [ "$i" -eq "$current" ]; then
                printf "     \033[7m  %-40s  \033[0m\n" "${items[$i]}"
            else
                printf "       %-40s\n" "${items[$i]}"
            fi
        done
    done

    tput cnorm 2>/dev/null   # restore cursor
    _clv_menu_result="$current"
}

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
    local key_url="${CLV_KEY_URLS[$idx]}"

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
    printf "  |  %-57s|\n" "Get one at: $key_url"
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

# Run provider-specific post-install authentication.
# Called once after first installation with the API key already exported.
_clv_post_install_auth() {
    local idx="$1"
    local cmd="${CLV_CMDS[$idx]}"
    local key_var="${CLV_KEY_VARS[$idx]}"

    case "${CLV_IDS[$idx]}" in
        gemini-cli)
            # Pre-select API-key auth in Gemini CLI's user settings to skip the
            # interactive first-run auth prompt. The actual key is read from
            # GEMINI_API_KEY at runtime (already exported by _clv_resolve_key).
            # Settings path: ~/.gemini/settings.json
            # Schema: { security: { auth: { selectedType: "gemini-api-key" } } }
            local settings_dir="$HOME/.gemini"
            local settings_file="$settings_dir/settings.json"
            if [ ! -f "$settings_file" ] || ! grep -q 'selectedType' "$settings_file" 2>/dev/null; then
                echo "  Configuring Gemini CLI for API key authentication..."
                mkdir -p "$settings_dir"
                cat > "$settings_file" <<'GEMEOF'
{"security":{"auth":{"selectedType":"gemini-api-key"}}}
GEMEOF
                chmod 600 "$settings_file"
                echo "  Gemini CLI configured."
            fi
            ;;
        codex-cli)
            # Store the API key in Codex CLI's internal config. The key is
            # piped through stdin to avoid shell history exposure.
            echo "  Authenticating Codex CLI..."
            if echo "${!key_var}" | "$cmd" login --with-api-key 2>&1; then
                echo "  Codex CLI authenticated."
            else
                echo "  WARNING: Codex CLI authentication may have failed."
            fi
            ;;
    esac
}

# Write the client's context/instructions file from its template.
#
# envsubst (no SHELL-FORMAT) substitutes every ${VAR} and $VAR reference in
# the template with the value of VAR from the current environment. The
# upstream templates only reference ${USERNAME}, ${ROOT_PASSWORD}, and
# ${AI_STUDIO_HOST}, but downstream apps (e.g. apps/gibbon's derived
# gibbon-ai-studio image, which overlays its own CLAUDE.md.tpl with extra
# ${GIBBON_HOST}, ${GIBBON_DB_HOST}, etc. references) can rely on this same
# call to render their custom env vars without any per-app shim. Any
# ${VAR} not in the env is replaced with the empty string.
#
# Template authors who want a literal "$VAR" or "${VAR}" in the rendered
# output (e.g. when documenting a PHP variable name) must avoid the
# leading "$" — envsubst has no escape syntax.
_clv_write_context() {
    local idx="$1"
    local tpl="${CLV_CONTEXT_TPLS[$idx]}"
    local dir="$HOME/${CLV_CONTEXT_DIRS[$idx]}"
    local file="${CLV_CONTEXT_FILES[$idx]}"
    [ -z "$tpl" ] && return 0

    # If AI_STUDIO_HOST was not explicitly set, fall back to the host
    # auto-detected by the auth server from the HTTP Host header.
    if [ -z "$AI_STUDIO_HOST" ] && [ -f /run/clouve/detected_host ]; then
        AI_STUDIO_HOST=$(cat /run/clouve/detected_host)
        export AI_STUDIO_HOST
    fi

    mkdir -p "$dir"
    USERNAME="$(whoami)" envsubst < "$tpl" > "$dir/$file"
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
    echo "  (Use ↑ ↓ arrows to navigate, Enter to confirm)"
    echo ""
    _clv_menu_select "Yes — run in auto-accept mode" "No  — run in standard/interactive mode"
    echo ""
    case "$_clv_menu_result" in
        0) _clv_launch_flags="$auto_flag" ;;
        1) _clv_launch_flags="$std_flag"  ;;
    esac
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

    # ── Re-read web preferences each iteration ───────────────────────────────
    # The user may have changed preferences via the web panel since the last
    # loop iteration, so we re-parse the file on each pass. This runs even
    # when AI_STUDIO_CLIENT is set because the execution mode (autoAccept)
    # is still user-configurable via the Preferences Panel.
    _CLV_WEB_IDX=""
    _CLV_WEB_AUTO="false"
    if [ -f "$CLV_PREFS_FILE" ]; then
        if command -v jq &>/dev/null; then
            _clv_web_client=$(jq -r '.client // empty' "$CLV_PREFS_FILE" 2>/dev/null)
            _clv_web_auto=$(jq -r '.autoAccept // false' "$CLV_PREFS_FILE" 2>/dev/null)
        else
            _clv_web_client=$(sed -n 's/.*"client"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CLV_PREFS_FILE" 2>/dev/null)
            _clv_web_auto=$(sed -n 's/.*"autoAccept"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$CLV_PREFS_FILE" 2>/dev/null)
        fi
        if [ -z "$_CLV_FORCED_IDX" ] && [ -n "$_clv_web_client" ]; then
            for _clv_i in "${!CLV_IDS[@]}"; do
                if [ "${CLV_IDS[$_clv_i]}" = "$_clv_web_client" ]; then
                    _CLV_WEB_IDX="$_clv_i"
                    break
                fi
            done
        fi
        [ "$_clv_web_auto" = "true" ] && _CLV_WEB_AUTO="true"
        unset _clv_web_client _clv_web_auto _clv_i
    fi

    # ── Forced client (AI_STUDIO_CLIENT override) — skip menu entirely ────────
    if [ -n "$_CLV_FORCED_IDX" ]; then
        selected_idx="$_CLV_FORCED_IDX"
        # If the Preferences Panel has saved a mode preference, use it
        [ -f "$CLV_PREFS_FILE" ] && _clv_web_mode_applied=1

    # ── Web preferences (set via the Preferences Panel) ───────────────────────
    elif [ -n "$_CLV_WEB_IDX" ]; then
        selected_idx="$_CLV_WEB_IDX"
        # Apply auto-accept mode from web preferences
        _clv_web_mode_applied=1

    else

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
        echo "  (Use ↑ ↓ arrows to navigate, Enter to confirm)"
        echo ""
        _clv_menu_select "${CLV_NAMES[@]}"
        selected_idx="$_clv_menu_result"
        echo ""
    fi

    fi  # end of non-forced / non-web-prefs branch

    # ── AI client selected — resolve key, install, configure ─────────────────

    # Save the selection so next session can offer to reuse it
    mkdir -p "$CLV_CACHE_DIR"
    echo "$selected_idx" > "$CLV_CACHE_FILE"

    client_name="${CLV_NAMES[$selected_idx]}"
    client_cmd="${CLV_CMDS[$selected_idx]}"

    [ -z "$_CLV_FORCED_IDX" ] && [ -z "${_clv_web_mode_applied:-}" ] && echo "" && echo "  Selected: $client_name"

    # Install the client if not already present
    _clv_just_installed=0
    if ! command -v "$client_cmd" &>/dev/null; then
        echo ""
        echo "  $client_name is not installed. Installing now..."
        _clv_install "$selected_idx"
        if ! command -v "$client_cmd" &>/dev/null; then
            echo ""
            echo "  Installation failed — '$client_cmd' not found after install."
            _clv_gate_exit
        fi
        _clv_just_installed=1
        echo ""
    fi

    # Resolve (or prompt for) the API key
    _clv_resolve_key "$selected_idx"

    # Run provider-specific post-install authentication (first install only)
    [ "$_clv_just_installed" -eq 1 ] && _clv_post_install_auth "$selected_idx"

    # Write the client's context/instructions file from template
    _clv_write_context "$selected_idx"

    # ── Ask for launch mode (auto-accept vs standard) ─────────────────────────
    # If the web Preferences Panel already set the mode, apply it directly
    # without showing the interactive prompt.
    if [ "${_clv_web_mode_applied:-}" = "1" ]; then
        if [ "$_CLV_WEB_AUTO" = "true" ] && [ -n "${CLV_AUTO_FLAGS[$selected_idx]}" ]; then
            _clv_launch_flags="${CLV_AUTO_FLAGS[$selected_idx]}"
        else
            _clv_launch_flags="${CLV_STD_FLAGS[$selected_idx]}"
        fi
    else
        _clv_ask_mode "$selected_idx"
    fi

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
          client_name client_cmd _clv_launch_flags _clv_mode _clv_web_mode_applied \
          _clv_just_installed

done
