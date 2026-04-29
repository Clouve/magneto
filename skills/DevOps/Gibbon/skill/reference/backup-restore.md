# Backup & Restore

## What a "complete" Gibbon backup contains

A complete backup for this app is **four things**. If any one is missing, the restore is incomplete.

1. **Database dump** — `mysqldump` of the `gibbon` schema.
2. **Uploads** — everything under `/var/www/html/uploads/` except `uploads/cache/`.
3. **`config.php`** — at `/var/www/html/config.php`. Tiny but irreplaceable: contains the tenant's `$guid`, without which old sessions and some internal references break.
4. **Custom assets** — `/var/www/html/customAssets/` if present (custom logos, theme overlays). Most tenants won't have this.

Not backed up:
- The pristine Gibbon package (`/clouve/gibbon/gibbon-$GIBBON_VERSION/`) — rebuilt from the image layer on every container start.
- `uploads/cache/` — wiped on every container start anyway.
- `/var/log/gibbon-cron.log`, `/var/log/gibbon-cron.state/` — operational diagnostics, not data.

## Volume layout in this app

Both volumes are sized per the app's `clv-docker-compose.yml`:

| Volume | Container path | What's on it | Size |
|---|---|---|---|
| `gibbondata` | `/var/www/html` | Web root: `config.php`, `uploads/`, `customAssets/`, `modules/`, the upgraded package contents | 10 GiB (default) |
| `dbdata` | `/var/lib/mysql` (on `gibbon-mysql`) | MySQL data files | 10 GiB (default) |

Backup of `gibbondata` captures items 2, 3, 4. Dump of the DB captures item 1.

## Backup procedure (what `scripts/backup.sh` does)

Run from the AI Studio container. Writes a timestamped tarball to `$HOME/backups/`.

```
timestamp=$(date +%Y-%m-%d-%H-%M-%S)
out="$HOME/backups/gibbon-$timestamp"
mkdir -p "$out"

# 1. DB dump
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysqldump \
  -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" \
  --single-transaction --quick --lock-tables=false \
  --default-character-set=utf8mb3 \
  "$GIBBON_DB_NAME" > "$out/gibbon.sql"

# 2/3/4. files over HTTP? No — we don't have a shell in the gibbon container from AI Studio.
# Use the Gibbon admin UI's "Backup" feature (if the tenant has it enabled) OR
# escalate to Clouve ops to snapshot the gibbondata volume.
```

**The gotcha:** from the AI Studio container, you can dump the DB (it's a network-reachable MySQL on port 3306) but you **cannot** tar `/var/www/html` — that path is on the `gibbon` container's volume, which AI Studio has no filesystem view of. You have three options:

1. **Ask the user / Clouve ops to snapshot the `gibbondata` volume** (the app's canonical disaster-recovery path).
2. **Use Gibbon's admin UI "System Backup" feature** if enabled in the tenant's install — it produces a zip you can download over HTTPS.
3. **SSH into the `gibbon` container** — requires `kubectl exec`, which is not available from AI Studio. **Do not fabricate** a procedure that assumes it is.

Tell the user which path you took and ask them to confirm.

## Restore procedure

### DB restore (what you can do from AI Studio)

```
# 1. Confirm gibbon-mysql is reachable and the target DB is empty or you're overwriting intentionally
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" \
  "$GIBBON_DB_NAME" -e "SHOW TABLES;" | wc -l

# 2. Drop and recreate the DB (requires root access — usually NOT available to the gibbon user)
# This is where it gets hard from AI Studio's side. In practice:
#   - For a partial restore (a single table), SOURCE the relevant section from the dump.
#   - For a full restore, the tenant should redeploy the app with a fresh dbdata volume and
#     run mysql < dump.sql as the first-boot step, OR escalate to Clouve ops.

# Partial-restore example (single table recovery — only with explicit user ack):
# Extract just that table's CREATE+INSERTs from the dump:
awk '/^-- Table structure for table `gibbonBehaviour`/,/^-- Table structure for table `/' dump.sql > one.sql
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" < one.sql
```

### Filesystem restore

Same constraint as above: you cannot write `/var/www/html` from AI Studio. Escalate to Clouve ops and have them:

1. Stop the app's `gibbon` container.
2. Restore `gibbondata` from volume snapshot (or replay a tar into a fresh volume).
3. Restart the `gibbon` container.
4. On boot, `entrypoint.sh` runs `update-config.sh`, which re-syncs `$DB_{HOST,NAME,USER,PASSWORD}` into `config.php`. If your restore brought in a stale `config.php` with the wrong creds, this fixes it.

## Verify a restore

After a restore, before you tell the user "you're good":

1. **Row counts match.** Pre-backup counts of `gibbonPerson`, `gibbonAttendanceLogPerson`, `gibbonMarkbookEntry`, `gibbonFinanceInvoice` should match post-restore counts (use `SELECT COUNT(*)`). If pre-backup counts aren't recorded, at least confirm counts are non-zero and plausible.
2. **`gibbonSetting(version) == version.php $version`.** If they diverge, run `update.php` or ask the user to.
3. **`absoluteURL` matches the tenant's current `$GIBBON_URL`.** Our `update-config.sh` should handle this on next restart; confirm.
4. **Admin login works.** Ask the user to log in. Don't touch the password yourself.
5. **HTTP 200 on `/index.php`** and the home page renders. `curl -sI https://$tenant/index.php`.
6. **Cron runs.** After a minute, `/var/log/gibbon-cron.log` should show a fresh tick (or idle ticks suppressed — check `service cron status`).

## How often should the tenant back up?

For a live school: daily at minimum, with retention. Weekly full + daily incremental is standard. This skill does not automate scheduling — that's a Clouve-platform concern. The skill's role is to make a backup on demand before any risky operation (upgrades, module installs, rollover, `ALTER TABLE`).

## What to tell the tenant

When you take a backup on their behalf, tell them:
- Where it is (`$HOME/backups/gibbon-<timestamp>/`).
- What's in it (DB dump only, from AI Studio → escalate for files, OR full via UI/ops).
- That AI Studio's `/home` volume survives pod restarts, so the backup persists, but it is not off-site.
- That for disaster recovery, they should periodically download the backup to their own laptop or cloud storage.
