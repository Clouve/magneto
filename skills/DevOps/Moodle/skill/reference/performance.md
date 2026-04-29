# Performance

Tuning a Moodle 5.2 instance, in the order of leverage.

## 1. OPcache (mandatory)

Without OPcache, every request reparses ~200 PHP files from disk. A school's homepage can go from 80 ms to 800 ms. The `php:8.3-apache` image ships OPcache enabled — verify with `php -i | grep opcache.enable`.

`/etc/php/8.3/apache2/conf.d/10-opcache.ini` should set:

| Directive | Value | Why |
|---|---|---|
| `opcache.enable` | `1` | On for web requests |
| `opcache.enable_cli` | `0` (default) | Don't cache CLI invocations — `admin/cli/upgrade.php` would see a stale codebase |
| `opcache.memory_consumption` | `256` | Moodle codebase is ~150MB of PHP; 256MB gives headroom |
| `opcache.max_accelerated_files` | `20000` | Default 10000 is below Moodle's file count |
| `opcache.validate_timestamps` | `0` (production) | Skip the per-request mtime check |
| `opcache.revalidate_freq` | `0` (with validate_timestamps=1) or `60` | If timestamps are checked, don't check every request |
| `opcache.fast_shutdown` | `1` | Faster request teardown |

**`validate_timestamps = 0` means OPcache won't notice when you deploy a new codebase.** You MUST restart PHP-FPM (or send `apachectl graceful`) after a code drop, otherwise users see a mix of old and new code. The Magneto deploy flow already does this; if you're hand-deploying, remember.

## 2. PHP-FPM pool sizing (or mod_php worker count)

A Moodle request typically takes 50–500 ms (homepage), 1–5 s (course page), 5–30 s (a quiz attempt close, or a backup task). PHP-FPM child count must cover the **peak concurrent slow requests**, not just the average.

Rule of thumb for a school of 1000 active users:

| Resource | Setting |
|---|---|
| `pm.max_children` | 32–64 (depends on RAM per child) |
| `pm.start_servers` | 8 |
| `pm.min_spare_servers` | 4 |
| `pm.max_spare_servers` | 16 |
| `pm.max_requests` | 1000 (recycle children to release memory leaks) |
| Per-child memory | 80–150 MB (one-shot pages); plan `max_children * 150MB` of RAM |

The Magneto Moodle image runs Apache with mod_php, not PHP-FPM. `MaxRequestWorkers` in `apache2.conf` is the equivalent knob. Same logic — measure peak concurrent users, allocate accordingly.

## 3. MUC application cache

See [caching.md](caching.md). On a single node, the file store backed by `<cachedir>` is fine. On a cluster, **switch the application mode to Redis** — file-based cache invalidation across nodes is unreliable.

APCu as a per-pod accelerator for read-mostly definitions (language strings, role caps) is worth ~20% page render time on the home page. Add it on top of the application cache, not as a replacement.

## 4. `cachejs`, `themedesignermode`, `langstringcache`

Three settings that **must** be at production values:

```php
$CFG->cachejs           = true;   // Caches built JS bundles
$CFG->cachetemplates    = true;   // Caches Mustache templates
$CFG->langstringcache   = true;   // Caches language strings
$CFG->themedesignermode = false;  // Caches compiled SCSS
```

`themedesignermode = true` recompiles SCSS on every page render. This is the single fastest way to make a Moodle site feel sluggish. Production sites have it `false`. If a developer turned it on locally and forgot to revert, the site is now 10x slower.

`cachejs = false` and `langstringcache = false` have similar but less dramatic costs.

## 5. Static asset serving

Moodle serves theme CSS, JS bundles, and language packs through `theme/styles.php`, `lib/javascript.php`, and `lib/requirejs.php` — all of which are PHP. With `cachejs/cachetemplates/themedesignermode` set right, the response includes `Cache-Control: max-age=...` headers and browsers cache aggressively. But every cold-cache user incurs a PHP request for each asset.

Knobs:

- **CDN**: a CDN in front of Moodle dramatically cuts asset PHP load. Configure via `$CFG->themerev` and `$CFG->jsrev` (auto-incremented on cache purge).
- **`expectedrev` URL parameter**: Moodle includes `?_v=<rev>` in asset URLs; the rev changes on every theme/JS purge. CDNs cache forever and re-fetch on URL change — this is the "right" CDN-friendly design.
- **`X-Sendfile` / `X-Accel-Redirect`**: `$CFG->xsendfile = 'X-Accel-Redirect'` (nginx) or `'X-Sendfile'` (Apache mod_xsendfile) lets Moodle hand the actual file delivery to the webserver, freeing the PHP worker. Big win for downloads of large files.

