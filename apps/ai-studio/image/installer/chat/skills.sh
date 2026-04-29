#!/bin/bash
# ============================================================================
# Skill loader — runs at container init, sourced from chat/install.sh
# ============================================================================
# Stages two things into /clouve/skills/:
#
#   1. The base context template (skills/CONTEXT.md.tpl in the magneto
#      repo) — ALWAYS staged, regardless of AI_STUDIO_SKILLS. It is the
#      platform-wide CLAUDE.md/GEMINI.md/AGENTS.md skeleton, rendered as-is
#      when AI_STUDIO_SKILLS is unset.
#
#   2. Each skill listed in AI_STUDIO_SKILLS (comma-separated
#      <Category>/<Name>) — rendered as ~/.claude/skills/<slug>/ symlinks
#      and appended as "## Skill: …" sections to the rendered context file.
#      <slug> is the ID lowercased with "/" replaced by "-".
#
# Source priority (applies to both base template and skills):
#   1. Git fetch via AI_STUDIO_SKILLS_REPO (single sparse-checkout clone
#      that pulls CONTEXT.md.tpl + every requested skill subdir).
#      Best-effort — failures degrade gracefully.
#   2. Baked-in offline fallback at /clouve/skills-bundled/ (populated at
#      image build time from the repo-root skills/ tree).
#   3. Skip with a warning if neither source has the asset.
#
# Output state:
#   /clouve/skills/CONTEXT.md.tpl           — base template (always)
#   /clouve/skills/<slug>/                  — full skill payload (per skill)
#   /clouve/skills/.active                  — TSV: <slug>\t<Category>/<Name>
#                                             one line per active skill, in
#                                             the order given in AI_STUDIO_SKILLS
#
# Consumed by:
#   - /etc/profile.d/clv-skills.sh (login-time symlinker over .active)
#   - .bash_profile _clv_write_context() (reads CONTEXT.md.tpl, then
#     appends per-skill sections from .active)
#
# This script does NOT abort the container on any error — a broken or
# unreachable source must not prevent the rest of ai-studio from
# starting. Missing/invalid items are logged and skipped.
# ============================================================================

# Use the same color codes as entrypoint.sh (already exported in this scope)
_skill_log() {
    echo -e "${GREEN}[skills]${NC} $*"
}
_skill_warn() {
    echo -e "${YELLOW}[skills]${NC} $*" >&2
}
_skill_err() {
    echo -e "${RED}[skills]${NC} $*" >&2
}

# Always wipe the active set so a removed skill (AI_STUDIO_SKILLS shrunk
# between restarts) doesn't linger in /clouve/skills/. Cheap on a small tree.
rm -rf /clouve/skills 2>/dev/null
mkdir -p /clouve/skills

# ─── Parse and validate AI_STUDIO_SKILLS (may be empty) ──────────────────────
# Comma-separated <Category>/<Name>. Trim whitespace around each entry.
# Validation regex blocks path traversal (.., leading /, control chars).
_skill_re='^[A-Za-z0-9_]+/[A-Za-z0-9_.-]+$'
declare -a _skill_ids=()
declare -a _skill_slugs=()

if [ -n "${AI_STUDIO_SKILLS:-}" ]; then
    IFS=',' read -ra _raw_skills <<< "$AI_STUDIO_SKILLS"
    for entry in "${_raw_skills[@]}"; do
        # Trim whitespace
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [ -z "$entry" ] && continue
        if [[ ! "$entry" =~ $_skill_re ]]; then
            _skill_err "rejected invalid skill ID: '$entry' (expected <Category>/<Name>)"
            continue
        fi
        # Compute slug: lowercase, "/" → "-"
        slug="${entry,,}"
        slug="${slug//\//-}"
        _skill_ids+=("$entry")
        _skill_slugs+=("$slug")
    done
fi

# ─── Optional git fetch (single sparse clone for base + skills) ──────────────
# Runs whenever AI_STUDIO_SKILLS_REPO is set, regardless of whether any
# skills are listed — so a fresh base CONTEXT.md.tpl can flow in even
# without per-skill activation.
SKILLS_REPO="${AI_STUDIO_SKILLS_REPO:-}"
SKILLS_REF="${AI_STUDIO_SKILLS_REF:-main}"
SKILLS_PATH="${AI_STUDIO_SKILLS_PATH:-skills}"
FETCH_DIR="/var/lib/clouve/skills-fetch"
FETCH_OK=0

