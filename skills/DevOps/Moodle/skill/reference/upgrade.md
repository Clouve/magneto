# Upgrade

Upgrading Moodle means: replace the codebase, run [admin/cli/upgrade.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/upgrade.php), purge caches. The script reconciles the schema and seeds new config rows on every plugin's `db/install.xml` and `db/upgrade.php`.

## The version invariant

Two values must agree for a healthy site:

| Value | Where |
|---|---|
| **Code version** | `$version` in [public/version.php](https://github.com/moodle/moodle/blob/v5.2.0/public/version.php) — for 5.2.0, `2026042000.00` |
| **DB version** | `value` from `mdl_config WHERE name = 'version'` |

When code version > DB version, an upgrade is **pending**. The site refuses normal access and shows "Moodle needs an upgrade to be applied" until `admin/cli/upgrade.php` (or the web upgrader at `/admin/`) runs to completion.

When code version < DB version, the site **refuses to bootstrap** — you have downgraded a code drop without restoring the DB. Restore from backup; never try to "downgrade" a Moodle DB by hand.

When they're equal, the site is healthy.

```bash
# Check the invariant from the AI Studio container:
CODE_VER=$(curl -sf http://moodle/version.php 2>/dev/null | grep -oE "version *= *[0-9.]+" | head -1)
# Or via SSH into the moodle container:
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@"$MOODLE_HOST" \
    'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo \$CFG->version, PHP_EOL;"'
# DB version:
PGPASSWORD="$MOODLE_DB_PASSWORD" psql -h "$MOODLE_DB_HOST" -U "$MOODLE_DB_USER" -tAc \
    "SELECT value FROM mdl_config WHERE name='version';"   # or the equivalent mysql one-liner
```

## The 5.2 floor: `requires=4.4`

[public/admin/environment.xml](https://github.com/moodle/moodle/blob/v5.2.0/public/admin/environment.xml) declares `<MOODLE version="5.2" requires="4.4">`. This means the **source instance must be on Moodle 4.4 or later** before upgrading to 5.2. If you find a tenant on 4.3 or older, you must upgrade them through 4.4 (or 4.5/5.0/5.1) first — a single jump from 4.3 → 5.2 fails.

## CLI upgrade signature

From [admin/cli/upgrade.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/upgrade.php) `cli_get_params(...)`:

| Flag | Default | Purpose |
|---|---|---|
| `--non-interactive` | `false` | Required for unattended scripts. Combined with `--allow-unstable` if you're upgrading to a non-stable release. |
| `--allow-unstable` | `false` | Required to proceed when target is `MATURITY_RC` / `MATURITY_BETA` / `MATURITY_ALPHA`. Required in non-interactive mode for any non-stable target. |
| `--maintenance` | `true` | If `true`, the upgrader enables maintenance mode for the duration. Setting `false` is dangerous — only do it for read-only updates with no schema change, and the script will refuse if the diff isn't safe. |
| `--is-pending` | `false` | Probe mode: exit code `2` if an upgrade is required, `0` otherwise. Useful in liveness checks. |
| `--is-maintenance-required` | `false` | Probe mode: exit code `2` if maintenance mode is required for this upgrade, `3` if not. |
| `--set-ui-upgrade-lock` / `--unset-ui-upgrade-lock` | `false` | Toggle the lock that prevents concurrent web-UI upgrades from clobbering a CLI upgrade. |
| `--lang=CODE` | site lang | CLI output language. |
| `--verbose-settings` | `false` | Verbose output. |
| `-h`, `--help` | | |

### Reference invocation

```bash
sudo -u www-data php admin/cli/upgrade.php --non-interactive
```

For an unattended container deploy of a stable release, this is enough — `--maintenance` defaults to `true`, the script enables maintenance mode, runs every plugin's upgrade hooks, then disables maintenance mode and exits.

For an upgrade to a `MATURITY_RC` build (don't do this on production):

```bash
sudo -u www-data php admin/cli/upgrade.php --non-interactive --allow-unstable
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success (or, with `--is-pending`/`--is-maintenance-required`, the "no upgrade needed" answer) |
| `1` | Generic error |
| `2` | (probe modes) Upgrade is pending / maintenance is required |
| `3` | (probe mode) No maintenance is required for the pending upgrade |

## Pre-upgrade checks

Before running the upgrade:

1. **Take a complete backup.** DB dump *and* `moodledata`. See [backup-restore.md](backup-restore.md).
2. **Read the upstream `UPGRADING.md` for the target version.** [https://github.com/moodle/moodle/blob/v5.2.0/UPGRADING.md](https://github.com/moodle/moodle/blob/v5.2.0/UPGRADING.md) and the per-component sub-sections (e.g. `### core`, `### mod_quiz`, `### auth_oauth2`). Look at the **Removed**, **Changed**, **Deprecated** sections — these are the breaking changes.
3. **Verify environment satisfies new floors.** `php admin/cli/checks.php` runs the full environment check ([admin/cli/checks.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/checks.php)). For 5.2: PHP ≥ 8.3, DB engine and version match the table in [stack-and-runtime.md](stack-and-runtime.md), required PHP extensions present.
4. **Probe whether the upgrade is required.**
   ```bash
   sudo -u www-data php admin/cli/upgrade.php --is-pending
   echo "Exit: $?"   # 0 = nothing to do, 2 = upgrade required
   ```
5. **Probe whether maintenance is required.**
   ```bash
   sudo -u www-data php admin/cli/upgrade.php --is-maintenance-required
   echo "Exit: $?"   # 2 = required, 3 = not required
   ```
6. **Disable cron during the window.** `admin/cli/cron.php` runs every minute under most setups. If the operator's cron fires while the upgrade is mid-flight, you get a hung lock. Either pause the cron job at the scheduler, or briefly set `$CFG->cron_enabled = false`.

## Post-upgrade

1. **Purge caches.** Mandatory — the upgrader's own warning says: *"Caches (except theme) will be STALE and MUST be purged after upgrading."*
   ```bash
   sudo -u www-data php admin/cli/purge_caches.php
   ```
   See [scripts/purge-caches.sh](../scripts/purge-caches.sh).
2. **Verify versions match.** `mdl_config(version)` should equal `public/version.php $version`.
3. **Re-enable cron.**
4. **Smoke-test.** Open the home page, log in as admin, open one course, open one quiz attempt screen. The most common post-upgrade symptom is a plugin whose `db/upgrade.php` partially failed — the site itself loads fine, but one feature throws a 500.
5. **Run the checks dashboard.**
   ```bash
   sudo -u www-data php admin/cli/checks.php
   ```
   Or visit Site administration → Reports → System status. Anything in red was either pre-existing or caused by the upgrade.

## Rollback

A failed upgrade rolls back via **restore from backup**, full stop. There is no "downgrade" path — Moodle's `db/upgrade.php` files are forward-only. See [playbooks/rollback-from-backup.md](../playbooks/rollback-from-backup.md).

The implication: you MUST have a known-good backup taken **after maintenance mode was enabled** and **before the upgrade started**. The window where data can mutate but no backup exists is exactly the danger zone — keep it short.

## Plugin upgrades vs. core upgrades

`admin/cli/upgrade.php` runs the upgrade hooks for **every** installed plugin, not just core. If a contributed plugin's `db/upgrade.php` fails, the whole upgrade aborts mid-flight and the site is left in maintenance mode with a partially-upgraded schema.

When this happens:

1. The error message will name the plugin and the failing version increment.
2. Your options are:
   - **Fix the plugin** (write the missing migration step) and re-run.
   - **Uninstall the plugin** via [admin/cli/uninstall_plugins.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/uninstall_plugins.php) and re-run.
   - **Restore from backup** and skip this upgrade.

This is the strongest argument for keeping contributed plugins to a minimum and for vetting them before install. See [playbooks/install-plugin.md](../playbooks/install-plugin.md).

## Concurrency

There's a UI lock (set via `--set-ui-upgrade-lock` / unset via `--unset-ui-upgrade-lock`) and an internal advisory lock during the schema migration. Two concurrent upgraders will collide; the second exits with an error. **Never run a manual `admin/cli/upgrade.php` while a CronJob or another operator may also be running it.**
