# Troubleshooting — failure modes seen in the wild

Ordered by how often they actually occur. For each: symptoms, the first thing to check, and the fix.

## 1. Stale upload cache after an upgrade

**Symptoms.** After bumping the app's Gibbon version, a page renders with the old CSS/JS, or a TinyMCE editor stops saving, or a form shows fields from the previous version.

**First check.** Did anyone restart the `gibbon` container since the version bump? `entrypoint.sh` wipes `uploads/cache/` on every start. If the container wasn't restarted, the cache is stale.

**Fix.** Restart the pod (Clouve UI or `kubectl rollout restart`), or from the Gibbon UI go to **System Admin → Cache Manager → Clear Cache**.

## 2. `max_input_vars` exhausted during rollover or mass import

**Symptoms.** Rollover runs but some students' enrolments are missing. An import "succeeded" but skipped rows. Form saves only update half the fields.

**First check.** `SELECT COUNT(*) FROM gibbonPerson WHERE status='Full'` and compare to `max_input_vars` (shipped at 8000). Any form submission that has N×(fields per row) POST vars exceeding that silently truncates.

**Fix.** Temporarily bump `max_input_vars` via `.htaccess` at `/var/www/html/.htaccess`:
```
php_value max_input_vars 20000
```
The image already writes `php_value max_input_vars 8000` there — the user can raise it. No container restart required. Rerun the failed operation. **If rollover was partial, restore from backup first.**

## 3. Charset / collation mismatch — MariaDB instead of MySQL

**Symptoms.** Install fails with `Specified key was too long; max key length is 767 bytes` or similar. Foreign keys can't be added. `utf8mb4` tables refuse to be created with `utf8mb3` collation.

**First check.** `SELECT VERSION()` — is it MySQL 8.0.x or MariaDB? This app ships MySQL 8.0 via `gibbon-mysql`. If a tenant or ops swapped it for MariaDB, expect installation issues.

**Fix.** Use MySQL 8.0 (the app default). v30.0.01 specifically fixed `default collation in gibbon.sql causing installation issues for MariaDB systems`, but this app is tested on MySQL only. Do not advise a MariaDB swap.

## 4. `config.php` clobbered by the `update-config.sh` sed

**Symptoms.** After a container restart, `config.php` has `$databasePassword = '';` or a mangled value. Gibbon shows the DB-connection error page.

**First check.** Look at `$DB_PASSWORD`. Does it contain `/` or `&`? The image's `update-config.sh` escapes these before the sed, but earlier versions had a bug there. Double-check with the current script at [apps/gibbon/image/installer/update-config.sh](../../image/installer/update-config.sh).

