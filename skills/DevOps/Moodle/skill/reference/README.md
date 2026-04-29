# Moodle DevOps reference

Per-topic facts about Moodle 5.2.0, sourced from the upstream tag `v5.2.0` (commit `c197f31fd89bf5dd5ba41661b06660167e419099`) and the [official 5.2 admin docs](https://docs.moodle.org/502/en/Main_page).

## How to navigate

Start with [stack-and-runtime.md](stack-and-runtime.md) and [architecture.md](architecture.md) when onboarding to a new instance — the rest of the docs assume you know which file lives at the project root vs. inside `public/`.

| File | What it covers |
|---|---|
| [shell-access.md](shell-access.md) | SSH'ing into the moodle / moodle-mysql side containers as `clouve-ops`, when to use SSH vs. TCP `mysql`/`curl` |
| [stack-and-runtime.md](stack-and-runtime.md) | PHP 8.3+, supported DBs (MariaDB 10.11+, PostgreSQL 16+, MySQL 8.4+, MSSQL 15+), required + recommended PHP extensions, OS-level packages, filesystem layout |
| [architecture.md](architecture.md) | The 5.2 `public/` webroot relocation, request lifecycle, plugin taxonomy, where each subsystem lives |
| [configuration.md](configuration.md) | `config.php` cheat sheet — DB, paths, sessions, MUC, sslproxy, debug, security flags — with the recommended `getenv()` pattern |
| [install-and-bootstrap.md](install-and-bootstrap.md) | Non-interactive install via `admin/cli/install_database.php`, the `mdl_config` install sentinel, what "installed" means |
| [upgrade.md](upgrade.md) | `version.php` ↔ `mdl_config(version)` invariant, `admin/cli/upgrade.php` flag semantics, exit codes, the `requires=4.4` floor for 5.2 |
| [cron-and-tasks.md](cron-and-tasks.md) | Every-minute cron, `tool_task` scheduled vs. adhoc tasks, `--keep-alive` daemon mode, lock factories |
| [caching.md](caching.md) | MUC stores in 5.2 (apcu, file, redis, session, static — memcached and mongodb cache stores are gone), recommended store mappings |
| [file-storage.md](file-storage.md) | `moodledata/filedir/` content-addressable layout, `alternative_file_system_class`, shared-volume requirement for HA |
| [backup-restore.md](backup-restore.md) | DB + `moodledata` coordination, course-level `.mbz` vs. site-level snapshots, maintenance-mode timing |
| [data-model.md](data-model.md) | Never-touch tables, safe-to-touch tables, the `mdl_config` / `mdl_config_plugins` / `mdl_user` / `mdl_course` tables |
| [security.md](security.md) | File permissions, https + sslproxy, `preventexecpath`, cookies, antivirus, CSRF/sesskey, headers |
| [performance.md](performance.md) | PHP-FPM pool sizing, OPcache, `cachejs`, theme designer mode warning, DB read/write split |
| [scaling.md](scaling.md) | Preconditions for horizontal scaling: shared `moodledata`, shared MUC, shared session store |
| [observability.md](observability.md) | `report_log`, `tool_log`, `admin/cli/checks.php`, the `\core\check\check` framework, liveness/readiness probes |
| [troubleshooting.md](troubleshooting.md) | Failure modes seen in the wild and the first thing to check for each |
| [changes-in-5.2.md](changes-in-5.2.md) | The operator-relevant changelog distilled from `UPGRADING.md` |

## Citation convention

When a fact in these docs is sourced from the upstream tree, the citation links to GitHub at tag `v5.2.0` so the reference is stable: `[public/version.php](https://github.com/moodle/moodle/blob/v5.2.0/public/version.php)`. When the fact comes from the Clouve packaging, the link is relative into the `apps/moodle/` tree.
