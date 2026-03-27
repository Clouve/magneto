# LibreChat + MongoDB Implementation Plan

## Overview

This document describes the plan for integrating [LibreChat](https://github.com/danny-avila/LibreChat) and MongoDB into AI Studio as a rich chat UI replacement for the current ttyd-based terminal experience at `/_clv/chat`. The terminal interface moves to `/_clv/terminal` for power users.

This plan follows the architectural conventions established across existing Magneto apps (WordPress, Moodle, Odoo, LimeSurvey) and builds on the recommendation from [RICH_UI_INVESTIGATION.md](RICH_UI_INVESTIGATION.md).

---

## Architecture Decision: Multi-Service Compose Stack

AI Studio currently runs as a **single container** with nginx, ttyd, FileBrowser, and an auth server all managed by the entrypoint script. Adding LibreChat + MongoDB as processes inside that same container would create fragile process supervision, complicate resource limits, and break the pattern used by every other Magneto app.

**Decision:** Move to a multi-service Docker Compose stack, consistent with how WordPress (app + MariaDB), Moodle (app + MySQL), and Odoo (app + PostgreSQL) are structured. AI Studio becomes three services:

| Service | Role | Port (internal) |
|---------|------|-----------------|
| `ai-studio` | Ubuntu env — nginx, ttyd, FileBrowser, auth server | 80 |
| `ai-studio-librechat` | LibreChat Node.js/Express app | 3080 |
| `ai-studio-mongodb` | MongoDB 7 data store for LibreChat | 27017 |

Nginx inside the `ai-studio` container reverse-proxies `/_clv/chat` to `ai-studio-librechat:3080` and continues to serve `/_clv/terminal` (ttyd) and `/_clv/browser` (FileBrowser) locally.

---

## Directory Structure

Following the established `apps/<app-name>/` layout:

```
apps/ai-studio/
├── README.md                              # Updated with LibreChat instructions
├── logo.png
├── docker-compose.yml                     # Updated: 3 services
├── clv-docker-compose.yml                 # Updated: 3 services + Clouve metadata
├── clv-docker-compose-claude.yml          # Existing variant (unchanged)
├── clv-docker-compose-gemini.yml          # Existing variant (unchanged)
├── clv-docker-compose-openai.yml          # Existing variant (unchanged)
├── docs/
│   ├── RICH_UI_INVESTIGATION.md           # Existing
│   └── LIBRECHAT_IMPLEMENTATION_PLAN.md   # This document
└── image/
    ├── build.config                       # Updated: add MONGODB_IMAGE
    ├── Dockerfile                         # Updated: install envsubst deps if needed
    ├── installer/
    │   ├── entrypoint.sh                  # Updated: STEP 2-4 changes for LibreChat
    │   ├── init.sh                        # Unchanged
    │   ├── nginx-default.conf             # Updated: /_clv/chat → LibreChat, new /_clv/terminal
    │   ├── chat/                          # Unchanged (ttyd + CLI clients)
    │   ├── files/                         # Unchanged (FileBrowser)
    │   ├── auth/                          # Unchanged (Python auth server)
    │   └── librechat/
    │       ├── librechat.yaml.tpl         # NEW: LibreChat config template
    │       └── custom-theme.css           # NEW: Clouve branding overrides
    └── mongodb/
        └── Dockerfile                     # NEW: Thin wrapper around mongo:7
```

### New Files

| File | Purpose |
|------|---------|
| `image/mongodb/Dockerfile` | Wraps `mongo:7` for multi-platform builds via `build.sh`, matching the pattern in `wordpress/image/mariadb/Dockerfile` and `moodle/image/mysql/Dockerfile` |
| `image/installer/librechat/librechat.yaml.tpl` | LibreChat configuration template with `${VARIABLE}` placeholders resolved at container start via `envsubst` |
| `image/installer/librechat/custom-theme.css` | CSS overrides for Clouve branding (colors, logo) loaded by LibreChat's custom CSS feature |

---

## Docker Compose Changes

### docker-compose.yml (Local Development)

```yaml
services:
  ai-studio:
    image: r.clv.zone/e2eorg/ai-studio
    container_name: ai_studio_server
    restart: unless-stopped
    ports:
      - "${TEST_HTTP_PORT:-8080}:80"
    environment:
      AI_STUDIO_USERNAME: admin
      AI_STUDIO_PASSWORD: Admin@123
      AI_STUDIO_ROOT_PASSWORD: Root@123
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      GEMINI_API_KEY: ${GEMINI_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      AI_STUDIO_HOST: ${TEST_DOMAIN:-localhost:8080}
      LIBRECHAT_HOST: ai-studio-librechat   # container DNS name
      LIBRECHAT_PORT: "3080"
    volumes:
      - ai-studio-home:/home
      - ai-studio-usr:/usr
      - ai-studio-opt:/opt
      - ai-studio-var:/var
    depends_on:
      ai-studio-librechat:
        condition: service_healthy
    networks:
      - ai_studio_network

  ai-studio-librechat:
    image: ghcr.io/danny-avila/librechat:latest
    container_name: ai_studio_librechat
    restart: unless-stopped
    environment:
      HOST: "0.0.0.0"
      PORT: "3080"
      MONGO_URI: mongodb://ai-studio-mongodb:27017/librechat
      DOMAIN_SERVER: http://ai-studio:80
      DOMAIN_CLIENT: http://${TEST_DOMAIN:-localhost:8080}
      # Auth — disable LibreChat's native login, trust nginx auth
      ALLOW_REGISTRATION: "false"
      ALLOW_SOCIAL_LOGIN: "false"
      # AI provider keys — passed through from host
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:-}
      OPENAI_API_KEY: ${OPENAI_API_KEY:-}
      GOOGLE_KEY: ${GEMINI_API_KEY:-}
    volumes:
      - librechat-data:/app/client/public/images
    depends_on:
      ai-studio-mongodb:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3080/api/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - ai_studio_network

  ai-studio-mongodb:
    image: r.clv.zone/e2eorg/ai-studio-mongodb
    container_name: ai_studio_mongodb
    restart: unless-stopped
    volumes:
      - mongodb-data:/data/db
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s
    networks:
      - ai_studio_network

volumes:
  ai-studio-home:
    driver: local
  ai-studio-usr:
    driver: local
  ai-studio-opt:
    driver: local
  ai-studio-var:
    driver: local
  librechat-data:
    driver: local
  mongodb-data:
    driver: local

networks:
  ai_studio_network:
    driver: bridge
```

**Key patterns followed:**
- `TEST_DOMAIN` / `TEST_HTTP_PORT` substitution (same as WordPress, LimeSurvey)
- Registry image prefix `r.clv.zone/e2eorg/` for custom-built images
- Named volumes for all persistent data
- Single bridge network connecting all services
- Health checks on database and app services with `depends_on` conditions

### clv-docker-compose.yml (Marketplace Manifest)

```yaml
version: '3.8'
services:
  ai-studio:
    image: ai-studio:latest
    ports:
      - '80:80'
    environment:
      AI_STUDIO_USERNAME: '{user.firstName}_{user.lastName}'
      AI_STUDIO_PASSWORD: ai-studio-password
      AI_STUDIO_ROOT_PASSWORD: ai-studio-root-password
      AI_STUDIO_HOST: applicationUrl
      LIBRECHAT_HOST: ai-studio-librechat
      LIBRECHAT_PORT: "3080"
    x-clouve-environment-types:
      AI_STUDIO_USERNAME: applicationUsername
      AI_STUDIO_PASSWORD: applicationPassword
      AI_STUDIO_ROOT_PASSWORD: secret
      AI_STUDIO_HOST: applicationUrl
      LIBRECHAT_HOST: containerReference
      LIBRECHAT_PORT: static
    volumes:
      - ai-studio-home:/home
      - ai-studio-usr:/usr
      - ai-studio-opt:/opt
      - ai-studio-var:/var
    x-clouve-metadata:
      containerName: ai-studio
      purpose: App
      protocol: TCP
      isPublic: true
      memoryBase: 4
      cpuBase: 1
    x-clouve-bundle-metadata:
      appVersion: '24.04'
      appTitle: AI Studio
      appDescription: >-
        A cloud-hosted AI workspace with a rich chat UI powered by LibreChat,
        supporting Claude, GPT, and Gemini. Includes a full Ubuntu 24.04 LTS
        environment with web terminal access and FileBrowser for file management.
      appIcon: /thermo/assets/Company/e2eorg/attachments/b104956a61c5528f-logo.png
      adminPath: /_clv/
    x-clouve-healthcheck:
      enabled: true
      type: HTTP
      path: /
      port: 80
      initialDelay: 60
      interval: 60
      timeout: 60
      failureThreshold: 15
      successThreshold: 1
    healthcheck:
      test: ['CMD', 'wget', '--spider', '-q', 'http://localhost:80/']
      interval: 60s
      timeout: 60s
      retries: 15
      start_period: 60s
    x-clouve-volumes:
      - name: ai-studio-home
        size: 10
        description: Persistent volume for home directories
      - name: ai-studio-usr
        size: 10
        description: Persistent volume for system binaries and libraries (/usr)
      - name: ai-studio-opt
        size: 10
        description: Persistent volume for optional software (/opt)
      - name: ai-studio-var
        size: 10
        description: Persistent volume for /var (package db, cache, logs, web files)

  ai-studio-librechat:
    image: librechat:latest
    ports:
      - '3080:3080'
    environment:
      HOST: "0.0.0.0"
      PORT: "3080"
      MONGO_URI: mongodb://ai-studio-mongodb:27017/librechat
      DOMAIN_SERVER: http://ai-studio:80
      DOMAIN_CLIENT: applicationUrl
      ALLOW_REGISTRATION: "false"
      ALLOW_SOCIAL_LOGIN: "false"
    x-clouve-environment-types:
      HOST: static
      PORT: static
      MONGO_URI: containerReference
      DOMAIN_SERVER: containerReference
      DOMAIN_CLIENT: applicationUrl
      ALLOW_REGISTRATION: static
      ALLOW_SOCIAL_LOGIN: static
    x-clouve-metadata:
      containerName: ai-studio-librechat
      purpose: App
      protocol: TCP
      isPublic: false
      memoryBase: 1
      cpuBase: 0.5
    x-clouve-healthcheck:
      enabled: true
      type: HTTP
      path: /api/health
      port: 3080
      initialDelay: 30
      interval: 30
      timeout: 10
      failureThreshold: 5
      successThreshold: 1
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:3080/api/health']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    x-clouve-volumes:
      - name: librechat-data
        size: 5
        description: LibreChat uploaded images and file attachments

  ai-studio-mongodb:
    image: ai-studio-mongodb:latest
    ports:
      - '27017:27017'
    x-clouve-metadata:
      containerName: ai-studio-mongodb
      purpose: Database
      protocol: TCP
      isPublic: false
      memoryBase: 1
      cpuBase: 0.5
    x-clouve-healthcheck:
      enabled: true
      type: command
      command: mongosh --eval "db.adminCommand('ping')"
      initialDelay: 20
      interval: 30
      timeout: 10
      failureThreshold: 5
      successThreshold: 1
    healthcheck:
      test: ['CMD', 'mongosh', '--eval', "db.adminCommand('ping')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s
    volumes:
      - mongodb-data:/data/db
    x-clouve-volumes:
      - name: mongodb-data
        size: 5
        description: MongoDB data files for LibreChat conversations and user data

volumes:
  ai-studio-home:
    driver: local
  ai-studio-usr:
    driver: local
  ai-studio-opt:
    driver: local
  ai-studio-var:
    driver: local
  librechat-data:
    driver: local
  mongodb-data:
    driver: local
```

**Clouve metadata patterns followed:**
- `containerReference` type for inter-service hostnames (same as WordPress `WORDPRESS_DB_HOST`)
- `secret` type for auto-generated passwords
- `applicationUrl` type for user-facing URLs
- `static` type for fixed configuration values
- `isPublic: false` for internal-only services (MongoDB, LibreChat)
- Resource allocation sized appropriately (LibreChat: 0.5 CPU / 1 GB, MongoDB: 0.5 CPU / 1 GB)
- `purpose: Database` for MongoDB (same as WordPress MariaDB, Odoo PostgreSQL)

---

## Build System Changes

### image/build.config

```
# Build Configuration for AI Studio
# This file defines the Docker image configuration for building the AI Studio services

# Application image name (used for tagging in registry)
APP_IMAGE="ai-studio"

# Database image name (MongoDB for LibreChat)
MONGODB_IMAGE="ai-studio-mongodb"
MONGODB_NAME="MongoDB"
```

This follows the convention in `wordpress/image/build.config` (`APP_IMAGE` + `MARIADB_IMAGE`) and `odoo/image/build.config` (`APP_IMAGE` + `POSTGRES_IMAGE`).

The centralized `build.sh` reads these variables to tag and push images:
- `r.clv.zone/e2eorg/ai-studio`
- `r.clv.zone/e2eorg/ai-studio-mongodb`

LibreChat itself uses the upstream `ghcr.io/danny-avila/librechat` image (not custom-built), so it does not need a build.config entry. If customization is needed later (e.g., baked-in theme or plugins), a `librechat/Dockerfile` can be added and a `LIBRECHAT_IMAGE` entry created.

### image/mongodb/Dockerfile

```dockerfile
FROM mongo:7

LABEL maintainer="Clouve Team"
LABEL description="MongoDB 7 for AI Studio LibreChat — multi-platform wrapper"

# No customization needed; this exists solely to build multi-arch images
# through the centralized build.sh pipeline and avoid Docker Hub rate limits
# on the production registry.
```

This matches the pattern in `wordpress/image/mariadb/Dockerfile` — a thin wrapper enabling multi-platform builds through the existing `build.sh` pipeline.

---

## Nginx Configuration Changes

Update `image/installer/nginx-default.conf` to route `/_clv/chat` to LibreChat and move ttyd to `/_clv/terminal`:

```nginx
# ── Chat (LibreChat) — protected by session auth ──────────────────────
# LibreChat runs in the ai-studio-librechat container. Nginx proxies
# all requests under /_clv/chat to it, stripping the prefix.
location /_clv/chat/ {                                   # [clouve-hosted]
    auth_request /_clv/_auth/verify;

    # Strip /_clv/chat prefix before forwarding to LibreChat
    rewrite ^/_clv/chat/(.*) /$1 break;
    proxy_pass http://ai-studio-librechat:3080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;
    client_max_body_size 100M;

    error_page 401 = @auth_required;
}

# ── Terminal (ttyd) — protected by session auth ────────────────────────
# ttyd is retained for power users who prefer the CLI AI clients.
# Moved from /_clv/chat to /_clv/terminal.
location /_clv/terminal {                                # [clouve-hosted]
    auth_request /_clv/_auth/verify;

    proxy_pass http://127.0.0.1:7890;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
    proxy_buffering off;

    error_page 401 = @auth_required;
}
```

**Important:** The LibreChat proxy target uses the Docker Compose service name (`ai-studio-librechat`) rather than `127.0.0.1` since LibreChat runs in a separate container. The nginx `resolver` directive should be added to handle Docker DNS:

```nginx
server {
    listen 80;
    server_name _;
    absolute_redirect off;

    # Docker DNS resolver for container-to-container name resolution
    resolver 127.0.0.11 valid=30s;
    set $librechat_upstream http://ai-studio-librechat:3080;

    # ... (use $librechat_upstream in proxy_pass)
}
```

---

## Authentication Integration

### Strategy: Trusted Header Auth

LibreChat supports multiple auth modes. For Clouve integration, use the **trusted header** approach — the simplest path that avoids duplicating user management:

1. Nginx's `auth_request` validates the session cookie against the existing Python auth server (unchanged)
2. On success, the auth server returns `X-Auth-User` header with the username
3. Nginx forwards this header to LibreChat
4. LibreChat is configured to trust the header and auto-create/login the user

This avoids requiring users to log in twice (once to AI Studio, once to LibreChat) and keeps the Python auth server as the single source of truth.

### LibreChat Configuration

In `librechat.yaml.tpl`:

```yaml
version: 1.2.1
cache: true

registration:
  socialLogins: []
  allowedDomains: []

endpoints:
  anthropic:
    apiKey: "${ANTHROPIC_API_KEY}"
    models:
      default:
        - claude-opus-4-20250514
        - claude-sonnet-4-20250514
      fetch: true
  openAI:
    apiKey: "${OPENAI_API_KEY}"
    models:
      default:
        - gpt-4o
        - gpt-4o-mini
        - o1
        - o3-mini
      fetch: true
  google:
    apiKey: "${GEMINI_API_KEY}"
    models:
      default:
        - gemini-2.5-pro
        - gemini-2.5-flash
      fetch: true
```

The template is resolved at container start by the entrypoint script using `envsubst`, following the same pattern AI Studio already uses for nginx configuration.

### API Key Flow

| Scenario | Behavior |
|----------|----------|
| Keys set as env vars in Compose | LibreChat uses them directly — users see all configured providers |
| Keys not set | LibreChat's settings UI lets users enter their own keys per session |
| Mixed | Pre-configured providers are available; users can add additional ones |

This matches the current AI Studio behavior where `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and `GEMINI_API_KEY` are optional environment variables.

---

## Entrypoint Script Changes

The existing `entrypoint.sh` needs two modifications:

### 1. Generate LibreChat Config from Template

Add after STEP 1 (user configuration):

```bash
# ============================================================================
# STEP 1b: Generate LibreChat configuration
# ============================================================================

LIBRECHAT_CONFIG_DIR="/var/lib/clouve/librechat"
mkdir -p "$LIBRECHAT_CONFIG_DIR"

envsubst < /clouve/ai-studio/installer/librechat/librechat.yaml.tpl \
         > "$LIBRECHAT_CONFIG_DIR/librechat.yaml"

echo -e "${GREEN}[SUCCESS]${NC} LibreChat configuration generated."
```

### 2. Update ttyd Base Path

In `chat/install.sh`, change the ttyd `--base-path` from `/_clv/chat` to `/_clv/terminal`:

```bash
# Before:
ttyd --base-path /_clv/chat ...

# After:
ttyd --base-path /_clv/terminal ...
```

### 3. Update Ready Message

```bash
echo -e "${GREEN}[SUCCESS]${NC} AI Studio is ready!"
echo -e "${GREEN}[INFO]${NC} Chat UI available at http://localhost/_clv/chat"
echo -e "${GREEN}[INFO]${NC} Web terminal available at http://localhost/_clv/terminal"
echo -e "${GREEN}[INFO]${NC} File browser available at http://localhost/_clv/browser"
```

---

## SPA (Landing Page) Changes

The existing SPA at `/_clv/` presents the split-pane layout (chat iframe + file browser iframe). Update the iframe source:

In `image/installer/web/static/js/app.js` (or equivalent):

```javascript
// Before:
chatIframe.src = '/_clv/chat';

// After:
chatIframe.src = '/_clv/chat';  // Now points to LibreChat instead of ttyd
```

No URL change needed — the nginx rewrite handles the backend switch transparently. The SPA code remains unchanged.

Add a UI toggle or menu option to switch the chat iframe between `/_clv/chat` (LibreChat) and `/_clv/terminal` (ttyd) for users who prefer the CLI experience.

---

## Resource Allocation

### Local Development (docker-compose.yml)

No explicit resource limits — Docker allocates as needed on the developer's machine.

### Marketplace Deployment (clv-docker-compose.yml)

| Service | CPU | Memory | Storage |
|---------|-----|--------|---------|
| ai-studio | 1 | 4 GB | 40 GB (4 volumes x 10 GB) |
| ai-studio-librechat | 0.5 | 1 GB | 5 GB |
| ai-studio-mongodb | 0.5 | 1 GB | 5 GB |
| **Total** | **2** | **6 GB** | **50 GB** |

Compared to the current single-container setup (1 CPU, 4 GB, 40 GB), the addition of LibreChat + MongoDB adds 1 CPU, 2 GB RAM, and 10 GB storage. This is within the resource budget for a development workspace.

---

## Testing

### URL Substitution Testing

The existing `test.sh` script tests `TEST_DOMAIN` and `TEST_PORT` substitution in `docker-compose.yml`. Verify it handles the new services:

```bash
./test.sh apps/ai-studio
./test.sh apps/ai-studio custom.domain.com custom2.domain.com 8090
```

### Manual Verification Checklist

1. **Build:** `./build.sh ai-studio` completes for both platforms
2. **Start:** `./start.sh ai-studio` brings up all three services
3. **Health:** `./status.sh ai-studio` shows all services healthy
4. **Auth:** Navigate to `/_clv/` — login required before accessing chat or terminal
5. **Chat:** After login, `/_clv/chat` loads LibreChat UI
6. **Providers:** Configure an API key — verify chat works with at least one provider
7. **Terminal:** `/_clv/terminal` loads ttyd with the CLI client selector
8. **Files:** `/_clv/browser` loads FileBrowser (unchanged)
9. **Persistence:** `./stop.sh ai-studio && ./start.sh ai-studio` — conversations and files survive restart
10. **Cleanup:** `./start.sh ai-studio --cleanup` starts fresh (all volumes removed)
11. **Logs:** `./logs.sh ai-studio` shows output from all services

---

## Implementation Steps

### Phase 1: MongoDB + LibreChat Services (Core Integration)

1. Create `image/mongodb/Dockerfile` (thin `mongo:7` wrapper)
2. Update `image/build.config` with `MONGODB_IMAGE`
3. Create `image/installer/librechat/librechat.yaml.tpl` config template
4. Create `image/installer/librechat/custom-theme.css` with Clouve branding
5. Update `docker-compose.yml` — add `ai-studio-librechat` and `ai-studio-mongodb` services
6. Update `clv-docker-compose.yml` — add services with full Clouve metadata
7. Update `image/installer/nginx-default.conf` — route `/_clv/chat` to LibreChat, move ttyd to `/_clv/terminal`
8. Update `entrypoint.sh` — add config generation step
9. Update `chat/install.sh` — change ttyd base path to `/_clv/terminal`
10. Build and verify locally: `./build.sh ai-studio && ./start.sh ai-studio --cleanup`

### Phase 2: Authentication + Branding

11. Configure LibreChat trusted-header auth or OIDC integration with the Python auth server
12. Apply Clouve theme CSS and logo
13. Test single sign-on flow: login at `/_clv/` grants access to chat, terminal, and files
14. Verify API key passthrough from environment variables to LibreChat

### Phase 3: SPA + UX Polish

15. Add terminal/chat toggle to the SPA landing page
16. Update the `appDescription` in `clv-docker-compose.yml`
17. Update `README.md` with LibreChat-specific instructions
18. Run full test suite: `./test.sh apps/ai-studio`
19. Update variant manifests (`clv-docker-compose-claude.yml`, etc.) if applicable

### Phase 4: Registry + Deployment

20. Push images: `./build.sh ai-studio --push`
21. Verify marketplace deployment via Clouve platform
22. Monitor resource usage and tune `memoryBase`/`cpuBase` if needed

---

## Rollback Plan

If LibreChat integration causes issues:

1. Revert `nginx-default.conf` to point `/_clv/chat` back to ttyd (`127.0.0.1:7890`)
2. Revert `chat/install.sh` to use `--base-path /_clv/chat`
3. The `ai-studio-librechat` and `ai-studio-mongodb` services can be removed from compose files without affecting the core AI Studio container
4. MongoDB data volume can be preserved for future re-enablement

The core AI Studio container remains fully functional without LibreChat — all existing functionality (ttyd, FileBrowser, auth) is preserved in the same container and only the nginx routing changes.

---

## Open Questions

| # | Question | Impact | Default Assumption |
|---|----------|--------|--------------------|
| 1 | Should LibreChat use the upstream Docker image or a custom-built one? | Build pipeline, customization depth | Start with upstream `ghcr.io/danny-avila/librechat:latest`; switch to custom build if we need baked-in theme/plugins |
| 2 | Which LibreChat auth mode? Trusted-header vs. OIDC | Auth complexity, session management | Trusted-header (simpler, matches current nginx auth_request pattern) |
| 3 | Should the variant manifests (claude/gemini/openai) include LibreChat? | Marketplace listing scope | Yes — LibreChat supports all three providers; the variant just pre-configures the default |
| 4 | MeiliSearch for conversation search? | Additional service + resources | Defer to post-MVP; MongoDB text search is sufficient initially |
| 5 | Pin LibreChat to a specific version tag or use `latest`? | Stability vs. features | Pin to a specific release tag (e.g., `v0.7.x`) in production compose; use `latest` in dev |
