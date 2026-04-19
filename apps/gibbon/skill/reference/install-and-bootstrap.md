# Install & Bootstrap

## The two install paths

1. **Upstream web installer** — `installer/install.php`. Multi-step wizard: DB creds → create tables → create first admin → post-install settings. This is what you get on a Gibbon install done by hand on a bare LAMP server.
2. **Clouve auto-install** — [apps/gibbon/image/installer/auto.php](../../image/installer/auto.php). A CLI script that drives the same `Gibbon\Install\Installer` class non-interactively, reading env vars. This is the only path used by the app.

Both end in the same state: `config.php` written, schema loaded, first admin user created, post-install settings persisted to `gibbonSetting`.

## The container's first-boot flow

Source of truth: [apps/gibbon/image/installer/entrypoint.sh](../../image/installer/entrypoint.sh).

```
docker run
  └─ entrypoint.sh
     ├─ Set Apache LogLevel from $GIBBON_LOG_LEVEL
     ├─ Block on mysqladmin ping -h $DB_HOST
     ├─ If /var/www/html/clouve/installed/ does NOT exist:
     │    ├─ mkdir clouve/installed
     │    ├─ install.sh
     │    │    ├─ upgrade.sh  (cp -prf the pristine package to /var/www/html)
     │    │    └─ php auto.php  (run the headless installer)
     │    ├─ touch clouve/installed/$GIBBON_VERSION
     │    └─ If ENABLE_MOODLE_INTEGRATION=true: run GIBBON_INTEGRATION_SQL_*
     ├─ If clouve/installed/$GIBBON_VERSION does NOT exist (we're upgrading from an older version):
     │    ├─ upgrade.sh  (cp -prf the new package over the old files)
     │    └─ touch clouve/installed/$GIBBON_VERSION
     ├─ rm -rf /var/www/html/uploads/cache/*
     ├─ update-config.sh
     │    ├─ sed-patch config.php with $DB_{HOST,NAME,USER,PASSWORD}
     │    └─ UPDATE gibbonSetting SET value=$GIBBON_URL WHERE name='absoluteURL'
     ├─ Render /etc/cron.d/gibbon-cron from $GIBBON_CRON_INTERVAL
     ├─ service cron start
     └─ exec apache2-foreground
```

**Idempotency:** every phase is guarded. Re-running the container against an already-installed volume skips the initial install, skips the upgrade if version markers match, always clears the upload cache, always reapplies env-var-driven config, always restarts cron.

## What `auto.php` actually does

From [apps/gibbon/image/installer/auto.php](../../image/installer/auto.php), which is placed into `/var/www/html/installer/auto.php` and invoked with CWD set to that directory:

1. Loads `version.php`, fakes `$_SERVER['PHP_SELF']` and `$_SERVER['HTTP_HOST']` so the web-oriented installer code works in CLI.
2. Bootstraps `gibbon.php` (DI container).
3. Builds two data arrays from env vars:
   - `$data` — DB connection (`databaseServer`, `databaseName`, `databaseUsername`, `databasePassword`, `demoData`).
   - `$user_data` — first admin (title/firstName/surname/email/username/passwordNew) plus post-install settings (`absoluteURL`, `systemName`, `organisationName`, `organisationNameShort`, `installType="Production"`, `timezone`, `country`, `currency`, `statsCollection="N"`, `cuttingEdgeCode="No"`).
4. Calls the same `InstallController` / `Installer` the web UI uses:
   - `parseConfigSubmission` → `useConfigConnection` → `createConfigFile` → `install` (loads schema) → `createUser` → `setPersonAsStaff(1, 'Teaching')` → iterate post-install `setSetting` for each scope.
5. Emits plain text progress. Exits 0 on success. On settings failure prints `settings failed. Will trigger RecoverableException` but does not throw.

Because it reuses Gibbon's own installer classes, an `auto.php` install is **byte-identical** to a web install — same rows, same guid format, same `config.php` template.

## `config.php` — what's in it

Generated from `installer/config.twig.html` via the `Installer::createConfigFile` method. Contents (after install):

```php
<?php
$databaseServer = 'gibbon-mysql';
$databaseUsername = 'gibbon';
$databasePassword = '<secret>';
$databaseName = 'gibbon';
$guid = '<36-char guid>';  // Installer::randomGuid()
$caching = 10;             // default
$version = '30.0.01';
// plus optional extras: $cuttingEdgeCode, $statsCollection, $sessionHandler, etc.
```

**The `$guid` is the tenant's install identity.** Cookie names, session names, and various internal scopes are derived from it. Changing the `$guid` after install logs everyone out and orphans session state. Do not edit it.

**`$version` in `config.php` is NOT the authoritative "current schema version."** The authoritative one is `SELECT value FROM gibbonSetting WHERE scope='System' AND name='version'`. The `Updater` class compares the file's `$version` to the DB's `gibbonSetting.version` to decide whether `update.php` needs to run.

## Install sentinels (there are several — know which one to look at)

| Sentinel | Meaning |
|---|---|
| Presence of `/var/www/html/config.php` (non-empty) | Gibbon considers itself "installed." `Core::isInstalled()` checks this. Our cron wrapper (`gibbon-cron.sh`) uses it too. |
| `/var/www/html/clouve/installed/30.0.01` file | Clouve image's per-version marker. If present, skip install/upgrade on container start. |
| `/var/www/html/clouve/installed/.moodle-integration-setup` | Set once after `ENABLE_MOODLE_INTEGRATION=true` runs — prevents re-running integration SQL. |
| `gibbonSetting(scope='System', name='version').value == $version in version.php` | DB is on the same version as the code. If they drift, `update.php` believes an upgrade is required. |

If any of these disagree with each other, something went wrong in the boot flow. The fix depends on which disagree — see [troubleshooting.md](troubleshooting.md).

## Locale / timezone

Default locale is `en_US` (hard-coded in `auto.php`). Available locales live in the `gibboni18n` table; each has `installed` and `active` flags. Adding a new language = downloading a `.po` bundle (Gibbon has an in-UI "Manage Languages → Install" flow that fetches from the `i18n` service) and toggling the flag.

Timezone, country, and currency are post-install settings stored in `gibbonSetting` (scope `System`). Changing them after install does not touch any data — safe. Changing the timezone affects how cron jobs compute "today" for daily emails, so do it at a quiet hour.
