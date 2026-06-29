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
5. **The skill is authored against the actual Odoo 19.0 source** at `.research/odoo`,
   not generic Odoo knowledge. Every `reference/`/`playbooks/` claim is grounded in
   specific source files (cited in the appendix). The persona facts in section F were
   verified the same way, which corrected several initial assumptions (filestore path
   shape, logs-to-stderr, `odoo`≡`odoo-bin`, the `admin_passwd` footgun).

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
(`s/Gibbon/Odoo/`, `~/.claude/skills/odoo/`) — then make it Odoo/Postgres-specific.
All Odoo facts below are verified against the `.research/odoo` source (Odoo 19.0
FINAL); see the **Odoo 19.0 ground-truth** appendix for source citations.

- **Topology:** `${ODOO_HOST}` (Odoo 19.0 server, port 8069),
  `${ODOO_DB_HOST}` (PostgreSQL — image base `postgres:18`; Odoo requires PG ≥ 13 —
  database `${ODOO_DB_NAME}`, user `${ODOO_DB_USER}`, password `${ODOO_DB_PASSWORD}`),
  and the magneto-agent container.
- **CLI:** `odoo` and `odoo-bin` are the **same** entrypoint (both shim
  `odoo.cli.main()`). Subcommands: `server` (default), `shell`, `db`, `module`,
  `neutralize`, `scaffold`, `populate`, `deploy`.
- **DB tooling:** `psql` / `pg_dump` / `pg_restore` — **not** mysql/mysqldump.
- **Operational posture (Odoo-native):** module install/upgrade via
  `odoo-bin -d <db> -u <module> --stop-after-init` (or `-i` to install; both require
  `-d`, are CLI-only, mutate, and need `--stop-after-init` for one-shot) — or the
  `odoo-bin module install|upgrade|uninstall -d <db>` subcommands. Data fixes via
  `odoo shell` **with an explicit `env.cr.commit()`** (the shell rolls back before
  *and* after the session, so uncommitted changes are silently lost). Raw `psql`
  read-mostly; gate DDL and multi-row writes behind an explicit ack.
- **Backups are filestore-aware (most safety-critical):** prefer
  `odoo-bin db dump <db> <out.zip>` — it produces the canonical ZIP of `dump.sql`
  (`pg_dump --no-owner`) + `filestore/` + `manifest.json`, is filestore-aware, and
  **bypasses the master password**. A hand-rolled `pg_dump` alone is **incomplete**:
  it omits the per-DB filestore (binary attachments; missing files then read back as
  empty `b''` silently) and the manifest. The filestore lives at
  `<data_dir>/filestore/<dbname>` = `/var/lib/odoo/filestore/<dbname>` in this image
  (entrypoint sets `data_dir = /var/lib/odoo`), content-addressed `sha1[:2]/sha1`.
  Restore/clone via `odoo-bin db load -n <db> <zip>` (refuses to overwrite; `-n`
  neutralizes).
- **Sacred / never-touch via raw SQL** (all integrity is ORM/Python-enforced, no DB
  triggers — raw SQL corrupts silently and unrepairably): `account_move` /
  `account_move_line` (posted entries: SHA-256 hash chain, gapless sequence, lock
  dates, audit trail — undo only via reversal/credit note, never delete/edit);
  `ir_model_data` (XML-ID ↔ res_id backbone); `ir_model`/`ir_model_fields`;
  `ir_module_module.state` (recover stuck states via
  `button_reset_state()`/`reset_modules_state()`, never hand-pick); `ir_sequence` +
  reconciliation tables; protected `ir_config_parameter` keys
  (`database.secret`, `database.uuid`, `web.base.url`, `base.login_cooldown_*`).
  Module **uninstall** is irreversible (`DROP TABLE/COLUMN CASCADE` + cascade to
  dependents) — only undo is restore-from-backup.
- **Secrets / DB-manager hardening:** treat `${ODOO_MASTER_PASSWORD}` (Odoo's
  `admin_passwd`, templated into `/etc/odoo/odoo.conf` by the entrypoint) like the
  API key. The 8 `/web/database/*` routes are `auth='none'` (mutating ones
  `csrf=False`), gated **only** by `admin_passwd` — and while it is still the default
  `'admin'` the first submitted password is silently adopted. The real kill-switch is
  `list_db=False` (`--no-database-list`) **plus** a pinned `db_name`/`dbfilter`; the
  manager GET page still returns 200 with a banner when disabled, so verify lockdown
  via the POST endpoints and block the `/web/database/` prefix at the ingress.
