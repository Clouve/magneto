# Odoo AI-Assistant — Magneto Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the magneto `odoo` app ship the Magneto Agent ("ai-assistant") sidecar exactly as moodle/gibbon do — clouve-ops SSH in both the app and postgres images, the `x-clouve-agent` manifest toggle, a local-dev agent service, and an Odoo-specific persona — adapted for odoo's PostgreSQL DB.

**Architecture:** Two sibling images (odoo app on Debian `odoo:19.0`; `odoo-postgres` on `postgres:18`) each run a backgrounded `clouve-ops` sshd alongside their main process so the agent can `ssh clouve-ops@<host>`. The marketplace manifest gains a top-level `x-clouve-agent` block (thermo synthesizes the agent container, `CLOUVE_OPS_PASSWORD`, port-22, headless siblings server-side); a `clv-docker-compose-basic.yml` is the agent-disabled variant. The app's DB-connection env vars are renamed `POSTGRES_DB_*` → `ODOO_DB_*` (plus a new `ODOO_HOST`) so the agent's persona references resolve cleanly. A per-app `CONTEXT.md.tpl` persona is baked into the app image.

**Tech Stack:** Docker (Debian-based images), Docker Compose, bash entrypoints, OpenSSH server, Clouve `clv-docker-compose.yml` YAML extensions.

**Companion plan:** `docs/superpowers/plans/2026-06-24-odoo-ai-assistant-skill.md` (the magneto-skills `odoo` plugin). The manifest's `?plugins=odoo` resolves nothing until that plugin is registered and pushed to GitHub — see the cross-repo note in Task 12.

**Source spec:** `docs/superpowers/specs/2026-06-24-odoo-ai-assistant-design.md` (read its "Odoo 19.0 ground-truth" appendix before the persona task).

## Global Constraints

- **Repo & branch:** all work in the `magneto` repo on branch `odoo-ai-assistant` (already created off `develop`). `cd /home/aj/Projects/magneto` before any command.
- **Reference apps:** moodle and gibbon implement this pattern identically — copy their artifacts verbatim except where odoo (Debian app image + postgres DB) differs. The app image is Debian (`FROM odoo:19.0`), so moodle's app-image SSH kit (also Debian/apt) drops in unchanged; the DB image is Debian `postgres:18`, so moodle's mysql (Oracle-Linux/microdnf) kit must be ported to apt.
- **Images stay root.** Never add a `USER` line — both images must start as root for sshd setup and the upstream entrypoints' root-time work (postgres gosu-drops to the `postgres` user itself).
- **Do not hand-add `CLOUVE_OPS_PASSWORD` or port 22 to `clv-docker-compose.yml`** — thermo's `AgentSidecarSynthesizer` injects them. They ARE hand-set in the local-dev `docker-compose.yml`.
- **The two SSH-script copies must stay byte-identical** to each other and to the moodle reference (`apps/odoo/image/installer/` and `apps/odoo/image/postgres/`), modulo the one doc-comment path/sibling-name line.
- **The `POSTGRES_DB_*` → `ODOO_DB_*` rename must be complete** — these vars are read with a `:-db` fallback, so a missed site fails silently against host `db`. The odoo-postgres container's own `POSTGRES_DB`/`POSTGRES_USER`/`POSTGRES_PASSWORD` are NOT renamed (the official postgres image requires those names).
- **Commit after every task** with a `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer. Do not push or open a PR until all tasks pass (Task 12).

## File structure

| File | Responsibility | Action |
|---|---|---|
| `apps/odoo/image/installer/clouve-ops-sshd.conf` | sshd hardening drop-in (app) | create |
| `apps/odoo/image/installer/start-clouve-ops-sshd.sh` | backgrounded sshd bring-up (app) | create |
| `apps/odoo/image/Dockerfile` | app image: openssh/sudo, clouve-ops user, COPYs, context | modify |
| `apps/odoo/image/installer/entrypoint.sh` | app: background sshd before exec; consume renamed vars | modify |
| `apps/odoo/image/postgres/clouve-ops-sshd.conf` | sshd hardening drop-in (DB) | create |
| `apps/odoo/image/postgres/start-clouve-ops-sshd.sh` | backgrounded sshd bring-up (DB) | create |
| `apps/odoo/image/postgres/entrypoint.sh` | DB entrypoint wrapper (sshd + upstream) | create |
| `apps/odoo/image/postgres/Dockerfile` | DB image: apt SSH kit, entrypoint wrap | modify |
| `apps/odoo/image/installer/install.sh` | consume renamed DB vars | modify |
| `apps/odoo/image/installer/update-config.sh` | consume renamed DB vars | modify |
| `apps/odoo/image/README.md` | document renamed DB vars | modify |
| `apps/odoo/clv-docker-compose-basic.yml` | agent-disabled marketplace manifest | create |
| `apps/odoo/clv-docker-compose.yml` | agent-enabled manifest (agent block + AI copy) | modify |
| `apps/odoo/docker-compose.yml` | local-dev: agent service + CLOUVE_OPS_PASSWORD | modify |
| `apps/odoo/image/context/odoo/CONTEXT.md.tpl` | per-app agent persona | create |

---

### Task 1: App-image clouve-ops SSH kit

**Files:**
- Create: `apps/odoo/image/installer/clouve-ops-sshd.conf`
- Create: `apps/odoo/image/installer/start-clouve-ops-sshd.sh`

**Interfaces:**
- Produces: a hardening sshd drop-in and a `start-clouve-ops-sshd.sh` that reads `CLOUVE_OPS_PASSWORD`, runs `ssh-keygen -A`, `chpasswd` the `clouve-ops` user, and `exec /usr/sbin/sshd -D`. Consumed by Task 2 (Dockerfile COPY + `sshd_config.d` install) and Task 3 (entrypoint backgrounds it).

- [ ] **Step 1: Copy the conf verbatim from moodle**

```bash
cp apps/moodle/image/installer/clouve-ops-sshd.conf apps/odoo/image/installer/clouve-ops-sshd.conf
```

- [ ] **Step 2: Copy the start script verbatim from moodle, then reword only its doc-comment path**

```bash
cp apps/moodle/image/installer/start-clouve-ops-sshd.sh apps/odoo/image/installer/start-clouve-ops-sshd.sh
sed -i 's#/clouve/moodle/installer/start-clouve-ops-sshd.sh#/clouve/odoo/installer/start-clouve-ops-sshd.sh#g; s/moodle-mysql/odoo-postgres/g; s/apache2-foreground/odoo/g' apps/odoo/image/installer/start-clouve-ops-sshd.sh
```

- [ ] **Step 3: Verify the executable logic is byte-identical to moodle (only comments differ)**

Run: `diff <(grep -vE '^\s*#|^\s*$' apps/moodle/image/installer/start-clouve-ops-sshd.sh) <(grep -vE '^\s*#|^\s*$' apps/odoo/image/installer/start-clouve-ops-sshd.sh)`
Expected: empty output (no diff in non-comment lines).

Run: `diff apps/moodle/image/installer/clouve-ops-sshd.conf apps/odoo/image/installer/clouve-ops-sshd.conf`
Expected: empty output (the conf is copied verbatim; it already references "clouve-ops" generically).

- [ ] **Step 4: Commit**

```bash
git add apps/odoo/image/installer/clouve-ops-sshd.conf apps/odoo/image/installer/start-clouve-ops-sshd.sh
git commit -m "feat(odoo): add app-image clouve-ops sshd kit

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: App Dockerfile — openssh, clouve-ops user, COPYs, context

