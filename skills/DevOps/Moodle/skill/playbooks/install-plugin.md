# Playbook: Install a plugin

Use this playbook whenever the user wants to add a Moodle plugin (a `mod_*`, `block_*`, `local_*`, `auth_*`, etc.) that is **not already in the shipped Moodle image**.

## Read first

A plugin runs arbitrary PHP inside the Moodle container with full DB access and `<dataroot>` write access. **Treat this like installing a server-side service**, not a UI customization.

In the Magneto-shipped Moodle pod, plugins installed at runtime live under `<dirroot>/local/`, `<dirroot>/mod/`, etc. — but **the codebase is part of the image**. Hand-installed plugins are wiped on the next pod restart unless they were baked into the image. So unless the user owns the image build:

- A "let me try this plugin" experiment may work for the rest of the pod's lifetime, but disappears on restart.
- A "production install" requires a Clouve image rebuild — surface this as a feature request to Clouve ops, not a runtime change.

This playbook covers both: the experimental install (acknowledged ephemeral) and the workflow for getting a plugin into the next image.

## Preconditions

- [ ] Backup taken (see [scripts/backup.sh](../scripts/backup.sh)). A bad plugin's `db/install.xml` can leave the DB schema partially extended — restoring is your safety net.
- [ ] User has named **the exact plugin** by its frankenstyle (e.g. `mod_bigbluebuttonbn`, `local_clouve`, `auth_oidc`) AND a download source (URL of release zip, Git repo + tag, or moodle.org plugin ID).
- [ ] User has confirmed the source is trusted (see "Vetting an untrusted plugin" below).
- [ ] User understands the change is ephemeral if not baked into the image, OR has agreed to the rebuild path.

## Vetting an untrusted plugin

Before unzipping anything into `<dirroot>`:

1. **Confirm the source.** moodle.org/plugins is the canonical registry; plugins there have at least passed automated checks (no `eval`, declared dependencies, etc.). GitHub repositories under `github.com/moodle` or `github.com/moodlehq` are first-party. Any other source = third-party.

2. **Read `version.php`.**
   ```bash
   curl -s "$PLUGIN_URL/raw/main/version.php" | grep -E '^\s*\$plugin->'
   ```
   You're checking:
   - `$plugin->component` matches the directory and the user's claim.
   - `$plugin->requires` is `>= 2024xx` (4.4 or later) or you'll get install-time failures on 5.2.
   - `$plugin->maturity = MATURITY_STABLE` (or at least RC). MATURITY_ALPHA is a no-go for production.
   - `$plugin->dependencies` lists what else needs to be installed first. If it depends on plugins you don't have, install those too — don't paper over with `$plugin->dependencies = []`.

