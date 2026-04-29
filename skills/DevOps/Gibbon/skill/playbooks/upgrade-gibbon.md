# Playbook: Upgrade Gibbon

Use this playbook whenever the tenant asks to upgrade Gibbon to a newer version, or when diagnosing shows that `gibbonSetting(version)` is behind `/var/www/html/version.php` (a pending migration).

## Preconditions

- [ ] Backup taken within the last 24 hours (verify, do not trust a timestamp alone). Run [scripts/backup.sh](../scripts/backup.sh) if unsure.
- [ ] Tenant has acknowledged the maintenance window. Upgrades block writes for the duration; schools usually do this overnight or on a weekend.
- [ ] Release notes read. `https://github.com/GibbonEdu/core/releases/tag/v<target-version>` — look at the `Changes With Important Notices` section. Any flag changes in `config.php`? Any module relocations? Any deprecations?
- [ ] Target version is reachable from the app. The app is pinned to `GIBBON_VERSION` in its compose; tenant upgrades via the Clouve marketplace "update available" flow (opt-in per §5 decision 5 of the spec).

## Steps

### 1. Capture the pre-upgrade state

```bash
# Record current versions.
echo "Code version: $(curl -sf http://gibbon/version.php 2>/dev/null | grep -oP "version = '\K[^']+" || echo 'unknown-no-cli-access')"
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -sN -e \
  "SELECT CONCAT('DB version: ', value) FROM gibbonSetting WHERE scope='System' AND name='version';"

# Record row counts for the tables we care about post-upgrade.
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
  SELECT 'gibbonPerson' AS t, COUNT(*) FROM gibbonPerson
  UNION ALL SELECT 'gibbonStudentEnrolment', COUNT(*) FROM gibbonStudentEnrolment
  UNION ALL SELECT 'gibbonMarkbookEntry', COUNT(*) FROM gibbonMarkbookEntry
  UNION ALL SELECT 'gibbonAttendanceLogPerson', COUNT(*) FROM gibbonAttendanceLogPerson
  UNION ALL SELECT 'gibbonFinanceInvoice', COUNT(*) FROM gibbonFinanceInvoice;"
```

Write these numbers down — literally put them in chat. You'll compare after.

### 2. Take a verified backup

```bash
bash "$SKILL_DIR/scripts/backup.sh"
```

Confirm the backup file exists and its size is non-trivial (a gibbon DB dump should be at least a few MB for any real school). Do NOT proceed if backup is missing or zero bytes.

### 3. Deploy the new app version

This step is outside AI Studio — the tenant clicks "Update" in the Clouve marketplace UI, or Clouve ops triggers a redeploy with the new `GIBBON_VERSION` in the app's compose. Tell the user:

> Trigger the app update from the Clouve marketplace. The `gibbon` container will be recreated with the new code; your data volumes (`gibbondata`, `dbdata`) are preserved.

Wait for the container to come back up. Confirm `curl -sI http://gibbon/index.php` returns 200.

### 4. Force-run the schema migration

The image's `upgrade.sh` copies new files but does NOT run `CHANGEDB.php` migrations. Those run lazily when someone visits `/update.php`. Do this explicitly:

```bash
# Curl /update.php as an admin via form-login OR ask the admin user to visit it in their browser.
# Since we don't have the admin credentials (they are tenant-owned), the cleaner path is:
#   Tell the tenant: "Please open https://<your-gibbon-url>/update.php in your browser now
#   while signed in as an admin. It should show a green success message; paste the full
#   page text back to me so I can verify."
```

Do not attempt to automate the form login — we don't have the tenant's admin creds, and we shouldn't.

### 5. Verify post-upgrade

```bash
# 1. Versions match.
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -sN -e \
  "SELECT value FROM gibbonSetting WHERE scope='System' AND name='version';"
# This should equal the new GIBBON_VERSION.

# 2. Row counts match. Compare to the pre-upgrade numbers.
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
  SELECT 'gibbonPerson' AS t, COUNT(*) FROM gibbonPerson
  UNION ALL SELECT 'gibbonStudentEnrolment', COUNT(*) FROM gibbonStudentEnrolment
  UNION ALL SELECT 'gibbonMarkbookEntry', COUNT(*) FROM gibbonMarkbookEntry
  UNION ALL SELECT 'gibbonAttendanceLogPerson', COUNT(*) FROM gibbonAttendanceLogPerson
  UNION ALL SELECT 'gibbonFinanceInvoice', COUNT(*) FROM gibbonFinanceInvoice;"
# None of these should have dropped.

# 3. No PHP fatal in the tenant's report.
# Ask them to confirm they can log in, see the dashboard, and click through one page per module they use.

# 4. Run the health script.
bash "$SKILL_DIR/scripts/verify-health.sh"
```

### 6. Communicate success

Tell the tenant, in one message:
- Old version → new version.
- Backup location.
- Row counts preserved.
- Any deprecation notices from the release notes that affect their workflow.
- A short "if something breaks in the next 24h, here's how to roll back" pointer to [rollback-from-backup.md](rollback-from-backup.md).

## If the migration fails

Stop. Do not retry.

1. Capture the error from `/update.php` (ask the user to paste it in full).
2. Capture the current state of `gibbonSetting(version)` and a list of tables: `SHOW TABLES LIKE 'gibbon%'`.
3. Roll back — see [rollback-from-backup.md](rollback-from-backup.md).
4. Report the error verbatim to the user so they can file a Gibbon upstream issue if the error is a real bug, not a local misconfiguration.

## Do NOT

- Do NOT run `CHANGEDB.php` statements manually via `mysql` CLI — the `;end` separator means they won't split correctly. Always go through `/update.php`.
- Do NOT skip version hops. Gibbon supports linear upgrade (24 → 25 → 26 → …). Jumping 24 → 29 works because the migrations are cumulative, but test in staging if the tenant has customizations.
- Do NOT touch `config.php` $version by hand to "trick" the updater. The Updater does sanity checks; you'll just move the break to somewhere harder to diagnose.
