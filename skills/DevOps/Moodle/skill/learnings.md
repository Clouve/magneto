# Learnings

Living scratchpad for Moodle-specific facts captured during real sessions that don't yet justify their own file under `reference/` or `playbooks/`. See [SKILL.md → Maintaining this skill](SKILL.md#maintaining-this-skill) for the protocol on what qualifies and how to write entries.

## Format

Each entry: dated (ISO-8601), terse, leads with the fact. If an entry grows past ~10 lines, promote it to a dedicated file and leave a one-line pointer.

---

## 2026-04-28 — Skill version skew: skill is for 5.2.0, shipped Magneto image is 5.0.1

The Magneto Moodle app at [apps/moodle/image/Dockerfile](../../../apps/moodle/image/Dockerfile) currently ships **Moodle 5.0.1** (`MOODLE_VERSION=501`). This skill is authored against **5.2.0** (`authoredAgainst: moodle v5.2.0` in [SKILL.md](SKILL.md)).

Implications until the app is upgraded:

- The 5.2 webroot relocation (`public/`) DOES NOT apply on the shipped image. On 5.0.1, `<dirroot>` IS the webroot — Apache `DocumentRoot` points at `/var/www/html` directly, `admin/cli/` lives at `/var/www/html/admin/cli/`, and there's no root tripwire `index.php`. Adjust the SSH commands in playbooks accordingly:
  - SSH path on 5.0.1: `/var/www/html/admin/cli/<script>.php`
  - SSH path on 5.2.0: `/var/www/html/admin/cli/<script>.php` (still root-level — same path; the change is the WEBROOT being inside `public/`).
- 5.0.1 supports `cachestore_memcached` and `cachestore_mongodb` as MUC stores — they're only **removed in 5.2**. So the "remove memcached MUC mapping" warning in [reference/changes-in-5.2.md](reference/changes-in-5.2.md) is a 5.2-upgrade gotcha, not a current-state problem.
- 5.0.1 supports Oracle (`dbtype = 'oci'`) — Oracle is dropped in 5.2.
- `requires=4.4` is the 5.2 floor. 5.0.1's floor was older; tenants on 4.x can upgrade to 5.0.1 without that gate.

**When the apps/moodle Dockerfile is bumped to 5.2.x, this entry becomes a closed item and can be deleted.** Until then, when working with a tenant on the shipped image, mentally translate "5.2-only" facts in this skill to "future state."

---

## 2026-04-28 — `admin/cli/` lives OUTSIDE the webroot in 5.2

In 5.2, the webroot is `<dirroot>/public/`, but `admin/cli/` stays at `<dirroot>/admin/cli/` — outside the webroot, intentionally. This means:

- `curl http://moodle/admin/cli/cron.php` returns 404 in 5.2 (was 200 with auth-bypass risk pre-5.2).
- All CLI invocations must be via `php` directly: `sudo -u www-data php /var/www/html/admin/cli/<script>.php`.
- The webserver has no way to reach these scripts.

This is a security improvement — pre-5.2 sites that didn't set `$CFG->cronclionly = true` were exposing every CLI maintenance script over HTTP.

---

## 2026-04-28 — DB choice in this skill: agnostic, with MariaDB as the implicit default

The Magneto-shipped Moodle uses **MariaDB**. Postgres is supported by Moodle 5.2 (≥16) and is preferred by some operators. This skill aims to be DB-agnostic — every SQL example is shown for both engines where syntax differs (e.g. `ON DUPLICATE KEY UPDATE` vs `ON CONFLICT`), and [reference/stack-and-runtime.md](reference/stack-and-runtime.md) documents the support matrix without picking a winner.

When a playbook uses `mysql` or `psql` in a one-liner, default to `mysql` (matching the shipped image). If the tenant is on Postgres, swap mentally.

---

## 2026-04-28 — Moodle 5.2 split Redis timeouts (MDL-85336)

Pre-5.2: `$CFG->session_redis_timeout = 3` (single value, applied to both connect and read).
5.2: split into `session_redis_connection_timeout` and `session_redis_read_timeout`, both accept floats.

Same applies to `cachestore_redis` admin UI. Documented in [reference/configuration.md](reference/configuration.md) and [reference/caching.md](reference/caching.md) with config-dist.php line refs.

The old single-value setting still works for backward compat — but on a 5.2 deploy, prefer the split values.

---

## Pruning rule

When an entry above is fully covered by a dedicated file under `reference/` or `playbooks/`, **delete it from this file**. Git history retains the original capture. This file should not grow beyond a screenful.
