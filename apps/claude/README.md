# Claude Code Server Docker Application

Custom Ubuntu 24.04 LTS server image with a browser-based web terminal (Claude Code) and a web-based file manager (Filebrowser Quantum) — both pre-installed and pre-configured.

## Deployment Context

This container is designed to run in a **Kubernetes cluster behind an ingress controller** (e.g. nginx-ingress with cert-manager). The ingress handles TLS termination and routes external HTTPS traffic to the container over HTTP on port 80. The container itself only speaks plain HTTP — no TLS configuration is required inside the image.

For local development and testing, the container can be run directly with `docker compose`.

## Quick Start

```bash
# Start the container
ANTHROPIC_API_KEY=sk-ant-... docker compose up -d

# Stop the container
docker compose down
```

## Access

### Landing Page
Open your browser and navigate to:
- **URL**: http://localhost:8080/

The landing page links to both the web terminal and the file manager.

### Web Terminal (Claude Code)
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
  CLAUDE_USERNAME: admin             # Admin username
  CLAUDE_PASSWORD: Admin@123         # Admin password (web terminal)
  CLAUDE_ROOT_PASSWORD: Root@123     # Root password
  ANTHROPIC_API_KEY: sk-ant-...      # Anthropic API key for Claude Code
```

To override the exposed port at runtime:

```bash
TEST_HTTP_PORT=9090 docker compose up -d
# Web terminal then available at http://localhost:9090/chat
```

## Using Claude Code

Claude Code is pre-installed and pre-configured. When the web terminal opens, the following happens automatically:

1. **Onboarding skipped** — `~/.claude.json` is pre-written with `hasCompletedOnboarding: true` so the first-run wizard never appears.
2. **API key resolution** — the login shell resolves the key in this order:
   - `ANTHROPIC_API_KEY` env var injected at container startup via `/etc/profile.d/clouve-env.sh` (set when `ANTHROPIC_API_KEY` is provided in `docker-compose.yml`)
   - Stored key from `~/.claude_api_key` (saved from a previous session) — validated against the Anthropic API before use; cleared and re-prompted if revoked
   - Interactive prompt — user enters a key, it is validated live, saved to `~/.claude_api_key`, and the session proceeds; Ctrl+C exits without granting shell access
3. **Permission prompts** — user is asked whether to run `claude --dangerously-skip-permissions` (default: yes, press Enter).
4. **Claude Code launches** automatically.

### Security notes

- The `clv-session` wrapper discards all ttyd URL query parameters (`?arg=`) to prevent bypassing `.bash_profile` from the browser.
- `BASH_ENV` and `ENV` are unset in `.bash_profile` so Claude Code's own `bash -l` subshells cannot source arbitrary files.
- `SIGINT`/`SIGTERM` are trapped until the API key gate is passed, preventing Ctrl+C escape to a bare shell.

### Updating the API Key

Update `ANTHROPIC_API_KEY` in `docker-compose.yml` and restart the container — the key is re-injected at startup:

```bash
docker compose down && docker compose up -d
```

To change a stored key without restarting the container, delete the saved key file from inside the terminal:

```bash
rm ~/.claude_api_key
```

The next login will prompt for a new key.

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
| `claudehome` | `/home` | 10 Gi | User home directories |
| `claudeusr` | `/usr` | 10 Gi | System binaries and libraries |
| `claudeopt` | `/opt` | 10 Gi | Optional / third-party software |
| `claudevar` | `/var` | 10 Gi | Package DB, cache, logs, web files |

## Features

- Ubuntu 24.04 LTS base image
- Multi-platform support (amd64 and arm64)
- [Claude Code](https://claude.ai/code) pre-installed and pre-configured via the official install script
- Browser-based terminal via [ttyd](https://github.com/tsl0922/ttyd) served at `/chat` (HTTP basic auth)
- Web-based file manager via [Filebrowser Quantum](https://github.com/gtsteffaniak/filebrowser) served at `/files/` (PAM auth)
- Landing page at `/` with navigation links to both the web terminal and the file manager
- nginx reverse proxy routing `/chat` → ttyd (localhost:7890) and `/files/` → Filebrowser (localhost:6070)
- API key gating: requires a valid Anthropic API key before granting shell access
- Admin user created from environment variables at startup with passwordless `sudo`
- Four persistent volumes for `/home`, `/usr`, `/opt`, `/var` — seeded from image snapshots on first start

## Files

- `image/Dockerfile` — Ubuntu 24.04 image with Claude Code, nginx, ttyd, Filebrowser Quantum, and CLI tools
- `image/installer/init.sh` — Bootstrap script (seeds `/usr` and `/var` from image snapshots into Kubernetes PVCs on first start)
- `image/installer/entrypoint.sh` — Startup script (user creation, Claude Code config, ttyd, Filebrowser, nginx)
- `image/installer/nginx-default.conf` — nginx site config proxying `/chat` → ttyd and `/files/` → Filebrowser; serves landing page at `/`
- `image/installer/index.html` — Landing page at `/` with navigation cards for Claude Code (`/chat`) and File Manager (`/files/`)
- `image/installer/chat/install.sh` — ttyd (web terminal) install script
- `image/installer/chat/CLAUDE.md.tpl` — Claude Code context template rendered at startup via `envsubst` into `~/.claude/CLAUDE.md`
- `image/installer/chat/.bash_profile` — Login shell profile: API key resolution, validation, and auto-launch of `claude`
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
../../build.sh apps/claude

# Build and push multi-platform image to registry (amd64 + arm64)
../../build.sh apps/claude --push
```

