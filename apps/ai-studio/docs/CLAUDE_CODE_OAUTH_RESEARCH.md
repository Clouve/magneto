# Claude Code OAuth Authentication in AI Studio — Technical Findings

## Executive Summary

Claude Code supports two authentication paths: **OAuth 2.0 with PKCE** (for Pro/Max/Teams/Enterprise subscriptions) and **API key injection** (for pay-per-token API billing). The OAuth flow requires a local browser and cannot complete inside a headless container today — Anthropic has not yet implemented RFC 8628 Device Authorization Grant. For AI Studio, the **recommended approach is API key injection via `ANTHROPIC_API_KEY`**, which is already implemented and works seamlessly. A future upgrade path to OAuth-based subscription auth is outlined below, contingent on Anthropic shipping device flow support.

---

## 1. Claude Code's Current Auth Mechanism

### 1.1 OAuth 2.0 with PKCE (Subscription Auth)

Claude Code's primary authentication uses **OAuth 2.0 Authorization Code Grant with PKCE** (RFC 7636):

- **Provider**: Anthropic's own identity service (`claude.ai`)
- **Flow**: Claude Code opens a browser to Anthropic's authorization endpoint, the user consents, and a token is exchanged via a dynamically assigned localhost redirect port
- **Callback URL**: `https://claude.ai/api/mcp/auth_callback` (for MCP OAuth); subscription OAuth uses random local ports (e.g., `http://127.0.0.1:54212/callback`)
- **Trigger**: Running `claude` for the first time, or `claude auth login`

**Why this breaks in AI Studio**: The container is headless — there is no browser to open. The OAuth redirect targets a random localhost port on the machine running Claude Code, which is inside the container and unreachable from the user's external browser.

### 1.2 Credential Storage

| Platform | Location | Format |
|----------|----------|--------|
| macOS | macOS Keychain (encrypted) | System keychain entry |
| Linux | `~/.claude/.credentials.json` | JSON file, mode `0600` |
| Custom | `$CLAUDE_CONFIG_DIR/.credentials.json` | Same JSON format |

The credentials file stores OAuth refresh tokens, API keys, and provider-specific auth data (Bedrock, Vertex, Foundry).

### 1.3 Token Lifecycle

