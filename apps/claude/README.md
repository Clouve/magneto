# Claude Code Server Docker Application

Custom Ubuntu 24.04 LTS server image with a browser-based web terminal and Claude Code pre-installed and pre-configured.

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

### Web Terminal
Open your browser and navigate to:
- **URL**: http://localhost:8080/chat
- **Username**: `admin`
- **Password**: `Admin@123`

All other paths redirect to `/chat`.

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

Claude Code is pre-installed and pre-configured. When `ANTHROPIC_API_KEY` is set, the container automatically:

- Exports the key into every shell session via `/etc/profile.d/`
- Writes `~/.claude.json` with completed onboarding state so the first-run wizard is skipped
- Auto-launches `claude` when a login shell is opened in the web terminal

No login prompt, no manual setup.

### Updating the API Key

Update `ANTHROPIC_API_KEY` in `docker-compose.yml` and restart the container — the key is re-injected at startup:

```bash
docker compose down && docker compose up -d
```

## Features

- Ubuntu 24.04 LTS base image
- Multi-platform support (amd64 and arm64)
- [Claude Code](https://claude.ai/code) pre-installed and pre-configured (`claude` CLI, Node.js 22)
- Browser-based terminal via [ttyd](https://github.com/tsl0922/ttyd) served at `/chat` (HTTP basic auth)
- nginx reverse proxy routing `/chat` to ttyd on localhost; all other paths redirect to `/chat`
- Common CLI tools: `curl`, `wget`, `git`, `vim`, `nano`, `htop`, `jq`, `tree`, `unzip`
- Admin user created from environment variables at startup
- Passwordless `sudo` for the admin user
- Persistent home directory volume across container restarts

## Files

- `image/Dockerfile` — Ubuntu 24.04 image with Node.js 22, Claude Code, nginx, ttyd, and CLI tools
- `image/installer/entrypoint.sh` — Startup script (user creation, Claude Code config, ttyd, nginx)
- `image/installer/nginx-default.conf` — nginx site config proxying `/chat` to ttyd
- `image/installer/CLAUDE.md.tpl` — Claude Code context template (rendered at startup via `envsubst`)
- `image/installer/.bash_profile` — Login shell profile (auto-launches `claude` in interactive sessions)
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

### Web terminal not loading
```bash
# Confirm nginx is serving /chat
docker compose exec claude curl -sf http://localhost/chat | head -5

# Confirm ttyd is listening on localhost
docker compose exec claude curl -sf http://localhost:7890/chat | head -5
```

### Claude Code still prompts for login
Ensure `ANTHROPIC_API_KEY` is set in `docker-compose.yml` and the container has been restarted:
```bash
docker compose down && docker compose up -d
# Verify the key is present inside the container
docker compose exec claude cat /etc/profile.d/clouve-env.sh
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
