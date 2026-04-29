# Architecture

The single most load-bearing fact about Moodle 5.2: **the project root is no longer the webroot.** The webserver `DocumentRoot` must point to `<dirroot>/public/`. Operator-only artifacts (`config.php`, `admin/cli/`, build manifests) live outside it.

## Top-level layout

| Path | Type | Notes |
|---|---|---|
| `<dirroot>/index.php` | tripwire | [Source](https://github.com/moodle/moodle/blob/v5.2.0/index.php). Throws `moodle_exception('rootdirpublic', 'error')` if served by a webserver that mistakenly points at the root. |
| `<dirroot>/config.php` | operator-edited | Created by the operator (or `install.php`). Holds DB creds, `wwwroot`, `dataroot`, MUC mappings. NEVER reachable via HTTP. |
| `<dirroot>/config-dist.php` | template | [Source](https://github.com/moodle/moodle/blob/v5.2.0/config-dist.php). Reference template, copy + edit. |
| `<dirroot>/admin/cli/` | CLI scripts | All maintenance entry points. Outside webroot — cannot be invoked over HTTP. See [admin/cli/](https://github.com/moodle/moodle/tree/v5.2.0/admin/cli). |
| `<dirroot>/lib/setup.php` | shim | [Source](https://github.com/moodle/moodle/blob/v5.2.0/lib/setup.php). Migration helper that delegates to `public/lib/setup.php`. |
| `<dirroot>/composer.json`, `composer.lock` | build manifest | Out-of-webroot per security best practice. |
| `<dirroot>/package.json`, `Gruntfile.js` | build manifest | Front-end build (Grunt + esbuild). |
| `<dirroot>/UPGRADING.md` | docs | Per-component upgrade notes — the source of truth for breaking changes per release. |
| `<dirroot>/public/` | webroot | DocumentRoot points here. |
| `<dataroot>/` | runtime data | `$CFG->dataroot`. MUST be outside `<dirroot>`. See [file-storage.md](file-storage.md). |

## Inside `public/`

```
public/
├── index.php                ← real entry point: bootstraps and routes
├── config.php               ← shim: requires ../config.php; redirects to install.php if absent
├── version.php              ← Moodle's own version: $version, $release, $branch, $maturity, $requires
├── install.php              ← interactive web installer (only callable when ../config.php is missing)
├── lib/
│   ├── setup.php            ← REAL Moodle bootstrap; loaded after config.php
│   ├── dml/                 ← DB driver layer; one *_native_moodle_database.php per engine
│   ├── classes/             ← PSR-4 autoloaded core (\core\*)
│   ├── filestorage/         ← File API
│   └── outputrenderers.php  ← Output renderer base classes
├── admin/                   ← admin WEB UI (settings pages); NOT the CLI
│   ├── environment.xml      ← per-version requirements matrix (DB, PHP, extensions)
│   ├── tool/                ← admin "tools" — task scheduler, log, plugin management, ...
│   └── ...
├── mod/                     ← activity modules (assign, quiz, forum, lesson, scorm, lti, h5pactivity, ...)
├── blocks/                  ← side-bar blocks
├── auth/                    ← authentication plugins (manual, db, ldap, oidc, oauth2, shibboleth, ...)
├── enrol/                   ← enrolment methods (manual, self, cohort, meta, lti, paypal, ...)
├── theme/                   ← themes (boost is the default in 5.2)
├── local/                   ← site-local plugins (operator-installed)
├── repository/              ← file repositories (filesystem, equella, googledocs, onedrive, s3, ...)
├── filter/                  ← content filters (mathjaxloader, glossary, multilang, ...)
├── format/                  ← course formats (topics, weeks, singleactivity, ...)
├── question/                ← question engine + qtypes
├── report/                  ← site-level reports (log, loglive, performance, security, ...)
├── cache/
│   ├── stores/              ← MUC stores: apcu, file, redis, session, static
│   ├── locks/               ← lock providers (file)
│   └── ...
├── webservice/              ← REST/SOAP/AJAX/Mobile web services
├── ai/                      ← (5.2) AI provider abstractions
├── communication/           ← (5.x) Communication providers (Matrix, BBB, ...)
├── h5p/                     ← H5P engine (vendored)
└── ...
```

## Plugin taxonomy

Moodle's plugin system is type-prefixed. Every plugin directory contains a `version.php`, an optional `db/install.xml`, an optional `db/upgrade.php`, and (most types) a `lib.php`. The plugin's identity is `<frankenstyle>` = `<type>_<name>`, e.g. `mod_assign`, `auth_oauth2`, `block_html`, `local_clouve`.

| Type prefix | Path under `public/` | What it does | Install hook |
|---|---|---|---|
| `mod_*` | `mod/<name>/` | Activity modules (assignments, quizzes, forums, ...) | `db/install.xml` + `lib.php::<name>_add_instance()` |
| `block_*` | `blocks/<name>/` | Side-bar blocks | `db/install.xml`, `block_<name>.php` extends `block_base` |
| `auth_*` | `auth/<name>/` | Authentication source | `auth.php` extends `auth_plugin_base` |
| `enrol_*` | `enrol/<name>/` | Enrolment method | `lib.php` extends `enrol_plugin` |
| `theme_*` | `theme/<name>/` | UI theme | `config.php` declares parents and renderers |
| `local_*` | `local/<name>/` | Site-local plugin (custom integrations) | Standard plugin callbacks |
| `tool_*` | `admin/tool/<name>/` | Admin "tool" — scheduler, plugins, log, behat, ... | Standard plugin callbacks |
| `repository_*` | `repository/<name>/` | File repository | `lib.php` extends `repository` |
| `filter_*` | `filter/<name>/` | Content filter | `filter.php` extends `moodle_text_filter` |
| `format_*` | `course/format/<name>/` | Course format | Note: 5.x lives at `public/course/format/`, not `public/format/` |
| `report_*` | `report/<name>/` | Site-level report | Standard plugin callbacks |
| `qtype_*` | `question/type/<name>/` | Question type | Extends `question_type` |
| `qbank_*` | `question/bank/<name>/` | Question-bank tool | (Newer plugin type, modernized in 4.x) |
| `cachestore_*` | `cache/stores/<name>/` | MUC backend (apcu, file, redis, ...) | Extends `cache_store` |
| `cachelock_*` | `cache/locks/<name>/` | Distributed lock backend | Extends `cache_lock_interface` |
| `dataformat_*` | `dataformat/<name>/` | Tabular export format (csv, json, html, ods, pdf, excel) | |
| `availability_*` | `availability/<name>/` | Activity availability conditions | |
| `media_*` | `media/<name>/` | Media player | |
| `payment_*` | `payment/<name>/` | Payment gateway | |
| `customfield_*` | `customfield/<name>/` | Custom field type | |
| `mlbackend_*` | `lib/mlbackend/<name>/` | Analytics ML backend | |
| `aiplacement_*`, `aiprovider_*` | `ai/<placement\|provider>/<name>/` | (5.2) AI providers and placements | |
| `communication_*` | `communication/<name>/` | (5.x) Communication providers | |

For the full enumeration walk `ls public/` and `ls public/admin/tool/` against the v5.2.0 tree.

## Request lifecycle

1. **Webserver** receives a request for `https://<wwwroot>/<path>`.
2. **DocumentRoot** is `<dirroot>/public/`, so the file system path resolves under `public/`.
3. PHP loads the target script (e.g. `public/course/view.php`), which begins with:
   ```php
   require_once(__DIR__ . '/../config.php');
   ```
   Because `public/config.php` is a shim ([source](https://github.com/moodle/moodle/blob/v5.2.0/public/config.php)) that requires `../config.php`, this loads the OPERATOR-EDITED root `config.php`.
4. Root `config.php` sets `$CFG` properties (`dbtype`, `dbhost`, `dbname`, `dbuser`, `dbpass`, `prefix`, `wwwroot`, `dataroot`) and ends with:
   ```php
   require_once(__DIR__.'/lib/setup.php');
   ```
   This loads the root `lib/setup.php` shim, which requires `public/lib/setup.php` — the **real** Moodle bootstrap.
5. **`public/lib/setup.php`** initialises the autoloader, opens the DB connection, loads the cache configuration, sets up sessions, restores the user session, and dispatches to the requested page.
6. The page renders via the output renderer system ([public/lib/outputrenderers.php](https://github.com/moodle/moodle/blob/v5.2.0/public/lib/outputrenderers.php)) and the active theme.

## Core libraries

| Path | What lives there |
|---|---|
| [public/lib/dml/](https://github.com/moodle/moodle/tree/v5.2.0/public/lib/dml) | Database abstraction. `$DB` is a `moodle_database` subclass; methods like `get_record`, `insert_record`, `update_record`, `delete_records` live here. **Always use `$DB`, never raw `mysqli_*`.** |
| [public/lib/classes/](https://github.com/moodle/moodle/tree/v5.2.0/public/lib/classes) | PSR-4 autoloaded `\core\*` namespace — task manager, session, encryption, file storage, output, hooks, router, ... |
| [public/lib/filestorage/](https://github.com/moodle/moodle/tree/v5.2.0/public/lib/filestorage) | File API. Files in Moodle are addressed by `(contextid, component, filearea, itemid, filepath, filename)`; the filesystem stores them by content hash. See [file-storage.md](file-storage.md). |
| [public/lib/outputrenderers.php](https://github.com/moodle/moodle/blob/v5.2.0/public/lib/outputrenderers.php) | Output system. Themes override renderers. |
| [public/webservice/](https://github.com/moodle/moodle/tree/v5.2.0/public/webservice) | Web services framework (REST, SOAP, AJAX, Mobile). External API endpoints. |
| [public/lib/externallib.php](https://github.com/moodle/moodle/blob/v5.2.0/public/lib/externallib.php) | Base classes for external API functions. |
| [public/lib/classes/session/](https://github.com/moodle/moodle/tree/v5.2.0/public/lib/classes/session) | Session manager + handlers (`file`, `database`, `redis`, `memcached`). |

## Sessions

Supported handlers in 5.2 (one file per handler under [public/lib/classes/session/](https://github.com/moodle/moodle/tree/v5.2.0/public/lib/classes/session)):

| Handler | Class | When to pick |
|---|---|---|
| File | `\core\session\file` | Single-node only; file locking required |
| Database | `\core\session\database` | Default if no other configured. Adds load to the DB. |
| Redis | `\core\session\redis` | Recommended for clustered deployments. Supports cluster mode, TLS, igbinary serialization. |
| Memcached | `\core\session\memcached` | Legacy. Still supported for sessions even though memcached as a *cache store* was removed in 5.2. |

The session handler is selected by `$CFG->session_handler_class` in `config.php`. See [configuration.md](configuration.md) for the full set of session-related flags.