**Files:**
- Modify: `apps/odoo/image/Dockerfile`

**Interfaces:**
- Consumes: the two files from Task 1.
- Produces: an app image that has `openssh-server`+`sudo`, a passwordless-sudo `clouve-ops` user, the sshd drop-in at `/etc/ssh/sshd_config.d/clouve-ops.conf`, the start script + conf under `/clouve/odoo/installer/`, and the persona tree at `/clouve/context/` (created in Task 11). Consumed by Task 3 (entrypoint path) and Task 12 (build).

- [ ] **Step 1: Add `openssh-server` and `sudo` to the apt install**

Replace the existing install block (`apps/odoo/image/Dockerfile:15-19`):

```dockerfile
# Install dependencies for database connectivity, health checks, and the
# clouve-ops shell channel (openssh-server + sudo) used by the Magneto Agent.
RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    curl \
    netcat-openbsd \
    openssh-server \
    sudo \
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Add the clouve-ops operator account after the apt block**

Insert immediately after the install block:

```dockerfile
# Operator account used by the Magneto Agent container's Claude Code agent for
# shell access into this container. Password is set at runtime by
# /clouve/odoo/installer/start-clouve-ops-sshd.sh from the per-pod
# CLOUVE_OPS_PASSWORD env var (same value on all three services). Passwordless
# sudo: the agent is a DevOps engineer with full root, gated by the safety rules
# in CONTEXT.md.tpl and the Odoo DevOps Skill rather than by sudoers.
RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops && \
    echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops && \
    chmod 0440 /etc/sudoers.d/clouve-ops
