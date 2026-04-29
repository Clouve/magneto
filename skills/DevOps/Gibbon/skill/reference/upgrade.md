# Upgrade

## How Gibbon versions itself

Gibbon's "current version" is split across three sources that have to agree:

1. **Code version** — `$version` in `/var/www/html/version.php`. Set at build time; cannot change at runtime.
2. **Config file version** — `$version` in `/var/www/html/config.php`. Written when the installer creates the file; updated by `update.php` when it runs.
3. **DB version** — `SELECT value FROM gibbonSetting WHERE scope='System' AND name='version'`. Written by the installer; updated by the `Updater` class at end-of-migration.

All three should match. If code > config/DB, an upgrade is pending. Gibbon's `Updater::isUpdateRequired()` checks this.

## The two upgrade paths

1. **Upstream** — user uploads new files over the old ones and visits `/update.php`. That page includes `gibbon.php`, instantiates `Gibbon\Database\Updater`, calls `$updater->update()` which walks `CHANGEDB.php`, then clears `uploads/cache/` and `var/log/`.
2. **Clouve** — on container start, if `/var/www/html/clouve/installed/$GIBBON_VERSION` is absent but `config.php` exists, [upgrade.sh](../../image/installer/upgrade.sh) runs:
   ```
   cp -prf /clouve/gibbon/gibbon-$GIBBON_VERSION/* /var/www/html/
   cp -prf /clouve/gibbon/gibbon-$GIBBON_VERSION/.[a-zA-Z0-9]* /var/www/html/
   chown -R www-data:www-data /var/www/html
   chmod -R 755 /var/www/html
   ```
   That copies the new code over the old code **without touching `config.php`, `uploads/`, or any persisted state.** The `cp -prf` preserves the old config because the shipped Gibbon package's `config.php` slot is empty (Gibbon ships uninstalled).
   
   The container then hits `update.php` equivalents via the first user web request — **but our image does not run `update.php` itself from the CLI on upgrade.** Schema migrations run lazily when someone logs in and Gibbon notices the version mismatch, OR the admin visits `/update.php` directly. **This is a footgun**: if a tenant upgrades the app and nobody logs in for an hour, the DB schema is stale for that hour and any cron script that reads a new column fails. See [playbooks/upgrade-gibbon.md](../playbooks/upgrade-gibbon.md) for how to force the migration immediately.

## `CHANGEDB.php` — the migration file

Located at `/var/www/html/CHANGEDB.php` (also in the shipped package). Structure:

```php
$sql = array();
$count = 0;

//v20.0.00
++$count;
$sql[$count][0] = '20.0.00';
$sql[$count][1] = "
ALTER TABLE `gibbonDepartment` ADD `sequenceNumber` INT(4) UNSIGNED NULL AFTER `logo`;end
UPDATE `gibboni18n` SET `name` = '...' WHERE `code` = 'es_ES';end
...
";

//v21.0.00
++$count;
$sql[$count][0] = '21.0.00';
$sql[$count][1] = "
...
";
```

### The `;end` separator gotcha

**Statements are terminated by `;end`, NOT by plain `;`.** The comment at the top of the file warns: `//USE ;end TO SEPERATE SQL STATEMENTS. DON'T USE ;end IN ANY OTHER PLACES!`.

The `Updater` class splits the block on `;end`, then executes each chunk as one PDO call. Implications:

- You can have embedded `;` inside a single statement (e.g. inside a string literal) without breaking anything.
- A stray `;end` inside a string literal would split in the wrong place. Gibbon's own migrations avoid this, but if you are hand-writing a custom migration to patch a tenant's DB, don't put the literal string `;end` inside a `VALUES(...)`.
- Running these statements with `mysql` CLI directly does **not** work — CLI splits on `;`, so every chunk still has the stray `end` at the end. Always apply migrations through `update.php` or through the `Updater` class.

### What migrations actually contain

Mostly:
- `ALTER TABLE` — column adds, type widenings, index changes
- `INSERT INTO gibbonAction` / `gibbonPermission` — new module actions + default role permissions
- `INSERT INTO gibbonSetting` — new system settings with their default values
- `UPDATE gibbonSetting` / `UPDATE gibbonAction` — rename / re-categorize existing ones
- `CREATE TABLE` — new feature tables

**What they never do:** mass-delete user data, drop `gibbonPerson` rows, rewrite passwords, or touch finance/attendance history.

## Order of operations for a safe upgrade

1. **Take a full backup.** DB dump + `uploads/` tarball + `config.php` copy. See [backup-restore.md](backup-restore.md).
2. **Freeze writes.** Put Gibbon in maintenance or just do it at 3 AM. The `Updater` does not lock tables globally — concurrent writes during a migration can produce inconsistent state.
3. **Deploy new files.** In this app: bump `GIBBON_VERSION` in the app's compose, redeploy. Container restart runs `upgrade.sh` automatically.
4. **Run migrations.** Either hit `/update.php` manually as an admin (the page is idempotent once per version), or wait for the first login. **Prefer hitting `/update.php` manually** so you see the success/failure message.
5. **Verify.** `gibbonSetting(version) == version.php $version`. `SELECT COUNT(*) FROM gibbonPerson` equals pre-upgrade count. Login as admin. Spot-check a module page.
6. **Re-enable writes.** Unfreeze.

## Rollback

There is no upstream "downgrade" mechanism — `CHANGEDB.php` has no DOWN migrations. Rollback means **restore from backup**. This is why step 1 is non-negotiable.

Our container rolls back by:
1. Stopping the app.
2. Restoring the `gibbondata` and `dbdata` volumes from the pre-upgrade backup.
3. Pinning the app back to the previous `GIBBON_VERSION`.
4. Restarting.

You cannot "roll back in place" by copying the old files over the new ones — the DB schema is already mutated, and the code expects its matching schema. Always go through volume restore.

## Patch vs. minor vs. major

- **Patch** (e.g. `30.0.00 → 30.0.01`) — bug fixes only; `CHANGEDB.php` may or may not grow. Low risk.
- **Minor** (e.g. `29.0.00 → 30.0.00`) — new features, new tables, lots of new migrations. Moderate risk. Read the release notes; check for the `Changes With Important Notices` section, which is where the Gibbon team flags breakage-adjacent changes. v30.0.00 noted: `The Impersonate User action must be manually enabled in the config.php file` and `Added a Pastoral heading to the main menu and moved Behaviour, Attendance and Individual Needs`.
- **Major** (e.g. `24 → 25`) — breaking changes possible, PHP version bumps, occasional schema rewrites. Always read the full changelog. Plan maintenance window.

The skill-update strategy is tied to Gibbon's release cycle: every minor or major release triggers a skill re-research pass (re-clone to new tag, diff against prior skill). Patch releases only trigger a skill update if they touched upgrade/migration/module behaviour.
