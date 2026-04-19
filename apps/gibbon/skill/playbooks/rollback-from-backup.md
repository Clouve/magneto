# Playbook: Rollback from Backup

Use when an upgrade, migration, rollover, or risky operation has left the DB in a bad state and the right answer is "go back to the last good point."

There is no upstream Gibbon "downgrade" story (see [reference/upgrade.md](../reference/upgrade.md)). Rollback = restore from the backup taken before the risky operation.

## Preconditions

- [ ] You have a complete backup. See [reference/backup-restore.md](../reference/backup-restore.md) — DB dump + uploads tar + `config.php` + customAssets.
- [ ] The tenant has acknowledged that any work done since the backup will be lost.

## Decision: partial-restore or full-restore?

- **Partial restore** — a single table (e.g. just `gibbonBehaviour` because a mis-import went wrong). Do this from AI Studio if you can cleanly scope the rows. High risk of FK orphans if you pick wrong.
- **Full restore** — the whole DB and the whole `gibbondata` volume. Always-correct, but it's an ops operation (requires Clouve platform access to replace volumes or to run `mysql < dump.sql` against an empty DB).

When in doubt, full restore. The operational cost is small; the cost of a partial restore that introduces FK orphans is weeks of chasing ghost data.

## Full restore — steps

### 1. Capture the current-bad state (so you know what you're throwing away)

```bash
# Timestamp + DB snapshot of what you're about to overwrite.
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysqldump \
  -h "$GIBBON_DB_HOST" -u gibbon \
  --single-transaction --quick --lock-tables=false \
  --default-character-set=utf8mb3 \
  gibbon > "$HOME/backups/pre-restore-$(date +%Y-%m-%d-%H-%M-%S).sql"
```

### 2. Coordinate the file-volume restore with Clouve ops

AI Studio cannot write to the `gibbon` container's `/var/www/html` volume. Tell the tenant:

> To restore, the Clouve ops team needs to:
> 1. Stop the `gibbon` container in this app.
> 2. Restore the `gibbondata` volume from the snapshot taken at `<timestamp>`.
> 3. Start the container back up.
> 
> While you're waiting, I'll restore the database from the SQL dump I have.

### 3. Restore the DB

```bash
# Wipe the existing tables. The gibbon user usually can DROP tables in its own DB.
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e \
  "SET FOREIGN_KEY_CHECKS=0;" \
  -e "$(MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -sN -e \
        "SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema='gibbon';" | tr '\n' ' ')"

# Apply the dump.
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql \
  -h "$GIBBON_DB_HOST" -u gibbon \
  --default-character-set=utf8mb3 \
  gibbon < "$HOME/backups/gibbon-<timestamp>/gibbon.sql"
```

**Safety:** before running the drop-and-replace, confirm with the user by showing them the dump file size and date, and the number of tables about to be dropped.

### 4. Force the container to re-sync

After the `gibbon` container restarts (post file-volume restore), `entrypoint.sh` will:
- Find `config.php` present → skip install.
- Find `clouve/installed/<version>` → skip upgrade.
- Wipe `uploads/cache/`.
- Run `update-config.sh` → re-sync `$DB_*` into `config.php` and `$GIBBON_URL` into `gibbonSetting.absoluteURL`.
- Render `/etc/cron.d/gibbon-cron` from current `$GIBBON_CRON_INTERVAL` and start cron.

Nothing to do from your side — just verify after.

### 5. Verify the restore

Follow [reference/backup-restore.md#verify-a-restore](../reference/backup-restore.md). At minimum:
- `gibbonSetting(version) == /var/www/html/version.php $version`.
- Row counts match pre-backup expectations.
- Admin login works (ask the user).
- Home page renders.
- Cron logs show fresh ticks after a minute or two.

## Partial restore — when and how

Appropriate when:
- A single table was corrupted by a bad import / bad SQL.
- You can name the exact tables and confirm no FKs point into them from other tables you're keeping.
- The user accepts they may end up with orphan rows if you got the scoping wrong.

### Extract one table from the dump

```bash
# Pulls everything from one table's CREATE to the next table's CREATE.
TABLE=gibbonBehaviour
awk "/^-- Table structure for table \`${TABLE}\`/,/^-- Table structure for table \`/" \
  "$HOME/backups/gibbon-<timestamp>/gibbon.sql" > "/tmp/${TABLE}.sql"

# Sanity-check: the file should contain exactly one CREATE TABLE.
grep -c '^CREATE TABLE' "/tmp/${TABLE}.sql"   # expect 2 (this table + the start of the next)
```

### Apply with FK checks off

```bash
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon <<EOF
SET FOREIGN_KEY_CHECKS=0;
DROP TABLE IF EXISTS \`${TABLE}\`;
SOURCE /tmp/${TABLE}.sql;
SET FOREIGN_KEY_CHECKS=1;
EOF
```

### Verify no orphans

For the partially-restored table, check every FK column matches live rows in the target:

```sql
-- Example for gibbonBehaviour.gibbonPersonID
SELECT COUNT(*) FROM gibbonBehaviour b
LEFT JOIN gibbonPerson p ON b.gibbonPersonID = p.gibbonPersonID
WHERE p.gibbonPersonID IS NULL;
-- Expect 0.
```

If orphans exist, you either need to also restore the parent tables or accept the orphans and manually clean them up.

## Do NOT

- Do NOT try to "reverse-apply" `CHANGEDB.php` migrations. No DOWN migrations exist.
- Do NOT manually rewrite `config.php $version` to match an older schema — the mismatch will be detected and corrupted migrations may re-run.
- Do NOT delete `dbdata` volume contents thinking "I'll just re-run the installer" — you'll lose the tenant's data entirely. The installer is for empty schemas only.
- Do NOT pick a partial restore because it "seems faster." The safe default is a full restore when anything feels uncertain.
