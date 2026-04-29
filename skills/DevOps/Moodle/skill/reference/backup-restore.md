# Backup & Restore

A Moodle "backup" is two coordinated artifacts: **the SQL dump and `<dataroot>` (specifically `filedir/`)**. Either one alone is unrecoverable — see the why-is-this-load-bearing in [file-storage.md](file-storage.md).

There are two scopes:

| Scope | What it covers | Tool | Format |
|---|---|---|---|
| **Course-level** | One course's content, activities, optionally user data | Moodle's backup API (UI or `admin/cli/backup.php`) | `.mbz` (Moodle backup zip) |
| **Site-level** | Everything: DB + `dataroot` | Operator: `pg_dump`/`mysqldump` + tar of `dataroot` | DB dump file + tarball |

Both are valid use cases. They serve different purposes:

- `.mbz` is for **moving content between sites** (e.g. exporting a course from staging to prod) and **course-level rollback** (restore a single course to a known state).
- Site-level backup is for **disaster recovery** (lost the cluster, restoring to a new one) and **before-upgrade rollback**.

## Course-level: `.mbz` backups

[admin/cli/backup.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/backup.php) and [admin/cli/restore_backup.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/restore_backup.php) drive the backup API from the CLI. The `.mbz` format is a zip with a manifest, course metadata, activity-by-activity dumps, and the files themselves embedded.

```bash
# Back up course id=42 to /tmp/course-42.mbz
sudo -u www-data php admin/cli/backup.php --courseid=42 --destination=/tmp/

# Restore from an .mbz into a target course (or a new course)
sudo -u www-data php admin/cli/restore_backup.php --file=/tmp/course-42.mbz --categoryid=2
```

The site has **automated course backups** scheduled via `admin/cli/automated_backups.php` (driven by the task scheduler). Configure under Site administration → Courses → Backups → Automated backup setup. By default disabled — turn it on after sizing the destination disk. Backups are stored where `backup_auto_destination` setting points (default: a subdir of `<dataroot>`).

**Operator note:** automated backups consume large amounts of `<dataroot>` if the site has heavy file content. Either point `backup_auto_destination` at object storage (via `tool_objectfs`) or set retention aggressively.

## Site-level: DB + `dataroot` snapshot

This is the "how do I rebuild everything from scratch" backup.

### Coordination

The DB and `<dataroot>` must be **logically consistent**. The safest sequence:

1. Enable maintenance mode (this stops new writes from users).
2. Wait for in-flight requests to drain (a few seconds).
3. Stop the cron runner (or wait for the current task to finish).
4. Take the DB dump.
5. Snapshot or tar `<dataroot>`.
6. Disable maintenance mode.
7. Resume cron.

```bash
# 1) Maintenance on
sudo -u www-data php admin/cli/maintenance.php --enable

# 2) Wait for cron — list any active tasks
sudo -u www-data php admin/cli/cron.php --list

# 3) DB dump (MariaDB / MySQL)
MYSQL_PWD="$MOODLE_DB_PASSWORD" mysqldump \
    -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" \
    --single-transaction --quick --lock-tables=false \
    --default-character-set=utf8mb4 \
    "$MOODLE_DB_NAME" \
    > moodle-$(date +%Y%m%d-%H%M%S).sql

# Or PostgreSQL
PGPASSWORD="$MOODLE_DB_PASSWORD" pg_dump \
    -h "$MOODLE_DB_HOST" -U "$MOODLE_DB_USER" \
    -F c -f moodle-$(date +%Y%m%d-%H%M%S).dump \
    "$MOODLE_DB_NAME"

# 4) dataroot tar — exclude scratch + cache + sessions; they regenerate
tar -C /var \
    --exclude='moodledata/temp/*' \
    --exclude='moodledata/cache/*' \
    --exclude='moodledata/localcache/*' \
    --exclude='moodledata/sessions/*' \
    --exclude='moodledata/trashdir/*' \
    --exclude='moodledata/muc/*' \
    -czf moodledata-$(date +%Y%m%d-%H%M%S).tar.gz \
    moodledata

# 5) Maintenance off
sudo -u www-data php admin/cli/maintenance.php --disable
```

The included paths under `<dataroot>` that **must** be backed up:

- `filedir/` — the actual user files
- `models/` — analytics models (if used)
- `lang/` — installed language packs (regenerable, but slow)
- `upgradelogs/` — historical record (small, optional)

Everything else (`temp`, `cache`, `localcache`, `sessions`, `trashdir`, `muc`) is regenerable and excludable. **`muc/` includes the cache configuration**, but Moodle reconstructs that on first request from `mdl_cache_*` tables — safe to drop.

### `--single-transaction` / `--quick`

For MariaDB / MySQL with InnoDB tables, `--single-transaction` gives a consistent snapshot without locking. `--quick` streams rows row-by-row instead of buffering the whole table — important for `mdl_files` (millions of rows) and `mdl_logstore_standard_log`.

For PostgreSQL `pg_dump` is consistent by design (single-transaction snapshot). Use the custom format (`-F c`) — it's compressed and supports parallel restore.

### Without maintenance mode (online backup)

If the operator *cannot* take a maintenance window:

- The DB dump can run online (InnoDB / Postgres MVCC).
- `<dataroot>/filedir/` can be tarred online — files are immutable once written (content-addressable), so a snapshot during writes only misses bytes that were being uploaded mid-snapshot.
- **The risk is desync:** a file may have been uploaded mid-snapshot, with the DB row in the dump but the bytes not yet in the tar. On restore, that one upload is missing.
- For most practical purposes the desync is small (one or two files per snapshot). For a high-stakes backup (pre-upgrade), take the maintenance window.

## Restore

### Course-level restore

```bash
sudo -u www-data php admin/cli/restore_backup.php --file=/path/course-42.mbz --categoryid=2
```

This creates a new course in category 2. To restore *into an existing course*, use the web UI (Site admin → Courses → Restore course) — the CLI doesn't support every restore option.

### Site-level restore

This is the **disaster-recovery** flow. New empty container, fresh DB, the backup artifacts in hand.

1. Bring up Moodle code at the **same version** as the backup. Confirm with `version.php` matching `mdl_config(version)` in the dump.
2. Restore the DB: `psql < moodle.dump.sql` or `pg_restore -d moodle moodle.dump`. Or `mysql moodle < moodle.sql`.
3. Restore `<dataroot>`:
   ```bash
   tar -C /var -xzf moodledata-...tar.gz
   chown -R www-data:www-data /var/moodledata
   ```
4. Boot the moodle container. Run `admin/cli/purge_caches.php` (the cache backing files in the snapshot may have been excluded; rebuild them).
5. Run `admin/cli/checks.php` — if anything is red, address it before letting users in.
6. Smoke-test: log in as admin, open a course, open one file, open one quiz attempt screen.

### Cross-version restore (DON'T)

If your code is **newer** than the backup, you'll need to upgrade after restore. Order: restore DB + dataroot at the *backup's* version, run `admin/cli/upgrade.php`, run `purge_caches.php`. Only do this when the backup version is reachable in the upgrade path (5.2 requires 4.4+).

If your code is **older** than the backup, **stop**. There is no downgrade path. Restore at the original version's image instead.

## Verifying a backup is restorable

The only true test is to restore it. Set up a smoke-test pipeline:

1. New empty DB, new empty `<dataroot>`.
2. Restore the artifacts.
3. Run `admin/cli/checks.php`.
4. Browse one course, one user, one file.

Anything less is hope-driven backups. The `scripts/backup.sh` wrapper records the backup's manifest (size, table count, file count) so you can at least notice a broken artifact before you need it.
