# Stack & Runtime

Gibbon v30.0.01's declared requirements come from `version.php` (the `$systemRequirements` array) and `composer.json`. The Clouve image ([apps/gibbon/image/Dockerfile](../../image/Dockerfile)) pins concrete versions that satisfy them.

## PHP

| Item | Gibbon requires | Clouve image ships |
|---|---|---|
| PHP | `^8.0` | 8.3 (`php:8.3-apache`) |
| Extensions (required) | `gettext`, `mbstring`, `curl`, `zip`, `xml`, `gd`, `intl`, `PDO`, `pdo_mysql` | All of the above + `opcache` |
| `max_input_vars` | `>= 8000` | 8000 (set in `php.ini` and echoed into `.htaccess`) |
| `max_file_uploads` | `>= 20` | default (20) |
| `allow_url_fopen` | `== 1` | default on |
| `register_globals` | `== 0` | PHP 5.4+ doesn't allow it — satisfied |
| `session.gc_maxlifetime` | `>= 1200` | default (1440) |
| `post_max_size` | `> 0` | 20M (set in `php.ini`) |
| `upload_max_filesize` | `> 0` | 20M (set in `php.ini`) |
| `memory_limit` | Installer needs ≥ 512M for some imports (`auto.php` ups it to 5120M for install) | 512M |

**Why `max_input_vars` matters:** the year-end rollover form in `modules/User Admin/rollover.php` has one input per enrolled student. If the school has more students than `max_input_vars`, the form silently truncates and the rollover is partial. The installer surfaces a hard check for this; our image sets 8000 which is fine for most schools but a big district may need more (see [academic-year-rollover.md](academic-year-rollover.md)).

## MySQL

| Item | Required | Shipped |
|---|---|---|
| MySQL | `>= 8.0` | MySQL 8.0 ([apps/gibbon/image/mysql/Dockerfile](../../image/mysql/Dockerfile)) |
| Collation | InnoDB + `utf8mb3` | `utf8mb3` (v30.0.01 fixed a collation bug for MariaDB hosts — MariaDB installs are unsupported in this app) |

**Character set trap:** Gibbon's schema (`gibbon.sql`) declares `CHARSET=utf8mb3`. MariaDB treats `utf8` as an alias differently than MySQL 8 does, which is why v30.0.01 explicitly notes "fixed default collation in gibbon.sql causing installation issues for MariaDB systems." The Clouve Gibbon app ships MySQL 8, not MariaDB — do not help a tenant swap the DB image for MariaDB without warning about this.

## Apache

| Item | Required | Shipped |
|---|---|---|
| Apache modules | `mod_rewrite` | `a2enmod rewrite` |
| | `mod_headers` | `a2enmod headers` (for security headers) |
| Default security headers | — | `X-Content-Type-Options: nosniff`, `X-Frame-Options: sameorigin`, `X-XSS-Protection: 1; mode=block` |
| Indexing | Off | `Options FollowSymLinks` (Indexes stripped) |
| `ServerTokens` | Prod | Prod |
| `ServerSignature` | Off | Off |
| `expose_php` | Off | Off (`php.ini`) |

## Filesystem layout (inside the `gibbon` container)

