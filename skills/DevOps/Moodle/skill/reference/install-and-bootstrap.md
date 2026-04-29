# Install & Bootstrap

Moodle has two install paths: the interactive web UI ([public/install.php](https://github.com/moodle/moodle/blob/v5.2.0/public/install.php)), which is what you get when you visit a fresh site without a `config.php`, and the **non-interactive CLI** at [admin/cli/install_database.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/install_database.php). Containerized deploys MUST use the CLI path — it's idempotent (well, "fail-loud-when-already-installed", which is what you want), scriptable, and reads admin credentials from flags rather than form posts.

## The "is it installed?" sentinel

Moodle is installed when **the DB has the `mdl_config` table populated with a `version` row**. The web installer's first action is to check `$DB->get_tables()` and bail with `clitablesexist` if any prefix-matching tables already exist; the CLI installer does the same. So:

```sql
-- Mariadb / MySQL
SELECT value FROM mdl_config WHERE name = 'version';

-- PostgreSQL
SELECT value FROM mdl_config WHERE name = 'version';
```

If this returns a numeric value, Moodle is installed at that schema version. If the table doesn't exist or the row is missing, the install is incomplete.

## Two-phase install

The CLI install is two distinct steps:

1. **Write `config.php`** — encodes DB credentials, `wwwroot`, `dataroot`, prefix. Done by the operator (or the entrypoint script) BEFORE running `install_database.php`. Without a valid `config.php`, the CLI installer cannot know the DB to populate.
2. **Run `admin/cli/install_database.php`** — populates the schema, seeds default data, creates the admin user.

The web installer collapses these into one wizard; the CLI splits them so each is scriptable and replayable independently.

## CLI install signature

From [admin/cli/install_database.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/install_database.php) `cli_get_params(...)`:

| Flag | Default | Required? | Purpose |
|---|---|---|---|
| `--lang` | `en` | no | Site default language pack. |
| `--adminuser` | `admin` | no | Admin username. |
| `--adminpass` | (empty) | **yes** | Admin password. Must be set or the script exits. |
| `--adminemail` | (empty) | recommended | Admin email; validated as RFC 822. |
| `--fullname` | (empty) | recommended | Site full name (e.g. "Acme Academy LMS"). |
| `--shortname` | (empty) | recommended | Site short name (used in nav and headings). |
| `--summary` | (empty) | no | Front-page summary HTML. |
| `--supportemail` | (empty) | no | Support contact. Validated. |
| `--noreplyemail` | (empty) | no | Override `$CFG->noreplyaddress`. Validated. |
| `--agree-license` | `false` | **yes** | Must pass `--agree-license` or the script exits with `You have to agree to the license`. |
| `-h`, `--help` | | | Print help. |

### Reference invocation

```bash
sudo -u www-data php admin/cli/install_database.php \
    --agree-license \
    --lang=en \
    --adminuser=admin \
    --adminpass='ChangeMe!Strong-Long-Random' \
    --adminemail=admin@example.org \
    --fullname='Example LMS' \
    --shortname='ELMS'
```

This is what [scripts/install.sh](../scripts/install.sh) wraps. Use the wrapper, not the bare invocation — the wrapper waits for the DB to be reachable, refuses to run if `mdl_config` already has a `version` row, and never echoes the password back into the log.

## Idempotency

The CLI installer is **not** silent-on-already-installed: if `$DB->get_tables()` returns any tables matching the prefix, it bails with `clitablesexist`. That's the right behaviour — running it twice on a populated DB would corrupt data.

The wrapper at [scripts/install.sh](../scripts/install.sh) detects the install sentinel before calling the CLI:

```bash
if php_query "SELECT value FROM mdl_config WHERE name='version'" | grep -q '[0-9]'; then
    echo "Moodle already installed (mdl_config.version is set). Nothing to do."
    exit 0
fi
```

This makes the wrapper safe to invoke from a container entrypoint on every restart.

## What the installer creates

After a successful run:

| Where | What |
|---|---|
| Database | All `mdl_*` tables defined in [public/lib/db/install.xml](https://github.com/moodle/moodle/blob/v5.2.0/public/lib/db/install.xml) and per-plugin `db/install.xml`. Site-wide config rows in `mdl_config`. |
| `mdl_user` | The admin user (id=2; id=1 is `guest`, id=0 is `nobody`). |
| `mdl_role` | Default roles: manager, coursecreator, editingteacher, teacher, student, guest, user, frontpage. |
| `mdl_course` | Site course (id=1). |
| `<dataroot>/` | `filedir/`, `temp/`, `cache/`, `localcache/`, `lock/`, `trashdir/` directory tree. |
| `<dataroot>/cache/` | Initial MUC config files. |

The admin password is stored hashed (bcrypt) in `mdl_user.password` for the admin row.

## What it does NOT create

- It does **not** create `<dataroot>` itself — that directory must exist with the right ownership before the script runs (`www-data:www-data`, mode `02770` recommended).
- It does **not** install any optional / contributed plugins — only what's bundled in the upstream tree at the time of release.
- It does **not** configure SSO — `auth_oauth2`, `auth_shibboleth`, etc. require post-install configuration.
- It does **not** register cron — the operator is expected to schedule `admin/cli/cron.php` externally. See [cron-and-tasks.md](cron-and-tasks.md).

## Bootstrap order on every request

This is the order in which a fresh PHP request initialises Moodle. Knowing this helps you debug "white screen of death" failures — the symptom maps to the step that failed.

1. Webserver dispatches to `public/<some>.php`.
2. Script `require_once`'s `<dirroot>/public/config.php` (a shim).
3. The shim requires `<dirroot>/config.php` (operator-edited). If missing → redirects to `install.php`.
4. `config.php` sets `$CFG`, then requires `<dirroot>/lib/setup.php` (a shim).
5. The setup shim requires `<dirroot>/public/lib/setup.php` (the real bootstrap).
6. Real bootstrap:
   1. Defines path constants (`$CFG->libdir`, etc.).
   2. Initialises the autoloader.
   3. Connects to the DB and constructs `$DB`.
   4. Loads `mdl_config` cache → populates `$CFG` defaults from DB.
   5. Sets up the configured cache (MUC).
   6. Sets up the configured session handler.
   7. Restores the user session.
   8. Sets up output buffering.
   9. Returns control to the calling page script.

If step 3 fails (no `config.php`) you see the install wizard. If step 6.3 fails (DB unreachable) you see "Error: Database connection failed". If step 6.5 fails (cache backend unreachable) you see a fatal at the cache layer. If step 6.6 fails (Redis session handler unreachable) you see a session error and the site is offline.

This is the whole reason cache and session backends are availability-critical, not "nice-to-have."
