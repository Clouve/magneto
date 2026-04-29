# Configuration (`config.php`)

`<dirroot>/config.php` is the only file the operator edits routinely. It is **outside the webroot** and `chmod 0640 root:www-data` (web reads, only deploy user writes). The reference template is [config-dist.php](https://github.com/moodle/moodle/blob/v5.2.0/config-dist.php) — copy it to `config.php` and edit; do not edit the dist file in place.

`config.php` is plain PHP, so you can call `getenv()` and conditionals to drive it from environment variables. The Clouve image follows that pattern — see [apps/moodle/image/installer/](../../../../apps/moodle/image/) for how the entrypoint generates `config.php` from `MOODLE_*` env vars on first boot.

## Minimum viable config.php

```php
<?php
unset($CFG);
global $CFG;
$CFG = new stdClass();

// 1. Database (mariadb shown — Magneto default)
$CFG->dbtype    = getenv('MOODLE_DBTYPE')    ?: 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = getenv('MOODLE_DB_HOST');
$CFG->dbname    = getenv('MOODLE_DB_NAME');
$CFG->dbuser    = getenv('MOODLE_DB_USER');
$CFG->dbpass    = getenv('MOODLE_DB_PASSWORD');
$CFG->prefix    = 'mdl_';
$CFG->dboptions = [
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => '',
    'dbcollation' => 'utf8mb4_unicode_ci',
];

// 2. Site URL — must match how users reach Moodle (incl. scheme + path).
$CFG->wwwroot = getenv('MOODLE_URL') ?: 'http://localhost';

// 3. Data directory — outside the webroot, owned by the web user.
$CFG->dataroot  = getenv('MOODLE_DATAROOT') ?: '/var/moodledata';
$CFG->admin     = 'admin';
$CFG->directorypermissions = 02777;

require_once(__DIR__ . '/lib/setup.php');
```

The required minimum is `dbtype`, `dbhost`, `dbname`, `dbuser`, `dbpass`, `prefix`, `wwwroot`, `dataroot` — everything else has sensible defaults.

## Configuration surface (organized by purpose)

Citations point to line numbers in [config-dist.php](https://github.com/moodle/moodle/blob/v5.2.0/config-dist.php). Use these as the canonical reference; this table is a navigation aid.

### Database

| Setting | Default / Type | Purpose |
|---|---|---|
| `$CFG->dbtype` | `'mariadb' \| 'mysqli' \| 'auroramysql' \| 'pgsql' \| 'sqlsrv'` | Engine selector. Drives which `*_native_moodle_database.php` driver loads. |
| `$CFG->dblibrary` | `'native'` | Only value supported. |
| `$CFG->dbhost`, `dbname`, `dbuser`, `dbpass` | strings | Connection. |
| `$CFG->prefix` | `'mdl_'` | Table prefix. Cannot be empty for MSSQL. |
| `$CFG->dboptions['dbpersist']` | `false` | Persistent connections. Generally leave off. |
| `$CFG->dboptions['dbsocket']` | `false` or path | Use UNIX socket; set `dbhost = 'localhost'`. |
| `$CFG->dboptions['dbport']` | `''` or int | TCP port. |
| `$CFG->dboptions['dbcollation']` | `'utf8mb4_unicode_ci'` | MariaDB/MySQL only. Required for full UTF-8 (4-byte chars). |
| `$CFG->dboptions['dbschema']` | `''` | PostgreSQL schema selector. |
| `$CFG->dboptions['ssl']` | `'prefer' \| 'disable' \| 'require' \| 'verify-full'` | TLS mode. |
| `$CFG->dboptions['readonly']` | array | Read replica config — see [performance.md](performance.md). |
| `$CFG->dboptions['fetchbuffersize']` | `100000` (Postgres) | Set to `0` if behind pgbouncer transaction-mode. |
| `$CFG->dboptions['versionfromdb']` | `false` | MySQL/MariaDB on PaaS may need `true`. |

### Paths

| Setting | Default / Type | Purpose |
|---|---|---|
| `$CFG->wwwroot` | URL | The canonical site URL. **Must match exactly** (scheme + host + path) the URL users hit, including trailing-slash behaviour. Mismatch → broken AJAX, broken auth redirects. |
| `$CFG->dataroot` | path | `moodledata` location. MUST be outside `<dirroot>`. |
| `$CFG->dirroot` | derived | Set automatically by `lib/setup.php`. **Do not set manually** unless you know why. |
| `$CFG->tempdir` | `<dataroot>/temp` | Override only if you need different storage for temp files. Cluster nodes MAY share. |
| `$CFG->cachedir` | `<dataroot>/cache` | Cluster nodes **MUST** share. |
| `$CFG->localcachedir` | `<dataroot>/localcache` | Per-node fast cache. NOT shared across cluster — that's the point. |
| `$CFG->backuptempdir` | `<dataroot>/backup_temp` | Backup scratch space. Cluster MUST share. |
| `$CFG->localrequestdir` | `sys_get_temp_dir()` | Per-request local-only temp. |
| `$CFG->directorypermissions` | `02777` | Permissions for `dataroot` subdirectories. |
| `$CFG->filepermissions` | `0666` | Same, for files. |

### Reverse proxy / TLS termination

| Setting | When to set |
|---|---|
| `$CFG->wwwroot` starting with `https://` | Always when users reach the site over HTTPS. |
| `$CFG->sslproxy = true` | When TLS is terminated **upstream** (load balancer / nginx) and the connection between the LB and Apache is HTTP. Without this, Moodle assembles URLs as `http://` and breaks SSO redirects. (config-dist.php line ~426) |
| `$CFG->reverseproxy = true` | When proxied — Moodle trusts `X-Forwarded-For` for client IP. (line ~422) |

### Sessions

| Setting | Purpose |
|---|---|
| `$CFG->session_handler_class` | `\core\session\file \| database \| redis \| memcached`. Default is `database`. |
| `$CFG->session_redis_host` | Redis host (single) or comma-separated list (cluster mode). config-dist.php line ~368. |
| `$CFG->session_redis_port`, `_database`, `_auth`, `_prefix` | Standard Redis params. |
| `$CFG->session_redis_acquire_lock_timeout` | Default 120s. |
| `$CFG->session_redis_lock_expire` | Default = session timeout. |
| `$CFG->session_redis_connection_timeout` | Default 3.0s. **5.2:** now a separate value from `session_redis_read_timeout` (was unified pre-5.2). Both accept floats. |
| `$CFG->session_redis_read_timeout` | Default 3.0s. **New in 5.2.** |
| `$CFG->session_redis_serializer_use_igbinary` | Faster + smaller. Requires phpredis built with igbinary. Flushing required if you switch. |
| `$CFG->session_redis_compressor` | `'none' \| 'gzip' \| 'zstd'`. |
| `$CFG->session_redis_encrypt` | TLS context options array — `['cafile' => ...]` or `['verify_peer' => false, 'verify_peer_name' => false]`. |
| `$CFG->session_database_acquire_lock_timeout` | DB session handler lock timeout. |
| `$CFG->session_file_save_path` | File handler only. Default `<dataroot>/sessions/`. |
| `$CFG->session_memcached_save_path`, `_prefix`, `_acquire_lock_timeout`, `_lock_expire`, `_lock_retry_sleep` | Memcached session handler config. |

### Performance flags

| Setting | Default | Purpose |
|---|---|---|
| `$CFG->cachejs` | `true` (production) | Caches built JS bundles. **Set to `false` ONLY for theme/JS development**, never on a live site. |
| `$CFG->cachetemplates` | `true` | Mustache template caching. |
| `$CFG->langstringcache` | `true` | String cache. |
| `$CFG->themedesignermode` | `false` | **Theme designer mode** disables theme caching. **Catastrophic on production** — every page recompiles SCSS. |
| `$CFG->yuislasharguments` | `1` | URL form for YUI module loading. |
| `$CFG->slasharguments` | `1` | URL rewriting for file pluginfile.php. |
| `$CFG->dboptions['logslow']` | `0` | Threshold in milliseconds. >0 logs slow queries to `mdl_log_queries`. Useful for diagnosing one-off slow pages; do not leave on permanently. |

### Security

| Setting | When to set |
|---|---|
| `$CFG->cookiesecure` | `true` if `wwwroot` is `https://`. Otherwise the session cookie can leak to mixed-content requests. |
| `$CFG->cookiehttponly` | `true` always — prevents JS access to session cookies. |
| `$CFG->loginhttps` | Removed in 4.x. If you find it in older configs, drop it. |
| `$CFG->preventexecpath` | `true` to block admins from configuring filesystem paths via the UI (e.g. ClamAV path, `aspell` path). Forces those into `config.php`. **Recommended on for hardened deployments.** (config-dist.php line ~609) |
| `$CFG->disableupdatenotifications` | `true` for sites that update via packaging, not via the in-product update feature. |
| `$CFG->disableupdateautodeploy` | `true` to prevent the UI from initiating plugin installs. |
| `$CFG->siterolesinitialized` | leave alone — set by installer. |
| `$CFG->additionalhtmlhead` | string | inject CSP / X-Frame-Options / referrer policy. See [security.md](security.md). |
| `$CFG->passwordpolicy` | `true` | enforce minimum complexity. |
| `$CFG->maxbytes` | int (bytes) | site-wide upload cap; admin UI enforces but PHP `upload_max_filesize` and `post_max_size` are the real caps. |

### Cron and tasks

| Setting | Purpose |
|---|---|
| `$CFG->cron_enabled` | `1` (default) — set to `0` to disable cron site-wide (rare; usually you want it on). |
| `$CFG->cronclionly` | `true` recommended — disallows `/admin/cron.php` over HTTP. With CLI cron the only way to trigger is `php admin/cli/cron.php`. |
| `$CFG->cronremotepassword` | If web cron is enabled (`cronclionly = false`), this gates HTTP access. |
| `$CFG->task_logmode` | `0 = none, 1 = always, 2 = on fail`. Default `2`. Logs to `mdl_task_log`. |
| `$CFG->task_logtostdout` | `true` to mirror task output to STDOUT. Helpful in container logs. |
| `$CFG->showcrondebugging` | `true` to force DEBUG_DEVELOPER for cron output. |

### Email

| Setting | Purpose |
|---|---|
| `$CFG->smtphosts` | `mailhost:port` (or `smtps://...`). |
| `$CFG->smtpsecure` | `'' \| 'ssl' \| 'tls'`. |
| `$CFG->smtpauthtype` | `'LOGIN' \| 'PLAIN' \| 'NTLM' \| 'CRAM-MD5'`. |
| `$CFG->smtpuser`, `smtppass` | Auth creds. |
| `$CFG->noreplyaddress` | Sender for system mail. **Must** be a valid mailbox at the SMTP host's allowed-sender list, or mails are silently rejected. |
| `$CFG->divertallemailsto` | DEV ONLY. Catch-all sink — divert all outgoing mail to one address. Never on production. |

### File storage

| Setting | Purpose |
|---|---|
| `$CFG->alternative_file_system_class` | `'\local_myfs\file_system'` to swap out the local-filesystem backend. Used for S3 / MinIO / Azure Blob via plugins. The base class is `\core_files\file_system`. (config-dist.php line ~1198) |

### Locking

| Setting | Purpose |
|---|---|
| `$CFG->lock_factory` | `'\core\lock\file_lock_factory'` (default), `'\core\lock\db_record_lock_factory'`, `'\core\lock\mysql_lock_factory'`, `'\core\lock\postgres_lock_factory'`. Cron and task scheduler need a working factory; on a cluster choose one that works across nodes (db_record or DB-specific advisory locks). |
| `$CFG->file_lock_root` | Override path for file lock factory. Cluster: shared mount. |

### Debugging — never on production

| Setting | Purpose |
|---|---|
| `$CFG->debug` | `E_ALL` for `DEBUG_DEVELOPER`. **Production: `0` or unset.** |
| `$CFG->debugdisplay` | `1` exposes errors in the page. **Production: `0`.** |
| `$CFG->debugstringids` | `1` annotates language strings with their ID — useful for translation work. |
| `$CFG->perfdebug` | `15` shows page generation timing in the footer. |
| `$CFG->themedesignermode` | covered above; never on production. |
| `$CFG->cachejs = false`, `cachetemplates = false`, `langstringcache = false` | covered above; never on production. |

## The `getenv()` pattern (Clouve packaging)

A 12-factor `config.php` reads from environment variables and falls back to defaults so the same image works across environments. Pattern:

```php
$CFG->dbtype     = getenv('MOODLE_DBTYPE')   ?: 'mariadb';
$CFG->dbhost     = getenv('MOODLE_DB_HOST')  ?: 'localhost';
$CFG->dbname     = getenv('MOODLE_DB_NAME')  ?: 'moodle';
$CFG->dbuser     = getenv('MOODLE_DB_USER')  ?: 'moodle';
$CFG->dbpass     = getenv('MOODLE_DB_PASSWORD') ?: '';
$CFG->wwwroot    = getenv('MOODLE_URL')      ?: 'http://localhost';
$CFG->dataroot   = getenv('MOODLE_DATAROOT') ?: '/var/moodledata';

// Behind a TLS-terminating LB:
if (filter_var(getenv('MOODLE_SSL_PROXY') ?: 'false', FILTER_VALIDATE_BOOL)) {
    $CFG->sslproxy = true;
}

// Optional Redis session handler:
$redishost = getenv('MOODLE_REDIS_HOST');
if (!empty($redishost)) {
    $CFG->session_handler_class = '\core\session\redis';
    $CFG->session_redis_host = $redishost;
    $CFG->session_redis_port = (int)(getenv('MOODLE_REDIS_PORT') ?: 6379);
    $CFG->session_redis_acquire_lock_timeout = 120;
    $CFG->session_redis_lock_expire = 7200;
    $CFG->session_redis_connection_timeout = 3.0;
    $CFG->session_redis_read_timeout = 3.0;
}
```

Operator-rotated DB passwords come in via the env injection on pod restart — no `config.php` edit needed. **This is the preferred path for credential rotation** — see the corresponding gate in [SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow).

## Settings that live in the DB, not `config.php`

Most administrator-facing settings live in `mdl_config` (site scope) and `mdl_config_plugins` (plugin scope). The admin UI writes to those tables. `config.php` values **override** the DB values for the keys they set — sometimes useful for forcing a setting, but it makes the admin UI confusing because the form value and the effective value diverge.

To inspect a setting's effective value:

```bash
sudo -u www-data php admin/cli/cfg.php --name=lang
sudo -u www-data php admin/cli/cfg.php --component=auth_oauth2 --name=...
```

[admin/cli/cfg.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/cfg.php) is the right tool for poking config from the CLI — it respects the `config.php` overrides and writes through to the DB cache.