```
/var/www/html/                       ← Apache DocumentRoot, Gibbon install, on gibbondata volume
├── config.php                       ← DB creds + guid + absolutePath; sentinel for "installed?"
├── version.php                      ← $version (e.g. '30.0.01')
├── gibbon.php                       ← bootstrap / DI container / config include
├── CHANGEDB.php                     ← ALL historical schema migrations
├── gibbon.sql                       ← reference schema (shipped, not applied at runtime)
├── gibbon_demo.sql                  ← demo-data seed (opt-in via DEMO_DATA=Y)
├── update.php                       ← the upstream web-UI upgrade trigger
├── installer/                       ← web installer + our auto.php
├── modules/<ModuleName>/            ← 27 core modules + any Additional modules installed
├── i18n/                            ← locale bundles
├── uploads/
│   ├── cache/                       ← wiped on every container start
│   └── <tenant files>               ← user-uploaded content
├── customAssets/                    ← optional: theme overrides, custom logos
├── themes/<ThemeName>/
├── clouve/installed/                ← Clouve-side install sentinel (versions)
└── var/log/                         ← Gibbon's own log dir (distinct from /var/log)

/clouve/                             ← image-layer scratch (NOT a volume — reset on each pod start)
├── gibbon/
│   ├── gibbon-30.0.01/              ← pristine package contents from InstallBundle.tar.gz
│   └── installer/                   ← entrypoint.sh, install.sh, upgrade.sh, auto.php, ...
└── skills/gibbon-devops/            ← THIS skill, mounted here by the app (AI Studio container only)

/var/log/gibbon-cron.log             ← our cron wrapper's log
/var/log/gibbon-cron.state/          ← per-task lastrun timestamps
/etc/cron.d/gibbon-cron              ← rendered from GIBBON_CRON_INTERVAL at container start
```

**Writable paths:** after `upgrade.sh` runs, the whole `/var/www/html` tree is `chown www-data:www-data` + `chmod -R 755`. Hot paths that Apache writes to during normal operation:

- `/var/www/html/config.php` — read-only at runtime; our `update-config.sh` rewrites it at boot
- `/var/www/html/uploads/` — user-uploaded files, recursive write
- `/var/www/html/uploads/cache/` — templates + compiled views; clobbered on every restart
- `/var/www/html/var/log/` — Gibbon's own logger output (separate from Apache stderr)

**Read-only paths under normal operation:** everything else under `/var/www/html/` including `modules/`, `i18n/`, `themes/`, `installer/`. Gibbon writes state to MySQL, not the filesystem (apart from uploads and cache).

## Container env surface

The installer and runtime read these env vars. Declared in [apps/gibbon/clv-docker-compose.yml](../../clv-docker-compose.yml):

| Var | Purpose | Set by |
|---|---|---|
| `DB_HOST` | MySQL hostname | `containerReference` — always `gibbon-mysql` in this app |
| `DB_NAME` | Database name | `static` — always `gibbon` |
| `DB_USER` | DB user | `static` — always `gibbon` |
| `DB_PASSWORD` | DB password | `secret` — Clouve auto-generates |
| `GIBBON_URL` | `absoluteURL` in `gibbonSetting` | `applicationUrl` — tenant's public URL |
| `GIBBON_USERNAME`/`_PASSWORD`/`_EMAIL` | First admin user | `applicationUsername`/`applicationPassword` |
| `GIBBON_ORGANISATION_NAME`/`_INITIALS` | School name / acronym | `userConfigurable` |
| `GIBBON_TIMEZONE` | default `America/Los_Angeles` | `userConfigurable` (optional — has default) |
| `GIBBON_COUNTRY` | default `United States` | same |
| `GIBBON_CURRENCY` | default `USD $` | same |
| `GIBBON_AUTOINSTALL` | `1` — drive non-interactive install | `static` |
| `GIBBON_LOG_LEVEL` | Apache `LogLevel` (`debug`/`info`/`warn`/`error`) | `static` |
| `GIBBON_CRON_INTERVAL` | crontab expression for the scheduled-tasks tick | `userConfigurable` (default `* * * * *`) |
| `DEMO_DATA` | `Y` or `N` | `static` — always `N` in this app |
| `ENABLE_MOODLE_INTEGRATION`, `GIBBON_INTEGRATION_SQL_*` | Moodle-view creation | only set by the `education-kit` bundle |

Anything in `$user_data` in `auto.php` that isn't backed by an env var falls back to a hard-coded default (e.g. `installType="Production"`, `statsCollection="N"`, `cuttingEdgeCode="No"`). If a tenant asks to change these post-install, they go through Gibbon's own UI (System Admin → System Settings), not env vars.
