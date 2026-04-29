# Playbook: Roll back from backup

Use this playbook when an upgrade or migration has put the site in a bad state, and the right move is to restore the pre-change state from backup. This is a destructive operation — every change since the backup is lost.

## Preconditions

- [ ] You have a backup that includes **both** the DB dump and `<dataroot>` (see [reference/backup-restore.md](../reference/backup-restore.md)). DB-only is not recoverable.
- [ ] The backup is **logically consistent** — taken with maintenance mode on, OR with `--single-transaction` for the DB and a clean tar of `<dataroot>/filedir/` (see backup-restore.md "Without maintenance mode" caveats).
- [ ] User has explicitly acknowledged the data loss window: every change since the backup is gone. Do NOT proceed without a `yes, I understand this is irreversible` ack.
- [ ] You know the **target Moodle version** the backup was taken at. Restoring data into a newer code version is fine ONLY if you then run `admin/cli/upgrade.php` to bring the schema up; restoring INTO an OLDER code version is not supported.

## Steps

### 1. Maintenance mode on

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/maintenance.php --enable'
```

### 2. Stop cron

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --disable-wait=120'
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --list'   # should show no running tasks
```

### 3. Capture the current (broken) state for forensics

Even though you're restoring, save what's there now — you may need it for diagnosis later, and "we kept the broken state for analysis" is the right answer if the user asks.

```bash
ts=$(date +%Y%m%d-%H%M%S)
out=/tmp/forensic-$ts
mkdir -p "$out"

# DB dump of the broken state
mysqldump -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" \
    --single-transaction --quick --lock-tables=false --default-character-set=utf8mb4 \
    "$MOODLE_DB_NAME" | gzip > "$out/db-broken.sql.gz"

# dataroot — DON'T tar it if it's huge; just record what's there
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo du -sh /var/moodledata/*' > "$out/dataroot-listing.txt"

# Last 200 lines of the PHP error log
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo tail -200 /var/log/apache2/error.log' > "$out/error.log"

ls -la "$out"
```

### 4. Restore the DB

This depends on the engine and the dump format.

#### MariaDB / MySQL (plain SQL dump from `mysqldump`)

```bash
# 4a. Drop existing tables (preserves the schema/database — Moodle owns the schema, not the DB).
mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" "$MOODLE_DB_NAME" -e "
SET FOREIGN_KEY_CHECKS = 0;
SET @tables = NULL;
SELECT GROUP_CONCAT('\`', table_name, '\`') INTO @tables
  FROM information_schema.tables WHERE table_schema = (SELECT DATABASE());
SET @tables = CONCAT('DROP TABLE IF EXISTS ', @tables);
PREPARE s FROM @tables; EXECUTE s; DEALLOCATE PREPARE s;
SET FOREIGN_KEY_CHECKS = 1;"

# 4b. Restore from dump.
mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" "$MOODLE_DB_NAME" < /path/to/backup.sql
```

Verify: `SELECT value FROM mdl_config WHERE name='version';` should match the backup's version.

#### PostgreSQL (custom format from `pg_dump -F c`)

```bash
# 4a. Drop and recreate the schema in one shot:
PGPASSWORD="$MOODLE_DB_PASSWORD" psql -h "$MOODLE_DB_HOST" -U "$MOODLE_DB_USER" -d "$MOODLE_DB_NAME" \
    -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# 4b. Restore:
PGPASSWORD="$MOODLE_DB_PASSWORD" pg_restore \
    -h "$MOODLE_DB_HOST" -U "$MOODLE_DB_USER" -d "$MOODLE_DB_NAME" \
    --no-owner --no-privileges \
    /path/to/backup.dump
```

### 5. Restore `<dataroot>`

```bash
# 5a. Move the broken dataroot aside (don't delete — forensics).
sshpass -e ssh clouve-ops@${MOODLE_HOST} <<'EOF'
ts=$(date +%Y%m%d-%H%M%S)
sudo mv /var/moodledata "/var/moodledata.broken-$ts"
sudo mkdir -p /var/moodledata
sudo chown www-data:www-data /var/moodledata
EOF

# 5b. Restore the tarball.
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    "sudo tar -C /var -xzf /tmp/moodledata-<timestamp>.tar.gz"

# 5c. Verify ownership.
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo ls -la /var/moodledata | head'
# Should show www-data:www-data on the immediate children.
```

If the tarball lives somewhere other than the moodle container's filesystem, scp it over first OR mount the backup volume read-only into the moodle container.

### 6. Reconcile code version with restored DB version

The restored DB has `mdl_config(version)` set to the value at backup time. The code on disk is what's running now. Two cases:

#### Case A: code version matches DB version

You restored to the same image you were on. Skip to step 7.

#### Case B: code version is NEWER than DB version

You restored, but the running container is at a newer image. You need to either:

1. **Run the upgrade now** — `admin/cli/upgrade.php --non-interactive`. The same upgrade that just failed will run again. **Only do this if you've identified and fixed the failure cause** (e.g. you uninstalled the plugin that was breaking it). Otherwise you're back to the same broken state.
2. **Roll back the image** — Clouve ops redeploys the previous image version. This is the safer answer when the failure cause is unclear.

#### Case C: code version is OLDER than DB version

You restored a backup taken on a newer Moodle into an older image. **Stop.** Moodle does not support downgrade. The site will refuse to bootstrap. Either fetch the matching newer image or restore an older backup.

### 7. Purge caches

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/purge_caches.php'
```

### 8. Run health checks

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/checks.php'
```

Anything red here is a problem. Address before letting users in.

### 9. Maintenance mode off

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/maintenance.php --disable'
```

### 10. Re-enable cron

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --enable'
```

### 11. Smoke-test

- Log in as the admin user.
- Open one course.
- Open one quiz attempt screen.
- Verify a recent file upload (within the backup window) is downloadable.
- Verify an event the user remembers seeing (a forum post, an assignment) is present.

### 12. Tell the user

Report:
- What was restored (DB + dataroot, from backup taken at `<timestamp>`).
- The data loss window: from backup time → now.
- The forensic snapshot location (`/tmp/forensic-...`).
- Specific things the user should re-do (any submissions, posts, grades they entered after the backup).
- Anything still red on the checks dashboard.

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| `mysql` errors during restore | Existing tables conflict; foreign keys | Step 4a is what fixes this — re-run if you skipped it |
| `pg_restore` errors with "owner does not exist" | Backup has owner info that doesn't apply to the destination DB | `--no-owner --no-privileges` — already in the command above |
| Restored site shows "needs upgrade" | DB version is older than code (Case B) | Run upgrade per step 6 |
| Restored site refuses to start with "version mismatch" | DB version is newer than code (Case C) | Use the matching code image |
| `<dataroot>` ownership wrong after restore | tar preserved different uid/gid | `chown -R www-data:www-data /var/moodledata` |
| Files in `mdl_files` reference hashes not in the dataroot tarball | Backup taken without maintenance mode, files uploaded mid-backup were missed | These files are now 404. Cannot recover; tell the user. |
| MUC errors on first request | `<cachedir>` was excluded from backup — fine; gets rebuilt | If errors persist, `purge_caches.php` |

## After-action

This is a high-impact event — capture what happened in [learnings.md](../learnings.md) per the protocol in [SKILL.md → Maintaining this skill](../SKILL.md#maintaining-this-skill). Especially:

- What the original failure was that triggered the rollback.
- Whether the rollback worked cleanly or required improv.
- The data loss window the user accepted.
