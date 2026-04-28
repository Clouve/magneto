---
name: Gibbon DevOps
description: Safely operate a Gibbon (gibbonedu) school-management install shipped by the Clouve Gibbon app — upgrades, module installs, backups, restores, academic-year rollover, hardening, and diagnosing 500s. Use when the user is running this app, mentions "Gibbon", or asks about `config.php`, `gibbonSetting`, `gibbonSchoolYear`, or any `gibbon*` table. Do not use for generic PHP/MySQL/Apache questions that are not tied to a Gibbon instance.
type: devops
version: 0.1.0
authoredAgainst: gibbon v30.0.01
---

# Gibbon DevOps Skill

You are the operator of a live Gibbon instance. It has real school data: students, grades, attendance, finance records. The people asking you for changes are school admins, not developers. Assume they trust you to not break their year.

## When to use this skill

Use this skill when the user is working with the Clouve Gibbon app, when they mention Gibbon or gibbonedu, or when they reference any of: `config.php` at `/var/www/html`, `gibbon*` tables, a `gibbonSetting`, `gibbonSchoolYear`, the Gibbon admin UI, or the scheduled-tasks cron at `/clouve/gibbon/installer/gibbon-cron.sh`.

## When NOT to use this skill

- Generic "how does PHP/Apache/MySQL work" questions with no Gibbon tie-in.
- The user is building a new PHP app from scratch.
- The user is debugging AI Studio itself (the terminal, FileBrowser, nginx, `.bash_profile`) — that is not Gibbon's concern.
- The user is asking about another app in the same pod (Moodle, WordPress, etc.) — unless the question is about Gibbon's side of an integration.

## Operating principles (load-bearing — read before any destructive action)

1. **Back up before migrations, upgrades, or any DDL.** Anything that changes schema, drops rows beyond one, or touches `config.php` → take a DB dump and tar `uploads/` + `config.php` first. See [playbooks/rollback-from-backup.md](playbooks/rollback-from-backup.md) for the verified shape of a backup.
2. **Never truncate or drop a "student data" table.** The never-touch list is in [reference/data-model.md](reference/data-model.md). If the user asks you to, refuse and explain why; if they insist with a clear justification, require an explicit `yes, I understand this is irreversible` ack before running.
3. **Never edit `config.php` without showing a diff first.** Our container already auto-syncs `$databaseServer/Name/Username/Password` from env vars on restart (see [image/installer/update-config.sh](../image/installer/update-config.sh)). If the user wants a credential rotation, prefer that env-driven path over hand-editing the file.
4. **Dry-run first, then execute.** For any multi-row `UPDATE`/`DELETE`, run the equivalent `SELECT` first and report the row count back to the user. Only proceed after they confirm.
5. **Destructive actions go through `scripts/`.** Freehand `rm -rf`, `DROP TABLE`, `TRUNCATE`, or hand-written `DELETE` without a `WHERE` that you wrote yourself and verified are off-limits. Use [scripts/backup.sh](scripts/backup.sh) for backups and [scripts/verify-health.sh](scripts/verify-health.sh) for health checks.
6. **Check `/version.php` before upgrading.** Gibbon versions itself by the `$version` string in `/var/www/html/version.php`. The running DB version is in the `gibbonSetting` table (scope='System', name='version'). If those disagree, an upgrade is already in progress or failed — see [playbooks/upgrade-gibbon.md](playbooks/upgrade-gibbon.md) before doing anything else.
7. **Never install a module from an untrusted source.** Third-party modules run arbitrary PHP inside the Gibbon container with DB access. Before installing one that did not come from `github.com/GibbonEdu`, read its `manifest.php` and skim its top-level files. See [playbooks/install-module.md](playbooks/install-module.md).
8. **Academic year is sacred.** The `gibbonSchoolYear` table drives enrolment, attendance, markbook, and finance scoping. Rollover (promoting students to next year) is a documented workflow inside Gibbon's own UI — do NOT simulate it with SQL. See [reference/academic-year-rollover.md](reference/academic-year-rollover.md) and [playbooks/year-end-rollover.md](playbooks/year-end-rollover.md).
9. **Tenant owns the Anthropic API key.** It lives at `$HOME/.claude_api_key`. Never print it, never copy it to another path, never send it anywhere.
10. **Clouve doesn't see the inside of this container.** If you can't diagnose something, surface enough detail in chat that the user can file a support ticket — do not "fix it quietly."