if [ -n "$SKILLS_REPO" ]; then
    if ! command -v git &>/dev/null; then
        _skill_warn "git not installed yet — falling back to bundled assets for this start."
    else
        _skill_log "Fetching from $SKILLS_REPO@$SKILLS_REF..."
        rm -rf "$FETCH_DIR"
        mkdir -p "$(dirname "$FETCH_DIR")"

        # Always include the base template; add each requested skill.
        declare -a _sparse_paths=("$SKILLS_PATH/CONTEXT.md.tpl")
        for entry in "${_skill_ids[@]}"; do
            _sparse_paths+=("$SKILLS_PATH/$entry")
        done

        # Authentication: bearer token via http.extraHeader (never embedded
        # in the URL or echoed). For HTTPS repos only.
        declare -a _git_auth_args=()
        if [ -n "${AI_STUDIO_SKILLS_TOKEN:-}" ]; then
            _git_auth_args=(-c "http.extraHeader=Authorization: bearer $AI_STUDIO_SKILLS_TOKEN")
        fi

        if git "${_git_auth_args[@]}" clone \
                --depth=1 \
                --filter=blob:none \
                --sparse \
                --branch "$SKILLS_REF" \
                "$SKILLS_REPO" \
                "$FETCH_DIR" 2>&1 | sed 's/^/  /' \
            && (cd "$FETCH_DIR" && git "${_git_auth_args[@]}" sparse-checkout set "${_sparse_paths[@]}" 2>&1 | sed 's/^/  /'); then
            FETCH_OK=1
            _skill_log "Git fetch complete."
        else
            _skill_warn "git fetch failed — falling back to bundled."
            rm -rf "$FETCH_DIR"
        fi
    fi
fi

# ─── Stage base CONTEXT.md.tpl (always) ──────────────────────────────────────
# Read by .bash_profile's _clv_write_context() as the platform-wide
# CLAUDE.md/GEMINI.md/AGENTS.md skeleton.
base_src=""
base_label=""
if [ "$FETCH_OK" = "1" ] && [ -f "$FETCH_DIR/$SKILLS_PATH/CONTEXT.md.tpl" ]; then
    base_src="$FETCH_DIR/$SKILLS_PATH/CONTEXT.md.tpl"
    base_label="git"
elif [ -f "/clouve/skills-bundled/CONTEXT.md.tpl" ]; then
    base_src="/clouve/skills-bundled/CONTEXT.md.tpl"
    base_label="bundled"
fi

if [ -n "$base_src" ]; then
    cp "$base_src" /clouve/skills/CONTEXT.md.tpl
    chmod a+r /clouve/skills/CONTEXT.md.tpl
    _skill_log "loaded base CONTEXT.md.tpl (source=$base_label)"
else
    _skill_err "base CONTEXT.md.tpl not found in git or bundled — context rendering will silently no-op."
fi

# ─── Materialise each requested skill into /clouve/skills/<slug>/ ────────────
ACTIVE_FILE="/clouve/skills/.active"
: > "$ACTIVE_FILE"

if [ ${#_skill_ids[@]} -eq 0 ]; then
    _skill_log "AI_STUDIO_SKILLS unset — base context only, no per-skill sections."
    return 0 2>/dev/null || exit 0
fi

for i in "${!_skill_ids[@]}"; do
    entry="${_skill_ids[$i]}"
    slug="${_skill_slugs[$i]}"
    src=""
    src_label=""

    if [ "$FETCH_OK" = "1" ] && [ -d "$FETCH_DIR/$SKILLS_PATH/$entry" ]; then
        src="$FETCH_DIR/$SKILLS_PATH/$entry"
        src_label="git"
    elif [ -d "/clouve/skills-bundled/$entry" ]; then
        src="/clouve/skills-bundled/$entry"
        src_label="bundled"
    fi

    if [ -z "$src" ]; then
        _skill_err "skill '$entry' not found in git or bundled sources — skipped."
        continue
    fi

    rm -rf "/clouve/skills/$slug"
    mkdir -p "/clouve/skills/$slug"
    cp -R "$src/." "/clouve/skills/$slug/"
    # Make the tree readable+writable for the tenant agent (matches the
    # gibbon-derived image's chmod -R a+rwX on its baked skill).
    chmod -R a+rwX "/clouve/skills/$slug" 2>/dev/null
    printf '%s\t%s\n' "$slug" "$entry" >> "$ACTIVE_FILE"
    _skill_log "loaded $entry → /clouve/skills/$slug (source=$src_label)"
done

if [ ! -s "$ACTIVE_FILE" ]; then
    _skill_warn "no skills successfully loaded."
fi

unset _skill_ids _skill_slugs _raw_skills _sparse_paths _git_auth_args \
      _skill_re entry slug src src_label SKILLS_REPO SKILLS_REF SKILLS_PATH \
      FETCH_DIR FETCH_OK ACTIVE_FILE base_src base_label
