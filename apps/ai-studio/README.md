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
3. **Context file** — a server-awareness context file is written into the client's config directory (e.g. `~/.claude/CLAUDE.md`, `~/.gemini/GEMINI.md`) from a template bundled in the image.
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

1. Add one entry to each parallel array in `chat/.bash_profile` (`CLV_NAMES`, `CLV_CMDS`, `CLV_INSTALLS`, `CLV_KEY_VARS`, `CLV_KEY_FILES`, `CLV_KEY_LABELS`, `CLV_CONTEXT_TPLS`, `CLV_CONTEXT_DIRS`, `CLV_CONTEXT_FILES`, `CLV_AUTO_FLAGS`, `CLV_STD_FLAGS`).
2. Create the corresponding install script at `chat/<client>/install.sh`.
3. Add validation logic for the client's API endpoint in `_clv_validate_key`.
4. `chmod +x` the new install script in the Dockerfile.

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
- `image/installer/init.sh` — Bootstrap script (seeds `/usr` and `/var` from image snapshots into Kubernetes PVCs on first start)
- `image/installer/entrypoint.sh` — Startup script (user creation, dev tool install, session setup, ttyd, Filebrowser, nginx)
- `image/installer/nginx-default.conf` — nginx site config proxying `/chat` → ttyd and `/files/` → Filebrowser; serves landing page at `/`
- `image/installer/index.html` — Landing page at `/` with navigation cards for the AI Studio terminal and File Manager
- `image/installer/chat/install.sh` — Dev tools install + session environment setup + ttyd startup (runs at container start)
- `image/installer/chat/.bash_profile` — Interactive AI client selector (runs at each terminal session start)
- `image/installer/chat/claude/install.sh` — Claude Code installer (sourced by `.bash_profile` on first use)
- `image/installer/chat/claude/CLAUDE.md.tpl` — Claude Code server context template (rendered into `~/.claude/CLAUDE.md`)
- `image/installer/chat/gemini/install.sh` — Gemini CLI installer (sourced by `.bash_profile` on first use)
- `image/installer/chat/gemini/GEMINI.md.tpl` — Gemini CLI server context template (rendered into `~/.gemini/GEMINI.md`)
- `image/installer/chat/openai/install.sh` — OpenAI Codex CLI installer (sourced by `.bash_profile` on first use)
- `image/installer/files/install.sh` — Filebrowser Quantum install script
- `image/installer/files/filebrowser-config.yaml` — Filebrowser Quantum configuration (port, base URL, auth)
- `image/installer/files/pam-filebrowser` — PAM service configuration for Filebrowser authentication
- `image/build.config` — Build configuration for the centralized build script
- `docker-compose.yml` — Container orchestration for local development/testing
- `clv-docker-compose.yml` — Clouve marketplace manifest

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
