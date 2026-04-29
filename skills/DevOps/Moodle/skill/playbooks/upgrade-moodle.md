# Playbook: Upgrade Moodle

Use this playbook whenever the tenant asks to upgrade Moodle to a newer version, or when diagnosing shows that `mdl_config(version)` is behind `public/version.php` (a pending migration).

## Preconditions

- [ ] Backup taken within the last 24 hours, **and verified restorable** (or running [scripts/backup.sh](../scripts/backup.sh) right now). DB-only is not enough — `<dataroot>` must be in the same backup. See [reference/backup-restore.md](../reference/backup-restore.md).
- [ ] Tenant has acknowledged the maintenance window. Upgrades block writes for the duration; schools usually do this overnight or on a weekend.
- [ ] Release notes read. [https://github.com/moodle/moodle/blob/v\<target\>/UPGRADING.md](https://github.com/moodle/moodle/blob/v5.2.0/UPGRADING.md). Look for the `Removed` and `Changed` sections under `### core` and any plugin you have installed. Any `requires` floor changes? Cache store removals? Auth changes?
- [ ] Source version satisfies the `requires` floor of the target. For 5.2: source must be **`>= 4.4`**. Check with:
      ```sql
      SELECT value FROM mdl_config WHERE name = 'version';
      ```
- [ ] PHP and DB versions on the target image satisfy the new minima — see [reference/changes-in-5.2.md](../reference/changes-in-5.2.md).
- [ ] No MUC mappings reference removed cache stores (memcached, mongodb in 5.2). See same file.

## Steps

### 1. Capture the pre-upgrade state

```bash
# 1a. Code version (what's on disk):
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo \"Code: \", \$CFG->version, PHP_EOL;"'

# 1b. DB version (what's been applied):
mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" "$MOODLE_DB_NAME" -sN \
    -e "SELECT CONCAT('DB: ', value) FROM mdl_config WHERE name='version';"
# Or for Postgres:
# PGPASSWORD="$MOODLE_DB_PASSWORD" psql -h "$MOODLE_DB_HOST" -U "$MOODLE_DB_USER" -d "$MOODLE_DB_NAME" \
#     -tAc "SELECT 'DB: ' || value FROM mdl_config WHERE name='version';"

# 1c. Row counts in the canaries — capture, you'll compare after:
mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" "$MOODLE_DB_NAME" -e "
  SELECT 'mdl_user' AS t, COUNT(*) FROM mdl_user
  UNION ALL SELECT 'mdl_course', COUNT(*) FROM mdl_course
  UNION ALL SELECT 'mdl_quiz_attempts', COUNT(*) FROM mdl_quiz_attempts
  UNION ALL SELECT 'mdl_assign_submission', COUNT(*) FROM mdl_assign_submission
  UNION ALL SELECT 'mdl_grade_grades', COUNT(*) FROM mdl_grade_grades
  UNION ALL SELECT 'mdl_files', COUNT(*) FROM mdl_files
  UNION ALL SELECT 'mdl_logstore_standard_log', COUNT(*) FROM mdl_logstore_standard_log;"
```

Write these numbers down — literally put them in chat. You'll compare after.

### 2. Take a verified backup

```bash
bash "$SKILL_DIR/scripts/backup.sh"
```

Confirm the backup file exists and its size is non-trivial (Moodle DB dumps for a real school are at least tens of MB; `<dataroot>/filedir` archives can be many GB). Do NOT proceed if backup is missing, zero bytes, or the table count looks too low.

### 3. Verify the upgrade is required (and what scope)

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --is-pending; echo "exit: $?"'
```

| Exit | Meaning |
|---|---|
| `0` | Nothing to upgrade — DB matches code. Stop, no upgrade needed. |
| `2` | Upgrade is pending — proceed to step 4. |

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --is-maintenance-required; echo "exit: $?"'
```

| Exit | Meaning |
|---|---|
| `2` | Maintenance mode is required (this is the normal case for a major upgrade). |
| `3` | Maintenance mode is NOT required (rare — a no-DDL plugin update). |

Tell the user the result before proceeding.

### 4. Disable cron during the window

If cron fires while the upgrader is mid-flight, you'll get a hung lock. Either pause the schedule (preferred) or:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --disable-wait=120'
```

This disables cron after waiting up to 120s for the current task to finish. Verify no cron is running:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --list'
```

Should report no running tasks.

### 5. Deploy the new code

This step is outside AI Studio — the tenant clicks "Update" in the Clouve marketplace UI, or Clouve ops triggers a redeploy with the new `MOODLE_VERSION` in the app's compose. Tell the user:

> Trigger the app update from the Clouve marketplace. The `moodle` container will be recreated with the new code; your data volumes (`moodledata`, the DB volume) are preserved.

Wait for the container to come back up. Confirm `curl -sI http://${MOODLE_HOST}/login/index.php` returns 200 (Moodle should be serving the "needs upgrade" page).

### 6. Run the upgrade

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --non-interactive'
```

The upgrader:
1. Enables CLI maintenance mode (`--maintenance` defaults to `true`).
2. Runs `db/upgrade.php` for core and every installed plugin.
3. Updates `mdl_config(version)` and per-plugin `mdl_config_plugins(*, name=version)`.
4. Disables maintenance mode.
5. Exits 0.

If it fails mid-flight: **stop**, look at the error message, and follow [rollback-from-backup.md](rollback-from-backup.md) unless you can clearly identify and fix the failing plugin. Do NOT re-run with `--allow-unstable` to "force through" — that flag relates to target maturity, not error suppression.

### 7. Purge caches

**Mandatory.** The upgrader's own warning says: *"Caches (except theme) will be STALE and MUST be purged after upgrading."*

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/purge_caches.php'
```

### 8. Re-enable cron

If you disabled it in step 4:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --enable'
```

Or unpause the external scheduler.

### 9. Verify post-upgrade

```bash
# 9a. Versions match — code and DB:
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo \"Code: \", \$CFG->version, PHP_EOL;"'
mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" "$MOODLE_DB_NAME" -sN \
    -e "SELECT CONCAT('DB: ', value) FROM mdl_config WHERE name='version';"
# Both should match the new release.

# 9b. Row counts compare to step 1c — none should have dropped:
mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" "$MOODLE_DB_NAME" -e "
  SELECT 'mdl_user' AS t, COUNT(*) FROM mdl_user
  UNION ALL SELECT 'mdl_course', COUNT(*) FROM mdl_course
  UNION ALL SELECT 'mdl_quiz_attempts', COUNT(*) FROM mdl_quiz_attempts
  UNION ALL SELECT 'mdl_assign_submission', COUNT(*) FROM mdl_assign_submission
  UNION ALL SELECT 'mdl_grade_grades', COUNT(*) FROM mdl_grade_grades
  UNION ALL SELECT 'mdl_files', COUNT(*) FROM mdl_files;"

# 9c. Health checks pass:
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/checks.php'
```

If 9a doesn't match: the upgrade didn't complete fully. Check `mdl_config_log` for the last upgrade run and re-run `admin/cli/upgrade.php`.

If 9b shows a count drop in a sacred table (`mdl_quiz_attempts`, `mdl_grade_grades`, `mdl_files`): **stop immediately** and surface to the user. This is the rollback case.

If 9c shows red items: investigate before letting users in.

### 10. Smoke-test as a real user

- Log in as the admin user.
- Open the home page; verify it renders without errors.
- Open one course (the one with the most activity).
- Open one quiz attempt screen (read-only — don't submit a fake attempt).
- Open one assignment grading screen.
- Check Site administration → Notifications for any red flags.

### 11. Tell the user

Report:
- Source → target version.
- Backup location.
- Cache purge confirmation.
- Row-count comparison: any deltas, expected or surprising.
- Any warnings from the checks dashboard.
- That cron is back on.

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| `requires` not satisfied (e.g. source 4.3, target 5.2) | Skipping versions | Upgrade to 4.4 (or 4.5/5.0/5.1) first, then to 5.2 |
| Plugin's `db/upgrade.php` errors | Plugin doesn't support the new version | Either fix the plugin, uninstall it via [admin/cli/uninstall_plugins.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/uninstall_plugins.php), or roll back |
| MUC error after upgrade ("unable to load store memcached") | 5.2 dropped these stores | Edit `<cachedir>/config.php` to remove the mapping; purge caches |
| Site loads but plugins missing settings UI | Stale MUC | `purge_caches.php` |
| Site loads but theme is broken | Stale theme cache | `purge_caches.php --theme` and hard-reload browser |
| `wwwroot` mismatch warnings | Underlying URL changed during deploy (HTTP→HTTPS, domain) | Update `wwwroot` env var, restart pod |
| `Database connection failed` post-upgrade | DB password env not picked up by new image | Check DB env vars are still injected; restart pod if `config.php` regen happens at boot |

## After-action

If you learned something Moodle-specific that future upgrade sessions will benefit from, capture it per [SKILL.md → Maintaining this skill](../SKILL.md#maintaining-this-skill). Especially worth capturing:

- A specific plugin that needed special handling.
- A row-count canary that turned out to be misleading.
- A specific DB engine quirk during the migration.
