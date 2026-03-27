# AI Studio Rich UI Investigation

## Current State

AI Studio runs Ubuntu 24.04 in a container with **ttyd** (web terminal) serving the AI client interaction at `/_clv/chat`. Users connect via browser, get a login shell, and an interactive bash selector lets them choose Claude Code, Gemini CLI, or OpenAI Codex CLI. The terminal is embedded in an iframe alongside FileBrowser in a split-pane layout. Authentication is handled by a custom Python server validating against `/etc/shadow`.

The terminal approach works but limits the experience to what a TTY can render — no rich markdown, no drag-and-drop file handling, no conversation history UI, no inline image previews.

---

## Candidate Approaches

### Option A: Integrate LibreChat (Standalone Open-Source Chat App)

**How it works:** Deploy LibreChat (React + Node.js/Express + MongoDB) as an additional service inside the AI Studio container or as a sidecar. It connects directly to AI provider APIs (Anthropic, OpenAI, Google) and provides a full ChatGPT-like web UI. Replace the ttyd iframe with a LibreChat iframe at `/_clv/chat`.

**What it entails:**

- Add MongoDB and LibreChat to the container (or compose stack)
- Configure LibreChat's `librechat.yaml` with provider endpoints and API keys
- Wire authentication (LibreChat supports OIDC, or we proxy auth via nginx)
- Theme to match Clouve branding via LibreChat's customization options

**Project details:**

