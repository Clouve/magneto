# Playbook: Purge caches

Trivial but worth a written playbook because it's the answer to a surprising number of "weird behaviour" reports.

## When to purge

Purge caches after ANY of:

- **Plugin install or uninstall** (any type).
- **Plugin upgrade** (whether triggered by core upgrade or stand-alone).
- **`config.php` edit** that changes anything Moodle reads (DB conn, MUC mappings, session handler, debug flags).
- **Theme change** at site level OR theme cache mode change (`themedesignermode`).
- **Language pack install / update.**
- **Major user-role / capability change** at the site level.
- **MUC store mapping change** (admin UI → Plugins → Caching → Configuration).
- **A user reports stale strings, missing nav items, or capability changes that didn't take effect.**

When in doubt: purge.

## Steps

### 1. Run the purge

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/purge_caches.php'
```

By default this purges everything: MUC, theme, JS, language strings, filter cache, others. It typically takes a few seconds on a small site, up to a minute on a large one.

### 2. (optional) Targeted purge

If you know which cache is stale and don't want the cold-cache penalty on the rest of the site:

| Flag | Purges |
|---|---|
| `--muc` | MUC application cache + lang cache |
| `--theme` | Compiled SCSS, theme image preprocessing |
| `--lang` | Language string cache |
| `--js` | JS bundle cache |
| `--filter` | Filter cache |
| `--courses=4,67,145` | Course-specific caches for given course IDs |
| `--other` | Other / catch-all |

Example:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/purge_caches.php --theme'
```

### 3. Tell the user

If the purge was for a specific complaint:

- "Purged caches. Reload the page (hard reload — Cmd-Shift-R / Ctrl-Shift-R) to pick up new JS/CSS bundles."
- The user must hard-reload — without that, their browser keeps the old `?_v=<rev>`-versioned JS until the URL changes (which the purge does — `themerev` and `jsrev` are auto-incremented).

## What "purge" does NOT include

- **Browser cache** — the user must hard-reload.
- **CDN cache** — if there's a CDN in front, its cache survives the Moodle purge until its own TTL expires (or you invalidate from the CDN side).
- **OPcache** — PHP's own bytecode cache. After a code drop (not a config change), you also need to restart Apache or send `apachectl graceful`. The Moodle `purge_caches.php` does NOT trigger an OPcache reset.
- **Redis session keys** — sessions are not "stale caches"; they're authoritative. Purging cache does not log users out.

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| `purge_caches.php` errors with "Cannot purge cache_redis" | Redis is down | Fix Redis connectivity first; the purge will then work |
| Purge "succeeds" but user still sees stale theme | Browser cached the old CSS | Tell user to hard-reload |
| Purge "succeeds" but plugin settings page still 404s | OPcache holding stale class map | `apachectl graceful` |
| Purge takes a very long time | The "filter" cache or "filter_active" cache rebuild is heavy on big sites | Purge specific caches instead of all-at-once |

## When purging doesn't help

If you've purged and the symptom persists, the issue is NOT cache. Move on to the relevant troubleshooting step in [reference/troubleshooting.md](../reference/troubleshooting.md).
