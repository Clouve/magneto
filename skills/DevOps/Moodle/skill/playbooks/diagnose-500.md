# Playbook: Diagnose a 500

Use this playbook when the user reports the Moodle site is returning HTTP 500 (Internal Server Error). Don't run more than one diagnostic step at a time; stop when the answer is clear and tell the user before changing anything.

## Step 0: Confirm the symptom

```bash
curl -sI "http://${MOODLE_HOST}/login/index.php"
# HTTP/1.1 500 Internal Server Error  ← that's the symptom
# HTTP/1.1 503 Service Unavailable    ← maintenance mode is on (different problem; see step 1.5)
# HTTP/1.1 200 OK                     ← site is up. The user may be wrong, or the problem is partial.
```

If `200 OK`, ask the user for:
- The exact URL where they saw the 500.
- A screenshot or copy of the error page.
- Approximate time it happened.

A 500 on one URL with the rest of the site working is a different fact pattern from "every page is 500" and the diagnostic ladder is different.

## Step 1: Read the PHP error log

This is almost always where the answer is.

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo tail -100 /var/log/apache2/error.log'
```

The Moodle error pattern looks like:

```
PHP Fatal error:  Uncaught Error: Class "foo" not found in /var/www/html/public/local/mything/lib.php:42
```

or

```
PHP Fatal error:  Uncaught Exception: Database connection failed in /var/www/html/public/lib/setup.php:587
```

or

```
[Tue Apr 28 12:34:56.789] [proxy_fcgi:error] [...] AH01071: Got error 'PHP message: PHP Fatal error: ...'
```

Capture the **first** fatal in the burst (the rest are usually downstream of it). Match the file path and line number to the cause.

## Step 1.5: Maintenance mode?

If the response is 503 with a "Site is undergoing maintenance" page, that's **not** a 500 — it's `admin/cli/maintenance.php --enable` having been called.

```sql
SELECT value FROM mdl_config WHERE name='maintenance_enabled';
```

If `1`, either disable it (`admin/cli/maintenance.php --disable`) or finish the operation that put it on. Don't disable maintenance mode if an upgrade is mid-flight — see [upgrade-moodle.md](upgrade-moodle.md).

## Step 2: Map the fatal to a category

| Fatal pattern | Category |
|---|---|
| `Class "X" not found` | Plugin / autoloader. Step 3a. |
| `Database connection failed` / `Could not connect to db` | DB. Step 3b. |
| `Cannot create directory` / `Permission denied` writing to `/var/moodledata` | dataroot permissions. Step 3c. |
| `Allowed memory size exhausted` | PHP memory limit. Step 3d. |
| `Maximum execution time of N seconds exceeded` | PHP execution time. Step 3e. |
| `Cache store ... not loadable` / `Unknown class cachestore_X` | MUC. Step 3f. |
| `Session ... write failed` / `session_write_close failed` | Session backend. Step 3g. |
| `rootdirpublic` / "throw moodle_exception('rootdirpublic')" | Webserver pointed at `<dirroot>` instead of `<dirroot>/public`. Step 3h. |
| `version mismatch` / "needs upgrade" | Pending upgrade. See [upgrade-moodle.md](upgrade-moodle.md). |
| `parse error` / `unexpected token` | Bad PHP syntax in a recently-changed file. Step 3i. |

## Step 3a: "Class not found"

The plugin's autoloader can't find a class. Causes:

- Plugin partially uninstalled — files removed but `mdl_config_plugins` row remains.
- Class file deleted but cached MUC class map still references it.
- Plugin has a typo in `version.php` `$plugin->component`.

Fix:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/purge_caches.php'
```

If still broken, list what `mdl_config_plugins` thinks is installed and reconcile with what's on disk:

```sql
SELECT plugin FROM mdl_config_plugins WHERE name = 'version' ORDER BY plugin;
```

Compare to:
```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'ls /var/www/html/public/{mod,blocks,auth,enrol,local,theme,filter}/ | sort'
```

Anything in the DB but not on disk is an orphan. Either reinstall the missing plugin from a known source, or `admin/cli/uninstall_plugins.php --plugins=<frankenstyle> --run` (after backup).

## Step 3b: "Database connection failed"

Check connectivity:

```bash
mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" -e "SELECT 1"
# or
PGPASSWORD="$MOODLE_DB_PASSWORD" psql -h "$MOODLE_DB_HOST" -U "$MOODLE_DB_USER" -c "SELECT 1"
```

If that fails:
- Is the DB process up? `sshpass -e ssh clouve-ops@${MOODLE_DB_HOST} 'sudo systemctl status mariadb'` (or `postgresql`).
- Out of disk on the DB volume? `sshpass -e ssh clouve-ops@${MOODLE_DB_HOST} 'df -h'`.
- Did the DB credentials change? Check `mdl_config` won't help (it's in the DB you can't reach); check `<dirroot>/config.php` and the env vars on the moodle pod.

