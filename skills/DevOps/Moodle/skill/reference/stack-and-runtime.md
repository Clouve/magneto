# Stack & Runtime

Moodle 5.2.0's declared requirements come from [public/admin/environment.xml](https://github.com/moodle/moodle/blob/v5.2.0/public/admin/environment.xml) (the `<MOODLE version="5.2">` block, lines 5111–) and [public/version.php](https://github.com/moodle/moodle/blob/v5.2.0/public/version.php). The Clouve image at [apps/moodle/image/Dockerfile](../../../../apps/moodle/image/Dockerfile) pins concrete versions that satisfy them.

## Version metadata

From `public/version.php`:

| Constant | Value |
|---|---|
| `$version` | `2026042000.00` (branch date 2026-04-20) |
| `$release` | `'5.2 (Build: 20260420)'` |
| `$branch` | `'502'` |
| `$maturity` | `MATURITY_STABLE` |

`environment.xml` declares `<MOODLE version="5.2" requires="4.4">` — meaning the source instance MUST be on **Moodle 4.4 or later** before upgrading to 5.2. Upgrading from 4.3 or older fails the `requires` check.

## PHP

| Item | 5.2 requires | Notes |
|---|---|---|
| PHP | `>= 8.3.0` | `<PHP version="8.3.0" level="required" />`. PHP 8.4 was not yet a target at branch time. |
| Extensions (required) | `iconv`, `mbstring`, `curl`, `openssl`, `ctype`, `zip`, `zlib`, `gd`, `simplexml`, `spl`, `pcre`, `dom` | All marked `level="required"` |
| Extensions (recommended) | `tokenizer`, `soap` | `level="optional"` with `ON_CHECK` recommendation |
| PCRE Unicode | optional | `<PCREUNICODE level="optional" />` — recommended for full UTF-8 |

The Clouve image inherits `php:8.3-apache`, which includes all required extensions either built-in or via the standard `docker-php-ext-install` invocations in [apps/moodle/image/Dockerfile](../../../../apps/moodle/image/Dockerfile).

### Required PHP ini values (operator must enforce)

The installer's environment check enforces these; if you `php -i | grep <key>` and they're below threshold, install/upgrade will fail. Numbers are the documented Moodle minima — bigger is fine.

| Setting | Recommended floor | Rationale |
|---|---|---|
| `memory_limit` | `>= 256M` (recommend `512M`) | Course backups and large quiz grading exceed 128M routinely. |
| `post_max_size` | `>= upload_max_filesize` | Uploads are gated by both. |
| `upload_max_filesize` | site policy | Defaults are 2M which is too small for video — bump to at least 256M for a typical school. |
| `max_input_vars` | `>= 5000` | Course settings forms with many sections / role overrides exceed 1000. |
| `max_execution_time` | `>= 120` for web, `0` for CLI | Cron and upgrade scripts run unbounded. |

## Databases

