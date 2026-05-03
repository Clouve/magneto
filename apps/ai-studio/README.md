# AI Studio Docker Application

Custom Ubuntu 24.04 LTS server image with a browser-based web terminal and a web-based file manager — both accessible from your browser with no local setup required.

On each terminal session, an interactive menu prompts the user to choose their preferred AI coding assistant: **Claude Code**, **Gemini CLI**, or **OpenAI Codex CLI**. The selected client is installed on first use and persists across container restarts via the `/usr` volume. Sessions can also be started without an AI client.

## Deployment Context

This container is designed to run in a **Kubernetes cluster behind an ingress controller** (e.g. nginx-ingress with cert-manager). The ingress handles TLS termination and routes external HTTPS traffic to the container over HTTP on port 80. The container itself only speaks plain HTTP — no TLS configuration is required inside the image.

For local development and testing, the container can be run directly with `docker compose`.

## Quick Start

```bash
# Start the container (no API key required — prompted at session start)
docker compose up -d

# Optionally pre-set one or more API keys to skip the per-session key prompt
ANTHROPIC_API_KEY=sk-ant-... docker compose up -d
GEMINI_API_KEY=AIza...      docker compose up -d
OPENAI_API_KEY=sk-...       docker compose up -d

# Stop the container
docker compose down
```

## Access

### Landing Page
Open your browser and navigate to:
- **URL**: http://localhost:8080/

The landing page links to both the web terminal and the file manager.

### Web Terminal (AI Studio)
- **URL**: http://localhost:8080/chat
- **Username**: `admin`
- **Password**: `Admin@123`

### File Manager (Filebrowser Quantum)
- **URL**: http://localhost:8080/files/
- **Username**: `admin`
- **Password**: `Admin@123`

nginx routes `/`, `/chat`, and `/files/` — all other paths return 404.

## Configuration

Edit `docker-compose.yml` to customize environment variables:

```yaml
environment:
  AI_STUDIO_USERNAME: admin          # Admin username
  AI_STUDIO_PASSWORD: Admin@123      # Admin password (web terminal + file manager)
  AI_STUDIO_ROOT_PASSWORD: Root@123  # Root password (available via `su - root`)
  # Optionally pre-set any API key to skip the per-session key prompt:
  ANTHROPIC_API_KEY: sk-ant-...
  GEMINI_API_KEY: AIza...
  OPENAI_API_KEY: sk-...
  # Optionally activate one or more skills from the magneto repo's skills/
  # tree. See "AI Skills" below.
  AI_STUDIO_SKILLS: https://github.com/Clouve/magneto-skills.git?plugins=gibbon,moodle
  AI_STUDIO_SKILLS_GIT_TOKEN: ''                                # for private marketplaces (default for every host)
  # AI_STUDIO_SKILLS_GIT_TOKEN__GITHUB_COM: ''                  # per-host override
```

To override the exposed port at runtime:

```bash
TEST_HTTP_PORT=9090 docker compose up -d
# Web terminal then available at http://localhost:9090/chat
```

## Using the AI Client Selector

When the web terminal opens, an interactive menu appears:

```
  ╔═══════════════════════════════════════════════╗
  ║           Welcome to AI Studio                ║
  ╚═══════════════════════════════════════════════╝

  Which AI coding assistant would you like to use?

    1)  Claude Code
    2)  Gemini CLI
    3)  OpenAI Codex CLI

  Select [1-3]:
```

**What happens next:**

