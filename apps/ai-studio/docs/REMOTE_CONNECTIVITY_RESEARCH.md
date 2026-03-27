# AI Studio Remote Connectivity Research

## Goal

Find a way to allow Claude Desktop (and equivalents) to connect to the AI client CLI installed on the AI Studio server and control it remotely — delivering a rich UI experience while preserving the agentic coding capabilities of each CLI tool.

---

## Remote Connectivity: Current State

| Capability | Claude Code | Codex CLI | Gemini CLI |
|---|---|---|---|
| **Native remote control** | **Yes** — `claude remote-control` (HTTPS polling via Anthropic API) | No (requested, no commitment) | No (requested, no commitment) |
| **Desktop app → remote server** | **Yes** — Claude Code Desktop has built-in SSH sessions | No | No |
| **Server/daemon mode** | `claude remote-control` acts as one | **Experimental** — `codex app-server --listen ws://HOST:PORT` (JSON-RPC 2.0 over WebSocket) | No (community prototype exists, not merged) |
| **Headless/CI mode** | `claude -p` (run-and-exit) | `codex exec` (run-and-exit) | `gemini -p` (run-and-exit) |
| **VS Code Remote SSH** | Works (extension runs on remote) | Works (extension runs on remote) | N/A (no VS Code extension) |
| **Auth on headless servers** | API key or OAuth | `codex login --device-auth` or API key | API key (`GEMINI_API_KEY`) |
| **Third-party remote clients** | Channels (Telegram, Discord, iMessage) | Remodex (iOS app), Zane, Codex-Pocket | None |

---

## Claude Code (Anthropic)

Claude Code is the only client with **first-party remote connectivity today**, via two shipping mechanisms:

### SSH Sessions (Claude Code Desktop)

The Claude Code Desktop app natively supports SSH connections to remote machines. When starting a session, the user chooses an environment: Local, Remote (Anthropic cloud), or SSH (own server).

- Requires Claude Code installed on the remote machine
- Configured via SSH host, port, and identity file (or `~/.ssh/config`)
- Supports permission modes, connectors, plugins, and MCP servers
- Desktop acts as the interface; Claude Code executes on the remote machine with access to its files and tools
- Limitation: "Continue in Claude Code on the Web" is not available for SSH sessions

### Remote Control

`claude remote-control` connects claude.ai/code or the Claude mobile app (iOS/Android) to a Claude Code CLI session running on any machine.

```bash
claude remote-control          # Server mode — waits for remote connections
claude --remote-control        # Interactive session with remote control enabled
/remote-control                # From within an existing session
```

- **Transport:** Outbound HTTPS only — the session registers with the Anthropic API and polls for work. No inbound ports opened.
- **Security:** Multiple short-lived credentials scoped to single purposes. All traffic over TLS.
- **Scaling:** Supports `--capacity <N>` for up to 32 concurrent sessions and `--spawn worktree` for git worktree isolation per session.
- **Requirements:** v2.1.51+, claude.ai subscription (Pro/Max/Team/Enterprise). API keys not supported. Team/Enterprise admins must enable explicitly.

### VS Code Remote SSH

The Claude Code VS Code extension works with Remote SSH, but Claude Code must be installed on the remote machine. Known issues exist with path handling and IDE detection in Remote SSH environments.

### MCP Remote Transport

MCP supports **Streamable HTTP** transport for remote servers — an HTTP-based protocol with optional SSE streaming, session management, and resumability. Claude.ai supports remote MCP servers via "Custom Connectors" (Settings > Connectors, HTTPS URL + OAuth). The stdio transport is local-only.

### Other Remote Options

- **Headless mode:** `claude -p "prompt"` for non-interactive/CI use
- **Agent SDK:** Python and TypeScript SDKs for programmatic control
- **Channels:** Forward messages from Telegram, Discord, or iMessage into a running session

### Sources

