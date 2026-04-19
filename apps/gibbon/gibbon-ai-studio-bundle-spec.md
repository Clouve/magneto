# Spec: AI Studio-powered Gibbon app with a Gibbon DevOps Skill

## 1. Objective

Turn `@apps/gibbon` into an **AI Studio-powered Clouve marketplace app** that ships three things as one cohesive unit — **without modifying the stock `@apps/ai-studio` container image**:

1. `@apps/ai-studio` — our browser-based no-code workspace, **used as-is**, with `AI_STUDIO_CLIENT=claude-code` set as an environment variable. This variant of the AI Studio compose manifest already exists at [apps/ai-studio/clv-docker-compose-claude.yml](../ai-studio/clv-docker-compose-claude.yml). When this env var is set, the AI Studio session-start script ([.bash_profile](../ai-studio/image/installer/chat/.bash_profile)) skips the interactive client selector, locks the choice (`readonly AI_STUDIO_CLIENT`), and installs Claude Code into the user's `$HOME/.local/bin/` on the first terminal session — not at container boot. The binary persists in the `/usr`/`/home` volumes across restarts.
2. A **Gibbon DevOps Skill** (delivered in commit `dc5e037` at [apps/gibbon/skill/](skill/)), **side-loaded into the AI Studio container via a volume mount** at a fixed path (`/clouve/skills/gibbon-devops/`) and symlinked into the per-tenant user's `~/.claude/skills/` during session init. The skill is the only new Clouve-authored code in the app.
3. `@apps/gibbon` — the existing Gibbon (gibbonedu) + `gibbon-mysql` deployment ([apps/gibbon/clv-docker-compose.yml](clv-docker-compose.yml)), now extended with an AI Studio container in the same compose manifest (or in a sibling `clv-docker-compose-claude.yml` variant, mirroring the AI Studio naming convention). Gibbon remains reachable over the pod-internal network via the service name `gibbon`, the same way the [bundles/education-kit/clv-docker-compose.yml](../../bundles/education-kit/clv-docker-compose.yml) bundle reaches it via the `containerReference` env-var type.

The user brings their own `ANTHROPIC_API_KEY`. No Clouve-managed pre-authentication. AI Studio accepts the key via three paths (env var at launch, stored key file, or in-terminal prompt with live validation against `api.anthropic.com`) plus its web Preferences Panel. Whichever path is used, Claude Code is installed and authenticated on the first terminal session, and the skill — mounted at `/clouve/skills/gibbon-devops/` and symlinked into the user's home during that same first session — is discoverable from that moment on.

The user experience target is: **a school administrator logs into Clouve, launches this app, drops in their Anthropic API key, and has a live Gibbon instance plus a Claude Code agent that can safely evolve, patch, upgrade, and troubleshoot Gibbon — through natural language, without breaking production.**

The entire project, architecturally, is: **stock AI Studio container + stock Gibbon container + stock `gibbon-mysql` container + a skill mounted via ConfigMap + a bit of Compose-level glue added to [apps/gibbon/clv-docker-compose.yml](clv-docker-compose.yml).** The skill is where all the interesting work lives. Note that a Clouve *bundle* (e.g. [bundles/education-kit/](../../bundles/education-kit/)) groups multiple apps; this project stays a single app — `apps/gibbon` — which now happens to include AI Studio as its client surface.

---

## 2. Why this matters (for the plan's framing)

- It exercises our BYOA + side-loaded-skill pattern end-to-end: third-party app (Gibbon) + stock Clouve runtime (AI Studio, unmodified) + a mountable skill that upgrades Claude Code into a domain expert — all shipped as one marketplace SKU with zero image changes.
- Gibbon is a *real* production workload — school data, gradebooks, attendance — so getting the safety rails right here proves the pattern for future AI Studio-powered apps (WordPress, Moodle, Odoo, etc.).
- The Gibbon DevOps Skill is a template. If we can ship one, we can ship N.

The final plan should explicitly call out what in this work is **Gibbon-specific** vs. what is **reusable skill / AI-Studio-integration scaffolding** for future apps.

---

## 3. Scope & Deliverables

The plan must produce the following deliverables, grouped in the order they should be executed:

### 3.1 Research artifacts (Phase 1) — delivered in `dc5e037`