If `SELECT 1` succeeds but Moodle still says it can't connect:
- Permissions on `<dirroot>/config.php` (must be readable by `www-data`).
- The DB user lacks `CREATE`/`ALTER`/`DROP` (Moodle needs these for upgrade) — try `SHOW GRANTS FOR CURRENT_USER`.
- TLS misconfiguration: if `dboptions['ssl']` is set but the DB doesn't support it (or vice-versa).

## Step 3c: dataroot permissions

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo ls -la /var/moodledata | head'
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo -u www-data touch /var/moodledata/.test && sudo rm /var/moodledata/.test'
```

If touch fails:
```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} <<'EOF'
sudo chown -R www-data:www-data /var/moodledata
sudo find /var/moodledata -type d -exec chmod 0770 {} +
sudo find /var/moodledata -type f -exec chmod 0660 {} +
EOF
```

If the volume is full:
```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo du -sh /var/moodledata/*'
```

Usual culprits: `<dataroot>/temp/`, `<dataroot>/trashdir/`, `<dataroot>/backup_temp/`, automated backups in `<dataroot>/backup/`. The first two are safe to wipe; the third is safe to wipe between cron runs; the fourth is configurable retention.

## Step 3d: PHP memory exhausted

The fatal names a script. If it's a Moodle CLI script (cron, upgrade, backup), bump CLI memory:

```bash
php -d memory_limit=2G admin/cli/<script>.php
```

If it's a web request, the cause is usually:
- A user opened a course backup of an enormous course over HTTP (should be done via cron / queue).
- A custom report query returns too many rows.
- A plugin has a runaway loop.

Don't permanently bump `memory_limit` to 4G — fix the underlying cause.

## Step 3e: Execution time exceeded

Same drill — usually a slow query or runaway loop in a plugin. Find the script in the fatal, profile it, fix the cause. CLI scripts run unbounded (`max_execution_time = 0` for CLI by default); web requests are typically capped at 30–60 s.

## Step 3f: MUC errors

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo cat /var/moodledata/muc/config.php' | head -50
```

(Note: this is `<cachedir>/config.php`, NOT `<dirroot>/config.php` — different file, same name.)

If you see `cachestore_memcached` or `cachestore_mongodb` mappings on a 5.2 site, those stores are gone. Either:
1. Edit Moodle's MUC config in the admin UI: Site administration → Plugins → Caching → Configuration → remove the bad mapping, switch to `redis` or `file`.
2. Or fix it via the cache config file: edit `<cachedir>/config.php` to remove the bad blocks, then `purge_caches.php`.

## Step 3g: Session backend errors

Most commonly: `\core\session\redis` configured but Redis is unreachable.

```bash
redis-cli -h <redis-host> ping
```

If Redis is down, the immediate fix is to switch to the DB session handler:

```php
// In <dirroot>/config.php, comment the redis lines and add:
$CFG->session_handler_class = '\core\session\database';
```

Then restart Apache. Users will lose their sessions but the site stays up. Get Redis back, then switch back.

## Step 3h: rootdirpublic

The webserver `DocumentRoot` is pointed at `<dirroot>` instead of `<dirroot>/public/`. Fix the webserver config (Apache `DocumentRoot`, nginx `root`). Restart the webserver.

In the Magneto Moodle image, the `DocumentRoot` is baked in at image build. If it's wrong, the image needs a fix — open a Clouve ops ticket.

## Step 3i: Parse error

A PHP file has bad syntax. Almost always a recent change:

- A plugin was hand-edited.
- A `config.php` edit introduced a syntax error.
- A partial `cp` left a half-written file.

Find the file from the fatal, check `git log` if it's git-tracked, restore the previous version. If it's `<dirroot>/config.php` and a recent edit broke it, restore from the env-driven config regen on pod restart (the entrypoint rewrites `config.php` from env on every boot).

## Step 4: Tell the user

After fixing:

- What the cause was (in one sentence).
- What you changed to fix it.
- Whether anything else needs to happen (a deploy, a restart, an opscall, a backup verification).
- The size of any data loss, if applicable.

Don't say "fixed" if you only stopped the symptom — surface root cause and remediation distinctly.

## When the answer isn't in the error log

Rare, but possible. Things to try:

1. Check `<dataroot>/upgradelogs/` — if the issue happened during a recent upgrade, the upgrader's full output is here.
2. Check `mdl_config_log` — the most recent config change.
3. Check the audit log for unusual activity:
   ```sql
   SELECT FROM_UNIXTIME(timecreated), userid, action, target FROM mdl_logstore_standard_log
   ORDER BY timecreated DESC LIMIT 20;
   ```
4. Check `mdl_task_log` for recent failed tasks:
   ```sql
   SELECT FROM_UNIXTIME(timestart), classname, result, output FROM mdl_task_log
   WHERE result <> 0 ORDER BY timestart DESC LIMIT 10;
   ```

If after all this you still don't know, stop and surface to the user with what you've gathered. "I don't know" with full evidence is more useful than guessing.
