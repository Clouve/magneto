# Enable the AI Assistant (Magneto Agent) on the Odoo app

**Date:** 2026-06-24
**Status:** Approved (design); pending implementation plan
**Repos touched:** `magneto` (primary) and `magneto-skills` (the `odoo` skill plugin)

## Goal

Ship the **Magneto Agent** ("ai-assistant") sidecar with the Odoo marketplace app,
exactly as it is shipped today with **moodle** and **gibbon**. The agent is a
browser Claude Code workspace that operates the running Odoo instance and its
PostgreSQL database as a passwordless-sudo DevOps engineer, gated by safety rules
in the per-app persona and the Odoo DevOps skill.

Enablement is **not** a single switch. It is a coordinated set of artifacts across
the app image, the DB image, the marketplace manifest, the local-dev compose, a
per-app persona, and a skill plugin in `magneto-skills`. The moodle and gibbon apps
implement this pattern identically; odoo will follow it, with the one structural
twist that odoo's database is **PostgreSQL**, not MySQL.

## How the pattern works (four layers)

1. **Declarative toggle.** A top-level `x-clouve-agent:` block in
   `clv-docker-compose.yml` turns the feature on. Its absence (the
   `clv-docker-compose-basic.yml` variant) turns it off. No agent service, env,
   port, volume, or healthcheck is hand-written in the manifest.
2. **Server-side synthesis (thermo — no code change needed).** At publish,
   `AgentSidecarSynthesizer` materializes the `magneto-agent` container, injects a
   generated `CLOUVE_OPS_PASSWORD` (type `secret`) onto every sibling, opens port
   22 on each sibling, makes siblings headless, and auto-derives
   `CLV_SIDECAR_HOSTS=odoo,odoo-postgres` from the non-agent siblings.
3. **The shell channel (per-image work — the bulk of the odoo gap).** Each sibling
   image (app **and** DB) independently ships a `clouve-ops` SSH daemon so the agent
   can `ssh clouve-ops@<host>` for OS-level operations. Routine SQL stays on the TCP
   DB client.
4. **Per-app persona + skill.** The app image COPYs a `context/<app>/CONTEXT.md.tpl`
   persona to `/clouve/context/`. At agent init, `sidecar-fetcher.sh` tars it off
   each sibling over SSH; `sidecar-env-fetcher.sh` snapshots each sibling's PID-1 env
   and re-exports it under an `<UPPER(namespace)>_*` prefix so the persona's
   `${ODOO_*}` placeholders resolve via `envsubst`. Separately, an `odoo` plugin in
   the `magneto-skills` marketplace supplies the skill payload (`SKILL.md` tree) and
   an `install.sh` that apt-installs the skill's runtime deps at agent start.

## Decisions

These were settled with the requester before design:

1. **Scope = both repos (full parity).** Do the magneto-side artifacts **and**
   create + register the `odoo` plugin in `magneto-skills`. Without the plugin,
   `skills.url=...?plugins=odoo` stages nothing and the feature ships half-wired.
2. **Rename the app's DB env vars to `ODOO_DB_*`.** Odoo's app container currently
   reaches its DB via `POSTGRES_DB_HOST/USER/PASSWORD`. After the sidecar
   env-fetcher namespaces them they would surface as the awkward, collision-prone
   `${ODOO_POSTGRES_DB_HOST}` (they do not already start with `ODOO_`, so they get
   prefixed). Renaming to `ODOO_DB_HOST/USER/PASSWORD` makes them pass through clean
   as `${ODOO_DB_*}`, matching moodle/gibbon ergonomics.
3. **SSH-enable both containers (full parity).** Adapt the SSH kit into the
   `odoo-postgres` image too (apt instead of microdnf; wrap the gosu-dropping
   postgres entrypoint), so the agent can operate the DB OS and the env-fetcher can
   read the DB's env.
