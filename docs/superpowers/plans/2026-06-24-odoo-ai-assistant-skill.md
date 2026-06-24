# Odoo DevOps Skill (magneto-skills `odoo` plugin) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author the `odoo` plugin in the `magneto-skills` marketplace — a Claude Code DevOps skill for safely operating a live Odoo 19.0 ERP — grounded in the actual `.research/odoo` source, mirroring the `moodle`/`gibbon` plugins.

**Architecture:** A self-contained plugin under `plugins/odoo/` with a `plugin.json` manifest, an idempotent `install.sh` runtime hook (apt-installs `postgresql-client openssh-client sshpass`), and a `skills/odoo/` payload (`SKILL.md` + `reference/` + `playbooks/` + `scripts/` + `learnings.md`). Registered in `.claude-plugin/marketplace.json`. The Magneto Agent clones this marketplace at start, stages the payload, runs `install.sh`, and the persona points the operator at `~/.claude/skills/odoo/`.

**Tech Stack:** Markdown (Anthropic skill bundle), JSON manifests, bash audited scripts. No build/test/lint in this repo — the deliverables are content validated with `claude plugin validate`.

**Companion plan:** `docs/superpowers/plans/2026-06-24-odoo-ai-assistant-magneto.md` (the magneto-side wiring). This skill is referenced by that manifest's `?plugins=odoo`. **Both must ship for the feature to work**; this plan's branch must be pushed/merged so `?plugins=odoo` resolves on GitHub before the agent can load the skill.

**Source spec:** `magneto/docs/superpowers/specs/2026-06-24-odoo-ai-assistant-design.md`. **Read its "Odoo 19.0 ground-truth" appendix before authoring any `reference/` doc — every fact + citation a reference doc needs is there.** Each reference doc below also names the exact `.research/odoo` files to read.

## Global Constraints

- **Repo & branch:** all work in the **`magneto-skills`** repo. `cd /home/aj/Projects/magneto-skills`. Create branch `odoo-skill` off `develop` (Task 1).
- **Authored against:** Odoo **19.0** FINAL (`.research/odoo`). Pin `authoredAgainst: odoo 19.0` in SKILL.md frontmatter. Python 3.10–3.14, PostgreSQL ≥ 13.
- **Naming identity (per `magneto-skills/CLAUDE.md`):** the plugin dir name, `plugin.json` `name`, `SKILL.md` frontmatter `name`, and the `marketplace.json` entry `name` must ALL equal `odoo` (lowercase kebab). The `description` must be **identical** across `plugin.json`, `marketplace.json`, and `SKILL.md` frontmatter.
- **Ground every reference/playbook claim in source.** Do not write generic Odoo lore. Cite the `.research/odoo` file each fact comes from (the appendix has the line numbers). When in doubt, read the cited source file.
- **Authoring conventions (per `magneto-skills/CLAUDE.md`):** reference facts → `reference/*.md`; verified procedures → `playbooks/*.md`; audited automation → `scripts/*.sh`; cross-cutting/small → `learnings.md`. Terse, dated (ISO-8601) entries. Cross-repo references stay as URLs, not relative paths.
- **The skill's scripts shell out over the `clouve-ops` SSH channel** to the odoo app container (where `odoo`/`odoo-bin` and the filestore live), using `sshpass -e` with `${CLOUVE_OPS_PASSWORD}`, reaching `${ODOO_HOST}` / `${ODOO_DB_HOST}`. `odoo` ≡ `odoo-bin`.
- **Commit after every task** with a `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer. Do not push/PR until Task 10 (validate) passes.

## File structure

```
plugins/odoo/
├── .claude-plugin/plugin.json          # manifest (Task 2)
├── install.sh                          # runtime apt hook (Task 3)
└── skills/odoo/
    ├── SKILL.md                        # entry point + golden rules + gates (Task 4)
    ├── reference/                      # Tasks 5–7 (grounded in cited Odoo source)
    │   ├── stack-and-runtime.md
    │   ├── configuration.md
    │   ├── data-model.md
    │   ├── file-storage.md
    │   ├── backup-restore.md
    │   ├── security.md
    │   ├── module-lifecycle.md
    │   ├── accounting-integrity.md
    │   ├── neutralization.md
    │   ├── observability.md
    │   └── shell-access.md
    ├── playbooks/                      # Task 8
    │   ├── install-or-upgrade-module.md
    │   ├── backup.md
    │   ├── restore-and-clone.md
    │   ├── harden-db-manager.md
    │   ├── recover-stuck-module-state.md
    │   └── safe-data-fix.md
    ├── scripts/                        # Task 9 (full bash)
    │   ├── backup.sh
    │   ├── restore.sh
    │   └── check-hash-integrity.sh
    └── learnings.md                    # Task 8
.claude-plugin/marketplace.json         # register odoo (Task 2)
```

---

### Task 1: Branch + plugin skeleton

**Files:** none yet (setup).

- [ ] **Step 1: Create the working branch off develop**

```bash
cd /home/aj/Projects/magneto-skills
git checkout develop && git checkout -b odoo-skill
mkdir -p plugins/odoo/.claude-plugin plugins/odoo/skills/odoo/reference plugins/odoo/skills/odoo/playbooks plugins/odoo/skills/odoo/scripts
```

- [ ] **Step 2: Verify the tree exists and the branch is set**

Run: `git rev-parse --abbrev-ref HEAD && ls -d plugins/odoo/skills/odoo/{reference,playbooks,scripts}`
Expected: `odoo-skill` and the three dirs listed.

(No commit yet — the empty dirs are committed with their first file.)

---

### Task 2: `plugin.json` + `marketplace.json` registration

**Files:**
- Create: `plugins/odoo/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

**Interfaces:**
- Produces: the canonical `description` string reused verbatim in SKILL.md (Task 4). The `name` `odoo` is referenced by the magneto manifest's `?plugins=odoo`.