1. **API key resolution** — if an API key for the selected client was provided at container start via an env var, it is used automatically. Otherwise the selector checks for a stored key from a previous session (`~/.{client}_api_key`), validates it live against the provider's API, and if absent or revoked prompts the user to enter one. The key is saved locally for future sessions.
2. **Installation (first use only)** — if the selected CLI is not yet installed, the selector installs it along with any required runtime (e.g. Node.js for Gemini CLI and OpenAI Codex CLI). Installed binaries persist in the `/usr` volume so subsequent sessions skip this step.
3. **Context file** — a server-awareness context file is rendered into the client's config directory (`~/.claude/CLAUDE.md`, `~/.gemini/GEMINI.md`, or `~/.codex/AGENTS.md`). The body is identical across the three clients: a single shared base template (`/clouve/skills/CONTEXT.md.tpl`) followed by one `## Skill: <Category> / <Name>` section for each skill listed in `AI_STUDIO_SKILLS`. Env vars referenced in the templates (`${AI_STUDIO_HOST}`, `${USERNAME}`, plus any app-specific vars like `${GIBBON_HOST}`) are interpolated by `envsubst` at render time. See [AI Skills](#ai-skills) below.
4. **Launch mode** — for clients that support an auto-accept mode, a numbered prompt appears:
   ```
   Claude Code is ready.
   Would you like to run in auto-accept mode?

     1)  Yes — run in auto-accept mode
     2)  No  — run in standard/interactive mode

   Select [1-2]:
   ```
   Auto-accept flags (`--dangerously-skip-permissions` for Claude Code, `--yolo` for Gemini CLI) are defined in the client registry and passed only when the user selects option 1. Clients without an auto-accept mode (OpenAI Codex CLI) skip this prompt.
5. **Persistent session loop** — after the client exits for any reason (normal quit, crash, or Ctrl+C inside the client), the selector menu is presented again automatically. The session never drops to a bare shell.
6. **Session persistence** — the last selection is cached in `~/.ai-studio/last-client`. On the next session, the selector offers to reuse it: `Use Claude Code again? [Y/n]`.

### Security notes

- The `clv-session` wrapper discards all ttyd URL query parameters (`?arg=`) to prevent bypassing `.bash_profile` from the browser.
- `BASH_ENV` and `ENV` are unset in `.bash_profile` so AI client subshells cannot source arbitrary files.
- `SIGINT`/`SIGTERM` are trapped during the selection menu and API key prompt, preventing Ctrl+C escape to a bare shell. The trap is cleared before the client launches so the client handles its own signals normally, then re-armed when the menu reappears.
- Set `AI_STUDIO_MAINTENANCE_MODE=true` in the container environment to bypass the selector entirely and open a plain shell (useful for administrative access without going through the menu).

### Updating an API Key

Update the key in `docker-compose.yml` and restart the container — the key is re-injected at startup via `/etc/profile.d/clouve-env.sh`:

```bash
docker compose down && docker compose up -d
```

To change a stored key from inside a running session, delete the saved key file:

```bash
rm ~/.claude_api_key    # for Claude Code
rm ~/.gemini_api_key    # for Gemini CLI
rm ~/.openai_api_key    # for OpenAI Codex CLI
```

### Adding a New AI Client

The selector is fully data-driven. To add a new client:

1. Add one entry to each parallel array in `chat/.bash_profile` (`CLV_NAMES`, `CLV_IDS`, `CLV_CMDS`, `CLV_INSTALLS`, `CLV_KEY_VARS`, `CLV_KEY_FILES`, `CLV_KEY_LABELS`, `CLV_KEY_URLS`, `CLV_CONTEXT_DIRS`, `CLV_CONTEXT_FILES`, `CLV_AUTO_FLAGS`, `CLV_STD_FLAGS`). The base context template path is shared across all clients (`CLV_CONTEXT_TPL` scalar) — only the destination dir/filename are per-client.
2. Create the corresponding install script at `chat/<client>/install.sh`.
3. Add validation logic for the client's API endpoint in `_clv_validate_key`.
4. `chmod +x` the new install script in the Dockerfile.

## AI Skills

