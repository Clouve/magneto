# Troubleshooting

Failure modes seen in the wild and the **first** thing to check for each. Stop after one diagnostic step — if the answer isn't obvious, escalate the diagnosis flow rather than running 5 tools at once.

## "The site is down / 500 on every page"

Order of likelihood:

1. **PHP error log first.** `tail -100 /var/log/apache2/error.log`. The fatal will name a file and a line. Most production 500s map to:
   - Recent code change with a syntax error → revert the deploy.
   - DB connection error → check the DB process, network, credentials.
   - File-permission error → `<dataroot>` not writable by `www-data`.
   - Plugin throwing an uncaught exception during boot → the plugin's `lib.php` or `version.php` is broken.

2. **Maintenance mode unexpectedly on?**
   ```sql
   SELECT value FROM mdl_config WHERE name = 'maintenance_enabled';
   ```
   Or `<dataroot>/climaintenance.html` exists. If so, `admin/cli/maintenance.php --disable`.

3. **DB up?**
   ```bash
   PGPASSWORD="$MOODLE_DB_PASSWORD" psql -h "$MOODLE_DB_HOST" -U "$MOODLE_DB_USER" -c "SELECT 1"
   # or
   mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" -e "SELECT 1"
   ```

4. **`<dataroot>` writable?** `sudo -u www-data touch <dataroot>/.test && rm <dataroot>/.test`. Common after a volume remount or chown gone wrong.

5. **Disk full?** `df -h` on the moodle container and the dataroot volume.

6. **Pending upgrade?**
   ```bash
   sudo -u www-data php admin/cli/upgrade.php --is-pending
   echo $?   # 2 = pending
   ```
   If pending, the site refuses normal access — the symptom is "needs upgrade" page, not 500. But: if the upgrade was started and crashed, you may be in a partial state. See [upgrade.md](upgrade.md).

## "I see 'rootdirpublic' error" / "Throw moodle_exception"

