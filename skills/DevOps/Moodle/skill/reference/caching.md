# MUC — Moodle Universal Cache

Every cache in Moodle goes through MUC. The framework lives in [public/cache/](https://github.com/moodle/moodle/tree/v5.2.0/public/cache); definitions are declared in `db/caches.php` of each component.

## Stores in 5.2

What ships in core, from [public/cache/stores/](https://github.com/moodle/moodle/tree/v5.2.0/public/cache/stores):

| Store | Path | When to use |
|---|---|---|
| `static` | `cache/stores/static/` | In-process PHP array. Fastest; lives only for one request. Used for "request-scoped" caches. |
| `apcu` | `cache/stores/apcu/` | In-process shared memory via APCu. Per-PHP-FPM-pool. Useful for read-mostly config and language-string caches on a single node. |
| `file` | `cache/stores/file/` | Backing file under `<cachedir>` (or `<localcachedir>`). Cluster-safe **only** if `<cachedir>` is on a shared filesystem. |
| `redis` | `cache/stores/redis/` | Redis-backed. Cluster-safe by definition. Recommended for the **application** cache mode. |
| `session` | `cache/stores/session/` | PHP `$_SESSION`-backed. Used internally for session-scoped caches. |

**Notably absent in 5.2**:

- `memcached` cache store — **removed**. (memcached survives only as a *session* handler at [public/lib/classes/session/memcached.php](https://github.com/moodle/moodle/blob/v5.2.0/public/lib/classes/session/memcached.php).)
- `mongodb` cache store — **removed**.
- `memcache` (older) — long gone.

If you find a `mappingsonly => ['memcached' => ...]` block in an upgraded site's MUC config, it'll fail to load on 5.2. Replace with `redis`. See [troubleshooting.md](troubleshooting.md).

### Redis in 5.2: split timeouts

Per [UPGRADING.md](https://github.com/moodle/moodle/blob/v5.2.0/UPGRADING.md): "Redis connection timeout settings for cachestores and sessions have been split into connection timeout and read timeout to allow for finer control. These settings now also accept floats." (MDL-85336)

Practical impact: any pre-5.2 `config.php` that set `$CFG->session_redis_timeout` should now set both `$CFG->session_redis_connection_timeout` and `$CFG->session_redis_read_timeout`. Same change applies to the `cachestore_redis` admin UI.

## Cache definitions

A "cache definition" is a strongly-typed cache slot. Definitions live in `<plugin>/db/caches.php` and look like:

```php
$definitions = [
    'string' => [
        'mode' => cache_store::MODE_APPLICATION,
        'persistent' => true,
        'persistentmaxsize' => 600,
    ],
    'config' => [
        'mode' => cache_store::MODE_APPLICATION,
        'persistent' => true,
    ],
];
```

The `mode` selects which store family the definition is mapped to:

| Mode | Lifecycle | Sharing |
|---|---|---|
| `MODE_APPLICATION` | persists across requests | shared across all users |
| `MODE_SESSION` | persists for the user's session | per-user |
| `MODE_REQUEST` | one request | per-request (= the `static` store) |

The admin chooses which **store** to map each **mode** to (and can override per-definition). Site administration → Plugins → Caching → Configuration.

## Recommended mappings

For a containerized production deployment, the standard mapping is:

| Mode | Backing |
|---|---|
| `MODE_APPLICATION` | Redis (cluster-safe, fast, persistent, supports tagging) |
| `MODE_SESSION` | Redis OR DB (DB is fine if Redis isn't available, but slower) |
| `MODE_REQUEST` | static (always — there's no benefit to anything else) |

For a **single-node** non-clustered deploy on the Magneto Moodle pod (no Redis sidecar), the default file-based mapping is fine:

| Mode | Backing | Notes |
|---|---|---|
| `MODE_APPLICATION` | file | backed by `<cachedir>` which lives in `moodledata/cache/` |
| `MODE_SESSION` | session (handled separately by the session handler) | |
| `MODE_REQUEST` | static | |

Plus APCu as a per-pod accelerator for `MODE_APPLICATION` definitions that fit in memory — strings and config dictionaries especially.

## When caches must be purged

After ANY of these, run `admin/cli/purge_caches.php`:

- Plugin install or uninstall
- Plugin upgrade (whether triggered by core upgrade or stand-alone)
- `config.php` edit
- Theme change or theme cache mode change
- Language pack install
- Major user-role change at the site level

[admin/cli/purge_caches.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/purge_caches.php) supports targeted purges:

| Flag | Purges |
|---|---|
| (no flag) | Everything |
| `--muc` | All MUC caches (incl. lang cache) |
| `--theme` | Theme cache (compiled SCSS, image preprocessing) |
| `--lang` | Language string cache |
| `--js` | JS bundle cache |
| `--filter` | Filter cache |
| `--courses=4,67,145` | Course-specific caches for given course IDs |
| `--other` | Other / catch-all caches not covered above |

For most operator workflows, no flag (purge everything) is fine. A targeted purge is useful only when you know the exact cache and don't want to incur the cold-cache penalty on the rest of the site.

## How "stale" feels in production

Symptoms of stale caches:

- A renamed string in a plugin still shows the old name → `--lang` purge.
- A new plugin's settings pages return 404 → MUC `--muc` purge (the routing table is cached).
- An updated theme's logo doesn't appear → `--theme` purge.
- A new JS feature doesn't run, browser console says "module not found" → `--js` purge **and** browser hard-reload (the per-revision URL changes).
- Capability change for a role doesn't take effect → MUC purge.
- A custom field's options dropdown is stuck on old values → MUC purge (specifically the `customfield` definition).

When in doubt, full purge.

## Cluster considerations

The thing most likely to bite a clustered deployment: **cache invalidation broadcasts**.

When code or admin UI invalidates a definition, MUC needs to invalidate every node's local copy. For Redis-backed stores this is automatic (the data lives on Redis). For file stores on a shared mount, it works but is slower (every read does a stat). For `apcu` and `static`, **invalidation is per-process** — there is no broadcast mechanism. So `apcu` should only be used for definitions that are stable for hours (language strings) or where staleness is acceptable.

The site-administration setting "Stores cache" lets you change mappings without editing `config.php`. The setting persists in `mdl_cache_*` tables. For declarative deployments, prefer setting mappings via `config.php` so the deploy is reproducible.

## Reading current mappings

```bash
# From admin UI: Site administration → Plugins → Caching → Configuration
# From CLI: there is no direct dump tool, but the mapping is in:
sudo -u www-data php -r "require '/var/www/html/config.php'; print_r(cache_helper::get_active_stores_for(cache_store::MODE_APPLICATION, 'core/string'));"
```

Or look at the per-mode mapping:

```sql
SELECT cd.component, cd.area, cd.modes, cd.staticacceleration
FROM mdl_cache_definitions cd
ORDER BY cd.component, cd.area;
```

The actual mode→store binding lives in the MUC config file at `<cachedir>/config.php` (different file from `<dirroot>/config.php` — same name, different role).
