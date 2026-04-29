# Playbook: Diagnose a Gibbon 500

Use when the tenant reports "Gibbon is down" or "pages show an error." A 500 in Gibbon has a few distinct root-cause buckets; walk them in order of probability.

## Step 0 — confirm the symptom

```bash
curl -sI http://gibbon/index.php
# 200 — it's not actually down; the user is seeing a page-level error somewhere else
# 500 — genuine 5xx from Apache
# 502/503/504 — Apache/Gibbon container is not reachable (not a Gibbon issue — escalate)
# timeout / connection refused — network layer; check the pod is running
```

Ask the user for the **exact URL** that's broken and the **exact error text** they see. "It's broken" is not specific enough; "System Admin → Manage Users shows 500" is.

## Step 1 — is the container even running?

Have the tenant check the Clouve platform dashboard or pod-list. Is the `gibbon` container in `Running` state? Memory? CPU not throttled? If the pod restarted recently, `docker logs gibbon | head -200` will show the boot banner — check with ops.

## Step 2 — DB reachable?

```bash
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysqladmin -h "$GIBBON_DB_HOST" -u gibbon ping
# Expect: "mysqld is alive"
# If it fails: gibbon-mysql container is down, or DB_PASSWORD env is wrong.
```

If DB is down → escalate to ops. If creds are wrong → [rotate-admin-credentials.md](rotate-admin-credentials.md) path 2.

## Step 3 — version mismatch?

```bash
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -sN -e \
  "SELECT value FROM gibbonSetting WHERE scope='System' AND name='version';"
# Compare to the container's code version:
curl -sf http://gibbon/version.php 2>/dev/null || echo "version.php returned non-200"
# (Gibbon doesn't expose version.php over HTTP by default — you may need the tenant to share
#  the value from their System Admin → System Overview page.)
```

If the DB version is behind the code version, a migration is pending. Running some module pages against the wrong schema produces 500s. Follow [upgrade-gibbon.md step 4](upgrade-gibbon.md) — run `/update.php`.

## Step 4 — `config.php` intact?

You can't read `/var/www/html/config.php` from AI Studio. Indirect signal: if the login page renders but all post-login pages 500, `config.php` is usually fine (Gibbon got past the DB connect). If the login page itself 500s, `config.php` may be broken.

Ask the tenant or ops to verify:
- `config.php` is non-empty.
- `config.php` is syntactically valid PHP (`php -l /var/www/html/config.php`).
- `$databaseServer`, `$databaseName`, `$databaseUsername`, `$databasePassword` all non-empty.
- `$version` matches `version.php`.
- `$guid` is a 36-char string with dashes.

If `config.php` is broken → check if the most recent restart ran `update-config.sh` cleanly. The sed in that script can corrupt `config.php` if `$DB_PASSWORD` contains `/` or `&` (see [reference/troubleshooting.md#4](../reference/troubleshooting.md)). Restore `config.php` from backup.

## Step 5 — file permissions

If a specific page 500s with "permission denied" or "could not write to" in the error:

```bash
# Apache log has the actual error. AI Studio can't see it; ask the tenant or ops:
# docker exec gibbon tail -n 200 /var/log/apache2/error.log
```

Common: `/var/www/html/uploads/` or `/var/www/html/uploads/cache/` not writable by `www-data`. Fix with `chown -R www-data:www-data /var/www/html/uploads` (ops operation — not from AI Studio).

## Step 6 — bad module

A recently-installed or recently-upgraded module is a top suspect for 500s.

```bash
# Any module changes recently?
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e \
  "SELECT name, version, type, active FROM gibbonModule ORDER BY gibbonModuleID;"
# What's the page URL that 500s? What module does it belong to?
# The module can be found from the URL path: /modules/<ModuleName>/<file>.php.
```

If the 500 is isolated to one module:
- Disable it temporarily: `UPDATE gibbonModule SET active='N' WHERE name='<ModuleName>'` (require user ack).
- If it's an Additional module, uninstall it (see [install-module.md](install-module.md)) and restore from backup if its install corrupted state.
- If it's a Core module → do NOT disable; a Core-module 500 is a deeper issue (schema mismatch, usually from step 3).

## Step 7 — log table overflow or lock contention

Very busy schools can see `gibbonLog` grow to GB-scale and slow the whole app down. Check:

```bash
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
  SELECT COUNT(*) FROM gibbonLog;
  SELECT table_schema, table_name, ROUND(data_length/1024/1024, 2) AS size_mb
  FROM information_schema.tables
  WHERE table_schema='gibbon'
  ORDER BY data_length DESC LIMIT 10;"
```

If `gibbonLog` is dominant (> 1 GB), offer a prune:
```sql
-- Show first, prune after user ack
SELECT COUNT(*) FROM gibbonLog WHERE timestamp < NOW() - INTERVAL 1 YEAR;
-- Then with ack:
DELETE FROM gibbonLog WHERE timestamp < NOW() - INTERVAL 1 YEAR;
```

## Step 8 — uploads cache corruption

Twig compile errors manifest as 500 on the first page load after a code change, then resolve themselves. If the error text mentions `twig` or a template path, the cache is stale or corrupt.

From the Gibbon UI: **System Admin → Cache Manager → Clear Cache**.
Or restart the container — `entrypoint.sh` wipes `uploads/cache/` on every boot.

## If nothing above matches

1. Capture everything:
   - Exact URL, exact error, tenant's browser console + network tab if they can share.
   - `gibbonLog` entries in the last 10 minutes.
   - Output of all diagnostic queries above.
2. Ask the tenant or ops for the Apache error log from the `gibbon` container (we can't see it).
3. If it's reproducible after a restart and the tenant hasn't changed anything, file it upstream at `github.com/GibbonEdu/core/issues` with the stack trace.
4. Last resort: restore from backup to a known-good state, then observe whether the issue recurs.

## Do NOT

- Do NOT "fix" a 500 by disabling error reporting. Errors you hide still break things.
- Do NOT edit PHP files on the `gibbondata` volume speculatively — changes survive the restart but not the next app upgrade.
- Do NOT assume the issue is Gibbon's. 502/503/504 are ingress/pod issues; escalate to Clouve ops before spelunking in Gibbon.