- [Claude Code Desktop docs (SSH Sessions)](https://code.claude.com/docs/en/desktop)
- [Claude Code Remote Control docs](https://code.claude.com/docs/en/remote-control)
- [Claude Code Headless/Programmatic docs](https://code.claude.com/docs/en/headless)
- [Claude Code VS Code Extension docs](https://code.claude.com/docs/en/vs-code)
- [MCP Transport Specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [Connect to Remote MCP Servers](https://modelcontextprotocol.io/docs/develop/connect-remote-servers)

---

## Codex CLI (OpenAI)

Codex CLI has **experimental building blocks** for remote control but no official client-side support.

### App Server (Experimental)

Codex CLI includes an `app-server` subcommand exposing a JSON-RPC 2.0 API:

```bash
codex app-server                                    # stdio transport (local)
codex app-server --listen ws://127.0.0.1:4500       # WebSocket transport (experimental)
```

**JSON-RPC API methods include:**
- `thread/start`, `thread/resume`, `thread/fork`, `thread/list`, `thread/read` — thread management
- `turn/start`, `turn/interrupt`, `turn/steer` — turn control
- `command/exec` — run commands in sandbox
- `fs/readFile`, `fs/writeFile`, `fs/watch` — filesystem operations
- Health checks: `GET /readyz` and `GET /healthz`

**WebSocket authentication:**
- Capability token: `--ws-auth capability-token --ws-token-file /path`
- Signed bearer token: `--ws-auth signed-bearer-token --ws-shared-secret-file /path` (HMAC-signed JWT/JWS)
- Non-loopback listeners currently allow unauthenticated connections by default

The WebSocket transport is explicitly documented as **"experimental and unsupported"**.

### No First-Party Remote Client

- [Issue #2744](https://github.com/openai/codex/issues/2744) — "Connect ChatGPT Desktop to Codex CLI" — open, no official response
- [Issue #9224](https://github.com/openai/codex/issues/9224) — "Codex Remote Control" — open, no official response

### Third-Party Remote Clients

- **[Remodex](https://github.com/Emanuele-web04/remodex)** (1.5k stars) — iOS app + macOS bridge that connects to `codex app-server` via WebSocket with E2E encryption
- **Zane** and **Codex-Pocket** — community web clients connecting to the app-server JSON-RPC interface

### Authentication on Headless Servers

- `codex login --device-auth` — device code flow (no browser required)
- Copy `~/.codex/auth.json` from a machine with a browser
- `OPENAI_API_KEY` environment variable

### Sources

- [Codex App Server Documentation](https://developers.openai.com/codex/app-server)
- [Codex CLI Reference](https://developers.openai.com/codex/cli/reference)
- [Codex Authentication](https://developers.openai.com/codex/auth)
- [Unlocking the Codex Harness (OpenAI Blog)](https://openai.com/index/unlocking-the-codex-harness/)
- [Issue #2744 — Connect ChatGPT Desktop to Codex CLI](https://github.com/openai/codex/issues/2744)
- [Issue #9224 — Codex Remote Control](https://github.com/openai/codex/issues/9224)

---

## Gemini CLI (Google)

Gemini CLI has **no remote connectivity** — no server mode, no daemon mode, no remote control mechanism.

### What Exists

- **Interactive TUI mode** — the standard terminal UI
- **Headless mode** — `gemini -p "prompt"` runs once and exits. Returns structured JSON. No persistent session, no listening socket.
- **Remote Subagents (A2A)** — Gemini CLI can *call out* to remote agents via the Agent-to-Agent protocol. This is the reverse direction (CLI → remote agent, not remote client → CLI).

### What Does Not Exist

- No server/daemon mode
- No WebSocket or HTTP API for external control
- No desktop app with remote SSH support
- No mechanism for a local Google client to connect to a remote Gemini CLI process

### Community Requests (Open, No Official Response)

- [Issue #20782](https://github.com/google-gemini/gemini-cli/issues/20782) — "Stateful Remote WebSocket API for Interactive Control" — canonical open issue. A community member built a working prototype (Gemini CLI fork + Rust orchestrator + web UI) but nothing has been merged.
- [Issue #15338](https://github.com/google-gemini/gemini-cli/issues/15338) — "Add a stateful headless mode (daemon/server mode)"
- [Issue #21559](https://github.com/google-gemini/gemini-cli/issues/21559) — "Remote Session Support (like Claude Code)" — closed as duplicate of #20782

### Authentication on Headless Servers

Default OAuth flow requires a browser and fails on headless servers ([Issue #1696](https://github.com/google-gemini/gemini-cli/issues/1696)). Workarounds:
- Set `GEMINI_API_KEY` or `GOOGLE_API_KEY` environment variable (recommended for servers)
- Use `GOOGLE_APPLICATION_CREDENTIALS` for service account auth
- Debug mode (`gemini --debug`) prints OAuth URL for manual browser flow

### Google Cloud Alternatives

| Platform | Gemini CLI Available | Status |
|----------|---------------------|--------|
| Cloud Workstations | Yes (terminal) | GA, production-ready |
| Cloud Shell | Yes (pre-installed) | GA, production-ready |
| Firebase Studio (ex-IDX) | Yes (pre-installed) | **Sunsetting** (March 2026) |
| Antigravity | Yes (terminal + IDE) | Public preview, unstable |

In all cases, you access the remote environment through a browser and Gemini CLI runs locally within that environment. There is no mechanism where a local client connects to a remote Gemini CLI process.

### Sources

- [Gemini CLI Headless Mode Documentation](https://geminicli.com/docs/cli/headless/)
- [Remote Subagents (A2A) Documentation](https://geminicli.com/docs/core/remote-agents/)
- [Issue #20782 — Stateful Remote WebSocket API](https://github.com/google-gemini/gemini-cli/issues/20782)
- [Issue #15338 — Stateful Headless/Daemon Mode](https://github.com/google-gemini/gemini-cli/issues/15338)
- [Issue #1696 — Authentication on Headless Servers](https://github.com/google-gemini/gemini-cli/issues/1696)
- [Gemini CLI Authentication Documentation](https://geminicli.com/docs/get-started/authentication/)

---

## Implications for AI Studio

The original AI Studio model (install all three CLIs, user picks one per session via ttyd) treats the clients equally. For remote desktop connectivity, they are at very different maturity levels:

| Client | Remote Desktop Connectivity | What AI Studio Needs to Do |
|--------|----------------------------|---------------------------|
| **Claude Code** | Works today | Run `claude remote-control` inside the container. User connects from Claude Desktop or claude.ai/code. Container needs outbound HTTPS only. |
| **Codex CLI** | Experimental building blocks | Expose `codex app-server` WebSocket through nginx. No first-party client exists — only third-party apps (Remodex). |
| **Gemini CLI** | No path exists | User must use ttyd or SSH into the container. No remote control mechanism available. |