- **Process/log model:** Odoo is the container's main process / PID 1 (default
  `workers=0` threaded server, `exec /entrypoint-original.sh odoo …`). `SIGTERM` is
  graceful (a second forces exit), `SIGHUP` re-execs — so a restart is a
  pod/container recycle, **not** signalling PID 1; module upgrades are separate
  one-shot `odoo-bin` invocations. Logs go to **stderr** (no `--logfile` set) — read
  via `kubectl logs` / `docker logs`. There is no Apache/`/var/log/apache2` and the
  systemd `/var/log/odoo` path is unused in the container.
- **Prod→staging clones must be neutralized:** `odoo-bin neutralize -d <db>`
  (`--stdout` to audit first) disables mail servers, all crons (except autovacuum),
  payment providers, and webhooks, and sets `database.is_neutralized=true`.
- **Third-party addons:** vet before installing into `/mnt/extra-addons` (already on
  `addons_path`; runs arbitrary Python with full DB access).
- **Upstream refs:** <https://www.odoo.com/documentation/19.0/> and
  <https://github.com/odoo/odoo> (branch `19.0`); pin Odoo 19.0.

### G. `magneto-skills` `odoo` plugin (separate repo)

Modeled on `plugins/moodle/` and `plugins/gibbon/`, and authored **against the
`.research/odoo` source** — every reference/playbook file is grounded in specific
Odoo 19.0 source files (cited in the **Odoo 19.0 ground-truth** appendix), not
generic Odoo lore. Conventions per `magneto-skills/CLAUDE.md`: plugin dir name =
`plugin.json` `name` = `SKILL.md` frontmatter `name` = `marketplace.json` entry =
`odoo`; the `description` is kept in sync across all three; `marketplace.json`
`plugins[]` stays alphabetically sorted (odoo sorts **after** moodle).

- **`.claude-plugin/plugin.json`** — `name`/`version`/`description`/`author` (minimal).
- **`install.sh`** — dpkg-gated, idempotent, runs as root (copy moodle's/gibbon's
  shape), but with `REQUIRED_PACKAGES=(postgresql-client openssh-client sshpass)`
  (**not** `default-mysql-client`): `postgresql-client` for `psql`/`pg_dump`;
  `openssh-client` + `sshpass` for the `clouve-ops` SSH hop.
- **`skills/odoo/SKILL.md`** — frontmatter `name: odoo`, `description` (precise
  "use when… do not use for…"), `type: devops`, `version`, `authoredAgainst: odoo 19.0`.
  Body: when/when-not-to-use; the golden rules (odoo≡odoo-bin; one-shot `-i`/`-u`
  with `--stop-after-init`; a backup is the DB dump **and** the filestore; `odoo shell`
  needs `env.cr.commit()`; never raw-SQL accounting/`ir_model_data`; never expose
  `/web/database/*`; restart = pod recycle); environment (`${ODOO_HOST}`,
  `${ODOO_DB_*}`, the `clouve-ops` SSH channel); a safety-gates table; the
  "Maintaining this skill" + persistence-echo sections; and a pointer index into
  `reference/` + `playbooks/`.

The `skills/odoo/` tree (each file derived from the cited Odoo source):