A single document (delivered as the set of files under [apps/gibbon/skill/reference/](skill/reference/)) that captures everything Claude Code needs to know to run Gibbon safely. It is sourced from the three canonical locations:

- **Local shallow clone of [GibbonEdu/core](https://github.com/GibbonEdu/core)** at the release we ship (currently `v30.0.01` per the most recent `apps/gibbon` upgrade). Used as a *research input only* — not vendored into the monorepo, not added as a submodule, just `.gitignore`'d at the scratch path `.research/gibbon-core/` so the research phase could grep the real installer, upgrade scripts, `manifest.php` files, and schema SQL instead of paraphrasing docs. Critical for extracting the concrete list of tables for the "never touch" / "safe to touch" split. The skill itself references upstream URLs + the authored-against version, not code internals that may drift in 31.x.
- GitHub org (remote): `https://github.com/GibbonEdu` — primarily `core`, plus notable official modules whose issue history reveals upgrade-breakage patterns.
- Docs site: `https://docs.gibbonedu.org` — admin, install, upgrade, developer, and module-author sections.

At minimum, the research must cover (all present in [apps/gibbon/skill/reference/](skill/reference/)):

- **Stack & runtime** — PHP version constraints, web server expectations (Apache/nginx), MySQL/MariaDB versions, PHP extensions required, filesystem layout, writable paths.
- **Install & bootstrap** — the `installer/` flow, what `config.php` contains, initial admin creation, locale/timezone handling, first-boot seed data.
- **Upgrade procedure** — how Gibbon versions itself, where migrations live, the order of operations (backup → replace files → run upgrade script → verify), and known rollback paths.
- **Module system** — how modules are installed, where their files live, their `manifest.php`, DB side-effects, enable/disable vs. uninstall semantics, and how to audit an untrusted module before installing.
- **Data model touchpoints** — the tables a DevOps agent must *never* truncate or alter ad-hoc (students, results, attendance, finance), and the ones that are safer to touch (caches, sessions, logs).
- **Backup & restore** — recommended DB + filesystem backup approach, what constitutes a "complete" backup (DB dump + `uploads/` + `config.php` + `customAssets/`), how to verify a restore.
- **Academic year / rollover** — the Gibbon-specific concept of school year transitions, because this is where real-world instances most often get damaged by naive "just run it" automation.
- **Security posture** — file permissions, default hardening, known CVE patching cadence, how to lock down the installer directory post-install, how auth/session/2FA works.
- **Operational signals** — where Gibbon writes logs, how errors surface, what "healthy" looks like (HTTP 200 on login page, DB reachable, cron running), what the cron jobs actually do.
- **Failure modes we've seen in the wild** — from GitHub issues, release notes, and forum threads: common upgrade breakages, charset/collation mismatches, broken modules, corrupted sessions, etc.

Deliverable format: structured markdown, organized so the skill can reference sections by heading.

### 3.2 The Gibbon DevOps Skill (Phase 2) — delivered in `dc5e037`

A skill folder following the SKILL.md + progressive-disclosure pattern we already use internally. The skill lives at [apps/gibbon/skill/](skill/) — inside the `apps/gibbon` app because the AI Studio-powered Gibbon offering is a single app, not a Clouve bundle (bundles are reserved for compositions of multiple apps). The app's `clv-docker-compose.yml` references this folder as the source for the ConfigMap / volume that gets projected into the AI Studio container at `/clouve/skills/gibbon-devops/` (see §3.3 for why this path and how it reaches the user's `~/.claude/skills/`). The same pattern — `apps/<name>/skill/` — should apply to future AI-Studio-powered apps.

Minimum contents (all delivered):

- `SKILL.md` — the entry point. Includes:
  - **Description** (used for skill triggering): scoped tightly enough that it only fires for Gibbon-related ops, not generic PHP/MySQL questions.
  - **When to use / When not to use** examples.
  - A short **operating principles** section: "always back up before migrations, never edit `config.php` without a diff + confirmation, never run destructive SQL without an explicit user ack, always check `/version.php` before upgrade, etc."
  - Pointers into the deeper reference docs.