- [ ] **Step 1: Create `plugins/odoo/.claude-plugin/plugin.json`**

```json
{
  "name": "odoo",
  "version": "0.1.0",
  "description": "Safely operate an Odoo 19.0 ERP install — install/upgrade modules, filestore-aware backups and restores, prod→staging neutralization, database-manager hardening, and diagnosing module/upgrade failures — without corrupting accounting or framework data. Use when the user is running the Clouve Odoo app, mentions \"Odoo\", `odoo-bin`, `odoo.conf`, the master password, `account.move`, `ir_model_data`, `ir.config_parameter`, the filestore, or `/web/database/manager`. Do not use for generic Python/PostgreSQL/Linux questions that are not tied to an Odoo instance.",
  "author": {
    "name": "Clouve",
    "url": "https://clouve.com"
  }
}
```

- [ ] **Step 2: Register `odoo` in `.claude-plugin/marketplace.json`**

Add this object to the `plugins[]` array, **after the `moodle` entry** (alphabetical order: ai-studio, gibbon, mern, moodle, odoo). Use the SAME `description` as the plugin.json:

```json
    {
      "name": "odoo",
      "source": "./plugins/odoo",
      "description": "Safely operate an Odoo 19.0 ERP install — install/upgrade modules, filestore-aware backups and restores, prod→staging neutralization, database-manager hardening, and diagnosing module/upgrade failures — without corrupting accounting or framework data. Use when the user is running the Clouve Odoo app, mentions \"Odoo\", `odoo-bin`, `odoo.conf`, the master password, `account.move`, `ir_model_data`, `ir.config_parameter`, the filestore, or `/web/database/manager`. Do not use for generic Python/PostgreSQL/Linux questions that are not tied to an Odoo instance.",
      "version": "0.1.0",
      "category": "DevOps",
      "tags": ["devops", "erp", "odoo", "python", "postgresql"],
      "author": {
        "name": "Clouve",
        "url": "https://clouve.com"
      }
    }
```

- [ ] **Step 3: Verify both JSON files parse and names match**

Run: `python3 -c "import json; p=json.load(open('plugins/odoo/.claude-plugin/plugin.json')); m=json.load(open('.claude-plugin/marketplace.json')); o=[x for x in m['plugins'] if x['name']=='odoo'][0]; assert p['name']=='odoo'; assert p['description']==o['description']; print('json ok, descriptions in sync')"`
Expected: `json ok, descriptions in sync`

- [ ] **Step 4: Commit**

```bash
git add plugins/odoo/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "feat(odoo): register odoo plugin manifest + marketplace entry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `install.sh` runtime hook

**Files:**
- Create: `plugins/odoo/install.sh`

**Interfaces:**
- Produces: at agent start, `psql`/`pg_dump` (postgresql-client) and `ssh`/`sshpass` are present — the binaries the skill's scripts and playbooks shell out to.

- [ ] **Step 1: Create `plugins/odoo/install.sh`** (moodle's shape, odoo deps — `postgresql-client`, NOT mysql-client)

```bash
#!/bin/bash
# Odoo plugin — runtime install hook.
#
# Invoked by Magneto Agent's plugin-stager after the plugin payload is staged
# at /clouve/skills/odoo/plugin/. The contract for hooks is documented in
# https://github.com/Clouve/magneto-agent/blob/main/image/installer/chat/marketplace/plugin-stager.sh
#
# What this installs and why:
#   postgresql-client (psql, pg_dump, pg_restore) — scripts/backup.sh and the
#       diagnose / restore playbooks shell out to these to talk to the
#       odoo-postgres service over TCP.
#   openssh-client + sshpass — the agent ssh's into the odoo and odoo-postgres
#       containers as the clouve-ops operator account using `sshpass -e ssh …`
#       with the per-pod password from CLOUVE_OPS_PASSWORD (the filestore-aware
#       `odoo-bin db dump/load` and `odoo shell` run inside the odoo container).
#
# These do not belong in the upstream Magneto Agent image: no other consumer
# needs them, and shipping sshpass by default expands the platform's attack
# surface for tenants that don't use SSH-based ops at all. They live here so the
# deps travel with the skill that needs them.
#
# Idempotency: dpkg-query gates each package, so re-runs on subsequent container
# starts are a no-op aside from the dpkg lookup itself.

set -u

REQUIRED_PACKAGES=(postgresql-client openssh-client sshpass)

missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("$pkg")
    fi
done

if [ "${#missing[@]}" -eq 0 ]; then
    echo "[odoo/install] runtime packages already present — skipping apt-get."
    exit 0
fi

echo "[odoo/install] installing missing packages: ${missing[*]}"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq; then
    echo "[odoo/install] apt-get update failed — aborting" >&2
    exit 1
fi

if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    echo "[odoo/install] apt-get install failed for: ${missing[*]}" >&2
    exit 1
fi