| File | Grounded in |
|---|---|
| `reference/stack-and-runtime.md` | `odoo/release.py`, `odoo-bin`, `setup/odoo`, `odoo/cli/command.py`, `odoo/service/server.py` |
| `reference/configuration.md` | `odoo/tools/config.py` (admin_passwd, list_db, dbfilter, proxy_mode, data_dir, addons_path, workers, logfile) |
| `reference/data-model.md` | `addons/base/models/ir_model.py`, `ir_config_parameter.py`, `ir_module.py`, `ir_cron.py`, `res_users.py` — incl. the never-touch list |
| `reference/file-storage.md` | `odoo/addons/base/models/ir_attachment.py`, `odoo/tools/config.py` (filestore = `<data_dir>/filestore/<dbname>`) |
| `reference/backup-restore.md` | `odoo/service/db.py`, `odoo/cli/db.py`, `addons/web/controllers/database.py` (ZIP layout, restore detection, CLI vs HTTP) |
| `reference/security.md` | `addons/web/controllers/database.py`, `odoo/service/db.py`, `odoo/http.py` (DB-manager hardening, proxy_mode, cookies) |
| `reference/module-lifecycle.md` | `odoo/cli/module.py`, `odoo/modules/{loading,migration}.py`, `odoo/orm/registry.py`, `ir_module.py` |
| `reference/accounting-integrity.md` | `addons/account/models/{account_move,account_move_line,sequence_mixin,company,account_journal}.py` |
| `reference/neutralization.md` | `odoo/cli/neutralize.py`, `odoo/modules/neutralize.py`, `addons/base/data/neutralize.sql` |
| `reference/observability.md` | `odoo/netsvc.py`, `odoo/tools/config.py` (stderr logging, `--log-handler MODULE:LEVEL`) |
| `reference/shell-access.md` | `odoo/cli/shell.py` (SUPERUSER env, rollback-unless-commit) + the `clouve-ops` SSH channel |
| `playbooks/install-or-upgrade-module.md` | `odoo/cli/module.py`, `ir_module.py` |
| `playbooks/backup.md` | `odoo/cli/db.py`, `odoo/service/db.py` |
| `playbooks/restore-and-clone.md` | `odoo/cli/db.py`, `odoo/modules/neutralize.py` |
| `playbooks/harden-db-manager.md` | `odoo/tools/config.py`, `addons/web/controllers/database.py` |
| `playbooks/recover-stuck-module-state.md` | `ir_module.py`, `odoo/modules/loading.py` |
| `playbooks/safe-data-fix.md` | `odoo/cli/shell.py`, `account_move.py`, `ir_model.py` |
| `scripts/backup.sh` | wraps `odoo-bin db dump`; pg_dump+filestore-tar fallback |
| `scripts/restore.sh` | wraps `odoo-bin db load -n`; guards against overwriting a prod-named DB |
| `scripts/check-hash-integrity.sh` | pipes `env['res.company']._check_hash_integrity()` to `odoo shell` |
| `learnings.md` | captured operator learnings (per the dedup/edit rules) |

- **Register** the plugin in `magneto-skills/.claude-plugin/marketplace.json`
  (alphabetically after `moodle`), `category: DevOps`, with the same `description`.

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
7. **`admin_passwd` default-`admin` footgun.** The DB-manager routes are `auth='none'`
   and, while `admin_passwd` is still `'admin'`, the first submitted password is
   silently adopted. The image entrypoint templates `${ODOO_MASTER_PASSWORD}` into
   `admin_passwd`, so the secret must always be set; the skill's harden-db-manager
   playbook also sets `list_db=False` + pinned `db_name`/`dbfilter` and assumes the
   `/web/database/` prefix is blocked at the ingress.
8. **`pg_dump`-only backups silently lose data.** A backup that omits the per-DB
   filestore at `/var/lib/odoo/filestore/<dbname>` looks complete but loses all binary
   attachments (missing files read back as empty). The skill must prefer
   `odoo-bin db dump` and, in the manual fallback, always tar the filestore too.
9. **Raw-SQL accounting edits are unrepairable.** Posted `account.move` integrity is
   ORM-only (hash chain, gapless sequence, lock dates) with no DB triggers, so a
   single raw `UPDATE`/`DELETE` corrupts the journal's hash prefix with no repair path.
   The persona/skill must route all accounting changes through reversals, never SQL.

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
- In the running agent, the grounded skill works end-to-end against the live instance:
  `odoo-bin db dump <db> /tmp/x.zip` yields a ZIP containing `dump.sql` +
  `filestore/` + `manifest.json`; `odoo shell` ORM access works; `odoo-bin neutralize
  --stdout -d <db>` prints the expected SQL.
- `claude plugin validate .` passes in `magneto-skills` (or the manual checks:
  `odoo` dir/`plugin.json`/`SKILL.md`/`marketplace.json` names all match; description
  in sync), confirming the plugin is well-formed before publish.