AI Studio loads plugins from one or more **Claude Code plugin marketplaces** at container start. Each marketplace is a git repository following the [Claude Code marketplace spec](https://code.claude.com/docs/en/plugin-marketplaces) (a `.claude-plugin/marketplace.json` listing one or more plugins). Plugin SKILL.md trees are surfaced to the active AI client; per-plugin persona sections are composed from this repo's local [`context/`](../../context) directory.

Activate marketplaces via the `AI_STUDIO_SKILLS` env var on the ai-studio service.

### URL format

`AI_STUDIO_SKILLS` is a comma-separated list of marketplace repository URLs. Each URL may include:

- `?plugins=<name1>,<name2>` — load only the named plugins (default = all plugins in the marketplace).
- `#<branch>` — pin to a specific branch (default = `main`).

```yaml
environment:
  # Single marketplace, all plugins, default branch
  AI_STUDIO_SKILLS: https://github.com/Clouve/magneto-skills.git

  # Subset filter
  AI_STUDIO_SKILLS: https://github.com/Clouve/magneto-skills.git?plugins=gibbon,moodle

  # Pinned branch
  AI_STUDIO_SKILLS: https://github.com/Clouve/magneto-skills.git?plugins=gibbon#release/2026-q2

  # Multiple marketplaces (e.g. Clouve's plus a partner's)
  AI_STUDIO_SKILLS: https://github.com/Clouve/magneto-skills.git,https://gitlab.com/somepartner/skills.git?plugins=helpdesk

  # Self-hosted GitLab
  AI_STUDIO_SKILLS: https://git.internal.clouve.com/devops/skills.git#main
```

The loader works against any HTTPS-speaking git host (GitHub, GitLab incl. self-hosted, Bitbucket, Gitea / Forgejo, etc.). When the same plugin name appears in multiple marketplaces, **first occurrence wins** (in `AI_STUDIO_SKILLS` list order) — the duplicate is logged and skipped.

### What gets staged

For each active plugin:

- `/clouve/skills/<plugin>/plugin/` — full plugin payload (the entire plugin tree from the marketplace, including `.claude-plugin/`, `skills/`, `commands/`, `agents/`, etc.).
- `/clouve/skills/<plugin>/CONTEXT.md.tpl` — the per-plugin persona section, copied from this repo's `context/<plugin>/CONTEXT.md.tpl` baked into the image.

The base context template lives at `/clouve/context/CONTEXT.md.tpl` (baked from this repo's `context/CONTEXT.md.tpl`) and is always staged regardless of which plugins are active. At each interactive login, [`profile.d/clv-skills.sh`](image/installer/profile.d/clv-skills.sh) walks each plugin's `plugin/skills/<skill-name>/` and symlinks the skill into `~/.claude/skills/<skill-name>/`, `~/.gemini/skills/<skill-name>/`, and `~/.codex/skills/<skill-name>/`. Claude Code natively auto-loads its `~/.claude/skills/` entries; Gemini and Codex don't yet have a built-in skills-directory convention, so for those clients the skill content reaches the agent through the `## Skill: <plugin>` section appended to the merged `GEMINI.md` / `AGENTS.md`.

### The local `context/` directory

The repo-local [`context/`](../../context) tree holds AI-Studio–specific persona templates that the loader composes into each session's context file. It is **not** part of the marketplace contract — it is private to this repo and is baked into the AI Studio image at build time.

```
context/
├── CONTEXT.md.tpl         # Base context (always rendered)
├── gibbon/CONTEXT.md.tpl  # Persona section for the `gibbon` plugin
└── moodle/CONTEXT.md.tpl  # Persona section for the `moodle` plugin
```

The directory name under `context/` **must equal** the plugin's `name` field in the marketplace's `marketplace.json`. Plugin name regex: `[a-z0-9][a-z0-9_-]*` (lowercase, no slashes). A plugin may exist in a marketplace without a corresponding `context/<plugin>/CONTEXT.md.tpl` (the SKILL.md tree is still staged; the context section is silently omitted with a warning), and a `context/<plugin>/CONTEXT.md.tpl` may exist without any active plugin claiming it.

### Authentication for private marketplaces

Credentials are resolved per-host from env vars and injected at clone time via `GIT_ASKPASS` — never persisted to disk, embedded in URLs, or written to `.netrc`/`.git/config`.

| Var | Purpose |
| --- | --- |
| `AI_STUDIO_SKILLS_GIT_TOKEN` | Default token for every host. |
| `AI_STUDIO_SKILLS_GIT_USERNAME` | Optional default username override. |
| `AI_STUDIO_SKILLS_GIT_TOKEN__<HOST>` | Per-host token; takes precedence over the default. |
| `AI_STUDIO_SKILLS_GIT_USERNAME__<HOST>` | Per-host username override. |

`<HOST>` is the host uppercased with dots and dashes replaced by underscores: `github.com` → `GITHUB_COM`, `git.internal.clouve.com` → `GIT_INTERNAL_CLOUVE_COM`.

Username defaults when only a token is provided:

| Host | Default username |
| --- | --- |
| `github.com` | `x-access-token` |
| `gitlab.com` | `oauth2` |
| `bitbucket.org` | `x-token-auth` |
| anything else (incl. self-hosted) | `git` (token-as-password convention) |

Self-hosted GitLab/Gitea instances default to `git` because we cannot identify them from the hostname alone — set `AI_STUDIO_SKILLS_GIT_USERNAME__<HOST>` explicitly if your host needs a different username (e.g. `oauth2` for self-hosted GitLab).

If no token is configured for the host, the loader attempts an unauthenticated clone (works for public repos). On a 401/403 against a private repo with no token configured, the loader logs a clear error naming the host, repo, and the env var that would have supplied credentials, and continues with the next entry.

### Error handling

Each marketplace entry and each plugin within a marketplace is loaded independently — failures are logged and skipped, never fatal:

- Invalid URL → entry skipped.
- Clone failure (network, auth, missing branch) → entry skipped.
- Missing or malformed `marketplace.json` → entry skipped.
- Plugin filter references a name not in the marketplace → warning, continue with the rest.
- Plugin `source` doesn't exist in the working tree → plugin skipped.
- External plugin source clone failure → plugin skipped.
- Duplicate plugin name across marketplaces → first wins, subsequent occurrences skipped with a warning.
- Active plugin with no matching `context/<plugin>/CONTEXT.md.tpl` → context section omitted with a warning; SKILL.md tree still staged.
- Base `context/CONTEXT.md.tpl` missing → warning; rendered context falls back to the per-plugin sections only.

After processing the full list, the loader logs a summary: `<n> plugins loaded from <m> marketplaces, <k> skipped; <c> context sections composed`.

### Migrating from the old `<Category>/<Name>` format

The previous `AI_STUDIO_SKILLS=DevOps/Gibbon,DevOps/Moodle` format and the `AI_STUDIO_SKILLS_REPO` / `_REF` / `_PATH` / `_TOKEN` env vars are **fully removed** — there is no fallback. Update each `AI_STUDIO_SKILLS` value to one or more marketplace URLs, and replace the old token env var with `AI_STUDIO_SKILLS_GIT_TOKEN__<HOST>` (or the host-agnostic `AI_STUDIO_SKILLS_GIT_TOKEN`).

## Deploying Services

**Only port 80 is open externally.** Any service you run on a non-standard port must be proxied through nginx using a path-based location block to be reachable from the outside. For example, to expose a React app on port 3000:

```nginx
location /app {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
}
```

After editing the nginx config, reload it:

```bash
sudo nginx -s reload
```

The service is then accessible at `https://<your-domain>/app`.

Note: `/files/` is already reserved for Filebrowser Quantum — choose a different prefix for any additional services.

## Volumes

Four persistent volumes are used. On first start, `/usr` and `/var` are seeded from image snapshots bundled in the image (`/clouve/usr-seed.tar.gz`, `/clouve/var-seed.tar.gz`). A sentinel file (`.clouve-seeded`) is written inside each volume after successful seeding; subsequent starts skip extraction to preserve any changes made at runtime.

| Volume | Mount | Default size | Contents |
|--------|-------|-------------|----------|
| `ai-studio-home` | `/home` | 10 Gi | User home directories |
| `ai-studio-usr` | `/usr` | 10 Gi | System binaries and libraries (AI clients installed here) |
| `ai-studio-opt` | `/opt` | 10 Gi | Optional / third-party software |
| `ai-studio-var` | `/var` | 10 Gi | Package DB, cache, logs, web files |

## Features

- Ubuntu 24.04 LTS base image
- Multi-platform support (amd64 and arm64)
- Interactive AI client selector at each session start — choose Claude Code, Gemini CLI, or OpenAI Codex CLI (or none)
- AI clients installed on first use and persisted in the `/usr` volume
- Browser-based terminal via [ttyd](https://github.com/tsl0922/ttyd) served at `/chat` (HTTP basic auth)
- Web-based file manager via [Filebrowser Quantum](https://github.com/gtsteffaniak/filebrowser) served at `/files/` (PAM auth)
- Landing page at `/` with navigation links to both the web terminal and the file manager
- nginx reverse proxy routing `/chat` → ttyd (localhost:7890) and `/files/` → Filebrowser (localhost:6070)
- API key gating: requires a valid provider API key before launching the selected AI client
- Session caching: last-used client is remembered and offered as the default on next session
- Admin user created from environment variables at startup with passwordless `sudo`
- Four persistent volumes for `/home`, `/usr`, `/opt`, `/var` — seeded from image snapshots on first start

## Files

- `image/Dockerfile` — Ubuntu 24.04 image with nginx, ttyd, Filebrowser Quantum, and CLI tools
- `image/prebuild.sh` — Build hook that stages the repo-root `context/` tree into `image/context-bundled/` (gitignored) so the Dockerfile can `COPY` it into `/clouve/context/`
- `image/postbuild.sh` — Build hook (run via EXIT-trap) that removes the staged `image/context-bundled/` after the image build completes
- `image/installer/init.sh` — Bootstrap script (seeds `/usr` and `/var` from image snapshots into Kubernetes PVCs on first start)
- `image/installer/entrypoint.sh` — Startup script (user creation, dev tool install, session setup, ttyd, Filebrowser, nginx)
- `image/installer/nginx-default.conf` — nginx site config proxying `/chat` → ttyd and `/files/` → Filebrowser; serves landing page at `/`
- `image/installer/index.html` — Landing page at `/` with navigation cards for the AI Studio terminal and File Manager
- `image/installer/chat/install.sh` — Dev tools install + session environment setup + skill loader source + ttyd startup (runs at container start)
- `image/installer/chat/.bash_profile` — Interactive AI client selector (runs at each terminal session start). Renders the merged context file via `_clv_write_context()`.
- `image/installer/chat/skills.sh` — Marketplace loader entry point. Sources the modules under `image/installer/chat/marketplace/` and invokes the orchestrator.
- `image/installer/chat/marketplace/loader.sh` — Top-level orchestrator: parses `AI_STUDIO_SKILLS`, runs the per-marketplace pipeline, deduplicates plugins by name (first-wins), writes `/clouve/skills/.active`.
- `image/installer/chat/marketplace/url-parser.sh` — Parses a marketplace URL into (host, clone URL, branch, plugin filter).
- `image/installer/chat/marketplace/credentials.sh` — Per-host credential resolution from env vars.
- `image/installer/chat/marketplace/git-fetcher.sh` — Clones with credentials injected via `GIT_ASKPASS`, deduplicates clones.
- `image/installer/chat/marketplace/git-askpass-helper.sh` — `GIT_ASKPASS` helper script.
- `image/installer/chat/marketplace/marketplace-reader.sh` — Reads `.claude-plugin/marketplace.json`, applies plugin filter.
- `image/installer/chat/marketplace/plugin-stager.sh` — Stages plugin payload + per-plugin context template, recursively resolves external plugin sources.
- `image/installer/chat/marketplace/context-composer.sh` — Composes `~/.{claude,gemini,codex}/{CLAUDE,GEMINI,AGENTS}.md` from base + per-plugin sections, runs `envsubst`.
- `image/installer/chat/claude/install.sh` — Claude Code installer (sourced by `.bash_profile` on first use)
- `image/installer/chat/gemini/install.sh` — Gemini CLI installer (sourced by `.bash_profile` on first use)
- `image/installer/chat/openai/install.sh` — OpenAI Codex CLI installer (sourced by `.bash_profile` on first use)
- `image/installer/profile.d/clv-skills.sh` — Login-time hook installed at `/etc/profile.d/clv-skills.sh`. Reads `/clouve/skills/.active` and creates `~/.claude/skills/<skill-name>/`, `~/.gemini/skills/<skill-name>/`, `~/.codex/skills/<skill-name>/` symlinks for each active plugin's skill tree.
- `image/installer/files/install.sh` — Filebrowser Quantum install script
- `image/installer/files/filebrowser-config.yaml` — Filebrowser Quantum configuration (port, base URL, auth)
- `image/installer/files/pam-filebrowser` — PAM service configuration for Filebrowser authentication
- `image/build.config` — Build configuration for the centralized build script
- `docker-compose.yml` — Container orchestration for local development/testing
- `clv-docker-compose.yml` — Clouve marketplace manifest

The base context template lives at the top of the magneto repo's [`context/`](../../context) tree (`context/CONTEXT.md.tpl`), not under `apps/ai-studio/`. It's baked into the image at `/clouve/context/CONTEXT.md.tpl` (via `prebuild.sh`) and consumed at runtime by the marketplace loader's context composer.

## Building and Pushing Images

Use the centralized build script from the `magneto/` directory:

```bash
# Build locally
../../build.sh apps/ai-studio

# Build and push multi-platform image to registry (amd64 + arm64)
../../build.sh apps/ai-studio --push
```

For more information about the build system, see the [Build Script Documentation](../../README.md).

## Troubleshooting

### Container won't start
```bash
docker compose logs ai-studio
```

### Volume seeding failure on first start
If you see `[init] ERROR: failed to seed /usr` or `[init] ERROR: failed to seed /var` in the logs, the seeding failed (e.g. due to a conflict with directories pre-created by the container runtime). The sentinel file was not written, so seeding will be retried automatically on the next start:

```bash
docker compose restart ai-studio
```

### Web terminal not loading
```bash
# Confirm nginx is serving /chat
docker compose exec ai-studio curl -sf http://localhost/chat | head -5

# Confirm ttyd is listening on localhost
docker compose exec ai-studio curl -sf http://localhost:7890/chat | head -5
```

### File manager not loading
```bash
# Confirm nginx is routing /files/
docker compose exec ai-studio curl -sf http://localhost/files/ | head -5

# Confirm Filebrowser is listening on localhost
docker compose exec ai-studio curl -sf http://localhost:6070 | head -5
```

### AI client not installing
If an install fails, check that `/usr` has sufficient space and that the container has internet access:
```bash
docker compose exec ai-studio curl -sf https://api.anthropic.com/v1/models | head -5
```

### API key rejected at login
A previously saved key may have been revoked. The login shell validates stored keys automatically and clears them if rejected. You can also clear manually:
```bash
rm ~/.claude_api_key    # for Claude Code
rm ~/.gemini_api_key    # for Gemini CLI
rm ~/.openai_api_key    # for OpenAI Codex CLI
```

## Production Deployment Checklist

- [ ] Set strong passwords via `AI_STUDIO_USERNAME`, `AI_STUDIO_PASSWORD`, `AI_STUDIO_ROOT_PASSWORD`
- [ ] Optionally pre-set API keys (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`)
- [ ] Provision four PVCs with at least 10 Gi each for home, usr, opt, var
- [ ] Configure ingress with TLS termination pointing to port 80
- [ ] Verify health check passes at `GET /` (port 80, expected 200)
