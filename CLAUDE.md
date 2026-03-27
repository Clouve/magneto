# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Magneto** is a Docker Compose-based system for packaging containerized applications (WordPress, Moodle, Gibbon, LimeSurvey, Odoo, OwnCloud, SuiteCRM, Bluesky PDS, AI Studio) for deployment in Kubernetes-based marketplace environments. It provides standardized structures for single applications and multi-application bundles.

## Common Commands

### Build Images
```bash
# Build a specific app (multi-platform: amd64 + arm64)
./build.sh wordpress
./build.sh apps/wordpress

# Build all apps
./build.sh --all

# Build and push to registry
./build.sh wordpress --push

# Environment-specific builds
./build-dev.sh wordpress
./build-prod.sh wordpress
./build-uat.sh wordpress
```

### Start / Stop Applications
```bash
# Start an app
./start.sh wordpress
./start.sh apps/wordpress

# Start fresh (remove volumes)
./start.sh wordpress --cleanup

# Stop an app
./stop.sh wordpress

# Stop and remove persistent data
./stop.sh wordpress --cleanup
```

### Monitoring & Debugging
```bash
# View logs (follow mode)
./logs.sh wordpress -f

# View last N lines for a specific service
./logs.sh wordpress wordpress -n 50

# Check health and resource usage
./status.sh wordpress
```

### Testing URL Change Detection
```bash
# Test dynamic URL substitution without modifying files
./test.sh apps/wordpress
./test.sh apps/wordpress custom.domain.com custom2.domain.com 8090
./test.sh apps/limesurvey
```

## Architecture

### Project Layout
```
apps/<app-name>/           # Individual application packages
bundles/<bundle-name>/     # Multi-app combinations
build.sh                   # Multi-platform image builder
start.sh / stop.sh         # Orchestration scripts
logs.sh / status.sh        # Monitoring utilities
test.sh                    # URL substitution testing
```

### Application Package Structure
Each app in `apps/` contains:
- `docker-compose.yml` — Local development/testing configuration
- `clv-docker-compose.yml` — Marketplace manifest with Clouve metadata extensions
- `image/Dockerfile` — Custom application container
- `image/build.config` — Image name and registry configuration
- `image/installer/entrypoint.sh` — Container initialization logic
- Optional: `image/<db>/Dockerfile` for custom database containers

### Two Docker Compose Files Per App
The key distinction between the two compose files:
- **`docker-compose.yml`**: Uses `.data/` volume mounts for local persistence, supports `TEST_DOMAIN`/`TEST_PORT` env var substitution for URL testing
- **`clv-docker-compose.yml`**: Marketplace manifest — no host volume mounts, uses Clouve-specific YAML extensions for orchestration metadata

### Clouve Metadata Extensions
The `clv-docker-compose.yml` files use custom YAML extensions to describe how the marketplace orchestrates the app:

- **`x-clouve-metadata`**: Per-container purpose (`app`, `database`), resource limits, protocol
- **`x-clouve-environment-types`**: Declares how each env var is handled:
  - `static` — fixed value
  - `secret` — auto-generated secure password
  - `containerReference` — reference to another container's name/IP
  - `applicationUrl` — replaced with the deployment URL
  - `applicationUsername` / `applicationPassword` — user credentials
  - `userConfigurable` — user can modify at deploy time
- **`x-clouve-healthcheck`**: HTTP/TCP/command-based health checks for the marketplace
- **`x-clouve-bundle-metadata`**: App title, version, icon path, description
- **`x-clouve-volumes`**: Volume sizing and human-readable descriptions

Template variables available in manifest values: `{user.userEmail}`, `{user.firstName}`, `{org.name}`

### Bundles
Bundles in `bundles/` combine multiple apps with integration:
- Each service's environment variables can cross-reference other services via `containerReference` type
- Used for SSO, enrollment sync, shared databases between apps
- Example: `bundles/education-kit/` integrates Gibbon + Moodle

### Build System
`build.sh` reads `image/build.config` from each app directory to determine image names and registry paths. It uses Docker Buildx for multi-platform builds (`linux/amd64` + `linux/arm64`).

### AI Studio (`apps/ai-studio/`)
The AI Studio app runs Ubuntu 24.04 with ttyd (web terminal), nginx, and FileBrowser Quantum. It serves a browser-based terminal at `/chat` where users interactively choose their preferred AI coding assistant (Claude Code, Gemini CLI, or OpenAI Codex CLI) on each session start; the selected client is installed on first use and persists across restarts. Access: `http://localhost:8080/chat` (admin/Admin@123 for local dev).

## Known Issues

### Self-signed TLS certificates break WebSocket (ttyd terminal) on Kubernetes
AI Studio's web terminal (ttyd) relies on WebSocket (`wss://`). Browsers silently reject WebSocket connections when the TLS certificate is not trusted — the page and HTTP requests work (user accepted the cert warning), but `new WebSocket("wss://...")` fails before the request ever leaves the browser. Symptoms: the terminal iframe loads but stays blank; server logs show repeated `/token` fetches with zero `/_clv/chat/ws` entries.

**Root cause on the local dev cluster:** The `letsencrypt-prod` ClusterIssuer is misconfigured as `spec.selfSigned: {}` — it issues self-signed certs despite the name.

**Diagnosis:**
```bash
# Check if the cert is self-signed (empty issuer = self-signed)
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -subject

# Verify the ClusterIssuer config (look for selfSigned: {} vs proper ACME)
kubectl get clusterissuer letsencrypt-prod -o yaml
```

**Fix:** Reconfigure the ClusterIssuer with real ACME (HTTP-01 or DNS-01). Docker deployments are unaffected (HTTP only, no TLS).
