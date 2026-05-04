# Magneto Agent — Marketplace Listing

This directory contains the **Clouve marketplace manifests** for the [Magneto Agent](https://github.com/Clouve/magneto-agent) container. The image source and build scripts live in the standalone [`Clouve/magneto-agent`](https://github.com/Clouve/magneto-agent) repository — this directory only describes how the marketplace deploys the published image, plus a thin `docker-compose.yml` for pulling and running it locally.

## Contents

| File | Role |
| --- | --- |
| `docker-compose.yml` | Local dev compose — pulls `r.clv.zone/e2eorg/magneto-agent` and runs it on `localhost:8080` |
| `clv-docker-compose.yml` | Default marketplace manifest — all three AI clients available; user picks at session start |
| `clv-docker-compose-claude.yml` | Claude Code-locked variant (`MAGNETO_AGENT_CLIENT=claude-code`) |
| `clv-docker-compose-gemini.yml` | Gemini CLI-locked variant (`MAGNETO_AGENT_CLIENT=gemini-cli`) |
| `clv-docker-compose-openai.yml` | OpenAI Codex CLI-locked variant (`MAGNETO_AGENT_CLIENT=codex-cli`) |

Each `clv-docker-compose*.yml` file is a marketplace manifest that uses Clouve YAML extensions (`x-clouve-metadata`, `x-clouve-environment-types`, `x-clouve-bundle-metadata`, `x-clouve-healthcheck`, `x-clouve-volumes`) to describe how the marketplace orchestrates the container. The three locked variants pin `MAGNETO_AGENT_CLIENT` so the in-terminal client selector is bypassed and the choice becomes `readonly` for the lifetime of every session — useful when shipping a single-client bundle (e.g. a Claude-Code-only Gibbon DevOps app).

## Quick Start (Local Dev)

```bash
# Run with all three AI clients available (interactive selector at session start)
docker compose up -d

# Optionally pre-set one or more API keys to skip the per-session key prompt
ANTHROPIC_API_KEY=sk-ant-... docker compose up -d
GEMINI_API_KEY=AIza...      docker compose up -d
OPENAI_API_KEY=sk-...       docker compose up -d

# Stop
docker compose down
```

Then open <http://localhost:8080/> — the landing page links to:

- **Web Terminal** at `/chat` — `admin` / `Admin@123`
- **File Manager** at `/files/` — `admin` / `Admin@123`

To override the published port: `TEST_HTTP_PORT=9090 docker compose up -d`.

## Key Environment Variables

Set these on the `magneto-agent` service in `docker-compose.yml` or any `clv-docker-compose*.yml`. See the [`Clouve/magneto-agent` README](https://github.com/Clouve/magneto-agent/blob/main/README.md) for the full reference (in-terminal selector flow, marketplace plugin loader, sidecar persona pull, per-host git credentials, etc.).

| Var | Purpose |
| --- | --- |
| `MAGNETO_AGENT_USERNAME` | Admin username for web terminal + file manager (default `admin`) |
| `MAGNETO_AGENT_PASSWORD` | Admin password (default `Admin@123`) |
| `MAGNETO_AGENT_ROOT_PASSWORD` | Root password — available via `su - root` (default `Root@123`) |
| `MAGNETO_AGENT_CLIENT` | Lock the AI client to `claude-code`, `gemini-cli`, or `codex-cli`. When set, the in-terminal selector is skipped and the value is `readonly` in every shell. Set in the `-claude` / `-gemini` / `-openai` manifest variants. |
| `MAGNETO_AGENT_SKILLS` | Comma-separated list of Claude Code plugin marketplace URLs. Each entry may include `?plugins=<n1>,<n2>` (subset filter) and `#<branch>` (default `main`). |
| `MAGNETO_AGENT_SKILLS_GIT_TOKEN` / `MAGNETO_AGENT_SKILLS_GIT_USERNAME` | Default credentials for private marketplaces. Per-host overrides use `__<HOST>` suffix (uppercased, dots/dashes → underscores), e.g. `MAGNETO_AGENT_SKILLS_GIT_TOKEN__GITHUB_COM`. |
| `ANTHROPIC_API_KEY` / `GEMINI_API_KEY` / `OPENAI_API_KEY` | Optional pre-set API keys. If absent, the user is prompted at session start and the entered key is saved to `~/.{client}_api_key` for reuse. |
| `CLV_SIDECAR_HOSTS` | Comma-separated sidecar hosts whose `/clouve/context/` trees Magneto Agent should pull at init for per-plugin personas (set by app/bundle manifests that pair Magneto Agent with a sidecar, e.g. `gibbon`). |
| `CLOUVE_OPS_PASSWORD` | SSH password for the `clouve-ops` operator account on every sidecar — required when `CLV_SIDECAR_HOSTS` is set. |

## Volumes

Four persistent volumes, seeded from image snapshots on first start (sentinel file `.clouve-seeded` written after extraction so subsequent starts preserve runtime changes):

| Volume | Mount | Default size | Contents |
|--------|-------|-------------|----------|
| `magneto-agent-home` | `/home` | 10 Gi | User home directories |
| `magneto-agent-usr` | `/usr` | 10 Gi | System binaries (AI clients install here) |
| `magneto-agent-opt` | `/opt` | 10 Gi | Optional / third-party software |
| `magneto-agent-var` | `/var` | 10 Gi | Package DB, cache, logs, web files |

## Building the Image

This directory does **not** contain image source. The image is built and pushed from the [`Clouve/magneto-agent`](https://github.com/Clouve/magneto-agent) repository:

```bash
git clone https://github.com/Clouve/magneto-agent.git
cd magneto-agent

./build.sh           # build locally for current platform, load into Docker
./build.sh --push    # build + push multi-platform (amd64 + arm64) to the registry
```

Default registry is `r.clv.zone/e2eorg`. Override with `REGISTRY=…` or use the env-specific wrappers in that repo (`./build-dev.sh`, `./build-uat.sh`, `./build-prod.sh`).

## Networking

Only **port 80** is exposed externally — nginx inside the container routes:

- `/` → landing page
- `/chat` → ttyd (web terminal, localhost:7890)
- `/files/` → Filebrowser Quantum (localhost:6070)

All other paths return 404. To expose additional services, proxy them through nginx with a path-based location block — see the magneto-agent repo's README for the pattern.

## Troubleshooting

```bash
# Container won't start
docker compose logs magneto-agent

# Volume seeding failed on first start (sentinel not written → retried on next start)
docker compose restart magneto-agent

# Web terminal not loading
docker compose exec magneto-agent curl -sf http://localhost/chat       | head -5
docker compose exec magneto-agent curl -sf http://localhost:7890/chat  | head -5

# File manager not loading
docker compose exec magneto-agent curl -sf http://localhost/files/ | head -5
docker compose exec magneto-agent curl -sf http://localhost:6070   | head -5

# AI client install failure (check space + network)
docker compose exec magneto-agent curl -sf https://api.anthropic.com/v1/models | head -5

# Stored API key rejected — clear and retry
rm ~/.claude_api_key    # for Claude Code
rm ~/.gemini_api_key    # for Gemini CLI
rm ~/.openai_api_key    # for OpenAI Codex CLI
```

## Production Deployment Checklist

- [ ] Pick the right manifest variant: `clv-docker-compose.yml` (selector available) or `-claude` / `-gemini` / `-openai` (client-locked)
- [ ] Set strong passwords via `MAGNETO_AGENT_USERNAME`, `MAGNETO_AGENT_PASSWORD`, `MAGNETO_AGENT_ROOT_PASSWORD`
- [ ] Optionally pre-set API keys (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `OPENAI_API_KEY`)
- [ ] Provision four PVCs ≥ 10 Gi each for `home`, `usr`, `opt`, `var`
- [ ] Configure ingress with TLS termination pointing at port 80
- [ ] Verify health check passes at `GET /` (port 80, expected 200)
