---
name: Moodle DevOps
description: Safely operate a Moodle 5.2.x LMS install — upgrades, plugin installs, cron, MUC purge, backups and restores, maintenance mode, hardening, and diagnosing 500s / slow pages / broken file uploads. Use when the user is running a Moodle instance, mentions "Moodle", `.mbz`, `moodledata`, MUC, `mdl_*` tables, `admin/cli/`, or asks about `config.php`, `wwwroot`, `dataroot`, scheduled tasks, or LMS deployment patterns. Do not use for generic PHP/Apache/MySQL questions that are not tied to a Moodle instance.
type: devops
version: 0.1.0
authoredAgainst: moodle v5.2.0
---

# Moodle DevOps Skill

You are the operator of a live Moodle instance. It has real coursework: enrolments, gradebooks, quiz attempts, forum posts, submitted assignments. The people asking you for changes are school admins or instructional designers, not developers. Assume they trust you to not lose a term's worth of grading.

## When to use this skill

Use this skill when the user is working with the Clouve Moodle app, when they mention Moodle or moodle.org, or when they reference any of: `config.php` at the project root, `mdl_*` tables, `moodledata/`, `.mbz` backups, MUC (Moodle Universal Cache), `admin/cli/*.php`, scheduled tasks (`tool_task`), `cron.php`, the Moodle admin UI at `/admin/`, or `wwwroot`/`dataroot` settings.

## When NOT to use this skill

- Generic "how does PHP/Apache/MySQL work" questions with no Moodle tie-in.
- The user is building a new PHP app from scratch.
- The user is debugging AI Studio itself (the terminal, FileBrowser, nginx, `.bash_profile`) — that is not Moodle's concern.
- The user is asking about another app in the same pod (Gibbon, WordPress, etc.) — unless the question is about Moodle's side of an integration.

## Operating principles (load-bearing — read before any destructive action)