Moodle 5.2 supports the following DB engines — declared in `environment.xml` and implemented by the drivers in [public/lib/dml/](https://github.com/moodle/moodle/tree/v5.2.0/public/lib/dml).

| Engine | Minimum version | Driver file | `dbtype` value |
|---|---|---|---|
| MariaDB | 10.11.0 | `mariadb_native_moodle_database.php` | `'mariadb'` |
| MySQL | 8.4 | `mysqli_native_moodle_database.php` | `'mysqli'` |
| Aurora MySQL | 8.0 | `auroramysql_native_moodle_database.php` | `'auroramysql'` |
| PostgreSQL | 16 | `pgsql_native_moodle_database.php` | `'pgsql'` |
| MS SQL Server | 15.0 | `sqlsrv_native_moodle_database.php` | `'sqlsrv'` |

**Oracle is dropped in 5.2.** If you find a `dbtype = 'oci'` in a config.php this site is on Moodle ≤ 5.1 and the upgrade to 5.2 will fail until the data is migrated to one of the supported engines.

### Clouve packaging

The Magneto-shipped image uses **MariaDB**, see [apps/moodle/docker-compose.yml](../../../../apps/moodle/docker-compose.yml). Confirm with `env | grep -i moodle_db` — the username and DB name are usually `moodle`. The actual MariaDB version is shipped in [apps/moodle/image/mysql/Dockerfile](../../../../apps/moodle/image/mysql/Dockerfile).

If the user asks about migrating to Postgres, that is a one-way data migration and a different skill — flag the [Migrating to a different database upstream guide](https://docs.moodle.org/502/en/Converting_your_MySQL_database_to_UTF8mb4) and surface it as a separate engagement.

## Web server / SAPI

Moodle does not ship a preferred SAPI in environment.xml — both Apache (mod_php or php-fpm) and nginx (php-fpm) are supported. The Clouve image ships **Apache 2.4 + mod_php** on port 80 (`php:8.3-apache`).

The web server's `DocumentRoot` MUST point at `<dirroot>/public/`, **not** at `<dirroot>`. The repo-root [public/index.php](https://github.com/moodle/moodle/blob/v5.2.0/public/index.php) is the entry point; the root [index.php](https://github.com/moodle/moodle/blob/v5.2.0/index.php) is a tripwire that throws `moodle_exception('rootdirpublic', 'error')`. See [architecture.md](architecture.md) for the full layout.

## OS-level packages

Moodle delegates these to the operator. The packages most commonly needed by Moodle features:

| Package | Why |
|---|---|
| `imagemagick` | Thumbnail generation, PDF rendering for assignment annotation |
| `ghostscript` | Required by `assignfeedback_editpdf` for PDF assignment annotation |
| `unoconv` | Optional: document conversion for assignment submissions (`tool_unoconv`) |
| `clamav` | Optional: antivirus scanning (`antivirus_clamav`) on user uploads — see [security.md](security.md) |
| `aspell` | Optional: spell-check in the editor |

`apt-get install -y imagemagick ghostscript` covers the common case. ClamAV is heavy and optional — only install if the site enables `antivirus_clamav`.

## Filesystem layout (inside the `moodle` container)

Moodle 5.2 is structured around a public/non-public split. Memorize this — it is the load-bearing change in 5.2.

```
/var/www/html/                       ← $CFG->dirroot, project root, on a moodledata volume
├── config.php                       ← operator-edited config; OUTSIDE webroot
├── index.php                        ← TRIPWIRE: throws moodle_exception('rootdirpublic', 'error')
├── admin/                           ← OUTSIDE webroot
│   └── cli/                         ← all CLI maintenance scripts (cron, upgrade, install_database, ...)
├── lib/                             ← OUTSIDE webroot — migration shim that requires public/lib/setup.php
│   └── setup.php
├── composer.json, package.json      ← build manifests, OUTSIDE webroot
├── UPGRADING.md, INSTALL.txt        ← docs
└── public/                          ← $CFG->wwwroot DocumentRoot — webserver points here
    ├── index.php                    ← real entry point
    ├── config.php                   ← shim that requires ../config.php (or redirects to install.php if missing)
    ├── version.php                  ← $version, $release, $branch, $maturity, $requires
    ├── lib/setup.php                ← real Moodle bootstrap
    ├── admin/                       ← Moodle admin web UI (NOT the CLI)
    ├── mod/, blocks/, auth/, enrol/ ← plugin trees
    ├── theme/, local/, repository/, filter/, format/, question/, report/
    ├── cache/                       ← MUC stores, locks, definitions
    ├── lib/dml/                     ← DB drivers
    └── ...

/var/moodledata/                     ← $CFG->dataroot, MUST be writable by the web user
├── filedir/                         ← content-addressable file storage (hash-prefixed dirs)
├── temp/                            ← $CFG->tempdir; safe to wipe between runs
├── cache/                           ← $CFG->cachedir; MUST be shared across cluster nodes
├── localcache/                      ← $CFG->localcachedir; intended for per-node fast cache
├── lock/                            ← file lock factory backing store
├── sessions/                        ← only if $CFG->session_handler_class is file
└── trashdir/                        ← deleted-file holding pen
```

### `dirroot` semantics

The root [lib/setup.php](https://github.com/moodle/moodle/blob/v5.2.0/lib/setup.php) is a migration helper:

```php
if (property_exists($CFG, 'dirroot') && !str_ends_with($CFG->dirroot, '/public')) {
    $CFG->libdir = $CFG->libdir . '/lib';
}
require_once(dirname(__DIR__) . '/public/lib/setup.php');
```

This means: `$CFG->dirroot` may be set either to the project root OR to `<root>/public`. Both work. The recommended modern setting is the project root, with the webserver `DocumentRoot` at `<dirroot>/public/`.

### `dataroot` is a security boundary

`$CFG->dataroot` MUST be **outside** the webroot. The directory holds user-uploaded files keyed by content hash; serving it from a URL would bypass Moodle's permission checks. The default examples in [config-dist.php](https://github.com/moodle/moodle/blob/v5.2.0/config-dist.php) (line ~191) use `/home/example/moodledata` precisely for this reason. Never `chmod` `moodledata/` into `public/` "for convenience."

### Required permissions

| Path | Owner | Mode | Notes |
|---|---|---|---|
| `<dirroot>` (project root) | `root:www-data` (or deploy user) | `0755` dirs, `0644` files | Web server reads, does not write |
| `<dirroot>/public/` | same | same | Web-served |
| `<dirroot>/config.php` | `root:www-data` | `0640` | Contains DB password — restrict |
| `<dataroot>` | `www-data:www-data` | `0770` dirs, `0660` files | Web server writes |
| `<dataroot>/filedir` | same | same | Content-addressable file storage |

Do NOT make `<dirroot>` writable by the web user. `admin/cli/upgrade.php` runs as root or the deploy user; runtime PHP must not be able to overwrite the codebase, otherwise an RCE in any plugin becomes a full takeover.