For more information about the build system, see the [Build Script Documentation](../../README.md).

## Troubleshooting

### Container won't start
```bash
docker compose logs claude
```

### Volume seeding failure on first start
If you see `[init] ERROR: failed to seed /usr` or `[init] ERROR: failed to seed /var` in the logs, the seeding failed (e.g. due to a conflict with directories pre-created by the container runtime). The sentinel file was not written, so seeding will be retried automatically on the next start:

```bash
docker compose restart claude
```

### Web terminal not loading
```bash
# Confirm nginx is serving /chat
docker compose exec claude curl -sf http://localhost/chat | head -5

# Confirm ttyd is listening on localhost
docker compose exec claude curl -sf http://localhost:7890/chat | head -5
```

### File manager not loading
```bash
# Confirm nginx is routing /files/
docker compose exec claude curl -sf http://localhost/files/ | head -5

# Confirm Filebrowser is listening on localhost
docker compose exec claude curl -sf http://localhost:6070 | head -5

# Check Filebrowser logs
docker compose exec claude journalctl -u filebrowser --no-pager -n 50
```

### Claude Code still prompts for login
Ensure `ANTHROPIC_API_KEY` is set in `docker-compose.yml` and the container has been restarted:
```bash
docker compose down && docker compose up -d
# Verify the key is present inside the container
docker compose exec claude cat /etc/profile.d/clouve-env.sh
```

### Stored API key rejected at login
A previously saved key may have been revoked. The login shell validates stored keys automatically and clears them if rejected. You can also clear it manually:
```bash
docker compose exec -u admin claude rm /home/admin/.claude_api_key
```

### Reset credentials
Update `CLAUDE_PASSWORD` in `docker-compose.yml` and restart:
```bash
docker compose down && docker compose up -d
```

## Production Deployment

Before deploying to production:
1. Change `CLAUDE_PASSWORD` and `CLAUDE_ROOT_PASSWORD` to strong, unique passwords
2. Set `ANTHROPIC_API_KEY` to your Anthropic API key
3. Deploy behind a Kubernetes ingress controller — the ingress handles TLS; the container only needs port 80 exposed
4. Build and push the image: `../../build.sh apps/claude --push`
5. Verify the web terminal is accessible at `/chat` and `claude` launches on login
6. Verify the file manager is accessible at `/files/`