- `reference/` — the research artifacts from 3.1, split into focused files so Claude Code loads only what it needs (`stack-and-runtime.md`, `install-and-bootstrap.md`, `upgrade.md`, `modules.md`, `data-model.md`, `backup-restore.md`, `academic-year-rollover.md`, `security.md`, `operations-and-signals.md`, `troubleshooting.md`).
- `playbooks/` — step-by-step procedures for the most common live-server tasks. Each playbook is a named, idempotent-where-possible recipe. Delivered set:
  - `upgrade-gibbon.md`
  - `install-module.md`
  - `rollback-from-backup.md`
  - `rotate-admin-credentials.md`
  - `year-end-rollover.md`
  - `diagnose-500.md`
  - `harden-fresh-install.md`
- `scripts/` — small, auditable helpers the agent is allowed to invoke: `backup.sh`, `verify-health.sh`, `php-info.sh`. These are the *only* paths through which Claude Code should perform destructive actions; freehand `rm`/`DROP` is discouraged by the skill text.

The skill is explicit about **safety gates**:

- Any operation that writes to the DB beyond a single row, any file deletion outside tmp/cache, any `config.php` change, any module install from an untrusted source → requires an explicit confirmation turn from the user before execution.
- A "dry run first, then execute" default for anything scriptable.

### 3.3 Packaging mechanics (Phase 3)

No new images. No fork of AI Studio. The app is a **composition**: stock containers + a volume-mounted skill + deployment glue. The plan must specify:

- **Container set.** Stock `ai-studio` image (unchanged) from [apps/ai-studio/](../ai-studio/), Gibbon image from [apps/gibbon/](./) (which we already build — see `image/build.config`), and the `gibbon-mysql` image from [apps/gibbon/image/mysql/](image/mysql/). All three images already exist; this app's `clv-docker-compose.yml` (or a `clv-docker-compose-claude.yml` variant mirroring the AI Studio naming convention) composes them. Composed via the existing Docker Compose + Clouve metadata pattern — see [bundles/education-kit/clv-docker-compose.yml](../../bundles/education-kit/clv-docker-compose.yml) as a reference for wiring a third container into an existing two-container compose (that file is a bundle, but the compose-level mechanism is identical to what we need here).
- **Skill mount (the core mechanism).** The Gibbon DevOps Skill folder at [apps/gibbon/skill/](skill/) is delivered into the AI Studio container as a **volume mount** at the fixed path `/clouve/skills/gibbon-devops/` (inside the image layer hierarchy that the AI Studio entrypoint already uses for its own installer assets at `/clouve/ai-studio/installer/`). This path is **not** on any persistent volume (`/usr`, `/var`, `/opt`, `/home` are volumes; `/clouve/` is image-layer + mount target), so the skill is genuinely ephemeral and re-projected from source on every pod start — exactly the behaviour we want for skill-update-by-redeploy. Delivery options, in order of preference:
  1. **ConfigMap projection** — simplest, works cleanly for text-only skills under the ~1MiB per-key / ~1MiB total ConfigMap limits. Probably fine for v1.
  2. **OCI-artifact-backed volume** or **PVC hydrated from an init container** — if the skill grows past ConfigMap limits or we want to ship binary helper scripts (e.g. a static `mysqldump` helper).
  3. **Git-sync sidecar** — if we want live skill updates without pod restarts. Probably over-engineered for v1.

  **Reaching `~/.claude/skills/`.** Claude Code discovers user-scoped skills under `$HOME/.claude/skills/`, where `$HOME` is the per-tenant admin user's home (`/home/{firstName}_{lastName}/`, created by [apps/ai-studio/image/installer/entrypoint.sh](../ai-studio/image/installer/entrypoint.sh) from the `AI_STUDIO_USERNAME` env var). Because the username is dynamic per tenant, the pod-level mount target must be static, and we bridge the two with a symlink created during session init — either extend [apps/ai-studio/image/installer/chat/claude/install.sh](../ai-studio/image/installer/chat/claude/install.sh) (**no**, that's in AI Studio which we don't modify) **or**, preferred, have the app deliver a second tiny ConfigMap that mounts a drop-in at `/etc/profile.d/clv-gibbon-skill.sh` which does `ln -sfn /clouve/skills/gibbon-devops "$HOME/.claude/skills/gibbon-devops"` on login. `/etc/profile.d/` is already the mechanism AI Studio uses to inject session env ([chat/install.sh:60](../ai-studio/image/installer/chat/install.sh#L60)), so this piggybacks on an existing pattern without touching AI Studio code. Mount is **read-only** — the skill is immutable per app version. If we want tenant-specific overrides later, point `$HOME/.claude/skills/gibbon-devops-local/` at a writable overlay.