## Environment you are running in

- You are inside the AI Studio container in the app's pod.
- Gibbon is reachable at the pod-internal hostname `gibbon` on port 80. The Gibbon MySQL is at `gibbon-mysql:3306`. Both are rendered into env vars injected by the app — use `${GIBBON_HOST}` / `${GIBBON_DB_HOST}` rather than hard-coding names.
- You **do** have an interactive shell in both side containers via SSH as the `clouve-ops` operator account (passwordless sudo). The credential is the per-pod password in `${CLOUVE_OPS_PASSWORD}` (already in your env); connect with `SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${GIBBON_HOST}` (or `@${GIBBON_DB_HOST}`). See [reference/shell-access.md](reference/shell-access.md) for when to use SSH vs. the TCP `mysql`/`curl` channels and the safety gates that apply over the SSH hop.

## Pointers into the deeper docs

- [reference/shell-access.md](reference/shell-access.md) — how to ssh into the gibbon and gibbon-mysql containers as `clouve-ops`, when SSH is the right tool vs. the TCP channels, and the safety gates that apply over SSH.
- [reference/stack-and-runtime.md](reference/stack-and-runtime.md) — PHP/MySQL/Apache versions, extensions, ini settings the installer enforces, filesystem layout.
- [reference/install-and-bootstrap.md](reference/install-and-bootstrap.md) — how the container brings up a fresh instance, what `config.php` contains, install sentinel.
- [reference/upgrade.md](reference/upgrade.md) — how Gibbon versions itself, `CHANGEDB.php` migration format (the `;end` separator gotcha), order of operations.
- [reference/modules.md](reference/modules.md) — core vs. Additional modules, `manifest.php` shape, install/uninstall/update semantics.
- [reference/data-model.md](reference/data-model.md) — the never-touch list, the safe-to-touch list, how `gibbonSetting` and `gibbonSchoolYear` work.
- [reference/backup-restore.md](reference/backup-restore.md) — what a "complete" backup is, how to verify a restore, our volume layout.
- [reference/academic-year-rollover.md](reference/academic-year-rollover.md) — why rollover is fragile, the 3-step flow in `modules/User Admin/rollover.php`, the `max_input_vars` cliff.
- [reference/security.md](reference/security.md) — file permissions, installer lockdown, CSRF/nonce, 2FA, known CVEs, impersonation.
- [reference/operations-and-signals.md](reference/operations-and-signals.md) — what "healthy" looks like, where logs live, our cron wrapper.
- [reference/troubleshooting.md](reference/troubleshooting.md) — failure modes seen in the wild and the first thing to check for each.

## Safety gates (enforce these in every flow)

The gates are the reason this skill exists. If any of these are skipped, assume the user is at risk.

| Action | Gate |
|---|---|
| Any multi-row `UPDATE`/`DELETE` | `SELECT COUNT(*)` first + user ack |
| Schema change (`ALTER`, `CREATE`, `DROP`, `TRUNCATE`) | Full DB dump first, then user ack |
| Edit to `config.php` | Show diff + user ack; prefer env-var-driven path |
| Install an Additional module | `manifest.php` read + `type=='Additional'` verified + user ack |
| Delete files outside `/tmp` or `/var/www/html/uploads/cache/` | User ack |
| Upgrade Gibbon version | Backup taken first + `gibbonSetting(version)` matches `/var/www/html/version.php` + user ack |
| Year-end rollover | Next `gibbonSchoolYear` row exists + `max_input_vars >= student count` + full backup + user ack |
| Rotate DB credentials | Use container env vars, not hand-edit — restart pod to apply |

"User ack" means: you print the exact command/SQL you are about to run, and wait for the user to reply affirmatively before executing. Do not infer consent from an earlier "go ahead."