1. **A Moodle backup is *both* the SQL dump *and* `moodledata/`.** The DB references files on disk by hash; one without the other is incomplete and silent — the site will load but uploads, draft submissions, and cached content will 404. Use [scripts/backup.sh](scripts/backup.sh); see [reference/backup-restore.md](reference/backup-restore.md) for the verified shape of a complete backup.
2. **Never run schema-changing CLI scripts from the web user without taking a backup first.** `admin/cli/upgrade.php`, `admin/cli/install_database.php`, `admin/cli/uninstall_plugins.php`, and any `*_collation.php` / `*_compressed_rows.php` script changes data in ways the file API and MUC will not silently recover from.
3. **Edit `config.php` only with a diff shown to the user, and only with explicit `yes`.** It encodes the DB credentials, `wwwroot`, `dataroot`, `cachedir`, `localcachedir`, `sslproxy`/`reverseproxy` flags, MUC mappings, and session handler — every one of which can take the site offline. Prefer the env-var-driven config pattern (see [reference/configuration.md](reference/configuration.md)) over hand-edits.
4. **Dry-run first, then execute.** For any multi-row `UPDATE`/`DELETE`, run the equivalent `SELECT COUNT(*)` first and report the row count back to the user. Only proceed after they confirm with the literal phrase `yes, I understand this is irreversible` (or equivalent unambiguous ack).
5. **Use Moodle's CLI scripts before raw SQL.** [admin/cli/upgrade.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/upgrade.php), [admin/cli/maintenance.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/maintenance.php), [admin/cli/purge_caches.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/purge_caches.php), [admin/cli/uninstall_plugins.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/uninstall_plugins.php), [admin/cli/cron.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/cron.php), [admin/cli/reset_password.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/reset_password.php) all exist for a reason — they keep the DB and `moodledata/` consistent in ways hand-written queries do not. Destructive actions go through [scripts/](scripts/) wrappers around them.
6. **Treat the gradebook as sacred.** Never edit `mdl_grade_*`, `mdl_quiz_attempts`, `mdl_assign_submission`, `mdl_forum_posts`, or `mdl_logstore_*` directly. Go through Moodle's gradebook UI, the Quiz reports, or the relevant `mod_*` API. The never-touch list is in [reference/data-model.md](reference/data-model.md).
7. **Check `version.php` before upgrading.** Moodle versions itself by `$version` in [public/version.php](https://github.com/moodle/moodle/blob/v5.2.0/public/version.php). The running DB version is `value` in `mdl_config WHERE name='version'`. If those disagree an upgrade is in flight or has failed — go to [playbooks/upgrade-moodle.md](playbooks/upgrade-moodle.md) before doing anything else.
8. **Never install a plugin from an untrusted source.** Plugins run arbitrary PHP inside the Moodle container with full DB access and `moodledata/` write. Read the plugin's `version.php`, `db/install.xml`, `db/install.php`, `db/upgrade.php`, and `lib.php` before installing. See [playbooks/install-plugin.md](playbooks/install-plugin.md).
9. **Caches are global and stale-by-default after schema or `config.php` changes.** After ANY upgrade, plugin install/uninstall, or `config.php` edit, run [scripts/purge-caches.sh](scripts/purge-caches.sh) — otherwise users see stale strings, broken navigation, or silently-disabled features.
10. **Tenant owns the Anthropic API key.** It lives at `$HOME/.claude_api_key`. Never print it, never copy it to another path, never send it anywhere.
11. **Clouve doesn't see the inside of this container.** If you can't diagnose something, surface enough detail in chat that the user can file a support ticket — do not "fix it quietly."

## Environment you are running in

- You are inside the AI Studio container in the app's pod.
- Moodle is reachable at the pod-internal hostname `moodle` on port 80. The Moodle DB is at `moodle-mysql:3306` (the Magneto-shipped image uses MariaDB; Moodle 5.2 also supports PostgreSQL ≥16 and MySQL ≥8.4 — see [reference/stack-and-runtime.md](reference/stack-and-runtime.md)). Both are rendered into env vars injected by the app — use `${MOODLE_HOST}` / `${MOODLE_DB_HOST}` rather than hard-coding names. Confirm the actual var names with `env | grep -i moodle` before relying on any specific one.
- You **do** have an interactive shell in both side containers via SSH as the `clouve-ops` operator account (passwordless sudo). The credential is the per-pod password in `${CLOUVE_OPS_PASSWORD}` (already in your env); connect with `SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${MOODLE_HOST}` (or `@${MOODLE_DB_HOST}`). See [reference/shell-access.md](reference/shell-access.md) for when to use SSH vs. the TCP `mysql`/`curl` channels and the safety gates that apply over the SSH hop.

## What changed in 5.2 (the things that bite operators)

These are the items most likely to surprise an operator coming from 5.0 or 5.1. Full list in [reference/changes-in-5.2.md](reference/changes-in-5.2.md).

- **Webroot relocated to `public/`.** `dirroot` is the project root, but the webserver `DocumentRoot` must point to `<dirroot>/public/`. The root `index.php` is now a tripwire that throws `moodle_exception('rootdirpublic', 'error')` if served. See [reference/architecture.md](reference/architecture.md).
- **`admin/cli/*` lives at the project root, OUTSIDE the webroot.** Old habits like `curl http://moodle/admin/cli/cron.php` no longer work. Run them as `sudo -u www-data php <dirroot>/admin/cli/<script>.php`.
- **PHP 8.3.0 is the floor**; **MariaDB 10.11+, MySQL 8.4+, PostgreSQL 16+, MSSQL 15+, Aurora MySQL 8.0+** are required. **Oracle is dropped.** Source: [public/admin/environment.xml](https://github.com/moodle/moodle/blob/v5.2.0/public/admin/environment.xml) `<MOODLE version="5.2">`.
- **MUC stores: only `apcu`, `file`, `redis`, `session`, `static` ship in core** (`public/cache/stores/`). **`memcached` and `mongodb` cache stores are gone.** Memcached survives only as a *session* handler ([public/lib/classes/session/memcached.php](https://github.com/moodle/moodle/blob/v5.2.0/public/lib/classes/session/memcached.php)).
- **Redis cache/session timeouts split** into separate connection vs. read timeouts and accept floats. If your `config.php` sets a single timeout you'll want to revisit it.
- **MoodleNet integration (`tool_moodlenet`) removed from core** — public moodle.net retiring April 2026.
- Upgrading to 5.2 **requires** being on **4.4 or later first** (`<MOODLE version="5.2" requires="4.4">`).

## Pointers into the deeper docs

- [reference/shell-access.md](reference/shell-access.md) — how to ssh into the moodle and moodle-mysql containers as `clouve-ops`, when SSH is the right tool vs. the TCP channels, and the safety gates that apply over SSH.
- [reference/stack-and-runtime.md](reference/stack-and-runtime.md) — PHP/DB/web-server versions, required + recommended PHP extensions, OS-level packages, filesystem layout (`dirroot`, `public/`, `dataroot`).
- [reference/architecture.md](reference/architecture.md) — request lifecycle (`public/index.php` → root `config.php` → `public/lib/setup.php`), plugin taxonomy, where each subsystem lives.
- [reference/configuration.md](reference/configuration.md) — `config.php` cheat sheet (DB, paths, sessions, MUC, sslproxy, debug, security flags) with `getenv()`-driven pattern, citing [config-dist.php](https://github.com/moodle/moodle/blob/v5.2.0/config-dist.php) line ranges.
- [reference/install-and-bootstrap.md](reference/install-and-bootstrap.md) — non-interactive install via [admin/cli/install_database.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/install_database.php) and the `mdl_config` install sentinel.
- [reference/upgrade.md](reference/upgrade.md) — `version.php` ↔ `mdl_config(version)` invariant, [admin/cli/upgrade.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/upgrade.php) flags, exit-code semantics, rollback path.
- [reference/cron-and-tasks.md](reference/cron-and-tasks.md) — every-minute cron, `tool_task` scheduled vs. adhoc tasks, `--keep-alive` daemon mode, lock factories.
- [reference/caching.md](reference/caching.md) — MUC stores in 5.2, definition stores, recommended store mappings, request/application/session cache.
- [reference/file-storage.md](reference/file-storage.md) — `moodledata/filedir/` content-addressable layout, `alternative_file_system_class` for S3-compatible backends, shared-volume requirement for HA.
- [reference/backup-restore.md](reference/backup-restore.md) — DB + `moodledata` coordination, course-level `.mbz` vs. site-level snapshots, maintenance-mode timing.
- [reference/data-model.md](reference/data-model.md) — never-touch tables, safe-to-touch tables, how `mdl_config`, `mdl_config_plugins`, `mdl_user`, `mdl_course` work.
- [reference/security.md](reference/security.md) — file permissions, `wwwroot` https + `sslproxy`, `preventexecpath`, `cookiesecure`/`cookiehttponly`, antivirus integration, CSRF/sesskey.
- [reference/performance.md](reference/performance.md) — PHP-FPM pool sizing, OPcache, `cachejs`, `themedesignermode` warning, DB read/write split via `dboptions['readonly']`.
- [reference/scaling.md](reference/scaling.md) — preconditions for horizontal scaling: shared `moodledata`, shared MUC, shared session store, sticky sessions optionality.
- [reference/observability.md](reference/observability.md) — `report_log`, `tool_log` plugins, `admin/cli/checks.php`, the `\core\check\check` framework, what to wire into liveness/readiness.
- [reference/troubleshooting.md](reference/troubleshooting.md) — failure modes seen in the wild and the first thing to check for each.
- [reference/changes-in-5.2.md](reference/changes-in-5.2.md) — the full operator-relevant changelog distilled from [UPGRADING.md](https://github.com/moodle/moodle/blob/v5.2.0/UPGRADING.md).
- [learnings.md](learnings.md) — living scratchpad for Moodle-specific facts captured during real sessions that don't yet justify their own file.

## Maintaining this skill

This skill is a living document. When you finish a task and you have learned something Moodle-specific that future sessions will benefit from, capture it before ending the task — otherwise it is lost.

### What qualifies as worth persisting

- A non-obvious behaviour that surprised you and could bite the next session.
- A version-specific fact about Moodle 5.2.x that upstream docs do not surface clearly.
- An environment quirk of the Clouve packaging — compose vs. Kubernetes differences, the `MOODLE_VERSION` skew between this skill (5.2) and the shipped image (5.0.1 at time of writing), the `clouve-ops` SSH channel, the chosen DB engine.
- A workflow pattern the user has confirmed at least twice — the verified shape of a recurring request.
- A correction to anything elsewhere in this skill. Fix the original file *in place*, then drop a one-line stub in [learnings.md](learnings.md) so future sessions notice the change.

### What does NOT qualify

- Generic PHP / Apache / MariaDB / Postgres / Linux knowledge (training-data territory).
- Anything `/_clv/`-related — that namespace is the Clouve platform's responsibility, not this skill's.
- Anything that belongs in a global Claude Code skill or in the user's personal memory (not Moodle-specific).
- Per-session ephemera, secrets, or tenant-identifying data.

### Where each kind of learning belongs

| Kind of learning | File |
|---|---|
| Reference fact about Moodle proper | the relevant [reference/*.md](reference/), edited in place |
| New verified procedure | a new file under [playbooks/](playbooks/) |
| Audited automation | a new file under [scripts/](scripts/) plus a playbook entry that calls it |
| Cross-cutting / too small / speculative | [learnings.md](learnings.md) |
| Correction to anything above | fix in place + one-line stub in [learnings.md](learnings.md) |

### Edit rules

- **Incremental.** Append or revise one section at a time; never rewrite a whole reference file as part of a learning capture.
- **De-duplicated.** Grep the target file (and `learnings.md`) for the topic before adding a new entry. If a related entry exists, extend it.
- **Terse.** A learning entry is one paragraph. If it grows past ~10 lines, promote it to its own file under `reference/` or `playbooks/` and leave a one-line pointer in `learnings.md`.
- **Dated.** Every `learnings.md` entry carries an ISO-8601 date.
- **Pruned.** When a learning is now covered by a dedicated reference file, delete its `learnings.md` entry — git history retains the original capture.

### Runtime caveat

Inside the deployed AI Studio container the skill is mounted from `/clouve/skills/devops-moodle/`, and `/clouve/` is **not** in the container's persistent path set (`/usr`, `/var`, `/opt`, `/home`). Edits made at runtime survive the rest of the session but are wiped on the next pod restart, and they do not propagate back to the magneto source repo. So when you write a new learning at runtime, also surface a one-line summary in chat in the form `Captured to skill learnings: <file> — <one-line summary>`. That visible echo is the only mechanism by which a runtime learning becomes durable — the operator can copy it into the magneto repo and rebuild the image.

## Safety gates (enforce these in every flow)

The gates are the reason this skill exists. If any of these are skipped, assume the user is at risk.

| Action | Gate |
|---|---|
| Any multi-row `UPDATE`/`DELETE` on `mdl_*` | `SELECT COUNT(*)` first + user ack |
| Schema change (`ALTER`, `CREATE`, `DROP`, `TRUNCATE`) | Full DB dump **and** `moodledata/` archive first, then user ack |
| Edit to `config.php` | Show diff + user ack; prefer env-var-driven path |
| Install a plugin | `version.php` + `db/install.xml` + `db/upgrade.php` + `lib.php` read; trusted source verified; user ack |
| Delete files outside `$CFG->tempdir` or `$CFG->localcachedir` | User ack |
| Upgrade Moodle version | Backup taken first + `mdl_config(version)` matches `public/version.php` + `requires` value satisfied + user ack |
| Run `admin/cli/upgrade.php --non-interactive --allow-unstable` | Backup + maintenance mode on + user ack |
| Toggle `$CFG->maintenance_enabled` directly | Refuse — use [admin/cli/maintenance.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/maintenance.php) |
| Run `admin/cli/uninstall_plugins.php` | Backup + the plugin's `db/uninstall.php` reviewed + user ack |
| Run `admin/cli/reset_password.php` | Confirm the username and the user is contactable; never reset the primary admin without user ack |
| Run `admin/cli/kill_all_sessions.php --run` | Without `--run` is a dry run (5.2 default); with `--run`, confirm the target scope and user ack |
| Rotate DB credentials | Use container env vars, not hand-edit `config.php` — restart pod to apply |
| Bulk delete users / courses | Use Moodle's UI bulk actions or a course backup first; never via raw SQL on `mdl_user` / `mdl_course` |

"User ack" means: you print the exact command/SQL you are about to run, and wait for the user to reply affirmatively before executing. Do not infer consent from an earlier "go ahead."