**Fix.** If the password has unsafe characters and the escape is still broken, set `DB_PASSWORD` via a Kubernetes secret containing only alphanumerics + simple symbols. Tenant-editable passwords (e.g. from a rotated Clouve secret) should not contain `/`, `&`, `\`, or single-quote without escaping.

## 5. `gibbonSetting(version)` disagrees with `version.php`

**Symptoms.** Users get redirected to `/update.php` on every login. Admin UI shows `Update Required`. Cron scripts log SQL errors about missing columns.

**First check.** 
```sql
SELECT value FROM gibbonSetting WHERE scope='System' AND name='version';
```
Compare to the `$version` in `/var/www/html/version.php`. If file > DB, a migration is pending.

**Fix.** Visit `/update.php` as an admin. It runs `CHANGEDB.php` migrations between the DB version and the file version. If it fails partway, restore from backup and retry.

## 6. Cron is "running" but no emails go out

**Symptoms.** Teachers say they're not getting "you forgot to take attendance" emails. Parents say they're not getting weekly summaries. Library overdue notices silent.

**First check.** Three possible causes, in order:
1. **Mailer not configured.** `SELECT value FROM gibbonSetting WHERE scope='System' AND name='enableMailerSMTP'` — if `N`, Gibbon uses PHP's built-in `mail()`, which in a container usually does nothing. The fix is to configure SMTP in System Admin → Email.
2. **Cron not running.** Ask the user to `service cron status` in the `gibbon` container.
3. **The specific task's interval hasn't elapsed.** Check `ls -la /var/log/gibbon-cron.state/` — if `attendance_dailyIncompleteEmail.lastrun` is within the last 24h, it has run, and "no email" is a mailer issue, not a cron issue.

**Fix.** Depends on the cause. Mailer is 90% of these.

## 7. Partial install — Gibbon shows installer page

**Symptoms.** Browser lands on `/installer/install.php` even though the app has been running for days.

**First check.** `ls -la /var/www/html/config.php` — is it present, and non-empty? Any of the following breaks the install sentinel:
- `config.php` missing (never got written, or got deleted).
- `config.php` present but empty / zero bytes.
- `config.php` syntactically broken PHP (e.g. garbled by a bad sed).

**Fix.** If you have a backup of a valid `config.php`, restore it. If not: this is a fresh-install scenario — confirm with the user that there is no data to recover, then let the installer run again. **Do not let a tenant proceed past the installer without confirming the DB is empty** — running the installer over a populated DB will duplicate rows and corrupt state.

## 8. SSL / WebSocket issues (AI Studio side, but affects the app UX)

**Symptoms.** AI Studio's `/chat` terminal loads but stays blank. Browser console shows WebSocket connection refused. Repeated `/token` fetches with zero `/_clv/chat/ws` entries.

**First check.** See [CLAUDE.md](../../../CLAUDE.md) — "Self-signed TLS certificates break WebSocket" section. This is an ingress / cert-issuer config, not Gibbon.

**Fix.** Reconfigure the ClusterIssuer with real ACME (HTTP-01 or DNS-01). Not in scope for the Gibbon DevOps skill — raise this as a platform issue.

## 9. Module install left orphan tables

**Symptoms.** Tenant installed an Additional module, later uninstalled it, but tables the module created are still in the DB. Or: install errored halfway and left the DB in a half-installed state.

**First check.** List tables matching the module's naming convention: `SHOW TABLES LIKE 'gibbon<ModuleSlug>%'` or whatever the module used. Cross-reference with whatever `install.sql` / `uninstall.sql` the module ships.

**Fix.** If the module's `uninstall.sql` doesn't drop its own tables (a common oversight), the tables live on. Decide with the user whether to `DROP TABLE` them manually — a safe operation only if the module is truly gone and the tables contain data that only that module reads. **Always `SELECT COUNT(*)` and report the row count before dropping.**

## 10. Login redirect loop after public registration

**Symptoms.** Users registering via the public-registration flow end up redirected back to login without a session.

**First check.** v30.0.00 fixed this specifically (see CHANGELOG: `fixed login redirect after public registration`). If running on a version older than 30.0.00, upgrade. If on 30.0.00+, check for a misconfigured `absoluteURL` — a mismatch between the URL in `gibbonSetting.absoluteURL` and the URL the browser is hitting breaks session cookie scoping.

**Fix.** Ensure `gibbonSetting.absoluteURL` matches `$GIBBON_URL` in the container env. Our `update-config.sh` auto-syncs this on every restart; verify with:
```sql
SELECT value FROM gibbonSetting WHERE scope='System' AND name='absoluteURL';
```

## 11. Integration views stale (Moodle integration only)

**Symptoms.** Moodle's SSO login fails for Gibbon users. Course list in Moodle is last year's courses.

**First check.** `SELECT * FROM information_schema.VIEWS WHERE TABLE_SCHEMA='gibbon' AND TABLE_NAME IN ('moodleUser', 'moodleCourse', 'moodleEnrolment');`. If the views exist but reference the previous school year, they're stale.

**Fix.** The views are created once (sentinel: `clouve/installed/.moodle-integration-setup`). After a year rollover, refresh them: `CREATE OR REPLACE VIEW moodleCourse AS SELECT * FROM gibbonCourse WHERE gibbonSchoolYearID = (SELECT gibbonSchoolYearID FROM gibbonSchoolYear WHERE status='Current')`. Ask the user before replacing, and show the old vs. new definition.

## 12. "Cannot write to config.php" during install

**Symptoms.** Auto-install fails with `config.php could not be created`. `auto.php` exits with RecoverableException.

**First check.** Is `/var/www/html/` writable by `www-data`? `ls -la /var/www/html/ | head`. The image's `upgrade.sh` always does `chown www-data:www-data`, so this is usually a volume-permissions issue (the `gibbondata` volume was mounted with a mismatched UID).

**Fix.** Restart the container — `entrypoint.sh` will re-chown the volume on boot. If the issue persists, escalate: the volume driver or storage class has a bad default ownership and needs Clouve ops.