| Attribute | Details |
|---|---|
| GitHub | [danny-avila/LibreChat](https://github.com/danny-avila/LibreChat) |
| Stars | ~35,000 |
| License | MIT |
| Frontend | React, Vite, Tailwind CSS |
| Backend | Node.js 20/22+, Express |
| Database | MongoDB (primary), MeiliSearch (search), vector DB for RAG |
| Auth | Email/password, OAuth2/OIDC (Azure AD, Keycloak, Okta, Google, GitHub, Discord, Apple), LDAP/AD, SAML, 2FA, RBAC |
| Docker | Docker Compose is the recommended deployment |
| Key Features | Multi-model switching, AI Agents, MCP support, Artifacts, Code Interpreter, DALL-E-3 image generation, OpenAPI Actions/Functions, message search, conversation branching/forking, presets, file uploads, RAG, custom endpoints |
| AI Providers | Direct integrations: OpenAI, Anthropic, Google (Vertex AI, Gemini), Azure OpenAI, AWS Bedrock, Groq, Mistral, OpenRouter, DeepSeek, Ollama |

### Option B: Integrate Open WebUI (Standalone Open-Source Chat App)

**How it works:** Similar to Option A but using Open WebUI (SvelteKit + Python/FastAPI + SQLite/PostgreSQL). Deploy alongside the existing services. Open WebUI connects to any OpenAI-compatible API endpoint.

**What it entails:**

- Add Open WebUI Python app to the container
- Configure AI provider connections via OpenAI-compatible proxy endpoints
- Set up OIDC or trusted-header auth integration
- Customize theme via admin panel

**Project details:**

| Attribute | Details |
|---|---|
| GitHub | [open-webui/open-webui](https://github.com/open-webui/open-webui) |
| Stars | ~129,000 |
| License | Custom "Open WebUI License" (branding restrictions for >50 users; NOT OSI-certified) |
| Frontend | SvelteKit, Tailwind CSS |
| Backend | Python, FastAPI |
| Database | SQLite (default), PostgreSQL supported |
| Auth | Email/password, OIDC/OAuth2, LDAP/AD, SAML, SCIM 2.0, trusted header auth |
| Docker | Primary deployment method; Kubernetes via Helm/Kustomize |
| Key Features | Full Markdown/LaTeX rendering, model builder, RAG with document uploads, image generation, voice/STT/TTS, code execution sandbox, PWA with offline support, Pipelines plugin framework, web search |
| AI Providers | Ollama (native), any OpenAI-compatible API (OpenAI, Anthropic via proxy, Google, Groq, etc.) |

### Option C: Build Custom Chat UI with Vercel AI SDK + AI Elements

**How it works:** Build a bespoke React chat application using the Vercel AI SDK for provider abstraction/streaming and AI Elements for pre-built chat components (message threads, input, markdown rendering). Host as a lightweight Next.js or Vite app inside the container. The backend uses AI SDK Core to route requests to whichever provider the user has configured.

**What it entails:**

- Scaffold a new React/Vite or Next.js app
- Use `useChat` hook + AI Elements components for the frontend
- Build a thin API layer (Node.js/Express) that reads the user's API key and proxies to the selected provider
- Implement conversation persistence (SQLite or filesystem)
- Build authentication integration with the existing Python auth server

**Project details:**

| Attribute | Details |
|---|---|
| GitHub | [vercel/ai](https://github.com/vercel/ai) |
| Stars | ~23,000 |
| License | MIT |
| Frontend | React (+ Vue, Svelte support) |
| Backend | Any Node.js framework |
| Database | None (you provide) |
| Auth | None (you provide) |
| Key Features | `useChat`/`useCompletion` hooks, streaming-first architecture, AI Elements (20+ production-ready React components for message threads, input, markdown rendering), provider-agnostic core |
| AI Providers | Unified interface for OpenAI, Anthropic, Google, Mistral, Cohere, AWS Bedrock, and more |

### Option D: Build Custom Chat UI with React Component Library (chatscope)

**How it works:** Similar to Option C but using lower-level React chat components from `@chatscope/chat-ui-kit-react` instead of AI Elements. More control, more work.

**What it entails:**

- Everything in Option C, plus manually implementing streaming display, markdown rendering, code highlighting, file handling
- Wire chatscope's `MessageList`, `ChatContainer`, `MessageInput` to a custom backend

**Project details:**

| Attribute | Details |
|---|---|
| GitHub | [chatscope/chat-ui-kit-react](https://github.com/chatscope/chat-ui-kit-react) |
| Stars | ~1,700 |
| License | MIT |
| npm Downloads | ~38,000/week |
| What it is | Pure React UI component library for chat interfaces (not an application) |
| Key Features | Message lists, chat containers, message input, typing indicators, avatars, conversation lists, sidebars. Companion `@chatscope/use-chat` hook for state management |
| Limitations | No AI integration built in; no streaming/markdown out of the box; somewhat dated visual design |

### Option E: Integrate LobeChat (Standalone Open-Source Chat App)

**How it works:** Deploy LobeChat (Next.js) as a standalone service. It can run in client-side mode (IndexedDB, no database needed) or server-side mode (PostgreSQL). Multi-provider support built in.

**What it entails:**

- Add LobeChat as a Next.js service
- Configure provider API keys via environment variables
- Set up authentication (Better Auth / NextAuth)
- Customize via theming system

**Project details:**

| Attribute | Details |
|---|---|
| GitHub | [lobehub/lobe-chat](https://github.com/lobehub/lobe-chat) |
| Stars | ~74,000 |
| License | Custom "LobeHub Community License" (commercial derivative works require a commercial license; NOT standard Apache 2.0) |
| Frontend | Next.js, Ant Design, custom lobe-ui component library, Zustand |
| Backend | Next.js Edge Runtime (serverless) |
| Database | Client-side IndexedDB (default), PostgreSQL for server-side mode (via Prisma) |
| Auth | Better Auth / NextAuth — OAuth providers, email login, credential login, magic links |
| Docker | Docker image available; also supports Vercel/Zeabur/Railway one-click deploy |
| Key Features | Knowledge Base with RAG, plugin marketplace, TTS/STT, vision/image analysis, Artifacts, agent marketplace, file upload, i18n, responsive design |
| AI Providers | OpenAI, Anthropic Claude, Google Gemini, Ollama, AWS Bedrock, Azure, Mistral, Perplexity, DeepSeek, Qwen |

### Option F: Desktop App (Electron/Tauri)

**How it works:** Package a chat UI as a desktop application that users install locally. Connects to AI provider APIs directly.

**What it entails:**

- Build or fork an existing chat app into an Electron/Tauri shell
- Handle distribution, auto-updates, cross-platform builds
- Manage local credential storage

---

## Comparative Analysis

| Dimension | A: LibreChat | B: Open WebUI | C: Vercel AI SDK (Custom) | D: chatscope (Custom) | E: LobeChat | F: Desktop App |
|---|---|---|---|---|---|---|
| **Implementation complexity** | Medium | Medium | Medium-High | High | Medium | Very High |
| **Time to MVP** | 2-3 weeks | 2-3 weeks | 4-6 weeks | 6-8 weeks | 2-3 weeks | 8-12 weeks |
| **UX quality** | High — polished ChatGPT-like UI, streaming, markdown, file upload, conversation branching | Very High — most feature-rich (RAG, voice, image gen, code sandbox) | High — modern AI Elements components, but you build the shell | Medium — dated visual style, manual streaming/markdown work | Very High — most polished design, agent marketplace | High but decoupled from web platform |
| **Clouve integration** | **Excellent** — Node.js/Express/React matches Thermo/Meso stack. OIDC auth. Docker-native. Runs behind nginx easily | Good — Python/FastAPI is a different stack but Docker-native. OIDC/trusted-header auth | **Excellent** — React fits Meso, Node.js fits Thermo. Full control over auth integration | Good — React-based but everything is manual | Good — Next.js is close to React. Docker support. OAuth auth | Poor — separate distribution, can't embed in platform |
| **Customizability & branding** | Good — `librechat.yaml` config, CSS theming, custom endpoints. Can fork (MIT) | Limited — custom license requires keeping Open WebUI branding for >50 users | **Full control** — you own every pixel | **Full control** — you own every pixel | Good — strong theming system, lobe-ui components | Full control but separate from web UI |
| **Scalability & maintainability** | Good — backed by ClickHouse, active community, MIT means we can fork if needed | Good — huge community but license risk. Python stack is a second language for the team | Moderate — we own the codebase, which means we maintain it. AI SDK is well-maintained (MIT, Vercel-backed) | Low — heavy maintenance burden, all custom code | Good — large community, but license restricts commercial derivatives | Low — cross-platform desktop maintenance is expensive |
| **Licensing & cost** | **MIT** — no restrictions | **Custom** — branding restrictions >50 users, enterprise license required for white-label | **MIT** (AI SDK) — no restrictions | **MIT** (chatscope) — no restrictions | **Custom** — commercial derivative works require license | N/A |

---

## Recommendation: LibreChat (Phase 1) with Custom UI Migration Path (Phase 2)

### Phase 1 — Integrate LibreChat (weeks 1-3)

**Why LibreChat is the best fit for Clouve:**

1. **Tech stack alignment.** LibreChat is React + Node.js/Express — the same stack as Meso (React) and Thermo (Node.js/Express). The team can read, debug, and contribute to the codebase from day one. No Python backend (Open WebUI) or SvelteKit (HuggingChat) mismatch.

2. **MIT license with no strings.** Unlike Open WebUI (branding restrictions) and LobeChat (commercial derivative restrictions), LibreChat's MIT license lets Clouve fully rebrand, modify, and distribute without constraint. This is non-negotiable for a marketplace product.

3. **Best-in-class multi-provider support.** LibreChat has direct, first-class integrations for Anthropic, OpenAI, and Google — the exact three providers AI Studio supports. No OpenAI-compatible proxy shims needed. Each provider's native features (streaming, tool use, vision) work correctly.

4. **Enterprise auth out of the box.** OIDC/OAuth2, LDAP, SAML, 2FA, role-based access control. This plugs directly into Clouve's existing auth infrastructure and gives us SSO for free.

5. **Docker-native deployment.** LibreChat's primary deployment is Docker Compose. It fits naturally into the AI Studio container architecture — either as a sidecar service or embedded in the existing container behind nginx.

6. **Sustainable project.** Acquired by ClickHouse in 2025, 35K stars, 23M+ container pulls, active 2026 roadmap. Low risk of abandonment.

**Implementation sketch:**

- Add LibreChat + MongoDB services to `docker-compose.yml`
- Configure `librechat.yaml` with provider endpoints, reading API keys from the existing env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`)
- Proxy LibreChat behind nginx at `/_clv/chat` (replacing ttyd)
- Integrate auth via OIDC or trusted-header passthrough from the existing Python auth server
- Apply Clouve branding via LibreChat's theming configuration
- Keep ttyd available at `/_clv/terminal` for power users who prefer the CLI experience

### Phase 2 — Custom UI with Vercel AI SDK (optional, months 3-6)

If LibreChat proves too rigid for deep Clouve platform integration (e.g., we need marketplace-specific features like workspace sharing, deployment-aware context, or tight coupling with Thermo's GraphQL API), migrate to a custom React UI built on Vercel AI SDK + AI Elements.

**Why this is the right Phase 2, not Phase 1:**

- AI SDK gives full control but requires building the application shell, persistence layer, auth, conversation management, and all the "boring" features LibreChat already has
- Starting with LibreChat validates the UX direction and user expectations before investing in custom development
- LibreChat's MIT codebase serves as a reference implementation — we can port proven patterns

---

## Caveats and Risks

| Risk | Mitigation |
|---|---|
| **MongoDB dependency** — LibreChat requires MongoDB, adding operational complexity | Use MongoDB as a sidecar container with a persistent volume. For the AI Studio single-container model, embed MongoDB directly (it runs well in containers). |
| **Resource footprint** — LibreChat + MongoDB adds ~300-500MB RAM to the container | AI Studio containers already have generous resource allocation (10Gi volumes). Monitor and tune. Consider SQLite adapter if one materializes in the LibreChat roadmap. |
| **Upstream drift** — LibreChat may evolve in directions that don't serve Clouve | MIT license means we can fork at any point. Pin to a known-good version and cherry-pick updates. |
| **Loss of CLI power-user features** — terminal AI clients have capabilities (file editing, shell access) that a chat UI cannot replicate | Keep ttyd available as a secondary interface. The chat UI serves the 80% case; power users retain terminal access. |
| **API key management UX change** — current flow validates keys interactively in the terminal | LibreChat handles API keys via its own settings UI, or we pre-configure them via environment variables (transparent to the user). |

---

## Prerequisites Before Starting

1. **Decide on single-container vs. multi-service architecture** — Adding LibreChat + MongoDB works best as additional Docker Compose services rather than cramming into the existing single container
2. **Evaluate Clouve auth integration** — Determine whether to use OIDC (cleanest) or trusted-header auth (simplest) from the existing Python auth server
3. **Define the branding requirements** — Gather Clouve's color tokens, logo assets, and UX guidelines to apply theming from the start
4. **Decide on ttyd retention** — Whether to keep terminal access as a parallel option or fully replace it