```

- [ ] **Step 3: Copy the two new installer files**

The existing Dockerfile copies installer scripts individually (`COPY installer/entrypoint.sh …` etc. at lines 25-27). Add the two new files alongside them:

```dockerfile
COPY installer/clouve-ops-sshd.conf /clouve/odoo/installer/
COPY installer/start-clouve-ops-sshd.sh /clouve/odoo/installer/
```

(The existing `RUN chmod +x /clouve/odoo/installer/*.sh` at line 30 makes the start script executable.)

- [ ] **Step 4: Install the sshd drop-in and copy the persona context tree**

Add after the `chmod +x` line:

```dockerfile
# clouve-ops sshd hardening drop-in (the system sshd_config Include picks it up).
RUN cp /clouve/odoo/installer/clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf

# Persona pulled at init by the Magneto Agent's sidecar-fetcher over clouve-ops
# SSH. The plugin-name subdir (context/odoo/) makes the persona self-identifying
# in the sidecar->agent merge.
COPY context/ /clouve/context/
```

- [ ] **Step 5: Verify the edits are present and there is still no `USER` line**

Run: `grep -nE 'openssh-server|clouve-ops|sshd_config.d|COPY context/' apps/odoo/image/Dockerfile`
Expected: shows the apt addition, the useradd, the conf COPY, the `cp … sshd_config.d`, and `COPY context/`.

Run: `grep -c '^USER ' apps/odoo/image/Dockerfile`
Expected: `1` (only the existing `USER root` at line 12; no new USER line — and it must not be moved later in the file).

- [ ] **Step 6: Commit**

```bash
git add apps/odoo/image/Dockerfile
git commit -m "feat(odoo): wire clouve-ops sshd + persona context into app image

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: App entrypoint — background sshd before exec

**Files:**
- Modify: `apps/odoo/image/installer/entrypoint.sh`

**Interfaces:**
- Consumes: `/clouve/odoo/installer/start-clouve-ops-sshd.sh` (Task 1/2).
- Produces: odoo stays PID 1 (the final `exec /entrypoint-original.sh …` is unchanged); sshd runs in a backgrounded tree and is reaped when odoo exits.

- [ ] **Step 1: Insert the backgrounded sshd launch before the STEP 5 exec block**

In `apps/odoo/image/installer/entrypoint.sh`, immediately before the `# STEP 5: Start Odoo` banner / the final `if [ $# -eq 0 ]` block (currently ~line 142-153), insert:

```bash
# ============================================================================
# CLOUVE-OPS SSHD: shell channel for the Magneto Agent container's Claude Code
# ============================================================================
# Backgrounded — applies the per-pod CLOUVE_OPS_PASSWORD to the clouve-ops user
# via chpasswd, then exec's sshd -D in its own background tree. Dies with the
# container when odoo (PID 1, via the exec below) exits.
/clouve/odoo/installer/start-clouve-ops-sshd.sh &
```

- [ ] **Step 2: Verify the sshd launch is backgrounded and precedes the exec**

Run: `grep -nE 'start-clouve-ops-sshd.sh &|exec /entrypoint-original.sh' apps/odoo/image/installer/entrypoint.sh`
Expected: the `start-clouve-ops-sshd.sh &` line number is LESS than both `exec /entrypoint-original.sh` line numbers (the `&` launch comes before the final `exec`).

- [ ] **Step 3: Verify bash syntax**

Run: `bash -n apps/odoo/image/installer/entrypoint.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add apps/odoo/image/installer/entrypoint.sh
git commit -m "feat(odoo): background clouve-ops sshd in app entrypoint

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: DB-image clouve-ops SSH kit

**Files:**
- Create: `apps/odoo/image/postgres/clouve-ops-sshd.conf`
- Create: `apps/odoo/image/postgres/start-clouve-ops-sshd.sh`

**Interfaces:**
- Produces: the same two SSH artifacts in the postgres build context (which cannot reach the app's `installer/` dir — the duplication is intentional, mirroring moodle's mysql split). Consumed by Task 5 (entrypoint) and Task 6 (Dockerfile COPY).

- [ ] **Step 1: Copy both verbatim from moodle's mysql image**

```bash
cp apps/moodle/image/mysql/clouve-ops-sshd.conf apps/odoo/image/postgres/clouve-ops-sshd.conf
cp apps/moodle/image/mysql/start-clouve-ops-sshd.sh apps/odoo/image/postgres/start-clouve-ops-sshd.sh
sed -i 's/moodle-mysql/odoo-postgres/g; s/mysqld/postgres/g' apps/odoo/image/postgres/start-clouve-ops-sshd.sh
```

- [ ] **Step 2: Verify the executable logic matches the app-image copy (cross-image identity)**

Run: `diff <(grep -vE '^\s*#|^\s*$' apps/odoo/image/postgres/start-clouve-ops-sshd.sh) <(grep -vE '^\s*#|^\s*$' apps/odoo/image/installer/start-clouve-ops-sshd.sh)`
Expected: empty output (same logic in both images).

Run: `diff apps/odoo/image/postgres/clouve-ops-sshd.conf apps/moodle/image/mysql/clouve-ops-sshd.conf`
Expected: empty output.

- [ ] **Step 3: Commit**

```bash
git add apps/odoo/image/postgres/clouve-ops-sshd.conf apps/odoo/image/postgres/start-clouve-ops-sshd.sh
git commit -m "feat(odoo): add postgres-image clouve-ops sshd kit

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: DB-image entrypoint wrapper

**Files:**
- Create: `apps/odoo/image/postgres/entrypoint.sh`

**Interfaces:**
- Consumes: `start-clouve-ops-sshd.sh` (Task 4), the upstream `docker-entrypoint.sh`.
- Produces: `/usr/local/bin/clouve-entrypoint.sh` (installed by Task 6) that backgrounds sshd **as root** before exec'ing the upstream postgres entrypoint.

- [ ] **Step 1: Create the wrapper**

Create `apps/odoo/image/postgres/entrypoint.sh`:

```bash
#!/bin/bash
# odoo-postgres entrypoint wrapper.
#
# Backgrounds the clouve-ops sshd bring-up (applies the per-pod password from
# CLOUVE_OPS_PASSWORD to the clouve-ops user via chpasswd, then exec's sshd -D),
# and chains to the upstream PostgreSQL docker-entrypoint.sh as PID 1's work.
#
# CRITICAL ORDER: the official postgres docker-entrypoint.sh, when started as
# root, re-execs itself as the unprivileged `postgres` user via gosu. So sshd
# MUST be backgrounded here while we are still root (chpasswd/ssh-keygen/sshd
# need root); doing it after the exec would run as the postgres user and fail.
# The background sshd inherits the container PID tree so it dies when postgres
# exits — no orphaned processes.

set -e

/usr/local/bin/start-clouve-ops-sshd.sh &

exec /usr/local/bin/docker-entrypoint.sh "$@"
```

- [ ] **Step 2: Verify bash syntax**

Run: `bash -n apps/odoo/image/postgres/entrypoint.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add apps/odoo/image/postgres/entrypoint.sh
git commit -m "feat(odoo): add postgres entrypoint wrapper (sshd before gosu drop)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: postgres Dockerfile — apt SSH kit + entrypoint wrap

**Files:**
- Modify: `apps/odoo/image/postgres/Dockerfile`

**Interfaces:**
- Consumes: the three files from Tasks 4-5.
- Produces: an `odoo-postgres` image that runs `clouve-entrypoint.sh` (sshd + postgres). Consumed by Task 12 (build).

- [ ] **Step 1: Append the SSH kit + entrypoint wrap to the Dockerfile**

Append to `apps/odoo/image/postgres/Dockerfile` (after the existing LABELs; the file currently ends at the comment block ~line 16):

```dockerfile
# clouve-ops shell channel (mirrors apps/odoo/image/Dockerfile and the moodle
# mysql image). openssh-server lets the Magneto Agent container's Claude Code
# `ssh clouve-ops@${ODOO_DB_HOST}` for OS-level DB ops (postgres restart, log
# inspection, postgresql.conf tweaks, disk usage). Routine SQL stays on TCP psql.
# Debian package names (vs the mysql image's Oracle-Linux/microdnf): procps,
# iproute2, vim-tiny; gosu/useradd/chpasswd are already in the postgres image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo procps iproute2 less vim-tiny \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (Claude Code)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops

COPY clouve-ops-sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY start-clouve-ops-sshd.sh /usr/local/bin/start-clouve-ops-sshd.sh
COPY entrypoint.sh /usr/local/bin/clouve-entrypoint.sh
RUN chmod +x /usr/local/bin/start-clouve-ops-sshd.sh /usr/local/bin/clouve-entrypoint.sh

# Wrap the upstream docker-entrypoint.sh so we get sshd alongside postgres.
# No USER line: must stay root for sshd setup and the upstream entrypoint's
# root-time initdb/chown before it gosu-drops to the postgres user.
ENTRYPOINT ["/usr/local/bin/clouve-entrypoint.sh"]
CMD ["postgres"]
```

- [ ] **Step 2: Verify CMD is `postgres` (not mysqld) and there is no USER line**

Run: `grep -nE 'CMD|ENTRYPOINT|^USER ' apps/odoo/image/postgres/Dockerfile`
Expected: `CMD ["postgres"]`, `ENTRYPOINT ["/usr/local/bin/clouve-entrypoint.sh"]`, and no `USER` line.

- [ ] **Step 3: Commit**

```bash
git add apps/odoo/image/postgres/Dockerfile
git commit -m "feat(odoo): clouve-ops sshd in postgres image (apt-ported from mysql)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Rename `POSTGRES_DB_*` → `ODOO_DB_*` across image scripts + README

**Files:**
- Modify: `apps/odoo/image/installer/entrypoint.sh`
- Modify: `apps/odoo/image/installer/install.sh`
- Modify: `apps/odoo/image/installer/update-config.sh`
- Modify: `apps/odoo/image/README.md`

**Interfaces:**
- Produces: the app image reads its DB connection from `ODOO_DB_HOST`/`ODOO_DB_USER`/`ODOO_DB_PASSWORD`. Consumed by Tasks 8-10 (manifests + compose must set the renamed names) and Task 11 (persona references `${ODOO_DB_*}`).

- [ ] **Step 1: Rename in the three image scripts**

```bash
sed -i 's/POSTGRES_DB_HOST/ODOO_DB_HOST/g; s/POSTGRES_DB_USER/ODOO_DB_USER/g; s/POSTGRES_DB_PASSWORD/ODOO_DB_PASSWORD/g' \
  apps/odoo/image/installer/entrypoint.sh \
  apps/odoo/image/installer/install.sh \
  apps/odoo/image/installer/update-config.sh
```

- [ ] **Step 2: Rename in the README**

```bash
sed -i 's/POSTGRES_DB_HOST/ODOO_DB_HOST/g; s/POSTGRES_DB_USER/ODOO_DB_USER/g; s/POSTGRES_DB_PASSWORD/ODOO_DB_PASSWORD/g' \
  apps/odoo/image/README.md
```

- [ ] **Step 3: Verify no `POSTGRES_DB_` references remain in the image scripts (the rename is complete)**

Run: `grep -rn 'POSTGRES_DB_' apps/odoo/image/installer apps/odoo/image/README.md`
Expected: empty output.

Note: `grep -rn 'POSTGRES_DB' apps/odoo/image/postgres` (the DB image's own `POSTGRES_DB`/`POSTGRES_USER`/`POSTGRES_PASSWORD`) is unaffected and must remain — those are the official postgres image's required vars, distinct from the app's `POSTGRES_DB_*`.

- [ ] **Step 4: Verify the scripts still parse**

Run: `for f in entrypoint install update-config; do bash -n apps/odoo/image/installer/$f.sh; done`
Expected: no output, exit 0.

- [ ] **Step 5: Commit**

```bash
git add apps/odoo/image/installer/entrypoint.sh apps/odoo/image/installer/install.sh apps/odoo/image/installer/update-config.sh apps/odoo/image/README.md
git commit -m "refactor(odoo): rename app DB vars POSTGRES_DB_* -> ODOO_DB_*

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Agent-disabled manifest `clv-docker-compose-basic.yml`

**Files:**
- Create: `apps/odoo/clv-docker-compose-basic.yml`

**Interfaces:**
- Produces: the agent-free marketplace variant. Identical to today's `clv-docker-compose.yml` except the app DB vars are renamed and `ODOO_HOST` is added. Differs from the agent-enabled file (Task 9) ONLY by the absence of the `x-clouve-agent` block and the AI-free title/description.

- [ ] **Step 1: Copy the current manifest to the basic variant**

```bash
cp apps/odoo/clv-docker-compose.yml apps/odoo/clv-docker-compose-basic.yml
```

- [ ] **Step 2: Rename the app DB vars in the basic variant**

In `apps/odoo/clv-docker-compose-basic.yml`, under the `odoo` service, rename in BOTH the `environment` map and the `x-clouve-environment-types` map:
- `POSTGRES_DB_HOST` → `ODOO_DB_HOST`
- `POSTGRES_DB_USER` → `ODOO_DB_USER`
- `POSTGRES_DB_PASSWORD` → `ODOO_DB_PASSWORD`

```bash
sed -i 's/POSTGRES_DB_HOST/ODOO_DB_HOST/g; s/POSTGRES_DB_USER/ODOO_DB_USER/g; s/POSTGRES_DB_PASSWORD/ODOO_DB_PASSWORD/g' apps/odoo/clv-docker-compose-basic.yml
```

- [ ] **Step 3: Add `ODOO_HOST` to the odoo service env + types**

In the `odoo` service `environment:` map, add as the first entry (so `${ODOO_HOST}` resolves to the container name, mirroring moodle's `MOODLE_HOST: moodle`):

```yaml
      ODOO_HOST: odoo
```

And in `x-clouve-environment-types:` add:

```yaml
      ODOO_HOST: containerReference
```

- [ ] **Step 4: Verify it parses as YAML and has no agent block**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('apps/odoo/clv-docker-compose-basic.yml')); print('ok')"`
Expected: `ok`

Run: `grep -c 'x-clouve-agent' apps/odoo/clv-docker-compose-basic.yml`
Expected: `0`

Run: `grep -n 'ODOO_HOST\|ODOO_DB_HOST\|appTitle' apps/odoo/clv-docker-compose-basic.yml`
Expected: shows `ODOO_HOST: odoo`, `ODOO_DB_HOST`, and `appTitle: Odoo` (unchanged AI-free title).

- [ ] **Step 5: Commit**

```bash
git add apps/odoo/clv-docker-compose-basic.yml
git commit -m "feat(odoo): add agent-disabled clv-docker-compose-basic.yml variant

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Agent-enabled `clv-docker-compose.yml`

**Files:**
- Modify: `apps/odoo/clv-docker-compose.yml`

**Interfaces:**
- Consumes: the renamed vars (Task 7) and the `odoo` plugin name (companion skill plan).
- Produces: the canonical agent-enabled manifest. Differs from the basic variant ONLY by the `x-clouve-agent` block + AI title/description.

- [ ] **Step 1: Apply the same DB-var rename + `ODOO_HOST` as Task 8**

```bash
sed -i 's/POSTGRES_DB_HOST/ODOO_DB_HOST/g; s/POSTGRES_DB_USER/ODOO_DB_USER/g; s/POSTGRES_DB_PASSWORD/ODOO_DB_PASSWORD/g' apps/odoo/clv-docker-compose.yml
```

Then add `ODOO_HOST: odoo` to the `odoo` service `environment:` (first entry) and `ODOO_HOST: containerReference` to `x-clouve-environment-types:` (as in Task 8 Step 3).

- [ ] **Step 2: Change the app title**

In `x-clouve-bundle-metadata`, change `appTitle: Odoo` to:

```yaml
      appTitle: Odoo with AI Assistant
```

- [ ] **Step 3: Rewrite the app description with the AI-Assistant framing**

Replace the `appDescription:` value with:

```yaml
      appDescription: Odoo is a comprehensive, open-source suite of business applications — CRM, accounting, inventory, HR and more — in one integrated, modular ERP. This edition adds a built-in AI Assistant: a browser-based Claude Code DevOps agent that operates your live Odoo instance through natural language — installing and upgrading modules, taking filestore-aware backups, diagnosing issues, and hardening the deployment — with safety gates that require explicit confirmation before any destructive or irreversible action. You own your Odoo data and your AI provider key.
```

- [ ] **Step 4: Append the `x-clouve-agent` block at document root**

At the END of the file, at document-root indentation (after the closing `volumes:` map), append:

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

(600s matches moodle — odoo's first-boot DB init + module install is slow.)

- [ ] **Step 5: Verify the manifest, and that it differs from the basic variant only by the agent block + title/description**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('apps/odoo/clv-docker-compose.yml')); assert d['x-clouve-agent']['enabled'] is True; assert 'odoo' in d['x-clouve-agent']['skills']['url']; print('agent ok')"`
Expected: `agent ok`

Run: `diff apps/odoo/clv-docker-compose-basic.yml apps/odoo/clv-docker-compose.yml`
Expected: the ONLY differences are the `appTitle`, the `appDescription`, and the appended `x-clouve-agent` block. (No other service/env/volume differences.)

- [ ] **Step 6: Commit**

```bash
git add apps/odoo/clv-docker-compose.yml
git commit -m "feat(odoo): enable x-clouve-agent in clv-docker-compose.yml

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Local-dev `docker-compose.yml` — agent service + CLOUVE_OPS_PASSWORD

**Files:**
- Modify: `apps/odoo/docker-compose.yml`

**Interfaces:**
- Consumes: the renamed vars (Task 7), the agent image, the `odoo` plugin (companion plan, via GitHub).
- Produces: a three-container local-dev pod (`odoo` + `odoo-postgres` + `magneto-agent`) reachable for `./start.sh odoo`. Prod is synthesized by thermo; this is local parity.

- [ ] **Step 1: Rename the app DB vars in local-dev compose**

```bash
sed -i 's/POSTGRES_DB_HOST/ODOO_DB_HOST/g; s/POSTGRES_DB_USER/ODOO_DB_USER/g; s/POSTGRES_DB_PASSWORD/ODOO_DB_PASSWORD/g' apps/odoo/docker-compose.yml
```

- [ ] **Step 2: Add `CLOUVE_OPS_PASSWORD` to both `odoo` and `odoo-postgres` services**

Add to the `environment:` map of `odoo-postgres` AND `odoo`:

```yaml
      # Shared per-pod password for the clouve-ops shell account. The same value
      # is set on all three services; the magneto-agent uses it to ssh in
      # (sshpass), odoo and odoo-postgres apply it to the clouve-ops user via
      # chpasswd at start. In prod this is generated by Clouve as a `secret`.
      CLOUVE_OPS_PASSWORD: clouve_ops_dev_password
```

- [ ] **Step 3: Add the `magneto-agent` service**

Add a third service (mirroring `apps/moodle/docker-compose.yml`'s `magneto-agent`), on the existing `odoo_network`:

```yaml
  magneto-agent:
    image: r.clv.zone/clouveinc/magneto-agent
    container_name: odoo_magneto_agent
    restart: unless-stopped
    ports:
      - "${MAGNETO_AGENT_PORT:-8081}:80"
    environment:
      MAGNETO_AGENT_USERNAME: admin
      MAGNETO_AGENT_PASSWORD: Admin@123
      MAGNETO_AGENT_ROOT_PASSWORD: Root@123
      # Activates the odoo DevOps plugin from the magneto-skills marketplace.
      # The loader clones it at start, stages skills/odoo/, and runs the
      # plugin's install.sh (postgresql-client, openssh-client, sshpass).
      MAGNETO_AGENT_SKILLS: https://github.com/Clouve/magneto-skills.git?plugins=odoo
      # Same value as the odoo/odoo-postgres services — Claude Code authenticates
      # via `sshpass -e ssh clouve-ops@…` with this password.
      CLOUVE_OPS_PASSWORD: clouve_ops_dev_password
      # Hosts the agent SSHes to at init for the persona + env pulls.
      CLV_SIDECAR_HOSTS: odoo,odoo-postgres
      CLV_SIDECAR_NAMESPACES: odoo,odoo-postgres
    volumes:
      - magneto_agent_home:/home
      - magneto_agent_usr:/usr
      - magneto_agent_opt:/opt
      - magneto_agent_var:/var
    networks:
      - odoo_network
```

- [ ] **Step 4: Add the four agent volumes to the top-level `volumes:` map**

```yaml
  magneto_agent_home:
  magneto_agent_usr:
  magneto_agent_opt:
  magneto_agent_var:
```

- [ ] **Step 5: Verify it parses and wires the agent correctly**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('apps/odoo/docker-compose.yml')); s=d['services']; assert 'magneto-agent' in s; assert s['odoo']['environment']['CLOUVE_OPS_PASSWORD']; assert s['odoo-postgres']['environment']['CLOUVE_OPS_PASSWORD']; assert s['odoo']['environment']['ODOO_DB_HOST']=='odoo-postgres'; print('compose ok')"`
Expected: `compose ok`

Run: `docker compose -f apps/odoo/docker-compose.yml config -q && echo valid`
Expected: `valid` (compose validates the merged config).

- [ ] **Step 6: Commit**

```bash
git add apps/odoo/docker-compose.yml
git commit -m "feat(odoo): add magneto-agent service to local-dev compose

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Per-app persona `CONTEXT.md.tpl`

**Files:**
- Create: `apps/odoo/image/context/odoo/CONTEXT.md.tpl`

**Interfaces:**
- Consumes: the renamed vars surface to the agent as `${ODOO_HOST}`, `${ODOO_DB_HOST}`, `${ODOO_DB_USER}`, `${ODOO_DB_PASSWORD}`, `${ODOO_DB_NAME}`, `${ODOO_MASTER_PASSWORD}` (all already `ODOO_`-prefixed, so they pass through the sidecar env-fetcher namespacing unprefixed); `${CLOUVE_OPS_PASSWORD}`.
- Produces: the persona appended as `## Skill: odoo` to the agent's `CLAUDE.md` at init.

The subdir name `odoo` MUST equal the plugin name. Model the structure on `apps/gibbon/image/context/gibbon/CONTEXT.md.tpl` (read it first), keeping the safety-gate, skill-maintenance, persistence-echo, and scope-guardrail sections with `s/Gibbon/Odoo/` and `~/.claude/skills/odoo/`. Every Odoo fact below is from the spec's "Odoo 19.0 ground-truth" appendix.

- [ ] **Step 1: Create the persona file with the full content below**

Create `apps/odoo/image/context/odoo/CONTEXT.md.tpl`:

```markdown
You are an experienced **Odoo DevOps engineer** embedded in a business's
production Odoo 19.0 (odoo.com) ERP instance. The people who reach you here
are business owners and administrators, not developers — their accounting,
inventory, and customer data lives in this system. Operate accordingly:
cautious, transparent, never destructive without explicit confirmation.

### Operator Persona & Domain

This pod is shipped as the **Magneto Agent-powered Odoo** marketplace app.
It runs three containers side by side; you live inside the Magneto Agent
container and reach the others over the pod-internal network:

- `${ODOO_HOST}` — the Odoo web/application server (Python, port 8069),
  config at `/etc/odoo/odoo.conf`, data dir `/var/lib/odoo`, custom addons at
  `/mnt/extra-addons`. Running **Odoo 19.0**.
- `${ODOO_DB_HOST}` — PostgreSQL (the `odoo-postgres` image, base `postgres:18`;
  Odoo requires PG ≥ 13). Database `${ODOO_DB_NAME}`, accessed as
  `${ODOO_DB_USER}` with the password in `${ODOO_DB_PASSWORD}`.
- the Magneto Agent container you are running inside of.

The `${...}` placeholders are interpolated at render time from the odoo
sibling's env by the magneto-agent's `sidecar-env-fetcher`.

### Cross-container shell access (clouve-ops)

You **do** have a shell into both side containers via SSH, as the `clouve-ops`
operator account (passwordless sudo — effectively root, gated only by the
safety rules in this document and the Odoo DevOps Skill). Authenticate with the
per-pod password in `CLOUVE_OPS_PASSWORD` (already in your env — never echo or
transmit it). Use `sshpass -e`:

```bash
export SSHPASS=$(printenv CLOUVE_OPS_PASSWORD)
sshpass -e ssh clouve-ops@${ODOO_HOST}            # the Odoo app container
sshpass -e ssh clouve-ops@${ODOO_DB_HOST}         # the PostgreSQL container
sshpass -e ssh clouve-ops@${ODOO_HOST} "sudo tail -50 /var/log/..."  # one-shot
```

Accept the host-key fingerprint once (`-o StrictHostKeyChecking=accept-new` on
the first run). Use this channel for things that must run inside the target:
`odoo-bin` invocations as the `odoo` user, inspecting `/etc/odoo/odoo.conf`,
the filestore at `/var/lib/odoo/filestore/${ODOO_DB_NAME}`, postgres config,
disk usage. Routine SQL goes through the TCP `psql` client from this container.

The Odoo DevOps Skill is mounted at `~/.claude/skills/odoo/` (its `SKILL.md`
is the entry point). Read it before non-trivial operations — it carries the
verified shape of module installs/upgrades, filestore-aware backups, restores,
prod→staging neutralization, DB-manager hardening, and the never-touch list.

Authoritative upstream references when the skill is silent:
- Docs: <https://www.odoo.com/documentation/19.0/>
- Source: <https://github.com/odoo/odoo> (branch `19.0`)

### Default Operating Posture

These rules apply to *every* Odoo-touching action.

1. **A complete backup is the PostgreSQL dump *and* the filestore.** The DB
   references attachments on disk by sha1 hash at
   `/var/lib/odoo/filestore/${ODOO_DB_NAME}`; a `pg_dump` alone silently loses
   them (missing files read back as empty). Prefer the filestore-aware
   `odoo-bin db dump ${ODOO_DB_NAME} <out.zip>` (produces dump.sql + filestore/
   + manifest.json). Use the audited `~/.claude/skills/odoo/scripts/backup.sh`.
2. **Back up before any module install/upgrade, migration, or DDL.**
3. **Operate Odoo-native, not by raw SQL.** `odoo` and `odoo-bin` are the same
   command. Module changes: `odoo-bin -d ${ODOO_DB_NAME} -u <module>
   --stop-after-init` (or `-i` to install) — both require `-d`, are CLI-only,
   and need `--stop-after-init` for one-shot. Data fixes: `odoo shell -d
   ${ODOO_DB_NAME}` — but it **rolls back unless you `env.cr.commit()`**.
4. **No destructive SQL without an explicit ack.** `DROP`, `TRUNCATE`,
   schema-altering `ALTER`, and any multi-row `UPDATE`/`DELETE` are gated. Run
   `SELECT COUNT(*)` first, report the count, and only proceed after the user
   confirms with `yes, I understand this is irreversible`.
5. **Never touch these via raw SQL** (all integrity is enforced in Python, not
   the DB — raw SQL corrupts silently and unrepairably):
   - `account_move` / `account_move_line` — posted journal entries have a
     SHA-256 hash chain, gapless sequence, and lock dates. Reverse a posted
     entry via a **credit note / reversal** or `button_cancel`, NEVER by delete
     or SQL. `hard_lock_date` is irreversible.
   - `ir_model_data` (the XML-ID↔record backbone), `ir_model` /
     `ir_model_fields`, `ir_module_module.state` (recover stuck `to install` /
     `to upgrade` states via `button_reset_state()`, never hand-pick a value).
   - protected `ir_config_parameter` keys: `database.secret` (changing it logs
     everyone out), `database.uuid`, `web.base.url`, `base.login_cooldown_*`.
   - the filestore files — let Odoo's autovacuum GC them; never hand-delete.
6. **Module uninstall is irreversible** (`DROP TABLE/COLUMN CASCADE` + cascades
   to dependents). Only undo is restore-from-backup. Confirm explicitly.
7. **Refuse to install third-party addons from untrusted sources** without
   reading their `__manifest__.py` and top-level Python first — addons run
   arbitrary Python in the Odoo container with full DB access. They go in
   `/mnt/extra-addons` (already on `addons_path`).
8. **Never expose the database manager.** The `/web/database/*` routes are
   `auth='none'`, gated only by the master password `${ODOO_MASTER_PASSWORD}`
   (Odoo's `admin_passwd`). Treat that value like the API key — never print or
   transmit it. The platform locks the manager (`list_db=False` + ingress
   block); do not re-enable it.
9. **A "restart" is a pod/container recycle, not a signal to PID 1.** Odoo is
   the container's main process; module upgrades are separate one-shot
   `odoo-bin … --stop-after-init` invocations, not a restart. Logs go to
   **stderr** (read via the platform's log view) — there is no Apache and no
   `/var/log/apache2` here.
10. **Any non-production clone must be neutralized** before use:
    `odoo-bin neutralize -d <db>` (`--stdout` to audit first) disables mail
    servers, crons, payment providers, and webhooks. Never run a clone that can
    email, charge, or webhook production systems.
11. **Never print, copy, or transmit the tenant's `ANTHROPIC_API_KEY`** (at
    `~/.claude_api_key`) or any other secret you discover.
12. **The `clouve-ops` SSH access is full passwordless sudo** — the same safety
    gates apply over SSH as locally.

### Skill Maintenance — Keep the Odoo Skill Current

The Odoo DevOps Skill at `~/.claude/skills/odoo/` is the **authoritative source**
for Odoo-specific knowledge. Read its `SKILL.md` before non-trivial work, and
treat `reference/` and `playbooks/` as load-bearing.

**Standing instruction for every Odoo session.** When you finish a task and have
discovered something Odoo-specific a future session will benefit from — a new
pattern, a corrected assumption, an undocumented dependency, a recurring failure
mode — **capture it in the skill before ending the task.** The full protocol
(what qualifies, where each kind of learning belongs, edit/dedup rules) lives in
the skill's `SKILL.md` under "Maintaining this skill" and in `learnings.md`.

Edits must be **incremental** and **de-duplicated**: prefer the right file
(`reference/*.md` for Odoo facts, `playbooks/*.md` for procedures, `scripts/`
for audited automation) over the catch-all `learnings.md`; grep before
appending; extend related entries instead of creating parallel ones.

**Scope guardrail — what NOT to capture in this skill:**

- Generic Python / PostgreSQL / Linux knowledge (training-data territory).
- Anything tied to a `/_clv/` path — platform-managed, outside this skill's scope.
- Anything that belongs in a global Claude Code skill or your personal memory.
- Secrets, credentials, or tenant-identifying data — ever.
- Per-session ephemera. Conversation context handles that.

**Persistence reality check.** The skill payload is staged at
`/clouve/skills/odoo/plugin/skills/odoo/` (login-time symlink at
`~/.claude/skills/odoo`), and `/clouve/` is **not** in the persistent path list.
Runtime edits survive the session but are wiped on pod restart and do not flow
back to the magneto-skills repo. So **when you write a new learning, also surface
a one-line summary in chat**:

> _Captured to skill learnings: `<file>` — `<one-line summary>`_

That visible echo is the only way a runtime learning becomes durable — the
operator mirrors it into magneto-skills and the next image rebuild bakes it in.
```

- [ ] **Step 2: Verify every `${...}` placeholder is a real, resolvable var name**

Run: `grep -oE '\$\{[A-Z_]+\}' apps/odoo/image/context/odoo/CONTEXT.md.tpl | sort -u`
Expected: only `${ODOO_HOST}`, `${ODOO_DB_HOST}`, `${ODOO_DB_NAME}`, `${ODOO_DB_USER}`, `${ODOO_DB_PASSWORD}`, `${ODOO_MASTER_PASSWORD}`, `${CLOUVE_OPS_PASSWORD}` — every one of which is set on the odoo service (`ODOO_*` after Task 7/9, `CLOUVE_OPS_PASSWORD` after Task 10) and so survives env-fetcher namespacing. No stray `${...}` (e.g. no leftover `${GIBBON_*}` / `${MOODLE_*}`).

Run: `grep -ci 'gibbon\|moodle\|mysql\|apache' apps/odoo/image/context/odoo/CONTEXT.md.tpl`
Expected: `0` (no reference-app leftovers).

- [ ] **Step 3: Commit**

```bash
git add apps/odoo/image/context/odoo/CONTEXT.md.tpl
git commit -m "feat(odoo): add Odoo DevOps agent persona (CONTEXT.md.tpl)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Integration build + smoke test

**Files:** none (verification only).

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a verified, agent-enabled local odoo deployment.

**Cross-repo prerequisite:** the agent loads `?plugins=odoo` by cloning the
`magneto-skills` GitHub repo at container start. For the agent to load the skill,
the companion plan (`2026-06-24-odoo-ai-assistant-skill.md`) must be implemented
**and its branch pushed/merged so `?plugins=odoo` resolves on GitHub.** The image
build, SSH, and persona-render checks below pass without it; only the
"skill present" check (Step 5) requires the published plugin.

- [ ] **Step 1: Build both images**

Run: `./build.sh odoo`
Expected: builds the `odoo` app image AND the `odoo-postgres` image with no apt/openssh errors (Debian package names resolve: `openssh-server sudo procps iproute2 less vim-tiny`).

- [ ] **Step 2: Start the pod fresh**

Run: `./start.sh odoo --cleanup`
Expected: `odoo`, `odoo-postgres`, and `magneto-agent` containers start.

- [ ] **Step 3: Verify odoo reaches the DB under the renamed vars and is healthy**

Run: `./status.sh odoo` and `./logs.sh odoo odoo -n 50`
Expected: odoo connects to `odoo-postgres` (no "PostgreSQL failed to become ready"), initializes, and serves; `wget -qO- http://localhost:${TEST_PORT:-8080}/web/health` returns healthy once up.

- [ ] **Step 4: Verify clouve-ops SSH works into BOTH containers**

```bash
SSHPASS=clouve_ops_dev_password sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@<odoo-container-ip> "whoami && sudo -n true && echo APP_SSH_OK"
SSHPASS=clouve_ops_dev_password sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@<odoo-postgres-container-ip> "whoami && sudo -n true && echo DB_SSH_OK"
```
Expected: `clouve-ops` / `APP_SSH_OK` and `DB_SSH_OK` (passwordless sudo works in both). Find IPs via `docker inspect` or ssh from inside the magneto-agent container by service name.

- [ ] **Step 5: Verify the agent renders the persona and (if plugin published) loads the skill**

Run: open `http://localhost:8081`, start a session, and confirm the agent's `~/.claude/CLAUDE.md` contains the `## Skill: odoo` persona with `${ODOO_*}` resolved to real values (e.g. `odoo`, `odoo-postgres`) — NOT empty strings. If the magneto-skills `odoo` plugin is published, `~/.claude/skills/odoo/SKILL.md` exists.
Expected: persona present with resolved vars; no empty `${...}` substitutions.

- [ ] **Step 6: Final grep guard for an incomplete rename**

Run: `grep -rn 'POSTGRES_DB_' apps/odoo/image/installer apps/odoo/*.yml`
Expected: empty output.

- [ ] **Step 7: Stop the pod**

Run: `./stop.sh odoo`

No commit (verification only). After this passes and the companion skill plan is done, push the branch and open the PR (see finishing-a-development-branch).

---

## Self-Review

**Spec coverage** (against spec sections A–G):
- A (app image SSH) → Tasks 1–3. ✓
- B (postgres image SSH, mysql→apt port) → Tasks 4–6. ✓
- C (DB-var rename + `ODOO_HOST`) → Task 7 (image scripts) + Tasks 8/9 (manifests) + Task 10 (compose). ✓
- D (manifests: basic + agent block) → Tasks 8–9. ✓
- E (local-dev agent service) → Task 10. ✓
- F (persona) → Task 11. ✓
- G (magneto-skills plugin) → **companion plan** (out of scope here; referenced). ✓

**Placeholder scan:** no `TBD`/`TODO`/"add appropriate"; every code/edit step shows exact content or an exact copy command. The persona is inlined in full. ✓

**Type/name consistency:** the renamed vars `ODOO_DB_HOST/USER/PASSWORD` + `ODOO_HOST` are used identically across Tasks 7–11; persona placeholders match the env vars set in Tasks 9–10; SSH-script paths match between Dockerfile (Task 2/6) and entrypoints (Task 3/5). ✓

**Note on testing style:** Dockerfile/YAML/persona work is verified via build/parse/grep/ssh/render checks rather than unit tests — appropriate for this artifact type and consistent with magneto's `build.sh`/`start.sh`/`status.sh` harness.