- **Subscription OAuth tokens**: Managed automatically by Claude Code; remain valid while the subscription is active. Refresh is transparent.
- **API keys (Console)**: Do not expire. Can be revoked manually at [console.anthropic.com](https://console.anthropic.com/settings/keys). Long-lived; suitable for automated/headless scenarios.
- **`apiKeyHelper` rotation**: Called every 5 minutes by default, or on HTTP 401. Custom interval via `CLAUDE_CODE_API_KEY_HELPER_TTL_MS`.

### 1.4 Headless / Non-Interactive Auth Modes

Claude Code supports several headless authentication mechanisms:

| Method | Env Var / Config | Headless? | Billing Model | Notes |
|--------|-----------------|-----------|---------------|-------|
| **API Key** | `ANTHROPIC_API_KEY` | Yes | Pay-per-token (API) | Simplest headless path. Requires one-time approval in interactive mode. |
| **Bearer Token** | `ANTHROPIC_AUTH_TOKEN` | Yes | Proxy/gateway | Sent as `Authorization: Bearer` header. For LLM gateway routing. |
| **apiKeyHelper** | `settings.json` → `"apiKeyHelper"` | Yes | Varies | Script returns a key dynamically. Good for vault/rotation. |
| **Bedrock** | `CLAUDE_CODE_USE_BEDROCK=1` | Yes | AWS billing | Uses AWS IAM credentials natively. |
| **Vertex AI** | `CLAUDE_CODE_USE_VERTEX=1` | Yes | GCP billing | Uses GCP service account credentials. |
| **Foundry** | `CLAUDE_CODE_USE_FOUNDRY=1` | Yes | Azure billing | Uses Azure identity credentials. |
| **Subscription OAuth** | Browser-based | **No** | Subscription (Pro/Max/Teams) | Requires local browser. Cannot work in containers today. |

### 1.5 Authentication Precedence

Claude Code checks credentials in this order:

1. Cloud provider (`CLAUDE_CODE_USE_BEDROCK`, `_VERTEX`, `_FOUNDRY`)
2. `ANTHROPIC_AUTH_TOKEN` (bearer token)
3. `ANTHROPIC_API_KEY` (API key)
4. `apiKeyHelper` script output
5. Subscription OAuth (default fallback)

**Important**: If `ANTHROPIC_API_KEY` is set, it **overrides** any active subscription. The user is billed per-token via the API, not against their subscription quota.

### 1.6 Relevant CLI Commands

```bash
claude auth login                          # Interactive OAuth login
claude auth login --console                # Login with API Console credentials
claude auth logout                         # Sign out
claude auth status                         # Show current auth method (JSON)
claude -p "prompt"                         # Non-interactive mode (uses env var auth)
claude --bare -p "prompt"                  # Bare mode — skips config, uses env vars only
```

---

## 2. OAuth Flow in a Headless/Containerized Context

### 2.1 Why Standard OAuth Fails

Claude Code's subscription OAuth requires:
1. Opening a browser on the machine running `claude`
2. User consents at Anthropic's authorization endpoint
3. Redirect to `http://127.0.0.1:<random-port>/callback`
4. Token exchanged and stored locally

In AI Studio, `claude` runs inside a container. Steps 1 and 3 fail because:
- No browser exists inside the container
- The localhost redirect port is on the container's loopback, unreachable from the user's browser
- ttyd provides a terminal-only interface — it cannot open browser windows

### 2.2 RFC 8628 Device Authorization Grant

The ideal solution for headless OAuth is [RFC 8628](https://datatracker.ietf.org/doc/html/rfc8628) (Device Authorization Grant):

1. Claude Code requests a device code from Anthropic
2. User is shown a URL and a short code (e.g., `https://claude.ai/device` → enter `ABCD-1234`)
3. User opens that URL on any browser (phone, laptop), enters the code, and consents
4. Claude Code polls Anthropic until the code is approved, then receives tokens
5. No localhost redirect needed — works in any environment

**Current status**: Anthropic has **not implemented device flow** for Claude Code subscription auth. Active feature requests:
- [anthropics/claude-code#22992](https://github.com/anthropics/claude-code/issues/22992) — Device flow for Pro/Max subscription users
- [anthropics/claude-code#20215](https://github.com/anthropics/claude-code/issues/20215) — RFC 8628 for MCP servers
- [anthropics/claude-code#34917](https://github.com/anthropics/claude-code/issues/34917) — OAuth in headless/Docker environments

### 2.3 Pre-Authentication via Token Injection

**Could we complete OAuth externally and inject the token?**

Theoretically:
1. User completes OAuth in their browser before launching AI Studio
2. The resulting refresh token is written to `~/.claude/.credentials.json` inside the container
3. Claude Code starts and finds valid credentials

**Challenges**:
- The credentials file format is undocumented and may change between versions
- Token refresh depends on machine-specific context (keychain vs file, platform detection)
- Anthropic's OAuth client configuration may reject tokens obtained from a different redirect URI
- Security: transmitting refresh tokens through a web application increases attack surface

**Verdict**: Fragile and unsupported. Not recommended.

---

## 3. Frictionless UX Analysis

### 3.1 Current AI Studio Auth Flow (API Key)

Today's flow in `.bash_profile`:
1. User opens AI Studio → SPA login with OS credentials
2. Selects "Claude Code" from the AI client menu
3. **If `ANTHROPIC_API_KEY` was injected at container start** → key is in env, Claude Code launches immediately
4. **If no key** → user is prompted to enter one, it's validated against Anthropic's API, saved to `~/.claude_api_key`, and exported

This flow is **already reasonably frictionless** when the API key is pre-provisioned. The main friction points are:
- Users must obtain an API key from [console.anthropic.com](https://console.anthropic.com/settings/keys) (requires an Anthropic account)
- API keys bill per-token, which may surprise users expecting subscription-style pricing
- Users with Pro/Max subscriptions cannot use their subscription quota

### 3.2 Ideal Future UX (Requires Device Flow)

```
User clicks "Launch AI Studio"
  → AI Studio SPA shows "Connect your Anthropic account" button
  → Click opens Anthropic OAuth consent in a popup/new tab
  → User approves
  → Token flows back to AI Studio backend via callback
  → Backend injects token into the container
  → Claude Code starts authenticated, using the user's subscription
  → No API key, no manual steps
```

This requires either:
- Anthropic implementing device flow (RFC 8628), OR
- Clouve registering as an OAuth client with Anthropic and brokering the flow

Neither is available today.

### 3.3 Re-Authentication on Token Expiry

- **API keys**: Never expire (no re-auth needed unless revoked)
- **OAuth tokens**: Would need transparent refresh. If Claude Code's refresh token expires during a session, the user would need to re-authenticate. The `apiKeyHelper` mechanism could help here by calling a script that obtains a fresh token from the AI Studio backend.

---

## 4. Security Considerations

### 4.1 API Key Storage in Container

**Current model**: API key stored in two places:
1. `/etc/profile.d/clouve-env.sh` (readable by all users on the system, mode 644)
2. `~/.claude_api_key` (mode 600, user-only)

**Risks in multi-tenant Kubernetes**:
- If namespace isolation is breached, the API key is exposed
- The `/etc/profile.d/` file is world-readable inside the container (acceptable for single-user containers)
- Named volumes persist across container restarts — keys survive `docker stop/start`

**Mitigations**:
- Each AI Studio instance runs in its own Kubernetes namespace (`org-<org-id>-<ticket-id>`)
- API keys are scoped to the user's Anthropic account, not Clouve's
- Keys can be revoked by the user at any time via Anthropic Console
- Container isolation (cgroups, namespaces) prevents cross-tenant access

### 4.2 Token Transmission

- API keys are injected as environment variables at container start (Docker/K8s secret injection)
- Never transmitted over the network by AI Studio itself
- Claude Code sends the key to `api.anthropic.com` over TLS
- The SPA auth flow (OS credentials) is separate from the API key flow

### 4.3 Blast Radius

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| API key leaked from container | Attacker can make API calls billed to user | User revokes key; per-token billing caps limit exposure |
| OAuth token leaked | Attacker has session access to user's Claude account | Short-lived tokens + refresh rotation limit window |
| Container escape | Access to host or other containers | K8s namespace isolation, pod security policies, network policies |

### 4.4 Anthropic OAuth Policy

Anthropic's terms do not explicitly address delegated/proxied authentication for CLI tools. The API key approach is explicitly supported (`ANTHROPIC_API_KEY` is a documented, first-party mechanism). Brokering OAuth on behalf of users would require Anthropic's partnership or an official OAuth client registration.

---

## 5. Alternative Approaches — Evaluation Matrix

### 5.1 API Key Injection (RECOMMENDED — Current Implementation)

```
ANTHROPIC_API_KEY injected at container start → Claude Code reads from env → authenticated
```

| Dimension | Assessment |
|-----------|------------|
| **Complexity** | Minimal — already implemented in AI Studio |
| **UX friction** | Low if key is pre-provisioned; moderate if user must obtain one |
| **Billing** | Pay-per-token API pricing (not subscription) |
| **Headless** | Full support |
| **Security** | API key is long-lived; user controls revocation |
| **Maintenance** | None — uses documented, stable Claude Code feature |

**How it works today in AI Studio**:
1. Clouve marketplace captures `ANTHROPIC_API_KEY` as a `secret`-typed env var in `clv-docker-compose.yml`
2. Entrypoint writes it to `/etc/profile.d/clouve-env.sh`
3. `.bash_profile` reads it from the environment; no prompt if present
4. Claude Code's `install.sh` pre-configures `~/.claude.json` with `hasCompletedOnboarding: true`
5. Claude Code launches and uses the API key automatically

### 5.2 apiKeyHelper Script

```
Claude Code calls a script → script fetches a fresh key from vault/API → returns it
```

| Dimension | Assessment |
|-----------|------------|
| **Complexity** | Moderate — requires a helper script and optionally a backend token service |
| **UX friction** | Zero (fully transparent) |
| **Billing** | Pay-per-token API pricing |
| **Headless** | Full support |
| **Security** | Excellent — enables short-lived, auto-rotated keys |
| **Maintenance** | Script must be maintained; TTL tuning needed |

**Implementation sketch**:
```bash
# ~/.claude/settings.json
{
  "apiKeyHelper": "/clouve/ai-studio/helpers/get-api-key.sh"
}

# /clouve/ai-studio/helpers/get-api-key.sh
#!/bin/bash
# Fetch a short-lived API key from Clouve's credential broker
curl -s -H "Authorization: Bearer $(cat /run/secrets/clouve-token)" \
     https://api.clouve.com/v1/credentials/anthropic | jq -r '.api_key'
```

**When to use**: If Clouve wants to manage API keys centrally (e.g., organization-wide key pools, usage tracking, key rotation) rather than requiring each user to bring their own key.

### 5.3 Clouve-Managed Proxy

```
Claude Code → Clouve proxy (attaches auth) → api.anthropic.com
```

| Dimension | Assessment |
|-----------|------------|
| **Complexity** | High — requires a custom API proxy, ANTHROPIC_AUTH_TOKEN or custom base URL |
| **UX friction** | Zero (fully transparent) |
| **Billing** | Clouve pays API costs and re-bills users |
| **Headless** | Full support |
| **Security** | Best — container never holds any credential |
| **Maintenance** | High — proxy must track API changes, handle rate limits, manage billing |

**Implementation sketch**:
```bash
# In container environment
export ANTHROPIC_API_KEY="clouve-session-token-xxxx"  # or use ANTHROPIC_AUTH_TOKEN
export ANTHROPIC_BASE_URL="https://ai-proxy.clouve.com/v1"
```

The proxy authenticates outbound requests with Clouve's master API key and tracks per-user usage.

**When to use**: If Clouve wants to offer "included AI minutes" as part of the marketplace subscription, abstracting away Anthropic billing entirely.

### 5.4 Session-Bound Token Broker

```
User authenticates in browser → AI Studio backend holds OAuth token → container gets scoped, time-limited access
```

| Dimension | Assessment |
|-----------|------------|
| **Complexity** | High — requires OAuth client registration with Anthropic + backend token management |
| **UX friction** | Lowest possible (browser-native OAuth popup) |
| **Billing** | User's subscription (Pro/Max) |
| **Headless** | Yes (token injected by backend) |
| **Security** | Good — short-lived, session-scoped tokens |
| **Maintenance** | High — OAuth client management, token refresh logic, Anthropic partnership |

**Blockers**: Requires Anthropic to either (a) support device flow, or (b) register Clouve as an OAuth client. Neither is available today.

### 5.5 Remote Control Mode

```
Claude Code runs inside container in remote-control mode → user connects from claude.ai/code or Claude Desktop
```

| Dimension | Assessment |
|-----------|------------|
| **Complexity** | Low — `claude remote-control` is a single command |
| **UX friction** | Moderate — user must have a Claude subscription and connect from a separate app |
| **Billing** | User's subscription (Pro/Max/Teams/Enterprise) |
| **Headless** | Yes (outbound HTTPS only) |
| **Security** | Excellent — credentials never enter the container; Anthropic manages auth |
| **Maintenance** | Low — first-party Anthropic feature |

**How it would work**:
1. AI Studio starts `claude remote-control` inside the container
2. User opens claude.ai/code or Claude Desktop and connects to the remote session
3. All auth is handled by Anthropic's infrastructure — the container only needs outbound HTTPS
4. No API key or OAuth token ever enters the container

**Limitations**:
- Requires Claude Pro/Max/Teams/Enterprise subscription (API keys not supported for remote control)
- User experience is split between AI Studio (file browser) and claude.ai/code (coding)
- Requires v2.1.51+ of Claude Code
- Team/Enterprise admins must enable remote control explicitly

This is documented in the existing [REMOTE_CONNECTIVITY_RESEARCH.md](REMOTE_CONNECTIVITY_RESEARCH.md).

---

## 6. Recommendation

### Primary Path: API Key Injection (Today)

**No changes needed.** The current implementation already provides zero-friction Claude Code authentication when `ANTHROPIC_API_KEY` is provisioned at deployment time. The flow:

1. Marketplace user enters their Anthropic API key during app deployment (captured as a `secret` env var)
2. Key is injected into the container via `/etc/profile.d/clouve-env.sh`
3. Claude Code reads it from the environment and authenticates automatically
4. Onboarding wizard is pre-skipped via `~/.claude.json`

**Improvement opportunity**: Add an `apiKeyHelper` script that fetches the key from a Clouve-managed credential store, enabling:
- Central key management and rotation
- Usage tracking and billing integration
- Organization-wide API key pools

### Secondary Path: Remote Control Mode (Today, Parallel Track)

For users who want to use their Claude subscription (not API billing), offer a "Remote Control" launch mode:
1. AI Studio starts `claude remote-control` instead of interactive `claude`
2. User connects from claude.ai/code or Claude Desktop
3. Auth is entirely handled by Anthropic — no credentials in the container

This is orthogonal to the API key approach and can coexist as a second launch option.

### Future Path: Device Flow OAuth (When Available)

Monitor [anthropics/claude-code#22992](https://github.com/anthropics/claude-code/issues/22992). When Anthropic ships RFC 8628 device flow:

1. Claude Code will display a URL + code in the terminal
2. User opens the URL in their browser, enters the code, and authorizes
3. Claude Code completes authentication using their subscription
4. No API key needed, subscription billing applies

This would be the ideal long-term solution. The AI Studio `.bash_profile` selector would simply launch `claude` without needing to resolve an API key for Claude Code, as the device flow prompt would appear naturally in the ttyd terminal.

---

## 7. Quick Reference: Environment Variables

| Variable | Purpose | Used By |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude Code | `.bash_profile` → Claude Code |
| `ANTHROPIC_AUTH_TOKEN` | Bearer token for proxy auth | Claude Code (if proxy approach used) |
| `ANTHROPIC_BASE_URL` | Custom API endpoint | Claude Code (if proxy approach used) |
| `CLAUDE_CONFIG_DIR` | Override `~/.claude/` credential directory | Claude Code |
| `CLAUDE_CODE_API_KEY_HELPER_TTL_MS` | Refresh interval for apiKeyHelper (ms) | Claude Code |
| `CLAUDE_CODE_USE_BEDROCK` | Route through AWS Bedrock | Claude Code |
| `CLAUDE_CODE_USE_VERTEX` | Route through GCP Vertex AI | Claude Code |
| `AI_STUDIO_CLIENT` | Force-select AI client (e.g., `claude-code`) | `.bash_profile` selector |

---

## 8. Sources

- [Claude Code Authentication Documentation](https://docs.anthropic.com/en/docs/claude-code/cli-reference)
- [Claude Code Headless / CI Mode](https://docs.anthropic.com/en/docs/claude-code/headless)
- [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control)
- [Managing API Key Environment Variables](https://support.claude.com/en/articles/12304248-managing-api-key-environment-variables-in-claude-code)
- [RFC 8628 — Device Authorization Grant](https://datatracker.ietf.org/doc/html/rfc8628)
- [GitHub Issue #22992 — Device Flow Feature Request](https://github.com/anthropics/claude-code/issues/22992)
- [GitHub Issue #34917 — OAuth in Headless/Docker](https://github.com/anthropics/claude-code/issues/34917)
- [AI Studio REMOTE_CONNECTIVITY_RESEARCH.md](REMOTE_CONNECTIVITY_RESEARCH.md) — Companion document covering remote desktop connectivity for all three AI clients