4. **Odoo-native operational posture for the persona/skill.** Schema/data changes go
   through `odoo-bin` (`odoo -u <module> --stop-after-init`, `odoo shell`) and the
   master-password-gated DB manager for create/drop/backup/restore. Raw `psql` is
   read-mostly; DDL and multi-row writes are gated behind explicit confirmation
   (mirroring gibbon's "no destructive SQL without ack").

## Change set

### A. App image — clouve-ops SSH channel (`apps/odoo/image/`)

- **New `installer/clouve-ops-sshd.conf`** — copy verbatim from
  `apps/moodle/image/installer/clouve-ops-sshd.conf` (password-only auth, no root,
  `AllowUsers clouve-ops`). Reword only the header comment.
- **New `installer/start-clouve-ops-sshd.sh`** — copy verbatim from moodle's app
  variant (guards `CLOUVE_OPS_PASSWORD`, `ssh-keygen -A`, `chpasswd`,
  `exec /usr/sbin/sshd -D`). Valid unchanged on Debian. Reword only the doc-comment
  path to `/clouve/odoo`. The existing `chmod +x ./odoo/installer/*.sh` makes it
  executable.
- **Edit `image/Dockerfile`** (`FROM odoo:19.0`, Debian, already `USER root`):
  - add `openssh-server` and `sudo` to the existing `apt-get install` (lines 15–19);
  - add the `clouve-ops` user + NOPASSWD sudoers drop-in (copied from moodle
    Dockerfile lines 36–38);
  - extend the existing explicit installer `COPY`s to also copy the two new scripts
    into `/clouve/odoo/installer/`;
  - `COPY context/ /clouve/context/`;
  - `RUN cp /clouve/odoo/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf`;
  - no `USER` line — the image already starts as root.
- **Edit `installer/entrypoint.sh`** — insert
  `/clouve/odoo/installer/start-clouve-ops-sshd.sh &` immediately before the final
  `exec /entrypoint-original.sh …` (line ~153). odoo stays PID 1 via the `exec`;
  sshd is reaped when odoo exits. `set -e` is unaffected by a backgrounded `&`.

### B. DB image — clouve-ops SSH adapted MySQL→PostgreSQL (`apps/odoo/image/postgres/`)

- **New `clouve-ops-sshd.conf`** and **`start-clouve-ops-sshd.sh`** — copies of
  `apps/moodle/image/mysql/` versions (OS-agnostic; `/usr/sbin/sshd`, `ssh-keygen -A`,
  `chpasswd`, `/run/sshd` all valid on Debian). Reword only the sibling-name comment.
- **New `entrypoint.sh` wrapper** (adapted from moodle's mysql entrypoint):
  ```bash
  set -e
  /usr/local/bin/start-clouve-ops-sshd.sh &      # backgrounded AS ROOT, before exec
  exec /usr/local/bin/docker-entrypoint.sh "$@"
  ```
  **Critical postgres difference:** the official postgres `docker-entrypoint.sh`,
  when started as root, re-execs itself as the unprivileged `postgres` user via
  `gosu`. So sshd must be backgrounded *first* (while still root, so `chpasswd` /
  `ssh-keygen` / `sshd` succeed), then chain to the upstream entrypoint.
- **Edit `postgres/Dockerfile`** (currently a bare `FROM postgres:18` repackage):
  - replace microdnf with apt:
    `apt-get install -y --no-install-recommends openssh-server sudo procps iproute2 less vim-tiny`
    (Debian equivalents of mysql image's `procps-ng`/`iproute`/`vim-minimal`;
    `gosu`/`useradd`/`chpasswd` already present);
  - `clouve-ops` user + NOPASSWD sudoers drop-in (identical to mysql);
  - `COPY` the conf + the two scripts; chmod the scripts;
  - `ENTRYPOINT ["/usr/local/bin/clouve-entrypoint.sh"]`, `CMD ["postgres"]`
    (**not** `mysqld`);
  - no `USER` line — must stay root for sshd setup and the upstream entrypoint's
    root-time `initdb`/`chown` before it gosu-drops.

> **Duplication note:** `clouve-ops-sshd.conf` and `start-clouve-ops-sshd.sh` are
> duplicated into both `image/installer/` and `image/postgres/` (the postgres build
> context cannot reach the app's `installer/` dir — same as moodle's mysql split).
> Keep the two copies byte-identical to each other and to the moodle reference.

### C. DB env-var rename → `ODOO_DB_*` + add `ODOO_HOST`

Rename the **app** container's `POSTGRES_DB_HOST/USER/PASSWORD` →
`ODOO_DB_HOST/USER/PASSWORD`, and add `ODOO_HOST: odoo` (type `containerReference`,
mirroring moodle's `MOODLE_HOST: moodle`) so `${ODOO_HOST}` resolves to the app
container. The **odoo-postgres** container's own `POSTGRES_DB` / `POSTGRES_USER` /
`POSTGRES_PASSWORD` are left unchanged — the official postgres image requires those
names, and they are distinct from the app's `POSTGRES_DB_*`.

The rename must be **complete** or odoo breaks (these vars are read with a `:-db`
fallback, so a partial rename fails silently against the wrong host). All sites:

- `image/installer/entrypoint.sh` (lines 33, 35, 36)
- `image/installer/install.sh` (lines 17, 19, 20)
- `image/installer/update-config.sh` (lines 18, 20, 21)
- `image/README.md` (lines 96–98, 291 — doc/example)
- `clv-docker-compose.yml` (app `environment` + `x-clouve-environment-types`)
- `clv-docker-compose-basic.yml` (same)
- `docker-compose.yml` (local dev, lines 41–43)

Resulting persona-visible variables (post-namespacing): `${ODOO_HOST}` = `odoo`,
`${ODOO_DB_HOST}` = `odoo-postgres`, `${ODOO_DB_USER}`, `${ODOO_DB_PASSWORD}`,
`${ODOO_DB_NAME}`, `${ODOO_MASTER_PASSWORD}` (the last two already start with
`ODOO_`, so they pass through unprefixed).

### D. Marketplace manifests (`apps/odoo/`)

- **New `clv-docker-compose-basic.yml`** — the agent-**disabled** variant: today's
  manifest content **with the renamed `ODOO_DB_*` vars + `ODOO_HOST`** (both
  variants share one image), **no** `x-clouve-agent` block, `appTitle: Odoo`, and
  the current AI-free description.
- **Edit `clv-docker-compose.yml`** — the agent-**enabled** canonical file. Identical
  to the basic file **except**:
  - append, at document root after the `volumes:` map, the agent block (matching
    moodle, `sidecarPullTimeout: 600` — odoo cold-start/DB-init is slow):
    ```yaml
    x-clouve-agent:
      enabled: true
      skills:
        url: https://github.com/Clouve/magneto-skills.git?plugins=odoo
        git:
          token: ''
          username: ''
      advanced:
        client: null
        sidecarPullTimeout: 600
    ```
  - `appTitle: Odoo with AI Assistant`;
  - rewrite `appDescription` to add the AI-Assistant framing (live Odoo + browser
    Claude Code agent with destructive-op safety gates; tenant owns the AI provider
    key and Odoo data).
  - Do **not** hand-add `CLOUVE_OPS_PASSWORD` or port 22 — thermo synthesizes them.

### E. Local-dev compose (`apps/odoo/docker-compose.yml`)

Mirror moodle's local-dev compose (prod is synthesized by thermo; this is parity for
`./start.sh odoo`):

- add `CLOUVE_OPS_PASSWORD: clouve_ops_dev_password` to **both** odoo and
  odoo-postgres `environment` (the start helper exits 1 if unset);
- add a `magneto-agent` service on `odoo_network`
  (`image: r.clv.zone/clouveinc/magneto-agent`, port `${MAGNETO_AGENT_PORT:-8081}:80`)
  with `MAGNETO_AGENT_USERNAME/PASSWORD/ROOT_PASSWORD`,
  `MAGNETO_AGENT_SKILLS=https://github.com/Clouve/magneto-skills.git?plugins=odoo`,
  `CLOUVE_OPS_PASSWORD=clouve_ops_dev_password`,
  `CLV_SIDECAR_HOSTS=odoo,odoo-postgres`, `CLV_SIDECAR_NAMESPACES=odoo,odoo-postgres`,
  and four `magneto_agent_*` volumes (`/home`, `/usr`, `/opt`, `/var`);
- add the four `magneto_agent_*` volumes to the top-level `volumes:` map.

### F. Persona (`apps/odoo/image/context/odoo/CONTEXT.md.tpl`)

New file; the subdir name `odoo` **must** equal the plugin name (the tar-merge and
composer key off it). Use gibbon's `CONTEXT.md.tpl` as the skeleton — keep the
safety-gate, skill-maintenance, persistence-echo, and scope-guardrail sections
(`s/Gibbon/Odoo/`, `~/.claude/skills/odoo/`) — then make it Odoo/Postgres-specific:

- **Topology:** `${ODOO_HOST}` (Odoo 19.0 server, port 8069),
  `${ODOO_DB_HOST}` (PostgreSQL 18, schema `${ODOO_DB_NAME}`, user `${ODOO_DB_USER}`,
  password `${ODOO_DB_PASSWORD}`), and the magneto-agent container.
- **DB tooling:** `psql` / `pg_dump` / `pg_restore` — **not** mysql/mysqldump.
- **Operational posture (Odoo-native):** module install/upgrade via
  `odoo -d <db> -u <module> --stop-after-init` and `odoo shell` (run as the `odoo`
  user); create/drop/backup/restore via the master-password-gated DB manager. Raw
  `psql` read-mostly; gate DDL and multi-row writes behind an explicit ack.
- **Sacred data / never-touch:** posted accounting moves (`account.move` in `posted`
  state), `ir_model_data` and `ir_*` config, and the filestore at
  `/var/lib/odoo/filestore` (the DB references it by hash). A consistent backup is
  the SQL dump **plus** a tar of the filestore.
- **Secrets:** treat `${ODOO_MASTER_PASSWORD}` like the `ANTHROPIC_API_KEY` — never
  print/transmit; never expose `/web/database/manager` publicly.
- **Process/log model (NOT apache2):** Odoo is the container's main process
  (`exec /entrypoint-original.sh odoo …`). Do **not** restart by killing PID 1; a
  full restart is a pod/container restart, and module upgrades are separate one-shot
  `odoo-bin` invocations. Logs go to stdout, not `/var/log/apache2`.
- **Third-party addons:** vet before installing into `/mnt/extra-addons` (arbitrary
  Python with full DB access).
- **Upstream refs:** <https://www.odoo.com/documentation/> and
  <https://github.com/odoo/odoo>; pin Odoo 19.0.

### G. `magneto-skills` `odoo` plugin (separate repo)

- **New `plugins/odoo/`** modeled on `plugins/moodle/` and `plugins/gibbon/`:
  - `.claude-plugin/plugin.json`;
  - `install.sh` that apt-installs the skill's runtime deps
    (`postgresql-client`, `openssh-client`, `sshpass`) — idempotent across restarts;
  - `skills/odoo/` tree: `SKILL.md` (frontmatter per `magneto-skills/CLAUDE.md`),
    `reference/` (incl. the Odoo never-touch list), `playbooks/` (upgrade, module
    install, backup, restore, diagnose-500, rotate-credentials, harden), `scripts/`
    (audited `backup.sh` / `verify-health.sh`, Postgres + filestore aware),
    `learnings.md`.
- **Register** the plugin in `magneto-skills/.claude-plugin/marketplace.json`
  (alongside `ai-studio`, `gibbon`, `mern`, `moodle`).

## Out of scope / non-goals

- No `thermo` code change — `AgentSidecarSynthesizer` already auto-derives the agent
  wiring from the manifest.
- No `build.config` change — it stays `odoo` / `odoo-postgres`; it is not consumed
  for agent wiring.
- No bundle changes; this is the standalone odoo app only.
- The healthcheck divergence (odoo `/web/health:8069` vs moodle `/ :80`) is unrelated
  to the agent and is left as-is.

## Risks

1. **Cross-repo blocking dependency.** `?plugins=odoo` resolves nothing until the
   `magneto-skills` plugin exists and is registered. Land the plugin alongside (or
   before) the manifest change, or the agent loads no skill and
   `~/.claude/skills/odoo/` won't exist.
2. **Incomplete rename fails silently.** The `${POSTGRES_DB_*:-db}` fallbacks mean a
   missed rename site connects to host `db` (nonexistent) rather than erroring
   loudly. Grep-verify zero remaining `POSTGRES_DB_` references in the app's
   `installer/` + manifests after the rename.
3. **Postgres privilege ordering is load-bearing.** If sshd is backgrounded after the
   upstream entrypoint gosu-drops (or a `USER` line is added), `chpasswd`/`sshd` fail
   and the SSH channel silently never comes up → agent SSH timeouts, no persona/env.
4. **`envsubst` renders unknown vars empty.** Every `${ODOO_*}` in the persona must
   match an actual post-namespacing env var name; a typo silently yields an empty
   string. Verify names against the manifest.
5. **Wider attack surface on an ERP.** A second long-lived sshd + a NOPASSWD-root
   `clouve-ops` user on a container holding financial data is heavier than for
   moodle/gibbon; the only gate is the per-pod `CLOUVE_OPS_PASSWORD` + persona/skill
   safety rules. Acceptable per "full parity" decision, but noted.
6. **Two SSH-script copies can drift** (app `installer/` vs `postgres/`). Keep them
   identical.

## Verification

- `cd magneto && ./build.sh odoo` builds both the app and `odoo-postgres` images
  cleanly (no openssh/sudo install errors on Debian).
- `./start.sh odoo` brings up odoo + odoo-postgres + magneto-agent; odoo reaches the
  DB under the renamed `ODOO_DB_*` vars; `/web/health` returns healthy.
- `sshpass -e ssh clouve-ops@<host>` works into **both** odoo and odoo-postgres with
  `CLOUVE_OPS_PASSWORD`.
- The agent at `:8081` loads: persona renders with all `${ODOO_*}` resolved (no empty
  substitutions), and `~/.claude/skills/odoo/SKILL.md` is present after the loader
  stages the `magneto-skills` plugin.
- `grep -rn 'POSTGRES_DB_' apps/odoo/image/installer apps/odoo/*.yml` returns nothing.