3. **Read `db/install.xml`.** This is the schema the plugin will create. Look for:
   - Tables named `<frankenstyle>_*`. They should NOT have generic names like `mdl_data` or `mdl_log` (those would conflict with core).
   - No `DROP TABLE` statements (this format doesn't allow them, but check anyway).

4. **Read `db/upgrade.php`** if present. Specifically the `xmldb_<frankenstyle>_upgrade()` function — it executes raw DDL on every upgrade. Look for `DROP TABLE`, mass `DELETE` statements, anything that touches tables NOT prefixed with the plugin's own frankenstyle.

5. **Read `lib.php`.** This is the main entry point. Look for:
   - File operations outside `<dataroot>`.
   - `exec()`, `shell_exec()`, `system()`, `passthru()`, `popen()`, `proc_open()`. There may be legitimate reasons (e.g. `mod_bigbluebuttonbn` shells out for some checks), but each one needs a one-line answer to "why".
   - `eval()`. Almost never legitimate.
   - `unserialize()` on user input. CVE territory.

6. **Run a static check.** `find . -name '*.php' -exec grep -l 'eval\|base64_decode\|gzinflate.*eval\|preg_replace.*\/e' {} \;` on the unpacked tree. Any hit is a stop-and-investigate.

If any of the above raise concerns, surface them to the user and ask them to choose a different plugin.

## Steps — experimental install (ephemeral)

### 1. Maintenance mode on

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/maintenance.php --enable'
```

### 2. Take the backup

```bash
bash "$SKILL_DIR/scripts/backup.sh"
```

### 3. Drop the plugin into the right path

For `mod_<name>`: `<dirroot>/public/mod/<name>/`
For `block_<name>`: `<dirroot>/public/blocks/<name>/`
For `local_<name>`: `<dirroot>/public/local/<name>/`
For `auth_<name>`: `<dirroot>/public/auth/<name>/`
For `enrol_<name>`: `<dirroot>/public/enrol/<name>/`
For `theme_<name>`: `<dirroot>/public/theme/<name>/`

Note the `public/` prefix — 5.2 puts plugin trees inside `public/`. The `<dirroot>/` path is the project root and lives outside webroot; the plugin code itself goes inside `public/`.

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} bash <<'EOF'
set -e
cd /tmp
curl -L -o plugin.zip "$PLUGIN_URL"
unzip -q plugin.zip -d plugin-unpacked
# Inspect the structure first:
ls plugin-unpacked/
# The release should have a single top-level dir like 'auth_oidc/' or 'oidc/'
sudo cp -r plugin-unpacked/<topdir> /var/www/html/public/auth/oidc/
sudo chown -R root:www-data /var/www/html/public/auth/oidc
sudo find /var/www/html/public/auth/oidc -type d -exec chmod 0755 {} +
sudo find /var/www/html/public/auth/oidc -type f -exec chmod 0644 {} +
EOF
```

Stop here and confirm with the user before running step 4.

### 4. Run the install hook

`admin/cli/upgrade.php` discovers the new plugin (because its `version.php` is now on disk) and runs its `db/install.xml` + `db/install.php`:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --non-interactive'
```

Watch the output for the plugin's name. If it says "Installing <plugin> 2024xxxx" and exits 0, you're good. If it errors on `db/install.xml` or `db/install.php`, the plugin is broken or incompatible — go to step 6.

### 5. Purge caches and disable maintenance

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/purge_caches.php && \
     sudo -u www-data php /var/www/html/admin/cli/maintenance.php --disable'
```

### 6. Verify

- `mdl_config_plugins WHERE plugin = '<frankenstyle>' AND name = 'version'` returns the new install version.
- The plugin's settings page is reachable: Site administration → Plugins → <type> → <name>.
- For `mod_*` plugins, you can add an instance of it to a course.
- For `auth_*` plugins, the auth method appears at Site admin → Plugins → Authentication → Manage authentication.

If any of these fail, the plugin install is broken. Restore from backup (step 2) and tell the user.

### 7. Persistence reminder

```
This plugin is installed for the lifetime of the current pod only. On the
next pod restart it will be wiped (the codebase comes from the image).
For a permanent install, the plugin must be added to the Moodle Docker
image — open a ticket with Clouve ops with:
  - the plugin frankenstyle and version
  - the source URL
  - confirmation that you accept the security implications
```

## Steps — image install (permanent, via Clouve ops)

This is not a runtime workflow. Surface to Clouve ops with:

- Plugin frankenstyle, version, source URL.
- The vetting findings from "Vetting an untrusted plugin" above.
- Any version-pinning preferences (specific tag, head of branch, etc.).

The image rebuild adds a `RUN` step in [apps/moodle/image/Dockerfile](../../../../apps/moodle/image/Dockerfile) that fetches and unpacks the plugin into `<dirroot>/public/<type>/<name>/`. On the next deploy, every tenant pod gets the plugin installed automatically (via `admin/cli/upgrade.php` running on first boot).

## Uninstalling

If a plugin install was a mistake or it's no longer needed:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/uninstall_plugins.php --plugins=<frankenstyle> --run'
```

[admin/cli/uninstall_plugins.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/uninstall_plugins.php) drops the plugin's tables, removes its `mdl_config_plugins` entries, and removes its files. **Take a backup first** — there's no undo.

The `--run` flag was historically required for the destructive action; without it the script lists what it WOULD do (dry run). Always do the dry run first:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/uninstall_plugins.php --plugins=<frankenstyle> --showsql'
```

After uninstall, purge caches.