rm -rf /var/lib/apt/lists/*

echo "[odoo/install] runtime packages installed."
```

- [ ] **Step 2: Make it executable and verify syntax + dep list**

Run: `chmod +x plugins/odoo/install.sh && bash -n plugins/odoo/install.sh && grep -q 'postgresql-client openssh-client sshpass' plugins/odoo/install.sh && echo ok`
Expected: `ok` (parses; installs the postgres client, not mysql).

- [ ] **Step 3: Commit**

```bash
git add plugins/odoo/install.sh
git commit -m "feat(odoo): add runtime install hook (postgresql-client, ssh, sshpass)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `SKILL.md` (entry point)

**Files:**
- Create: `plugins/odoo/skills/odoo/SKILL.md`

**Interfaces:**
- Consumes: the `description` from Task 2 (verbatim in frontmatter).
- Produces: the skill entry point — golden rules, safety-gates table, pointer index into `reference/` + `playbooks/`. Read `plugins/moodle/skills/moodle/SKILL.md` first for the structural template; keep the "Maintaining this skill" + persistence-echo + safety-gates sections (adapted to Odoo).

- [ ] **Step 1: Create `SKILL.md` with frontmatter + body**

Frontmatter (required fields per `magneto-skills/CLAUDE.md`: `name`, `description`, plus DevOps `type`/`version`/`authoredAgainst`):

```markdown
---
name: odoo
description: <PASTE THE EXACT description string from plugin.json Task 2>
type: devops
version: 0.1.0
authoredAgainst: odoo 19.0
---
```

Body must contain these sections (model structure on moodle's SKILL.md; every Odoo fact is from the spec appendix):

1. **Intro** — "You are the operator of a live Odoo 19.0 ERP. It holds real business data: posted invoices, journal entries, inventory, customers. The people asking are business admins, not developers. Assume they trust you not to corrupt their accounting."
2. **When to use / When NOT to use** — use for the Clouve Odoo app, `odoo-bin`, `odoo.conf`, `account.move`, `ir_model_data`, the filestore, `/web/database/manager`; do NOT use for generic Python/PostgreSQL questions, building a new app, debugging the Magneto Agent itself (`/_clv/`), or another app in the pod.
3. **Operating principles (golden rules — load-bearing).** State, each with a one-line why and a pointer to the relevant reference/playbook:
   - A complete backup is the **PG dump AND the filestore** at `/var/lib/odoo/filestore/<db>`; prefer `odoo-bin db dump` (ZIP = dump.sql + filestore/ + manifest.json); hand-rolled `pg_dump` silently loses attachments. → `reference/backup-restore.md`, `scripts/backup.sh`.
   - `odoo` ≡ `odoo-bin`. Module changes are one-shot `odoo-bin -d <db> -u/-i <mod> --stop-after-init` (require `-d`, CLI-only). → `reference/module-lifecycle.md`.
   - `odoo shell` rolls back unless you `env.cr.commit()`. → `reference/shell-access.md`.
   - **Never raw-SQL** `account_move*`, `ir_model_data`, `ir_model`/`ir_model_fields`, `ir_module_module.state`, protected `ir_config_parameter` keys, or the filestore. → `reference/data-model.md`, `reference/accounting-integrity.md`.
   - Reverse a posted entry via credit note/reversal, never delete; `hard_lock_date` is irreversible. → `reference/accounting-integrity.md`.
   - Module **uninstall** is irreversible (`DROP … CASCADE`). → `reference/module-lifecycle.md`.
   - Never expose `/web/database/*`; treat the master password (`admin_passwd`) like the API key; the real kill-switch is `list_db=False` + pinned `db_name`/`dbfilter`. → `reference/security.md`, `playbooks/harden-db-manager.md`.
   - A "restart" is a pod recycle, not a signal to PID 1; logs go to stderr. → `reference/observability.md`, `reference/stack-and-runtime.md`.
   - Any non-prod clone must be `neutralize`d. → `reference/neutralization.md`, `playbooks/restore-and-clone.md`.
   - Vet third-party addons (`__manifest__.py` + top-level Python) before install. → `reference/module-lifecycle.md`.
   - Tenant owns the `ANTHROPIC_API_KEY` (`~/.claude_api_key`) — never print/transmit.
4. **Environment you are running in** — inside the Magneto Agent container; Odoo at `${ODOO_HOST}:8069`, PG at `${ODOO_DB_HOST}` (confirm var names with `env | grep -i odoo`); the `clouve-ops` SSH channel (`SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST}`); → `reference/shell-access.md`.
5. **Pointers into the deeper docs** — a bulleted index linking every `reference/*.md` and `playbooks/*.md` with a one-line description (mirror moodle's "Pointers" section).
6. **Maintaining this skill** — copy moodle's section structure verbatim with `s/Moodle/Odoo/`, `~/.claude/skills/odoo/`, `/clouve/skills/odoo/`; keep the "what qualifies / does not / where each kind belongs / edit rules / runtime caveat + `Captured to skill learnings:` echo" content.
7. **Safety gates table** — `| Action | Gate |` rows: any multi-row `UPDATE`/`DELETE` on Odoo tables → `SELECT COUNT(*)` + ack; schema change / module upgrade / uninstall → `odoo-bin db dump` backup + ack; edit `odoo.conf` → show diff + ack (prefer env-driven); install addon → read `__manifest__.py` + trusted source + ack; drop/restore DB (`odoo-bin db drop`/`load -f`) → backup + ack; any write to `account_move*` → refuse, use reversal; change `admin_passwd`/`list_db` → confirm + ingress block; "User ack" = print the exact command and wait for affirmative.

- [ ] **Step 2: Verify frontmatter, name match, and description sync**

Run: `python3 -c "import re,json; t=open('plugins/odoo/skills/odoo/SKILL.md').read(); fm=t.split('---')[1]; assert 'name: odoo' in fm and 'authoredAgainst: odoo 19.0' in fm; d=json.load(open('plugins/odoo/.claude-plugin/plugin.json'))['description']; assert d in t, 'SKILL.md description must match plugin.json verbatim'; print('skill frontmatter ok')"`
Expected: `skill frontmatter ok`

Run: `grep -ci 'moodle\|gibbon\|mysql\|mdl_\|apache' plugins/odoo/skills/odoo/SKILL.md`
Expected: `0` (no reference-app leftovers).

- [ ] **Step 3: Commit**

```bash
git add plugins/odoo/skills/odoo/SKILL.md
git commit -m "feat(odoo): add SKILL.md entry point (golden rules + safety gates)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Reference docs — runtime & configuration

**Files:**
- Create: `plugins/odoo/skills/odoo/reference/stack-and-runtime.md`
- Create: `plugins/odoo/skills/odoo/reference/configuration.md`
- Create: `plugins/odoo/skills/odoo/reference/observability.md`
- Create: `plugins/odoo/skills/odoo/reference/shell-access.md`

Read first: `.research/odoo/odoo/release.py`, `odoo/cli/command.py`, `odoo/service/server.py`, `odoo/tools/config.py`, `odoo/netsvc.py`, `odoo/cli/shell.py`. Each doc is grounded prose (model on gibbon's `reference/stack-and-runtime.md`).

- [ ] **Step 1: `stack-and-runtime.md` — must state:**
  - Odoo 19.0 FINAL; Python 3.10–3.14; PostgreSQL ≥ 13 (`release.py`).
  - `odoo` ≡ `odoo-bin` (both shim `odoo.cli.main()`; `odoo-bin`, `setup/odoo`, `setup.py`). Full subcommand list (`server`/default, `shell`, `db`, `module`, `neutralize`, `scaffold`, `populate`, `deploy`, `cloc`, `upgrade_code`) (`odoo/cli/command.py`).
  - Process model: `workers=0` ⇒ threaded server = PID 1; `>0` ⇒ prefork; `SIGTERM` graceful (second forces exit), `SIGHUP` re-execs; restart = pod recycle, not signal PID 1 (`service/server.py`).
  - Canonical paths in this image: config `/etc/odoo/odoo.conf`, data `/var/lib/odoo`, addons incl. `/mnt/extra-addons`.

- [ ] **Step 2: `configuration.md` — must state:**
  - `odoo.conf` `[options]` INI format; precedence runtime > CLI > env (`PG*`) > file > default (`tools/config.py`).
  - Operator options with real names + defaults: `db_host/db_port/db_user/db_password/db_name/db_maxconn`, `admin_passwd` (default `'admin'`, **file-only, no CLI flag**, hashed), `list_db` (`--no-database-list`), `dbfilter` (`%h`/`%d`), `proxy_mode`, `data_dir` (computed default — pin it), `addons_path` (invalid dirs silently dropped), `workers`/`limit_*`, `log_level`/`logfile`/`syslog` (mutually exclusive), `without_demo`.
  - `-i`/`-u`/`--stop-after-init` are CLI-only (ignored in the conf file).
  - Note this image templates `${ODOO_MASTER_PASSWORD}` → `admin_passwd` and sets `data_dir = /var/lib/odoo`.

- [ ] **Step 3: `observability.md` — must state:**
  - Default logging is StreamHandler → **stderr** (no `--logfile` in the container) — read via the platform log view; not `/var/log/odoo` (systemd-only) and there is no Apache (`netsvc.py`).
  - Fixed log line format; verbosity via `--log-level` presets + repeatable `--log-handler MODULE:LEVEL` (e.g. `odoo.sql_db:DEBUG`, `odoo.http:DEBUG`); `--log-db` writes to `ir_logging` (bloat risk).

- [ ] **Step 4: `shell-access.md` — must state:**
  - The `clouve-ops` SSH channel: `SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST}` (or `@${ODOO_DB_HOST}`); accept host key once; passwordless sudo; when to use SSH (odoo-bin, filestore, conf, postgres OS ops) vs the TCP `psql` channel.
  - `odoo shell -d <db>` runs as SUPERUSER with `env`/`self`/`odoo` predefined and **`cr.rollback()` before AND after** — changes need an explicit `env.cr.commit()` (`cli/shell.py`). Single DB only. Use it for ORM-driven data fixes instead of raw SQL.

- [ ] **Step 5: Verify the four files exist and carry their load-bearing facts**

Run:
```bash
grep -q 'env.cr.commit' plugins/odoo/skills/odoo/reference/shell-access.md && \
grep -q 'stderr' plugins/odoo/skills/odoo/reference/observability.md && \
grep -q "admin_passwd" plugins/odoo/skills/odoo/reference/configuration.md && \
grep -qE 'odoo-bin|odoo.cli.main' plugins/odoo/skills/odoo/reference/stack-and-runtime.md && echo refs-1-ok
```
Expected: `refs-1-ok`

- [ ] **Step 6: Commit**

```bash
git add plugins/odoo/skills/odoo/reference/stack-and-runtime.md plugins/odoo/skills/odoo/reference/configuration.md plugins/odoo/skills/odoo/reference/observability.md plugins/odoo/skills/odoo/reference/shell-access.md
git commit -m "docs(odoo): runtime/config/observability/shell reference (grounded in source)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Reference docs — data model, filestore, modules

**Files:**
- Create: `plugins/odoo/skills/odoo/reference/data-model.md`
- Create: `plugins/odoo/skills/odoo/reference/file-storage.md`
- Create: `plugins/odoo/skills/odoo/reference/module-lifecycle.md`

Read first: `.research/odoo/addons/base/models/{ir_model,ir_config_parameter,ir_attachment,ir_module,ir_cron,res_users}.py`, `odoo/modules/{loading,migration}.py`, `odoo/orm/registry.py`, `odoo/cli/module.py`, `odoo/tools/config.py`.

- [ ] **Step 1: `data-model.md` — must state, with the never-touch list front and center:**
  - `ir.model.data` = XML-ID ↔ (model, res_id) backbone, ormcached, `_xmlid_lookup` raises "External ID not found"; on upgrade `_process_end` deletes records whose xmlid vanished (unless `noupdate`). Editing/deleting rows orphans external IDs and breaks upgrades.
  - `ir.config_parameter` protected keys: `database.secret` (changing logs out everyone / breaks CSRF+HMAC), `database.uuid`, `database.create_date`, `web.base.url` (auto-rewrites to the next system-user login host unless `web.base.url.freeze`), `base.login_cooldown_*`.
  - `ir.module.module` state machine (`uninstalled`/`installed`/`to install`/`to upgrade`/`to remove`); registry loads only `installed`; never raw-SQL `state`.
  - `ir.cron` skips a DB on version mismatch / module state; deactivates a job only after ≥5 failures AND ≥7 days.
  - **Never-touch list** (raw SQL bypasses ORM-only protections): `account_move`/`account_move_line` (→ accounting-integrity.md), `ir_model_data`, `ir_model`/`ir_model_fields` (ORM delete does `DROP TABLE/COLUMN CASCADE` that SQL skips), `ir_module_module.state`, protected `ir_config_parameter` keys, `ir_sequence` + reconciliation tables, the filestore.

- [ ] **Step 2: `file-storage.md` — must state:**
  - Filestore = `<data_dir>/filestore/<dbname>` = `/var/lib/odoo/filestore/<db>` here (`tools/config.py`); content-addressed `sha1[:2]/sha1`, deduplicated; backend = `ir_config_parameter` `ir_attachment.location` (`file` default vs `db`).
  - Missing file ⇒ `_file_read` returns empty `b''` **silently** (so a half-backup looks fine but serves blanks); deletes only mark for GC (`filestore/checklist/`), actual unlink by autovacuum; `force_storage()` migrates backends.
  - Therefore a backup MUST capture the filestore alongside the PG dump (→ backup-restore.md).

- [ ] **Step 3: `module-lifecycle.md` — must state:**
  - Install `odoo-bin -d <db> -i <mods> --stop-after-init`; upgrade `-u <mods>|all`; both require `-d`, are CLI-only, mutate, need `--stop-after-init` for one-shot. Dedicated subcommands `odoo-bin module install|upgrade|uninstall -d <db> <mods>` (add `--no-http`, exactly one DB).
  - Install/upgrade take an EXCLUSIVE lock on `ir_module_module`, lock `ir_cron`, rebuild the registry, and run `migrations/<version>/{pre,post,end}-*` scripts. Only one module op at a time.
  - **Uninstall is irreversible**: `DROP TABLE/COLUMN CASCADE` + deletes module-owned records via `ir.model.data`, cascading to dependents. Only undo = restore-from-backup.
  - Stuck `to install`/`to upgrade`/`to remove` + `ir_config_parameter base.partially_updated_database=1`: recover via `button_reset_state()`/`odoo.modules.loading.reset_modules_state(db)`, never hand-edit state (→ playbooks/recover-stuck-module-state.md).
  - `upgrade_code` rewrites SOURCE files in place (not DB) — unrelated to `-u`.
  - Third-party addons run arbitrary Python with full DB access — vet `__manifest__.py` + top-level Python; they live in `/mnt/extra-addons` (on `addons_path`).

- [ ] **Step 4: Verify**

Run:
```bash
grep -qi 'never' plugins/odoo/skills/odoo/reference/data-model.md && grep -q 'ir_model_data' plugins/odoo/skills/odoo/reference/data-model.md && \
grep -q 'filestore/<db' plugins/odoo/skills/odoo/reference/file-storage.md && \
grep -q 'stop-after-init' plugins/odoo/skills/odoo/reference/module-lifecycle.md && grep -qi 'uninstall' plugins/odoo/skills/odoo/reference/module-lifecycle.md && echo refs-2-ok
```
Expected: `refs-2-ok`

- [ ] **Step 5: Commit**

```bash
git add plugins/odoo/skills/odoo/reference/data-model.md plugins/odoo/skills/odoo/reference/file-storage.md plugins/odoo/skills/odoo/reference/module-lifecycle.md
git commit -m "docs(odoo): data-model/filestore/module-lifecycle reference (grounded)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Reference docs — backup/restore, security, accounting, neutralization

**Files:**
- Create: `plugins/odoo/skills/odoo/reference/backup-restore.md`
- Create: `plugins/odoo/skills/odoo/reference/security.md`
- Create: `plugins/odoo/skills/odoo/reference/accounting-integrity.md`
- Create: `plugins/odoo/skills/odoo/reference/neutralization.md`

Read first: `.research/odoo/odoo/service/db.py`, `odoo/cli/db.py`, `addons/web/controllers/database.py`, `odoo/http.py`, `addons/account/models/{account_move,account_move_line,sequence_mixin,company,account_journal}.py`, `odoo/cli/neutralize.py`, `odoo/modules/neutralize.py`, `addons/base/data/neutralize.sql`.

- [ ] **Step 1: `backup-restore.md` — must state:**
  - Odoo ZIP backup = `dump.sql` (`pg_dump --no-owner`, plain text) + `filestore/` + `manifest.json` (`service/db.py`); `--format dump` = custom-format `pg_dump -F c`, **DB only, no filestore/manifest**.
  - Restore: zip ⇒ create DB + `psql -f dump.sql` + move filestore in; non-zip ⇒ `pg_restore`; **no version check at restore** (only `list_db_incompatible` on the manager page); refuses to overwrite an existing DB.
  - Prefer the CLI `odoo-bin db dump|load|duplicate` — filestore-aware AND **bypasses the master password** (forces `list_db=True`); the HTTP `/web/database/backup|restore` needs `admin_passwd` + `list_db`.
  - `db load` flags: default new dbuuid (`--move` keeps it), `-n` neutralize, `-f` force (drops + `rmtree` filestore — irreversible). `db drop` = DROP DATABASE + `rmtree` filestore.
  - A hand-rolled `pg_dump` alone is incomplete (loses the per-DB filestore + manifest).

- [ ] **Step 2: `security.md` — must state:**
  - 8 `/web/database/*` routes all `auth='none'`; mutating ones `csrf=False` ⇒ gated ONLY by `admin_passwd`. Default `'admin'`; while default, the FIRST submitted password is silently adopted (footgun).
  - `list_db=False` (`--no-database-list`) is the real kill-switch (raises AccessDenied on db-management workers), but you MUST also pin `db_name`/`dbfilter` or the selector breaks. The GET manager page still returns 200 with a banner when disabled — verify via POST, and block the `/web/database/` prefix at the ingress.
  - `proxy_mode` must be on AND the proxy must strip client `X-Forwarded-*` (ProxyFix trusts one hop); session cookie is httponly but not Secure/SameSite — enforce TLS+Secure at the proxy. `restore` route is unbounded upload.

- [ ] **Step 3: `accounting-integrity.md` — the heart of the never-touch rule; must state:**
  - Tables `account_move` (header) / `account_move_line`; state `draft → posted → cancel`. Integrity is **ALL Python ORM, no DB triggers** — raw SQL bypasses everything.
  - Optional SHA-256 forward hash chain per journal (`restrict_mode_hash_table`; once hashed, irreversible); hashed fields enumerated; verified by `company._check_hash_integrity()` / report action; editing a hashed move via `write()` is blocked. Germany always forces it; India once accounting exists.
  - Gapless per-journal sequence (`sequence.mixin`); lock dates incl. **irreversible `hard_lock_date`** (cannot remove, only advance); `restrictive_audit_trail` forbids deleting posted moves / rewriting their chatter.
  - **Correct undo = reversal / credit note (`_reverse_moves`, `action_reverse`) or `button_cancel`** — NEVER delete or SQL-edit. One raw SQL edit corrupts the hash of that move and every later move in the journal, unrepairably.

- [ ] **Step 4: `neutralization.md` — must state:**
  - `odoo-bin neutralize -d <db>` (`--stdout` to audit the SQL without applying) runs each installed module's `data/neutralize.sql`.
  - base: deactivates mail servers + inserts a dummy invalid SMTP, deactivates all crons except `base.autovacuum_job`, sets `ir_config_parameter database.is_neutralized=true`, disables webhook server actions. mail/payment/l10n_edi/iap/oauth ship their own. `ir.cron.toggle` refuses to re-enable crons on a neutralized DB.
  - MANDATORY for any prod→staging clone before use (never let a clone email/charge/webhook prod).

- [ ] **Step 5: Verify**

Run:
```bash
grep -q 'manifest.json' plugins/odoo/skills/odoo/reference/backup-restore.md && \
grep -q "list_db" plugins/odoo/skills/odoo/reference/security.md && \
grep -qi 'reversal\|credit note' plugins/odoo/skills/odoo/reference/accounting-integrity.md && \
grep -q 'is_neutralized' plugins/odoo/skills/odoo/reference/neutralization.md && echo refs-3-ok
```
Expected: `refs-3-ok`

- [ ] **Step 6: Commit**

```bash
git add plugins/odoo/skills/odoo/reference/backup-restore.md plugins/odoo/skills/odoo/reference/security.md plugins/odoo/skills/odoo/reference/accounting-integrity.md plugins/odoo/skills/odoo/reference/neutralization.md
git commit -m "docs(odoo): backup/security/accounting/neutralization reference (grounded)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Playbooks + learnings.md

**Files:**
- Create: `plugins/odoo/skills/odoo/playbooks/install-or-upgrade-module.md`
- Create: `plugins/odoo/skills/odoo/playbooks/backup.md`
- Create: `plugins/odoo/skills/odoo/playbooks/restore-and-clone.md`
- Create: `plugins/odoo/skills/odoo/playbooks/harden-db-manager.md`
- Create: `plugins/odoo/skills/odoo/playbooks/recover-stuck-module-state.md`
- Create: `plugins/odoo/skills/odoo/playbooks/safe-data-fix.md`
- Create: `plugins/odoo/skills/odoo/learnings.md`

Each playbook is a numbered, copy-pasteable procedure (model on gibbon's `playbooks/*.md`), referencing the `scripts/` (Task 9) and `reference/` docs, with explicit safety-gate steps.

- [ ] **Step 1: `install-or-upgrade-module.md`** — steps: (1) `scripts/backup.sh` first; (2) confirm `/mnt/extra-addons` is on `addons_path`; (3) `sshpass -e ssh clouve-ops@${ODOO_HOST} "sudo odoo -c /etc/odoo/odoo.conf -d <db> -u <mod> --stop-after-init"` (or `-i` to install); (4) pod restart to resume serving; (5) verify module state via `odoo shell`; (6) on stuck `to upgrade` → `playbooks/recover-stuck-module-state.md`. Gate: backup + ack before upgrade; uninstall ack.

- [ ] **Step 2: `backup.md`** — preferred `scripts/backup.sh` (= `odoo-bin db dump <db> <out.zip>`); options `--no-filestore`/`--format dump` and their tradeoffs; manual fallback = `pg_dump` + tar of `/var/lib/odoo/filestore/<db>` + note the missing manifest; how to copy the artifact off the pod.

- [ ] **Step 3: `restore-and-clone.md`** — `scripts/restore.sh` (= `odoo-bin db load -n <db> <zip>`); refuses to overwrite (use `-f` to drop+rmtree, gated); `--move` vs new dbuuid; prod→staging = dump then `load -n` (or `db duplicate -n`); always confirm `database.is_neutralized=true` after (→ neutralization.md).

- [ ] **Step 4: `harden-db-manager.md`** — set a strong `admin_passwd` (never leave `'admin'`); set `list_db=False` AND pin `db_name`/`dbfilter`; `proxy_mode=True` + proxy strips `X-Forwarded-*`; Secure cookies + TLS at ingress; block the `/web/database/` prefix at ingress; verify lockdown by POSTing to `create`/`drop` and confirming AccessDenied (the GET 200 is not proof).

- [ ] **Step 5: `recover-stuck-module-state.md`** — symptoms (crons idle, partial upgrade); check `ir_module_module.state` + `ir_config_parameter base.partially_updated_database`; recover via `odoo shell` `env['ir.module.module'].button_reset_state()` / `reset_modules_state(db)`; never SQL-edit `state`; re-run `-u` to finish.

- [ ] **Step 6: `safe-data-fix.md`** — use `odoo shell` with `env.cr.commit()` instead of raw SQL; reverse a posted `account.move` via credit note / `_reverse_moves` or `button_cancel`; the never-`UPDATE`/`DELETE` table list (account_move*, ir_model_data, ir_sequence, protected ir_config_parameter).

- [ ] **Step 7: `learnings.md`** — seed with the load-bearing gotchas as dated ISO-8601 entries: filestore is per-DB and `pg_dump` alone loses it; `odoo shell` needs `env.cr.commit()`; `list_db=False` needs a pinned `db_name`; the `admin_passwd` default-`admin` auto-change footgun; `hard_lock_date` is one-way; raw SQL on posted accounting is unrepairable. Include the standard header explaining the dedup/edit rules (mirror gibbon's `learnings.md` preamble).

- [ ] **Step 8: Verify all seven files exist and the playbooks reference the scripts**

Run:
```bash
ls plugins/odoo/skills/odoo/playbooks/*.md | wc -l   # expect 6
grep -lq 'scripts/backup.sh' plugins/odoo/skills/odoo/playbooks/backup.md && \
grep -q 'env.cr.commit' plugins/odoo/skills/odoo/playbooks/safe-data-fix.md && \
grep -q 'button_reset_state' plugins/odoo/skills/odoo/playbooks/recover-stuck-module-state.md && echo playbooks-ok
```
Expected: `6` then `playbooks-ok`

- [ ] **Step 9: Commit**

```bash
git add plugins/odoo/skills/odoo/playbooks plugins/odoo/skills/odoo/learnings.md
git commit -m "docs(odoo): playbooks + learnings (module ops, backup/restore, hardening, data-fix)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Audited scripts

**Files:**
- Create: `plugins/odoo/skills/odoo/scripts/backup.sh`
- Create: `plugins/odoo/skills/odoo/scripts/restore.sh`
- Create: `plugins/odoo/skills/odoo/scripts/check-hash-integrity.sh`

**Interfaces:**
- Consumes: `${ODOO_HOST}`, `${ODOO_DB_NAME}`, `${CLOUVE_OPS_PASSWORD}` from the agent env; the `clouve-ops` SSH channel; `odoo`/`odoo-bin` + the filestore inside the odoo container.

- [ ] **Step 1: `scripts/backup.sh`** (filestore-aware via `odoo-bin db dump` on the app container)

```bash
#!/usr/bin/env bash
# Filestore-aware Odoo backup. Runs `odoo db dump` INSIDE the odoo app container
# (over the clouve-ops SSH channel) so the resulting ZIP carries dump.sql +
# filestore/ + manifest.json — a hand-rolled pg_dump would lose the filestore.
# Usage: backup.sh [db] [out-path-on-odoo-host]
set -euo pipefail

DB="${1:-${ODOO_DB_NAME:?set ODOO_DB_NAME or pass the db as arg 1}}"
TS="$(date +%Y-%m-%d-%H-%M-%S)"
OUT="${2:-/var/lib/odoo/backups/${DB}-${TS}.zip}"
: "${ODOO_HOST:?ODOO_HOST not set}" "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"
export SSHPASS="$CLOUVE_OPS_PASSWORD"
SSH=(sshpass -e ssh -o StrictHostKeyChecking=accept-new "clouve-ops@${ODOO_HOST}")

echo "[odoo/backup] ${DB} -> ${ODOO_HOST}:${OUT} (DB + filestore + manifest)"
# NOTE: `-c` is a parent-parser option of the `db` command, so it goes BETWEEN
# `db` and the `dump` subcommand. `odoo -c ... db dump` would be misparsed as the
# default `server` command (command.py treats a leading `-` as "no command").
"${SSH[@]}" "sudo mkdir -p '$(dirname "${OUT}")' && sudo odoo db -c /etc/odoo/odoo.conf dump '${DB}' '${OUT}'"

echo "[odoo/backup] verifying the archive contains a filestore + manifest ..."
"${SSH[@]}" "sudo python3 - '${OUT}' <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
assert any(n == 'dump.sql' for n in names), 'missing dump.sql'
assert any(n == 'manifest.json' for n in names), 'missing manifest.json'
assert any(n.startswith('filestore/') for n in names), 'missing filestore/ (attachments would be lost!)'
print('[odoo/backup] OK: dump.sql + manifest.json + filestore/ present')
PY"

echo "[odoo/backup] done: ${ODOO_HOST}:${OUT}  (copy it off the pod to retain it)"
```

- [ ] **Step 2: `scripts/restore.sh`** (neutralized load; guards the live DB)

```bash
#!/usr/bin/env bash
# Restore/clone an Odoo DB from a filestore-aware zip via `odoo db load`.
# Defaults to a NEUTRALIZED load and refuses to clobber the live DB.
# Usage: restore.sh <target-db> <backup.zip-on-odoo-host> [--prod]
set -euo pipefail

DB="${1:?usage: restore.sh <target-db> <backup.zip> [--prod]}"
ZIP="${2:?usage: restore.sh <target-db> <backup.zip> [--prod]}"
ALLOW_PROD="${3:-}"
: "${ODOO_HOST:?ODOO_HOST not set}" "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"

if [ "${DB}" = "${ODOO_DB_NAME:-}" ] && [ "${ALLOW_PROD}" != "--prod" ]; then
  echo "[odoo/restore] refusing to restore over the live DB '${DB}' without --prod" >&2
  echo "[odoo/restore] restore into a new name (e.g. ${DB}-staging) for a safe clone." >&2
  exit 1
fi

export SSHPASS="$CLOUVE_OPS_PASSWORD"
SSH=(sshpass -e ssh -o StrictHostKeyChecking=accept-new "clouve-ops@${ODOO_HOST}")

NEUTRALIZE="-n"
[ "${ALLOW_PROD}" = "--prod" ] && NEUTRALIZE=""   # a real prod restore is NOT neutralized

echo "[odoo/restore] loading ${ZIP} -> ${DB} ${NEUTRALIZE:+(neutralized)}"
# `-c` goes between `db` and `load` (parent-parser option of the `db` command);
# positional order is `load [database] <dump_file>` (db_name then dump path).
"${SSH[@]}" "sudo odoo db -c /etc/odoo/odoo.conf load ${NEUTRALIZE} '${DB}' '${ZIP}'"

if [ -n "${NEUTRALIZE}" ]; then
  echo "[odoo/restore] confirming database.is_neutralized ..."
  "${SSH[@]}" "sudo odoo shell -c /etc/odoo/odoo.conf -d '${DB}' --stop-after-init <<'PY'
print('is_neutralized =', env['ir.config_parameter'].sudo().get_param('database.is_neutralized'))
PY"
fi
echo "[odoo/restore] done."
```

- [ ] **Step 3: `scripts/check-hash-integrity.sh`** (detect SQL-corrupted accounting chains)

```bash
#!/usr/bin/env bash
# Run Odoo's own accounting hash-integrity check to detect SQL-tampered or
# corrupted journal entry chains. Read-only. Usage: check-hash-integrity.sh [db]
set -euo pipefail

DB="${1:-${ODOO_DB_NAME:?set ODOO_DB_NAME or pass the db as arg 1}}"
: "${ODOO_HOST:?ODOO_HOST not set}" "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"
export SSHPASS="$CLOUVE_OPS_PASSWORD"

echo "[odoo/hash-check] res.company._check_hash_integrity() on ${DB}"
sshpass -e ssh -o StrictHostKeyChecking=accept-new "clouve-ops@${ODOO_HOST}" \
  "sudo odoo shell -c /etc/odoo/odoo.conf -d '${DB}' --stop-after-init" <<'PY'
companies = env['res.company'].search([])
for c in companies:
    try:
        c._check_hash_integrity()
        print(f"company {c.id} {c.name!r}: integrity check ran (review the report for any non-compliant journal)")
    except Exception as e:
        # UserError when hashing isn't enabled is benign; other errors are not
        print(f"company {c.id} {c.name!r}: {type(e).__name__}: {e}")
PY
echo "[odoo/hash-check] done — investigate any journal flagged non-compliant (a broken/edited chain)."
```

- [ ] **Step 4: Make executable and verify syntax**

Run: `chmod +x plugins/odoo/skills/odoo/scripts/*.sh && for f in plugins/odoo/skills/odoo/scripts/*.sh; do bash -n "$f"; done && echo scripts-ok`
Expected: `scripts-ok`

- [ ] **Step 5: Commit**

```bash
git add plugins/odoo/skills/odoo/scripts
git commit -m "feat(odoo): audited scripts (filestore-aware backup, neutralized restore, hash check)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Validate the plugin

**Files:** none (verification only).

- [ ] **Step 1: Run the marketplace validator**

Run: `claude plugin validate .`
Expected: passes. If the command is unavailable, fall back to the manual checks below.

- [ ] **Step 2: Manual structural checks (fallback / belt-and-suspenders)**

Run:
```bash
python3 - <<'PY'
import json, os
m = json.load(open('.claude-plugin/marketplace.json'))
names = [p['name'] for p in m['plugins']]
assert 'odoo' in names, 'odoo missing from marketplace'
assert names == sorted(names), f'plugins not alphabetically sorted: {names}'
o = [p for p in m['plugins'] if p['name']=='odoo'][0]
assert o['source'] == './plugins/odoo'
pj = json.load(open('plugins/odoo/.claude-plugin/plugin.json'))
assert pj['name'] == 'odoo'
assert pj['description'] == o['description'], 'description out of sync (plugin.json vs marketplace.json)'
assert os.path.exists('plugins/odoo/skills/odoo/SKILL.md')
assert os.access('plugins/odoo/install.sh', os.X_OK)
print('manual validation ok')
PY
```
Expected: `manual validation ok`

- [ ] **Step 3: Confirm every reference/playbook the SKILL.md links actually exists**

Run:
```bash
cd plugins/odoo/skills/odoo
for f in $(grep -oE '(reference|playbooks|scripts)/[a-z0-9-]+\.(md|sh)' SKILL.md | sort -u); do
  test -e "$f" || echo "MISSING: $f"
done; echo "link check done"; cd - >/dev/null
```
Expected: `link check done` with no `MISSING:` lines.

No commit (verification only). After this passes, push the `odoo-skill` branch and open the PR; coordinate the merge so `?plugins=odoo` resolves on GitHub for the companion magneto plan's Task 12 Step 5.

---

## Self-Review

**Spec coverage** (against spec section G + the skillFileMap):
- plugin.json + marketplace registration → Task 2. ✓
- install.sh (postgresql-client/openssh-client/sshpass) → Task 3. ✓
- SKILL.md (frontmatter, golden rules, gates, maintenance) → Task 4. ✓
- 11 reference docs → Tasks 5–7 (4 + 3 + 4). ✓
- 6 playbooks + learnings.md → Task 8. ✓
- 3 scripts → Task 9. ✓
- validation → Task 10. ✓

**Placeholder scan:** the structured artifacts (plugin.json, marketplace entry, install.sh, the 3 scripts) are inlined in full. The markdown reference/playbook docs are specified as concrete "must state" fact-lists with the exact `.research/odoo` source files to read and verifiable `grep` gates — this is a content spec, not a `TODO`. (The full prose is authored at execution from those cited sources; inlining ~11 finished reference docs verbatim would duplicate the skill into the plan.)

**Type/name consistency:** the plugin name `odoo` and the shared `description` are asserted identical across plugin.json/marketplace.json/SKILL.md (Tasks 2/4/10); the scripts use `${ODOO_HOST}`/`${ODOO_DB_NAME}`/`${CLOUVE_OPS_PASSWORD}` matching the persona's exported vars (companion plan Task 11); `odoo` ≡ `odoo-bin` used consistently.

**Cross-repo ordering:** Task 10 notes the branch must be pushed/merged so `?plugins=odoo` resolves before the companion magneto plan's agent-loads-skill check.