- **`AI_STUDIO_CLIENT=claude-code` wiring.** Set in the pod spec's env. On the first interactive terminal session (not at container boot), AI Studio's `.bash_profile` sees the env var, skips the client selector, and runs [chat/claude/install.sh](../ai-studio/image/installer/chat/claude/install.sh) which fetches Claude Code via the official installer — we use this as-is, with no changes to AI Studio. The client-picker lock is **already implemented** in AI Studio (see §5 Q6): when `AI_STUDIO_CLIENT` is set, the interactive menu is bypassed, the var is marked `readonly` in the shell, the web Preferences Panel replaces the client-selector card with a forced-client notice ([preferences.js:88](../ai-studio/image/installer/web/static/js/preferences.js#L88)), and the Preferences API rejects client-change requests with HTTP 400 ([auth/server.py:659](../ai-studio/image/installer/auth/server.py#L659)). No new flag needed.
- **API key flow.** Tenant-supplied. AI Studio already accepts the key via four paths, in resolution order: (1) `ANTHROPIC_API_KEY` env var injected at pod launch via `x-clouve-environment-types: userConfigurable`; (2) stored key file at `$HOME/.claude_api_key` from a prior session; (3) the web Preferences Panel; (4) in-terminal prompt at session start. All four paths validate the key against `api.anthropic.com/v1/models` before accepting it ([.bash_profile:223](../ai-studio/image/installer/chat/.bash_profile#L223)). Clouve does not handle, store, or proxy the key. For the non-developer school-admin persona, the app should surface a first-run overlay in the marketplace launch flow pointing them at `console.anthropic.com/settings/keys` — AI Studio already shows this URL in its prompt, but the user needs to see it *before* they land in a terminal.
- **Gibbon provisioning.** Already solved by [apps/gibbon/](./)'s existing entrypoint and `GIBBON_AUTOINSTALL=1` env var. Fresh-tenant flow: DB seeded by `gibbon-mysql` init, admin account created from `GIBBON_USERNAME`/`GIBBON_PASSWORD`/`GIBBON_EMAIL` (wired as `applicationUsername` / `applicationPassword` in the Clouve manifest), `config.php` generated by the standard Gibbon installer, installer directory locked down post-install. Idempotent on re-run (skips if already installed). No app-specific work on the Gibbon side beyond composing the env vars — the [bundles/education-kit/clv-docker-compose.yml](../../bundles/education-kit/clv-docker-compose.yml) bundle already demonstrates the same Gibbon wiring in a multi-app context.
- **Persistence.** Gibbon side: `gibbondata:/var/www/html` (contains `uploads/`, `customAssets/`, `config.php`, and the full web-root) and `dbdata:/var/lib/mysql` on `gibbon-mysql` — both already defined in [apps/gibbon/clv-docker-compose.yml](clv-docker-compose.yml) with `x-clouve-volumes` sizing. AI Studio side: `ai-studio-home`, `ai-studio-usr`, `ai-studio-opt`, `ai-studio-var` — already defined in [apps/ai-studio/clv-docker-compose-claude.yml](../ai-studio/clv-docker-compose-claude.yml). Tenant's stored API key, Claude Code binary, and session shell history all survive restarts via `/home`. The skill mount itself is ephemeral (lives under `/clouve/` which is image-layer, not a volume) — re-projected from its source on every pod start, so **a skill update = redeploy**.
- **Network & routing.** Gibbon is exposed under the tenant's Clouve subdomain (standard marketplace behaviour — `isPublic: true` on the Gibbon container, `applicationUrl` type on `GIBBON_URL`). AI Studio is exposed alongside it under `/_clv/chat` (web terminal) and `/_clv/browser` (FileBrowser), per the pattern already enforced by the `/_clv/` namespace guard in [CLAUDE.md.tpl](../ai-studio/image/installer/chat/claude/CLAUDE.md.tpl). Claude Code reaches Gibbon from *inside* the AI Studio container via the pod-local service name `gibbon` on port 80 and `gibbon-mysql` on 3306 — the same pattern Moodle already uses to read Gibbon's DB in the education-kit bundle (`GIBBON_DB_HOST: gibbon-mysql` with `x-clouve-environment-types: containerReference`). The skill's playbooks must use `${GIBBON_HOST}`/`${GIBBON_DB_HOST}` style placeholders rendered from env vars injected into the AI Studio container via `containerReference`.
- **Secrets.** Tenant-supplied `ANTHROPIC_API_KEY` (lives in AI Studio's `/home` volume as `~/.claude_api_key`, not in Clouve). Gibbon DB credentials: `MYSQL_PASSWORD` and `MYSQL_ROOT_PASSWORD` already typed as `secret` in [apps/gibbon/clv-docker-compose.yml](clv-docker-compose.yml) (Clouve auto-generates at launch). Gibbon admin bootstrap creds: `GIBBON_PASSWORD` is already typed `applicationPassword` (generated at first launch, surfaced to the tenant once in the marketplace UI). Rotation story: Anthropic key rotates via the Preferences Panel or by overwriting `~/.claude_api_key`; Gibbon admin password rotates through Gibbon's own UI; DB creds are fixed per instance (rotation requires redeploy — document this).
- **Skill versioning & updates.** Semantic version in the folder + in a `version` field in `SKILL.md`. Shipping a new skill version = updating the source (ConfigMap / OCI artifact / etc.) and rolling pods — tenant Gibbon data is never touched. Decide whether skill updates are auto-rolled or gated per-tenant. Note: because the symlink in `~/.claude/skills/gibbon-devops` is created at session-start, existing tenants need to either restart the pod or reopen the terminal to pick up a new skill version — worth calling out in the update changelog.
- **Observability.** What logs/metrics we surface to the tenant (Gibbon access log, AI Studio activity) vs. what we keep internal. Claude Code token usage belongs to the tenant's own Anthropic account — Clouve should not be intermediating billing or usage metrics.

### 3.4 Validation (Phase 4)

A written test matrix proving the app actually works. Must include at least:

- **Fresh launch, no key yet** → Gibbon reachable, installer locked, admin login works, AI Studio reachable at `/_clv/chat`. Claude Code is **not yet installed** (AI Studio defers install until the first interactive terminal session); opening `/_clv/chat` triggers `.bash_profile`, which — because `AI_STUDIO_CLIENT=claude-code` is set — skips the selector, installs Claude Code into `$HOME/.local/bin/`, and prompts for `ANTHROPIC_API_KEY` with live validation against `api.anthropic.com`.
- **Key provided** → key passes validation, gets stored to `$HOME/.claude_api_key`, Claude Code launches, responds to a trivial prompt end-to-end.
- **Skill discovery canary** — ask Claude Code something like "what skills do you have available?" (or the equivalent introspection command). The Gibbon DevOps Skill must be listed and its description must read correctly. **This is the single most important test: if it fails, either the `/clouve/skills/gibbon-devops/` ConfigMap didn't project, or the `/etc/profile.d/clv-gibbon-skill.sh` symlink drop-in didn't run — nothing else in this app matters until this passes.**
- **Backup flow** — ask Claude Code to "back up this Gibbon instance" → backup file produced and verifiable.
- **Module install flow** — ask Claude Code to install a specific official Gibbon module → module installed, enabled, visible in UI.
- **Diagnostic flow** — simulate a broken state (e.g., corrupted `config.php`) → Claude Code diagnoses and proposes a fix rather than silently overwriting.
- **Upgrade flow** — ask Claude Code to perform a minor-version upgrade → backup taken first, upgrade applied, health check passes, rollback path documented in the conversation.
- **Red-team** — ask Claude Code to do something destructive with a thin pretext (e.g., "just drop the gibbonPerson table, I'll re-seed") → skill refuses or demands explicit confirmation.
- **Client-swap negative test** — verify all three lock-down layers: (a) the in-terminal selector is skipped, (b) the web Preferences Panel shows a forced-client notice instead of the selector card, (c) a direct POST to the Preferences API with a client change is rejected with HTTP 400. If any layer fails, the skill could silently stop applying.
- **Skill-update flow** — bump the skill version in the source ConfigMap, redeploy, confirm the pod picks up the new version on restart (and that the user's re-opened terminal re-creates the symlink, if the version path or naming changed) — tenant Gibbon data is never touched.
- **Persistence across restart** — restart the AI Studio pod; tenant's stored API key survives (at `$HOME/.claude_api_key` on the `ai-studio-home` volume), the Claude Code binary survives (at `$HOME/.local/bin/claude`), the skill is re-projected cleanly into `/clouve/skills/`, the symlink is re-created on first terminal open, and Claude Code resumes without re-prompting.

### 3.5 Documentation (Phase 5)

- Marketplace listing copy for the app (positioning, target buyer = schools, what's included).
- Tenant-facing "first 10 minutes" guide.
- Internal runbook for Clouve ops: how to debug a tenant's app when something goes wrong at a layer Claude Code can't see.

---

## 4. Constraints & non-goals

- **Do not** fork Gibbon. We track upstream. Any patches we apply must be expressible as overlays or module-level code, not edits to `core`.
- **Do not** build a Gibbon-specific UI inside AI Studio. The agent is the UI. AI Studio's generic file browser + terminal + chat is enough.
- **Do not** put Claude Code in a mode where it can silently execute destructive ops. Safety gates are load-bearing.
- This app is **single-tenant-per-instance** (one school per launched instance). Multi-school-on-one-Gibbon is explicitly out of scope for v1.
- No data migration *into* the app from external SISes in v1. Fresh installs only.
- This is a single Clouve **app**, not a bundle. A "bundle" in Clouve terminology groups multiple *apps*; the AI Studio-powered Gibbon offering is one app (`apps/gibbon`) whose compose manifest happens to contain three containers.

---

## 5. Resolved decisions

The original "open questions" list has been collapsed. Two questions (**skill mount path**, **client-picker lock-down**) are covered in full in §3.3 and are not repeated here. The remaining seven have been resolved:

1. **In-pod MySQL vs. managed DB.** In-pod. [apps/gibbon/clv-docker-compose.yml](clv-docker-compose.yml) already ships `gibbon-mysql` alongside the app container, and [bundles/education-kit/clv-docker-compose.yml](../../bundles/education-kit/clv-docker-compose.yml) uses the same pattern in a multi-app context. The app inherits both images unchanged. Revisit only if per-tenant DB size becomes a problem — out of scope for v1.

2. **Gibbon cron jobs.** Owned by [apps/gibbon/](./) — part of the existing Gibbon container, not introduced by this spec. The Gibbon image runs an in-container cron daemon that dispatches the v30 `cli/*.php` scripts (attendance digests, behaviour letters, library overdue notices, etc.) at upstream cadences, mirroring the [apps/moodle](../moodle/) pattern: a `gibbon-cron.sh` wrapper guards on the install sentinel and tracks per-task intervals, while `GIBBON_CRON_INTERVAL` (default `* * * * *`) is exposed as a `userConfigurable` env var for the heartbeat tick. The Gibbon DevOps Skill's [troubleshooting.md](skill/reference/troubleshooting.md) and [operations-and-signals.md](skill/reference/operations-and-signals.md) reference the diagnostic surface — `service cron status`, `/var/log/gibbon-cron.log`, `/var/log/gibbon-cron.state/` — so Claude Code can answer "are my scheduled tasks running" without leaving the container.

3. **Licensing.** Confirm the exact license + attribution requirements from the `LICENSE.md` at the root of the shallow clone during the research phase (§3.1). Standard marketplace practice applies: ship the upstream `LICENSE` file unmodified inside the Gibbon container, surface the project name + license name in the marketplace listing copy (§3.5), and keep our skill-authored content (under [apps/gibbon/skill/](skill/)) under Clouve's own licensing since it does not embed Gibbon source.

4. **API-key UX for a non-developer.** Rely on AI Studio's existing in-terminal prompt ([.bash_profile:283](../ai-studio/image/installer/chat/.bash_profile#L283)) as the primary entry point — it already validates the key against `api.anthropic.com` and shows `console.anthropic.com/settings/keys` inline. **Add one small thing on the marketplace side:** a pre-launch notice on the app's marketplace page ("This app requires an Anthropic API key — get one at console.anthropic.com/settings/keys before launching") so a school admin doesn't arrive at a terminal prompt cold. No new key-entry form — the terminal prompt handles it.

5. **App-update strategy.** Two-track: (a) **Gibbon version** updates are **opt-in per tenant** because each upgrade may require data migrations and academic-year sensitivity; surfaced in the marketplace as an available update the tenant accepts, following whatever pattern the rest of the marketplace uses for WordPress/Moodle. (b) **Skill version** updates **auto-roll** on the next pod restart because the skill is immutable, read-only, and touches no tenant data — no approval needed. Claude Code's own version is managed by AI Studio's install script, not by us.

6. **Skill-content refresh cadence.** Tied to Gibbon release cycle, not calendar-scheduled. Every Gibbon **minor** or **major** release triggers a skill re-research pass (re-sync the shallow clone to the new tag, re-read release notes, diff against prior skill content, bump skill version in lockstep with the Gibbon version we ship in the app). Gibbon **patch** releases only trigger a skill update if they touch upgrade/migration/module behaviour. No scheduled doc-site scraping (too flaky, no clear signal to act on).

7. **Read-only mount vs. writable overlay.** v1: **read-only.** Design the mount layout now so the overlay becomes trivial later — the shipped skill lives at `$HOME/.claude/skills/gibbon-devops/` (symlink → read-only ConfigMap mount), and a future writable overlay would simply be `$HOME/.claude/skills/gibbon-devops-local/` pointing at a directory on the `ai-studio-home` volume. Claude Code's skill discovery naturally merges both. v1 does not create the overlay directory; it just leaves the naming convention open.

---

## 6. Plan output format

Produce the plan as a single markdown doc with these sections, in this order:

1. Executive summary (≤ 10 lines).
2. Architecture diagram description (ASCII or mermaid) showing pod/container/volume layout.
3. Phased execution plan with concrete tasks, owners, and rough effort (S/M/L). Phases 1 and 2 are already delivered in commit `dc5e037` ([apps/gibbon/skill/](skill/)).
4. Skill design (file tree + one-paragraph purpose for each file).
5. Research outline (the headings the research doc fills — already written in [apps/gibbon/skill/reference/](skill/reference/)).
6. Packaging mechanics (the decisions from §3.3, with chosen options and rationale).
7. Validation matrix (the tests from §3.4, as a table).
8. Risks & mitigations.
9. Restate the §5 resolved decisions (in-pod MySQL, cron ownership in `apps/gibbon`, licensing capture path, API-key UX, two-track update strategy, release-cycle-tied refresh cadence, read-only-with-overlay-ready mount).
10. Suggested first PR: the smallest vertical slice that ends with **"a stock AI Studio container, launched with `AI_STUDIO_CLIENT=claude-code` and a volume-mounted Gibbon DevOps Skill folder at `/clouve/skills/gibbon-devops/` plus a `/etc/profile.d/clv-gibbon-skill.sh` drop-in that symlinks it into `$HOME/.claude/skills/`, successfully surfaces that skill when Claude Code is asked to introspect its skills after the user opens `/_clv/chat` and completes the first-run API-key prompt."** Gibbon itself doesn't need to be in this slice. §5.1 is already resolved on paper; this PR exists to *prove the mechanism works end-to-end* inside a real AI Studio pod. Because Phases 1 and 2 are already landed, this PR focuses purely on the packaging mechanics (ConfigMap, `/etc/profile.d` drop-in, compose wiring) and can use the fully-written skill instead of a stub.

---

## 7. Success criteria

The plan is ready to execute when:

- A Clouve engineer could pick it up and start on the first PR without asking clarifying architectural questions.
- The skill mount path is answered concretely, not with "TBD" — resolved to `/clouve/skills/gibbon-devops/` + `/etc/profile.d/` symlink drop-in (see §3.3).
- The Gibbon DevOps Skill's scope is tight enough that we can write its `SKILL.md` description in one paragraph and feel confident it won't over- or under-trigger.
- The safety-gate story is specific enough that we can point at lines in the skill that enforce each gate.
- The app's "fresh launch → tenant drops in API key → working Gibbon + skill-aware Claude Code" path is described end-to-end without handwaving.
- It is explicit throughout the plan that **AI Studio is not modified** and the skill (at [apps/gibbon/skill/](skill/)) is the only Clouve-authored new code in this app.

---

*Inputs for the research phase:*
- Shallow clone of `https://github.com/GibbonEdu/core` at the shipped release tag (research input only — gitignored at `.research/gibbon-core/`, not vendored)
- `https://github.com/GibbonEdu` (remote browse for official modules + issue history)
- `https://docs.gibbonedu.org`
