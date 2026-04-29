# Notable changes in Moodle 5.2

The operator-relevant items distilled from [UPGRADING.md](https://github.com/moodle/moodle/blob/v5.2.0/UPGRADING.md). Anything in this file is sourced from that file unless noted otherwise. The full UPGRADING.md is large (4 000+ lines for the 5.2 block alone, mostly developer-facing API changes); this is the operator subset.

## Required to upgrade

| Floor | Old (5.1) | New (5.2) |
|---|---|---|
| Source Moodle version | any 4.x or 5.x | **`>= 4.4`** (`<MOODLE version="5.2" requires="4.4">`) |
| PHP | `>= 8.2` | **`>= 8.3.0`** |
| MariaDB | `>= 10.6.7` | **`>= 10.11.0`** |
| MySQL | `>= 8.0` | **`>= 8.4`** |
| PostgreSQL | `>= 13` | **`>= 16`** |
| MS SQL Server | `>= 14.0` | **`>= 15.0`** |
| Aurora MySQL | `>= 3.02.0` | **`>= 8.0`** |
| Oracle | supported | **dropped** |

If your tenant is on Oracle, the upgrade to 5.2 cannot proceed; data must be migrated to one of the supported engines first. This is a substantial engagement — flag it early.

## Layout change: `public/` is the webroot

The largest visible change. Source structure now:

```
<dirroot>/                 ← project root
├── config.php             ← OUTSIDE webroot
├── admin/cli/             ← OUTSIDE webroot
├── lib/setup.php          ← shim → public/lib/setup.php
├── public/                ← webserver DocumentRoot points here
│   ├── version.php
│   ├── lib/, admin/, mod/, ...
│   └── ...
└── ...
```

Webserver `DocumentRoot` MUST be set to `<dirroot>/public/`. Pointing at `<dirroot>` triggers the [root tripwire](https://github.com/moodle/moodle/blob/v5.2.0/index.php) — `moodle_exception('rootdirpublic', 'error')`.

Breakages this causes for legacy operator habits:

- `curl http://moodle/admin/cli/cron.php` no longer works — `admin/cli/` is outside the webroot. Run via `sudo -u www-data php <dirroot>/admin/cli/cron.php`.
- Webserver configs that hard-code `<dirroot>` as DocumentRoot need updating.
- Any reverse proxy that fetches `<dirroot>/some.php` directly (rare) breaks.

The `dirroot` semantics are preserved for backwards compat: setting `$CFG->dirroot` to either the root or `<root>/public` works (the [lib/setup.php migration shim](https://github.com/moodle/moodle/blob/v5.2.0/lib/setup.php) reconciles them).

## Cache stores: `memcached` and `mongodb` removed

[public/cache/stores/](https://github.com/moodle/moodle/tree/v5.2.0/public/cache/stores) ships only: `apcu`, `file`, `redis`, `session`, `static`. Memcached as a *cache store* is gone. Memcached **as a session handler** still exists at [public/lib/classes/session/memcached.php](https://github.com/moodle/moodle/blob/v5.2.0/public/lib/classes/session/memcached.php).

Operator action on upgrade: any site that mapped MUC modes to `cachestore_memcached` or `cachestore_mongodb` must remap before/during the upgrade. Symptom of forgetting: "Unable to load store memcached" on every page.

```bash
# Diagnostic before upgrade — does the current site map memcached?
sudo -u www-data php -r "require '/var/www/html/config.php'; require_once \$CFG->dirroot.'/lib/cachelib.php'; print_r(cache_helper::get_stores_suitable_for_mode_default());"
```

## Redis: split timeouts (MDL-85336)

> Redis connection timeout settings for cachestores and sessions have been split into connection timeout and read timeout to allow for finer control. These settings now also accept floats.

Pre-5.2:
```php
$CFG->session_redis_timeout = 3;
```
5.2:
```php
$CFG->session_redis_connection_timeout = 3.0;   // socket connect
$CFG->session_redis_read_timeout       = 3.0;   // per-read
```

Same change applies to `cachestore_redis` admin UI (Redis cache store config). Keep your old single-timeout setting and the value will still apply broadly, but the modern config is two values.

## MoodleNet integration removed

> The MoodleNet integration plugin (`tool_moodlenet`) has been removed from Moodle core. The public MoodleNet service (moodle.net) is being retired in April 2026.

If your site has MoodleNet sharing enabled, this stops working. Self-hosted MoodleNet instances can install the plugin from the Moodle HQ GitHub repo (separate distribution).

## `\core_shutdown_manager` namespace move

> The namespace for the `\core_shutdown_manager` has been moved to `\core\shutdown_manager`. The legacy namespace will continue to work for the moment.

Plugin code that calls the legacy namespace still works in 5.2 but will break later. Plugin authors should update; operators just need to know that "deprecated namespace" warnings in the logs are expected for older plugins.

## `upgrade_ensure_not_running()` deprecated

> The `upgrade_ensure_not_running()` function has been deprecated and replaced with: `\core\setup::warn_if_upgrade_is_running()`, `\core\setup::ensure_upgrade_is_not_running()`, `\core\setup::is_upgrade_running()`.

Affects code, not config — flagged here only because plugin maintainers may push updates that touch this and you'll see them in changelogs.

## `kill_all_sessions.php`: `--run` is now required

> The CLI script used to terminate user sessions (`kill_all_sessions.php`) has been improved to make it safer and more flexible. A new `--run` parameter has been introduced. Without `--run`, the script performs a dry run making no changes. The script now supports targeted session termination using `--for-users` parameter.

Translation: `php admin/cli/kill_all_sessions.php` is now a **dry run by default**. To actually terminate, pass `--run`. To target specific users, use `--for-users=jane.doe,john.q`. This is strictly safer than the old behaviour. Operators who scripted this with the old behaviour ("kill all sessions on deploy") need to add `--run`.

## Web service responses include `initials` field

> Several core web services now include a new initials field in user data structures. This change is backward-compatible and only adds an optional field; no existing fields or field semantics have been changed.

Affects integrations that consume Moodle's web services and have strict schema validation. The added field is in:

- `core_enrol_get_enrolled_users` (and friends)
- `core_user_get_users`, `core_user_get_users_by_field`
- `core_message_*` member-info endpoints
- `mod_assign_list_participants`
- `mod_forum_get_forum_discussions`

If you hear "our integration broke after the upgrade with a schema error", this is a likely cause.

## qtype_random removed

> Removed `qtype_random` from core. `core\component::is_valid_plugin_name` has an additional check to ensure no-one can create a new plugin called qtype_random, as this would conflict with the support for restoring old backups.

Random questions in quizzes were previously implemented via the `qtype_random` plugin; in 5.2, that mechanism is integrated differently (the random-question feature lives in the quiz engine, not as a separate qtype). Existing quizzes with random questions continue to work; restoring older `.mbz` backups remains supported. No operator action.

## Other operator-visible items

- **`public/admin/tool/moodlenet/`** removed (paired with the `tool_moodlenet` removal).
- **`public/lib/classes/navigation/flat_navigation_node.php`** and **`flat_navigation.php`** removed — affects custom themes/blocks that used flat-nav APIs.
- **`MOD_PURPOSE_INTERFACE`** constant removed — affects very few plugins.
- **`grunt watch -f`** flag added — front-end developer convenience, not operator-relevant.
- **Confirm dialogue API** picked up two new params (`$title`, `$dialogtype`) — backwards-compatible.
- **`require_login()` redirect behaviour** changed for activity restrictions — when an activity has visibility restrictions configured, users are now redirected to a "restricted" page rather than seeing a generic error. UX change visible to end users.

## What this means for your upgrade plan

The compatibility matrix above is the gate. If everything in the matrix is satisfied:

1. Take the backup.
2. Verify the source is on 4.4 or later. If on 4.3 or earlier, upgrade to 4.4 first (which has its own `requires`, etc.).
3. Verify PHP 8.3+ on the target image.
4. Verify the DB engine version satisfies the new floor.
5. Verify you don't have `cachestore_memcached` or `cachestore_mongodb` in MUC mappings.
6. Run [admin/cli/upgrade.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/upgrade.php) per [playbooks/upgrade-moodle.md](../playbooks/upgrade-moodle.md).
7. Purge caches.
8. Smoke-test.

If any of items 1–5 are not satisfied, surface the gap to the user before proceeding — these are not "fix it during the upgrade" items.
