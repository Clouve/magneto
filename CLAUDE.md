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
The AI Studio app is a blank Ubuntu 26.04 LTS server with `openssh-server` and a `clouve-ops` operator account (passwordless sudo). It is **not** a UI host — it is a sibling workspace operated by the Magneto Agent. The user talks to the agent in the chat UI (provided automatically because `x-clouve-agent: enabled: true` is always set in [apps/ai-studio/clv-docker-compose.yml](apps/ai-studio/clv-docker-compose.yml)), and the agent SSHes in as `clouve-ops` to install software, write code, run services, and verify deploys. Four volumes (`/home`, `/usr`, `/opt`, `/var`) persist across pod restarts, so apt-installed packages and user files survive. The agent's behavioral contract lives in the `ai-studio` skill at [magneto-skills/plugins/ai-studio/](../magneto-skills/plugins/ai-studio/); the per-tenant persona is templated from [apps/ai-studio/image/context/ai-studio/CONTEXT.md.tpl](apps/ai-studio/image/context/ai-studio/CONTEXT.md.tpl). Local dev: `./build.sh ai-studio && ./start.sh ai-studio`, then `ssh -p 2222 clouve-ops@localhost` (password `ai-studio-ops-password`).

## Known Issues

### Untrusted TLS certificates break WebSocket (ttyd terminal) on Kubernetes
The Magneto Agent's web terminal (ttyd) relies on WebSocket (`wss://`). Browsers silently reject WebSocket connections when the TLS certificate is not trusted — the page and HTTP requests work (user accepted the cert warning), but `new WebSocket("wss://...")` fails before the request ever leaves the browser. Symptoms: the terminal iframe loads but stays blank; the AI client never spawns (or appears to spawn-and-exit); server logs show repeated `/_clv/chat/token` fetches with zero `/_clv/chat/*/ws` entries. This bites any deployment that includes `x-clouve-agent: enabled: true` — including AI Studio.

**Root cause on the kind / clv local cluster:** The `selfsigned` cert-issuer strategy installs the `gcp-prod` ClusterIssuer with `spec.selfSigned: {}` — each tenant ingress gets a unique self-signed leaf with no shared CA, so no amount of OS-keychain trust fixes them. Accepting the browser cert warning lets HTTP requests through but `new WebSocket("wss://...")` still rejects the connection.

**Diagnosis:**
```bash
# Check if the cert chain has no real issuer (empty issuer = self-signed leaf, no CA)
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -subject

# Confirm the ClusterIssuer is selfSigned and not CA-backed
kubectl get clusterissuer gcp-prod -o yaml | grep -A1 'spec:'
```

**Fix (kind / clv local clusters):** Pick the `dev` cert-issuer strategy — not `selfsigned` — when bringing up the local cluster. The `cluster/action` dispatcher only prompts for the strategy during `setup*` actions (see [strato/cluster/action](../../strato/cluster/action) lines 64–74, where `CERT_ISSUER_STRATEGY_ARR=("selfsigned" "dev")` is gated to actions `setup`, `setup-load-balancer`, and `setup-cert-issuers`):
```bash
./strato/cluster/action clv create                 # create the kind cluster
./strato/cluster/action clv setup                # pick "dev" at the strategy prompt
# (or, to re-issue on an existing cluster:)
./strato/cluster/action clv setup-cert-issuers   # pick "dev"
```
The `dev` strategy replaces the `selfSigned` `gcp-prod` ClusterIssuer with a **real public ACME issuer** — Google Trust Services (Google Public CA) — that solves DNS-01 against the `clouve.app` Cloud DNS zone (so the kind cluster needs valid GCP credentials for project `clouve-develop`). The resulting leaf certs chain to a publicly-trusted root already in every browser's trust store, so `wss://` upgrades validate without any local CA-trust step. See [strato/cluster/k8s/manifests/clouve-e2e/cert-issuers/dev/](../../strato/cluster/k8s/manifests/clouve-e2e/cert-issuers/dev/) for the issuer manifest that gets copied into place by `cluster/action` (lines 122–127).

**Fix (real prod clusters):** Same `dev`-style ACME ClusterIssuers — see the manifests linked above for working HTTP-01 / DNS-01 examples.

Docker deployments are unaffected (HTTP only, no TLS).