The webserver `DocumentRoot` is pointed at `<dirroot>` instead of `<dirroot>/public`. The root `index.php` is a [tripwire](https://github.com/moodle/moodle/blob/v5.2.0/index.php) that throws this exception specifically to catch this misconfiguration. Fix the webserver config.

## "Some pages work, others 404"

| Pattern | Likely cause |
|---|---|
| Static assets (CSS, JS, images) 404 | `slasharguments` mismatch — Moodle generates `/file.php/path/to/asset.png` URLs and the webserver isn't passing the path correctly. Check `AcceptPathInfo` (Apache) or fastcgi_split_path_info (nginx). |
| Some plugins' admin pages 404 | MUC stale routes — `php admin/cli/purge_caches.php`. |
| `pluginfile.php` returns 404 for files that exist | `<dataroot>/filedir` permissions, or `slasharguments` again. |
| Random 404s after deploy | OPcache holding stale filename map — restart Apache / FPM. |

## "Login works, then immediately logs out"

The session isn't persisting. Causes:

- **`cookiesecure = true` but request is HTTP**: browser refuses to send cookie. Either flip to HTTPS or set `cookiesecure = false`.
- **`wwwroot` mismatches the URL the user actually visits**: cookie domain doesn't match. Check `wwwroot` matches scheme + host + path the user types.
- **Session backend down**: `\core\session\redis` configured but Redis unreachable. Check Redis. Falling back to DB sessions (set `session_handler_class = '\core\session\database'`) is a good emergency move.
- **Two-pod cluster without shared session store**: each pod has its own session — user's first request sets a session on pod A, second goes to pod B which doesn't know them. Move sessions to Redis or DB.
- **Browser has stale cookie**: ask user to clear cookies for the site and try again.

## "Stale strings everywhere" / "An old plugin name is still showing"

Cache. `php admin/cli/purge_caches.php`. After install/uninstall, after upgrade, after `config.php` edit, after theme change. See [caching.md](caching.md).

## "Cron isn't running"

```sql
SELECT FROM_UNIXTIME(MAX(timestart)) FROM mdl_task_log;
```

If that's old:

1. **Is cron disabled?** `mdl_config WHERE name='cron_enabled'` (1 = on).
2. **Is the cron process actually running on the host?**
   - SSH to the moodle container: `SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${MOODLE_HOST}`
   - `ps aux | grep cron.php`
   - `cat /etc/cron.d/moodle` or check k8s `CronJob`.
3. **Is the cron process running but stuck?**
   ```bash
   sudo -u www-data php admin/cli/cron.php --list
   ```
4. **Is a task `disabled` or has a huge `faildelay`?**
   ```sql
   SELECT classname, lastruntime, nextruntime, disabled, faildelay
   FROM mdl_task_scheduled
   WHERE disabled = 1 OR faildelay > 0
   ORDER BY faildelay DESC;
   ```
5. **Does `admin/cli/cron.php` run cleanly when invoked manually?**
   ```bash
   sudo -u www-data php admin/cli/cron.php
   ```
   Watch the output for the failing task.

## "Quiz attempts disappeared / gradebook is wrong"

Stop. **Don't run any SQL.** Take a forensic backup. The fact pattern matters:

- The user may be looking at a different course / activity than they think.
- Capability changes can hide attempts that still exist (the user's role no longer has permission to see them).
- A grade override might have been applied through the UI — check the grade history.

```sql
-- Are the attempts in the DB?
SELECT id, userid, attempt, state, timestart, timefinish
FROM mdl_quiz_attempts
WHERE quiz = <quizid> AND userid = <userid>;
```

If they're there but invisible, the issue is permissions or visibility — NOT data loss. If they're not there, the next question is "when were they last seen?" and that goes via the audit log.

```sql
SELECT FROM_UNIXTIME(timecreated), eventname, contextid, objectid
FROM mdl_logstore_standard_log
WHERE eventname LIKE '%quiz%' AND objectid = <attempt_id>
ORDER BY timecreated DESC;
```

## "The upgrade failed mid-flight"

The site is in maintenance mode. Schema is partially upgraded. There are two paths:

1. **Diagnose and re-run.** The error message usually names the failing plugin and migration version. If you can fix the plugin (write the missing migration) or uninstall it (`admin/cli/uninstall_plugins.php`), re-run `admin/cli/upgrade.php --non-interactive`.
2. **Restore from backup.** The safer path. See [playbooks/rollback-from-backup.md](../playbooks/rollback-from-backup.md).

Never run `admin/cli/upgrade.php --allow-unstable` to "force through" a failed upgrade — `--allow-unstable` only relates to the maturity of the *target* version, not to ignoring errors.

## "File uploads succeed but downloads return 0 bytes"

Permissions: `www-data` can write to `<dataroot>/filedir/` but can't read what it just wrote. Usually `<dataroot>/filedir/<2hex>/<2hex>/<hash>` ended up `0600 root:root` because cron ran as root once. Fix:

```bash
chown -R www-data:www-data <dataroot>
find <dataroot> -type d -exec chmod 0770 {} +
find <dataroot> -type f -exec chmod 0660 {} +
```

## "MUC error: Unable to load store memcached"

The site was upgraded from a pre-5.2 version that had `cachestore_memcached` mapped. 5.2 removed the store. Either:

1. Site administration → Plugins → Caching → Configuration → remove the memcached mapping; switch to Redis or file.
2. From CLI: edit `<cachedir>/config.php` (NOT `<dirroot>/config.php`) and remove the memcached blocks; then `php admin/cli/purge_caches.php`.

## "Plugin install fails with 'database schema is incompatible'"

The plugin's `db/install.xml` declares a column the existing schema doesn't have, or the plugin is for a different Moodle major version. Before forcing it:

```bash
php admin/cli/check_database_schema.php
```

[admin/cli/check_database_schema.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/check_database_schema.php) reports schema drift between the install.xml definitions and the live DB. If everything is clean and the install still fails, the plugin doesn't support 5.2 — check its `version.php` `$plugin->requires` value.

## "Email isn't sending"

1. **`$CFG->divertallemailsto` set?** This is a dev-only sink. Check `mdl_config WHERE name='divertallemailsto'` AND the value of `$CFG->divertallemailsto` in `config.php`.
2. **`$CFG->noemailever`?** Same — set on dev sites.
3. **Test SMTP from CLI:**
   ```bash
   sudo -u www-data php admin/cli/emailstop.php   # only if you suspect the queue is wedged
   ```
   Or send a test email from Site administration → Server → Email → Test outgoing mail configuration.
4. **SMTP settings:** `mdl_config` keys `smtphosts`, `smtpsecure`, `smtpuser`, `noreplyaddress`. If `smtphosts` is empty, Moodle uses PHP `mail()` — which on most container images doesn't have a working sendmail.
5. **Cron firing?** Email sending is queued; if cron isn't running, queued mail piles up. See "Cron isn't running" above.

## "Theme looks broken" / "CSS missing"

| Step | What |
|---|---|
| 1 | Hard-reload the browser (cache busting). |
| 2 | `php admin/cli/purge_caches.php --theme`. |
| 3 | Look at browser devtools network tab — is the CSS URL returning 200 or 404? |
| 4 | If 404 with path `theme/styles.php/...`, suspect `slasharguments` (see "Some pages work, others 404"). |
| 5 | If 200 but wrong content, suspect themedesignermode being inadvertently on. Check `mdl_config WHERE name='themedesignermode'`. |

## "AI Studio can't reach the moodle container"

Out of skill scope — that's a Clouve platform / pod networking issue, not a Moodle issue. Confirm with `curl -v http://${MOODLE_HOST}/` from AI Studio. If 0 bytes / connection refused / DNS fail, it's not Moodle.

## When to escalate to Clouve ops

- Anything that requires changing the pod definition (storage class, resource limits, env injection, ingress).
- Anything that requires a CVE-driven image rebuild.
- Anything where the diagnosis points outside the moodle / moodle-mysql containers (cluster networking, ingress, cert-manager, namespace policies).
- Any data loss scenario where a forensic snapshot is needed of state outside `<dataroot>` and the DB.

Surface enough detail in chat that the user can paste it into a support ticket — version, release, error message, last 50 lines of the PHP error log, the scope of users affected. Do NOT paste secrets (DB password, Anthropic key, user emails).