## 6. Database tuning

Moodle is read-heavy. Most tuning lives at the DB engine level (InnoDB buffer pool, Postgres `shared_buffers`, work_mem). On the Moodle side:

| Setting | Effect |
|---|---|
| `$CFG->dboptions['readonly']` | Read replica config — see below |
| `$CFG->dboptions['logslow']` | `>0` logs queries exceeding N ms to `mdl_log_queries`. Use temporarily to find slow queries. |
| `$CFG->dboptions['logall']` | `true` logs every query. **Only for debugging** — fills `mdl_log_queries` fast. |
| `$CFG->dboptions['fetchbuffersize']` | Postgres only. `100000` default; set `0` if behind pgbouncer transaction-mode. |

### Read/write split

```php
$CFG->dboptions['readonly'] = [
    'instance' => [
        ['dbhost' => 'replica-1.internal'],
        ['dbhost' => 'replica-2.internal'],
    ],
    'connecttimeout' => 1,
];
```

Moodle routes SELECTs to a replica, INSERTs/UPDATEs/DELETEs to the primary, and respects transactional consistency (anything inside a transaction sticks to the primary). Replica lag is your problem — Moodle does not validate freshness.

This works well for read-heavy sites at scale (>10k DAU). For the Magneto Moodle pod (single tenant, single DB), the complexity is not worth it.

## 7. Course-level performance

| Symptom | Knob |
|---|---|
| Slow gradebook | Calculated grades — disable expensive calculations or simplify outcomes |
| Slow course pages with many activities | Enable course collapsed sections; lazy-load activity content |
| Slow forum render | Limit `forumlongpost`/`forumshortpost` settings; avoid threads with thousands of replies |
| Slow quiz on big question banks | Cache question definitions; avoid random questions across the whole bank |
| Slow logs report | Switch from "Live logs" to standard logs; use `--filter` |

## 8. Cron parallelism

By default cron runs single-threaded. For a busy site, run multiple parallel cron processes. They coordinate via the lock factory (see [cron-and-tasks.md](cron-and-tasks.md)).

```cron
* * * * * www-data /usr/bin/php /var/www/html/admin/cli/cron.php >/dev/null 2>&1
* * * * * www-data /usr/bin/php /var/www/html/admin/cli/cron.php >/dev/null 2>&1
* * * * * www-data /usr/bin/php /var/www/html/admin/cli/cron.php >/dev/null 2>&1
```

Three concurrent cron runners eat through the adhoc-task queue 3x faster. **Only do this with a working cluster-safe lock factory** — file-based locks on a non-shared mount will let two runners do the same task.

## 9. Profiling a slow request

When the user reports "page X is slow":

1. **Confirm** — get the URL and load it yourself, time it.
2. **Enable performance debug temporarily**:
   ```php
   $CFG->perfdebug = 15;
   ```
   This injects a footer with timing breakdown (DB queries, MUC hits/misses, includes, render time).
3. **Check slow query log**:
   ```php
   $CFG->dboptions['logslow'] = 500;  // log queries > 500ms
   ```
   Then `SELECT * FROM mdl_log_queries ORDER BY timestart DESC LIMIT 20;`. This stays small if the threshold is right.
4. **Disable in production** — both knobs above are dev-mode only.

For deeper analysis, use a PHP profiler (XHProf or Tideways) — Moodle has a built-in XHProf integration via `$CFG->profilingenabled`. That's a development workflow, not a production one.

## What's NOT a perf knob (despite folklore)

- **`$CFG->cachejs = false`** does not "improve perf for users" — it dramatically slows the site by forcing JS bundle rebuilds.
- **`opcache.revalidate_freq`** has no effect when `validate_timestamps = 0`.
- **Disabling cron** "to reduce load" breaks emails, course completion, scheduled backups, and analytics.
- **Memcached** — gone as a cache store in 5.2; use Redis.
- **Increasing `memory_limit` to 4G** rarely helps; if PHP needs >512MB for a page render, there's a code-level problem (a runaway loop or a query returning millions of rows).
