# Skills

Canonical source for AI Studio skill content. Each subdirectory under a top-level category is a single, self-contained skill that an ai-studio container can activate by name via the `AI_STUDIO_SKILLS` env var.

## On-disk layout

```
skills/
├── CONTEXT.md.tpl                    # Base AI Studio context template (always staged)
├── DevOps/
│   ├── Gibbon/
│   │   ├── CONTEXT.md.tpl            # Skill persona section (required)
│   │   └── skill/                    # Anthropic-style SKILL.md tree (optional)
│   │       ├── SKILL.md
│   │       ├── learnings.md
│   │       ├── playbooks/
│   │       ├── reference/
│   │       └── scripts/
│   └── Moodle/
│       └── CONTEXT.md.tpl            # Persona only — no skill/ tree yet
└── Web_Development/
    ├── MERN/
    │   └── CONTEXT.md.tpl
    └── Next.js/
        └── CONTEXT.md.tpl
```

A skill is identified by its **`<Category>/<Name>`** path. Category and Name must each match `[A-Za-z0-9_]+` and `[A-Za-z0-9_.-]+` respectively (strict regex enforced by the loader to block path traversal).

## Two file roles

### `skills/CONTEXT.md.tpl` (base template)

The platform-wide skeleton that gets rendered as the agent's main context file (`~/.claude/CLAUDE.md`, `~/.gemini/GEMINI.md`, or `~/.codex/AGENTS.md` — whichever client the user selects). It documents the `/_clv/` namespace protection, persistent paths, the network constraint, and other AI-Studio-wide guardrails. It is **always staged**, regardless of `AI_STUDIO_SKILLS`. Edits here affect every container.

### `<Category>/<Name>/CONTEXT.md.tpl` (per-skill section)

A composable section appended under a `## Skill: <Category> / <Name>` header to the rendered context file when the skill is active. Author it as section content:

- No leading `# H1` (the renderer emits the H2 skill heading itself).
- Use `### H3` for subsections so the in-file hierarchy stays clean (skill heading is H2 → subsections H3).
- Reference any env vars the deployment will set with `${VAR}` syntax — `envsubst` interpolates them at login time. Values for `${AI_STUDIO_HOST}`, `${USERNAME}`, `${ROOT_PASSWORD}` are always available; per-app vars (`${GIBBON_HOST}`, `${CLOUVE_OPS_PASSWORD}`, etc.) are whatever the deployment puts on the container.

### `<Category>/<Name>/skill/` (optional Anthropic-style payload)

A full Claude Code skill package: `SKILL.md` at the root (with YAML frontmatter), plus any of `playbooks/`, `reference/`, `scripts/`, `learnings.md`. At login time the symlink helper mounts it at `~/.claude/skills/<slug>/`, where Claude Code's native skill loader picks it up. Symlinks also land in `~/.gemini/skills/<slug>/` and `~/.codex/skills/<slug>/` for symmetry — those clients don't auto-load skills today, but the path is stable for the agent to reference.

## Activation and slugs

```yaml
environment:
  AI_STUDIO_SKILLS: DevOps/Gibbon,DevOps/Moodle
```

Each comma-separated entry maps to a directory under `skills/`. The loader computes a **slug** by lowercasing the ID and replacing `/` with `-`:

| ID                  | Slug              | Mounted at                            |
| ------------------- | ----------------- | ------------------------------------- |
| `DevOps/Gibbon`     | `devops-gibbon`   | `/clouve/skills/devops-gibbon/`       |
| `DevOps/Moodle`     | `devops-moodle`   | `/clouve/skills/devops-moodle/`       |
| `Web_Development/MERN` | `web_development-mern` | `/clouve/skills/web_development-mern/` |

Order matters: the rendered context file appends skill sections in the order given in `AI_STUDIO_SKILLS`.

## Adding a new skill

1. Pick a category (existing — `DevOps`, `Web_Development` — or create a new one with a CamelCase or `Snake_Case` name).
2. Create `skills/<Category>/<Name>/CONTEXT.md.tpl` with the persona section. Start with the persona prose, no leading `# H1`. Use `${VAR}` for any deployment-specific values.
3. (Optional) Create `skills/<Category>/<Name>/skill/SKILL.md` plus any supporting `playbooks/`, `reference/`, `scripts/` for the Anthropic-style payload.
4. Set `AI_STUDIO_SKILLS=<Category>/<Name>` (or include it in a comma-separated list) on the ai-studio service. Rebuild ai-studio if you want the new skill in the offline-fallback bake; otherwise set `AI_STUDIO_SKILLS_REPO` and the loader will sparse-clone the skill on every container start.

## Source priority at runtime

The loader resolves each asset (base template + each per-skill subdir) in this order:

1. **Git fetch** — when `AI_STUDIO_SKILLS_REPO` is set, a single sparse `git clone` pulls just the needed paths into `/var/lib/clouve/skills-fetch/`. Lets skill iteration happen without rebuilding the image.
2. **Baked fallback** — `/clouve/skills-bundled/`, populated from this directory at image build time by `apps/ai-studio/image/prebuild.sh`.

A failed git fetch falls through to the baked copy with a warning. Missing/invalid skills are logged and skipped — container init never aborts on a skill-loading error.

## Where to learn more

- [`apps/ai-studio/README.md`](../apps/ai-studio/README.md#ai-skills) — runtime/loader details, env var reference, full deployment context
- [`apps/ai-studio/image/installer/chat/skills.sh`](../apps/ai-studio/image/installer/chat/skills.sh) — the loader (heavily commented)
- [`apps/ai-studio/image/installer/chat/.bash_profile`](../apps/ai-studio/image/installer/chat/.bash_profile) — `_clv_write_context()` is what merges the base template with the per-skill sections
- [`apps/ai-studio/image/installer/profile.d/clv-skills.sh`](../apps/ai-studio/image/installer/profile.d/clv-skills.sh) — login-time symlink helper
