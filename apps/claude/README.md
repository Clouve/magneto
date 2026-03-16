# Claude Code Server Docker Application

Custom Ubuntu 24.04 LTS server image with a browser-based web terminal, SSH access, and Claude Code pre-installed and pre-configured.

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
- **URL**: http://localhost:7890
- **Username**: `admin`
- **Password**: `Admin@123`

### SSH
```bash
ssh admin@localhost -p 2222
```
- **Password**: `Admin@123`

Root access is also available:
```bash
ssh root@localhost -p 2222
# Password: Root@123
```

## Configuration

Edit `docker-compose.yml` to customize environment variables:

```yaml
environment:
  CLAUDE_USERNAME: admin                    # Admin username
  CLAUDE_PASSWORD: Admin@123               # Admin password (web terminal + SSH)
  CLAUDE_ROOT_PASSWORD: Root@123           # Root password
  ANTHROPIC_API_KEY: sk-ant-...           # Anthropic API key for Claude Code
```

To override the exposed ports at runtime:

```bash
TEST_PORT=8888 TEST_SSH_PORT=3022 docker compose up -d
ssh admin@localhost -p 3022
```

### SSH Key Authentication (optional)

Add an authorized public key so you can connect without a password:

```yaml
environment:
  CLAUDE_SSH_AUTHORIZED_KEY: "ssh-ed25519 AAAA... user@host"
```

## Using Claude Code

Claude Code is pre-installed and pre-configured. When `ANTHROPIC_API_KEY` is set, the container automatically:

- Exports the key into every shell session via `/etc/profile.d/` (SSH, web terminal, `su -`)
- Writes `~/.claude.json` with the key and completed onboarding state so the first-run wizard is skipped

Simply open the web terminal or SSH in and run:

```bash
claude
```

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
- Browser-based terminal via [ttyd](https://github.com/tsl0922/ttyd) (HTTP basic auth)
- OpenSSH server with password and public key authentication
- Common CLI tools: `curl`, `wget`, `git`, `vim`, `nano`, `htop`, `jq`, `tree`, `unzip`
- Admin user created from environment variables at startup
- Passwordless `sudo` for the admin user
- Persistent home directory volume across container restarts

## Files

- `image/Dockerfile` — Ubuntu 24.04 image with Node.js 22, Claude Code, SSH, ttyd, and CLI tools
- `image/installer/entrypoint.sh` — Startup script (user creation, Claude Code config, SSH, ttyd)
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
# Confirm ttyd is listening
docker compose exec claude curl -s http://localhost:7890/ | head -5
```

### SSH connection refused
```bash
# Confirm sshd is running inside the container
docker compose exec claude pgrep -a sshd
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
3. Add your public key via `CLAUDE_SSH_AUTHORIZED_KEY` and consider disabling password auth
4. Build and push the image: `../../build.sh apps/claude --push`
5. Verify the web terminal, SSH, and `claude` are all accessible