## Appendix — Odoo 19.0 ground-truth (source-cited)

The skill and persona are built against the `.research/odoo` checkout
(`odoo/release.py`: `version_info = (19, 0, 0, FINAL, 0)`; Python 3.10–3.14; PG ≥ 13).
Key load-bearing facts and their sources:

- **Entrypoints:** `odoo` ≡ `odoo-bin` — both shim `odoo.cli.main()` (`odoo-bin`,
  `setup/odoo`, `setup.py:23`). Subcommands auto-register in `odoo/cli/` (`command.py`).
- **Module lifecycle:** `-i`/`-u` require `-d`, are CLI-only, mutate, and need
  `--stop-after-init` for one-shot (`tools/config.py:227-232,431-432`). Uninstall does
  `DROP TABLE/COLUMN CASCADE` + cascades (`ir_model.py:2454-2626`,
  `ir_module.py:668-680`). Stuck `to install/upgrade/remove` states recover via
  `button_reset_state()`/`reset_modules_state()` (`ir_module.py:494-500`,
  `modules/loading.py:611-632`) — never hand-edit `ir_module_module.state`.
- **Backup/restore:** `dump_db` builds a ZIP = `dump.sql` (`pg_dump --no-owner`) +
  `filestore/` + `manifest.json` (`service/db.py:262-313`); `--format dump` is
  custom-format PG-only (no filestore). Restore is `psql -f` for ZIP, `pg_restore`
  otherwise, with **no** version check at restore time (`service/db.py:331-382`). The
  CLI `db` subcommand forces `list_db=True` and bypasses the master password
  (`cli/db.py:198`). Filestore = `<data_dir>/filestore/<dbname>`
  (`tools/config.py:1028-1029`), content-addressed `sha1[:2]/sha1`, missing files read
  as empty `b''` (`ir_attachment.py:131-155`).
- **DB-manager security:** 8 `/web/database/*` routes all `auth='none'`, mutating ones
  `csrf=False`, gated only by `admin_passwd` (default `'admin'`, auto-adopts first
  submitted) (`addons/web/controllers/database.py:59-185`, `service/db.py:60-63,510-521`,
  `tools/config.py:207`). `list_db=False` is the real kill-switch but needs a pinned
  `db_name`/`dbfilter` (`service/db.py:46-53`, `config.py:412-415`).
- **Accounting inalterability:** `account.move`/`account.move.line` integrity (SHA-256
  hash chain `restrict_mode_hash_table`, gapless `sequence.mixin`, lock dates incl.
  irreversible `hard_lock_date`, `restrictive_audit_trail` — DE always, IN) is
  ORM/Python-only, no DB triggers; undo is reversal/credit note `_reverse_moves`
  (`account_move.py:3892-3898,4736-4768,5441-5485`; `company.py:559-566,994-1085`;
  `sequence_mixin.py:17-86`).
- **Protected `ir_config_parameter` keys:** `database.secret`, `database.uuid`,
  `database.create_date`, `web.base.url`, `base.login_cooldown_*`
  (`ir_config_parameter.py:18-25,110-125`); `web.base.url` auto-rewrites to the next
  system-user login host unless `web.base.url.freeze` (`res_users.py:803-810`).
- **Process/logging:** `workers=0` ⇒ threaded server is PID 1; `SIGTERM` graceful
  (second forces exit), `SIGHUP` re-execs (`service/server.py:464-484,1591-1619`).
  Default logging is StreamHandler→**stderr** (`netsvc.py:232-275`); the container
  sets no `--logfile`, so read logs via `kubectl/docker logs`.
- **Neutralization:** `neutralize` runs each module's `data/neutralize.sql`
  (`cli/neutralize.py`, `modules/neutralize.py`); base disables mail servers + crons
  (except autovacuum) + webhooks and sets `database.is_neutralized=true`.
- **Shell:** `odoo shell` runs as SUPERUSER and `cr.rollback()` **before and after** —
  changes need an explicit `env.cr.commit()` (`cli/shell.py:147-149`).

> Full reader output (8 agents, ~564k tokens) is archived at the deep-study workflow
> result; this appendix is the distilled, load-bearing subset.
