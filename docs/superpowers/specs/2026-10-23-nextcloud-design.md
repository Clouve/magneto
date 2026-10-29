# Nextcloud app with the AI Assistant

**Date:** 2026-10-23
**Status:** Approved by AJ (2026-10-23). Plans: `docs/superpowers/plans/2026-10-23-nextcloud-{magneto,skill,integration}.md`
**Repos touched:** `magneto` (the app) and `magneto-skills` (a new `nextcloud` plugin)

## Goal

Add Nextcloud to the marketplace as an agent-enabled app, the way WordPress, Moodle, Gibbon and Odoo ship today, and give the AI Assistant a `nextcloud` skill that can run it for a small business: accounts, groups, team folders, sharing, apps, settings, health checks, backups and troubleshooting.

Both halves rest on the Nextcloud 35.0.2 source and on a stock `nextcloud:35.0.2-apache` instance probed during research, not on general Nextcloud knowledge. The appendix lists the facts the design depends on, with their sources.

## Who it's for

Small teams and businesses that want their own file sync and share service: staff accounts, team folders, links for clients, calendars and contacts. The people who talk to the AI Assistant are the business owner or office manager, not developers. The assistant must not lose their files or lock them out.

## Decisions settled with AJ (2026-10-23)

1. The listing speaks to small teams and businesses.
2. The first start installs Calendar, Contacts and Team folders (the `groupfolders` app) from the Nextcloud app store. If the store can't be reached, the start goes on and the assistant can add them later.
3. There is one manifest, titled "Nextcloud with AI Assistant", and no basic twin. The twins were retired on 2026-10-18, since the AI Assistant is now optional at install.
4. Redis runs inside the Nextcloud container, so it adds no container and no price. Web requests, cron and the assistant's `occ` commands share one cache and one lock store.
5. The Nextcloud container gets `memoryBase: 2`. In a test, 24 photo previews generated at once peaked at about 1 GB.
6. At x-small, one 20 GB volume holds `/var/www/html` (code, config, apps and user files), and the database gets 10 GB. Higher tiers multiply both.
7. The defaults:
   - Nextcloud 35.0.2 and MariaDB 12.3, both pinned.
   - The admin login is built from the customer's name, cleaned to Nextcloud's rules. They can also sign in with their email.
   - Background jobs run every 5 minutes, with heavy daily jobs between 01:00 and 06:00 UTC.
   - Trash is kept at most 30 days and file versions at most a year.
   - AppAPI (external apps) is switched off, because Clouve can't run them.
8. The assistant creates shares only for the admin's own files, through a short-lived app password, and sets up Team folders for teams. Other users share their own files, and the assistant explains how.
9. The work gets a full test on the kind rig: push the images to `r.clv.zone/e2eorg`, publish a private test listing on app.clouve.dev, start a trial and check the AI Assistant there, then remove the trial and the listing.
10. The stale twin-manifest text gets fixed in magneto's CLAUDE.md and README, and in the WordPress manifest's header comment.
11. New staff passwords never pass through the chat.
    - When mail works, Nextcloud emails each new person a set-password link (`user:add --generate-password --email`), and nobody sees a password.
    - When it doesn't, a script makes a strong temporary password and saves it to a private file in the AI Assistant's Files pane, never printing it. The admin passes it on, and the person changes it.
12. The admin enters the SMTP password in Nextcloud's own email form (Administration → Basic settings). The assistant walks them through it, then tests delivery and reads the log.

Working rules carried over from earlier work: everything is staged with `git add` and never committed; both repos stay on `develop`; the research clones in `magneto/.research/` are deleted at the end.

## Constraints that shape the design

These come from the platform and from Nextcloud itself. Each is cited in the appendix.

- The first manifest version is final for running deployments. Nothing re-applies a newer manifest to an existing deployment; only a new image reaches it. So the v1 environment and secret set must be complete, and any setting added later must be defaulted in the image.
- There is no startup probe. `x-clouve-healthcheck` becomes both the liveness and the readiness probe, with the same numbers. kubelet sends `Host: <pod IP>`, and Nextcloud answers any host not in `trusted_domains` with HTTP 400.
- A failing readiness probe hides the pod from the agent. Agent-enabled siblings sit behind headless Services, so a pod that isn't Ready drops out of DNS and the assistant loses SSH to it.
- The official image's env-driven config vanishes for `occ` over SSH. `sudo` resets the environment, so the `getenv()`-based fragments in `config/*.config.php` contribute nothing, and PHP's `memory_limit=${PHP_MEMORY_LIMIT}` expands to nothing (128 MB, plus a warning on stdout that breaks `--output=json`).
- Fragments beat config.php. Any `config/*.config.php` value overrides `config.php`, and any config write bakes every fragment and env value into `config.php`, SMTP password included.
- The ingress caps request bodies at 50 MB and times out after 60 s, and TLS ends there. Nextcloud's default upload chunk (the system key `files.chunked_upload.max_size`) is 100 MiB.
- Custom domains and clones rewrite the environment. A custom domain string-replaces the Clouve host in the app's env and restarts the namespace, while the ingress keeps serving both hosts. A clone copies the volumes and rewrites the env to new hosts, but `config.php` on the copied volume keeps the old ones.
- The image's upgrade step wipes unknown files. On every version change the entrypoint `rsync --delete`s `/var/www/html` except `config/`, `data/`, `custom_apps/`, `themes/` and `version.php`. Nextcloud's integrity check also flags any extra file outside `data/`, `config/`, `themes/` and app folders.
- A killed upgrade is never retried, and a failed install exposes the web installer. The entrypoint copies `version.php` before it runs `occ upgrade` or `occ maintenance:install`. A failed install leaves the web installer open on any Host, with the database password in the page source.
- Only a file's owner can create an ordinary share, and only over HTTP. No `occ` command writes `oc_share`. The new `sharing:*` commands in 35 write a separate, experimental store that Files doesn't read.
- Without a shared cache, `occ` changes reach the web pages late: mounts after up to 5 minutes, group names after 10, user display names after up to 24 hours.
- Every container requests 1 GiB of memory and 0.5 CPU from the cluster, whatever its `memoryBase`. Every volume is at least 8 GB and adds to the price.
- Container names may have at most one hyphen, or plan changes skip them.

## Non-goals

- No change to thermo, meso, strato or magneto-agent. The research found no per-app list there that a new app has to join.
- No Collabora/OnlyOffice server, Talk high-performance backend, notify_push, ClamAV, full-text search or ExApps. Each needs another service or a Docker socket. The skill says so.
- No publishing to dev, UAT or prod, no pushes beyond the rig's Harbor, and no merge to `main`. AJ does those.
- No developer-submitted (vanilla) Nextcloud shape in the skill. It targets the Clouve-packaged app and says what it needs.

## Anti-goals

- The assistant changing settings the image re-asserts at every start. The change would look fixed until the next restart.
- A health check that kills the container during an install or upgrade, or hides the pod during maintenance mode.
- Writing passwords into logs, personas, skill files or chat.
- Raw SQL writes to Nextcloud tables.
- The assistant reading or copying users' files without being asked.

## Change set

### A. magneto: the Nextcloud image (`apps/nextcloud/image/`)

#### Base and files

The image starts `FROM nextcloud:35.0.2-apache` (Debian trixie, PHP 8.5, Apache prefork, amd64 and arm64). The official entrypoint stays in place and our wrapper calls it, as the README's "extending official images" pattern says. The official image's environment-driven fragments stay inert, because the manifest sets none of their variables.

It adds `openssh-server` and `sudo` for the clouve-ops channel, `valkey-server` for the in-container cache (the BSD-licensed Redis fork; Debian 13 ships 8.1), and `mariadb-client` for `mariadb-dump` in backups.

| File | Role |
|---|---|
| `Dockerfile` | the above, the clouve-ops user, and the files below |
| `build.config` | `APP_IMAGE="nextcloud"`, `MARIADB_IMAGE="nextcloud-mariadb"`, `MARIADB_NAME="MariaDB"` |
| `installer/entrypoint.sh` | root wrapper; boot sequence below |
| `installer/lib.sh` | shared shell functions (URL parsing, admin-name cleanup, sizing math), so tests can source them |
| `installer/start-clouve-ops-sshd.sh`, `installer/clouve-ops-sshd.conf` | copied from `apps/wordpress/image/installer/`; as in the other apps, only the comments that name WordPress change |
| `installer/start-valkey.sh`, `installer/valkey.conf` | supervised in-container cache |
| `installer/healthcheck.sh` | the probe |
| `installer/nextcloud-config.sh` | the settings re-asserted at every start (run as www-data from the hooks) |
| `installer/hooks/{pre-installation,post-installation,post-upgrade,before-starting}/10-clouve.sh` | copied to `/docker-entrypoint-hooks.d/` |
| `installer/apache-clouve.conf` | HSTS header |
| `context/nextcloud/CONTEXT.md.tpl` | the persona (section D) |

#### Boot sequence

`entrypoint.sh` runs as root, with `set -e` and explicit error handling:

1. Map the platform env to the official image's. Before the first install only (no `version.php` on the volume yet), export `MYSQL_HOST/DATABASE/USER/PASSWORD` from `NEXTCLOUD_DB_*`, so later boots don't carry duplicates into PID 1's environment. Always export a cleaned `NEXTCLOUD_ADMIN_USER` and a decoded `NEXTCLOUD_ADMIN_EMAIL`. PID 1 then holds the real login, and that's what the agent's env fetcher reads.
   - Cleanup: decode HTML entities (the platform delivers `O&apos;Brien`), transliterate to ASCII with PHP's intl, map anything outside `a-zA-Z0-9 _.@-'` to `_`, trim (leading hyphens too, since `occ` would read a login like `-x` as an option), cap at 64 characters, and fall back to `admin` when the value is empty, unfilled (`{user.`) or `null`/`undefined`.
2. Write the PHP limits as literal values to `conf.d/zz-clouve.ini`: `memory_limit`, `upload_max_filesize`, `post_max_size` from the image's env defaults, plus `apc.shm_size=64M`. `occ` over SSH then gets the same limits as Apache, with no stdout warning.
3. Size Apache and previews to the container's memory (cgroup v2 `memory.max`, v1 fallback, `max` meaning unlimited). Write `conf-enabled/zz-clouve-mpm.conf` with `MaxRequestWorkers` = memory MB / 50, clamped to 10..150. Export the preview concurrency for the hook. Defaults when unlimited: 150 workers, previews 4/8.
4. Start Valkey on a unix socket (`/run/clouve/valkey/valkey.sock`, mode 700, user www-data, no persistence, `maxmemory 128mb`, `allkeys-lru`) under a small restart loop. Wait up to 30 s for `PING`.
5. Start the clouve-ops sshd in the background, gated on `CLOUVE_OPS_PASSWORD`. It starts early, so the agent can fetch the persona while Nextcloud installs. That also keeps it well inside the agent's rule that sshd must answer within 90 s of Apache.
6. Wait for the database with a PHP PDO connect, for at most 5 minutes, then `exit 1`. A plain PDO connection avoids client TLS quirks.
7. Start cron in a background job that waits until `config.php` says `installed`, then runs `busybox crond -f -L /dev/stdout`. It reuses the image's root-owned `www-data` crontab (`*/5 * * * * php -f /var/www/html/cron.php`). Cron jobs inherit crond's full environment (verified).
8. `exec /entrypoint.sh apache2-foreground`. The official entrypoint does the rsync, the install or upgrade (under its flock on `nextcloud-init-sync.lock`), the hooks, then Apache.

#### Hooks

The official entrypoint runs these as www-data, with the environment preserved:

- `pre-installation`: delete `config/CAN_INSTALL`, so a half-finished install can never show the web installer (tested upstream behaviour: `occ maintenance:install` works without it).
- `post-installation` (once, inside the install lock):
  - run `nextcloud-config.sh`;
  - set the admin's email;
  - `background:cron`, `maintenance_window_start=1`, `maintenance:repair --include-expensive`;
  - retention `trashbin_retention_obligation="auto, 30"` and `versions_retention_obligation="auto, 365"`;
  - `app:disable app_api`, `files_external_allow_create_new_local=false`, `files_sharing hide_disabled_user_shares=yes`, `updatechecker=false`, `serverid=1`;
  - `app:install calendar`, `contacts`, `groupfolders`, each non-fatal, logged and bounded at 300 s (then `app:enable` when the app is already on disk).
- `post-upgrade`: `db:add-missing-indices`, `db:add-missing-columns`, `db:add-missing-primary-keys`, `maintenance:repair --include-expensive` (`nc_post_upgrade_steps` in `lib.sh`). They delete the marker `clouve post_upgrade_done` first and write the version to it last. When maintenance mode is on as they begin and that marker is missing, a start cut off during them left it on, and `occ upgrade` kept it, so it goes off first. If it can't, they run but write no marker. When they can't delete the marker, they don't run at all, so a cut-off run can't leave an older version behind.
- `before-starting` (every start):
  1. refuse to start when Nextcloud is not installed (exit 1);
  2. resume an interrupted upgrade: when `occ status` says `needsDbUpgrade`, turn maintenance off if the interrupted run left it on and reset `loglevel` from 0 to 2, then take the init lock and run `occ upgrade` and the post-upgrade repairs under it (when that first `--off` fails, it is tried once more after a successful upgrade). The order matters: `occ upgrade` never turns off a maintenance mode it found on, so a second kill during the repairs would otherwise leave the site in maintenance for good (found in a drill);
  3. run `nextcloud-config.sh`;
  4. when the marker that the post-installation steps write last (the app config value `clouve first_install_done`) is missing, which means a first start was cut off during them, run the same steps again (`nc_first_install_steps` in `lib.sh`) under the init lock. They also write `clouve post_upgrade_done`, since a fresh install needs no post-upgrade steps;
  5. when `clouve post_upgrade_done` is missing (a cut-off run: the steps delete it first, and don't run when they can't) or names another version (the steps never began for this one, as after an upgrade the assistant finished at runtime), run `nc_post_upgrade_steps` under the init lock.

  The steps that 4 and 5 run both include `occ maintenance:repair`, which turns maintenance mode on for its run and puts the old value back only at its end, so a kill during it leaves maintenance on with nothing pending. A missing marker is a cut-off run: when maintenance mode is on, they turn it off first and log why. A post-upgrade marker for another version leaves maintenance mode as it is, since the steps never began. They wait for a later start while an upgrade is pending or a restore was cut off. A repair that dies on the way (an Error that occ doesn't catch) also leaves maintenance on, so the step functions turn it off again, and they write no marker when they can't.

The root entrypoint handles the AI Assistant's markers in `data/clouve-backups/`, which only root can enter. It notes `RESTORE-IN-PROGRESS` in `/run/clouve/restore-cut-off` for the hooks. When `BACKUP-IN-PROGRESS`, which `backup.sh` keeps and holds an exclusive `flock` on while it holds maintenance mode on, survived a kill, it turns maintenance mode off and removes the marker. It does neither while the lock is held (a backup is still running), a restore was cut off, or an upgrade is pending.

#### Settings re-asserted at every start

`nextcloud-config.sh` is idempotent, since Nextcloud only writes on change:

- `dbhost`, `dbname`, `dbuser`, `dbpassword` from `NEXTCLOUD_DB_*` (clones move the DB host);
- `overwrite.cli.url` = `NEXTCLOUD_URL`. When it differs from the stored value, log `Nextcloud URL has changed: <old> -> <new>` (the `./test.sh` contract);
- `overwriteprotocol=https` when the URL is https, deleted when http (local runs);
- `trusted_domains`: add `localhost` and the URL's host when missing, keeping every earlier entry (a custom domain leaves the Clouve host working);
- `trusted_proxies` = `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16`, the same ranges the image's Apache already trusts for `X-Real-IP`. This clears the "reverse proxy header" error without changing how client IPs are found;
- `memcache.distributed` and `memcache.locking` = `\OC\Memcache\Redis`, with `redis` = the socket (`port 0`);
- `preview_concurrency_new` / `preview_concurrency_all` from the memory sizing (1 GiB: 1/2, 2 GiB: 2/4, 4 GiB and up: 4/8);
- `files.chunked_upload.max_size` = 40 MiB (41943040) when it is unset, 0 or less, or above 50 MiB (52428800). A value of 0 or less turns chunking off, so every browser upload would be one request and anything over 50 MiB would get 413. An admin's value from 1 byte to 50 MiB stays. This system key is what Nextcloud 35 reads; the app key `files max_chunk_size` has no effect.

`overwritehost` is left unset on purpose. It would make every Host trusted, but once a customer adds a custom domain whose DNS isn't live yet, logins on the Clouve host would redirect to a host that doesn't resolve. `trusted_domains` plus `overwriteprotocol` keeps both hosts working.

#### Health check

The probe runs `healthcheck.sh` through `sh -c`:

- It reports healthy while the init lock is held (install, upgrade or upgrade recovery), so a long upgrade is never killed.
- It reports unhealthy when Valkey doesn't answer `PING`.
- Otherwise it runs `curl -fsS -m 10 -H 'Host: localhost' http://127.0.0.1/status.php` and reports healthy when the JSON says `"installed":true`. That covers maintenance mode and a pending upgrade, which both return 200, so the pod stays reachable for the assistant while it fixes them.
- HTTP 500 (database down) or no answer is unhealthy.

The manifest uses Moodle's budget: `initialDelay 60`, `interval 30`, `timeout 15`, `failureThreshold 15` (about 8.5 minutes before a restart), `successThreshold 1`.

#### Apache

- HSTS `max-age=15552000`, without `includeSubDomains`, for the setup check's `http://localhost` fallback. The ingress sends its own on TLS hosts.
- A `RewriteRule` for `/.well-known/(carddav|caldav)` to `https://%{HTTP_HOST}/remote.php/dav/`, inside the `<VirtualHost *:80>` (verified upstream; a `conf-enabled` file does nothing). It applies only when `X-Forwarded-Proto` is `https`, so local http runs keep the stock redirect. Without it, calendar and contact apps get an `http://` redirect behind the TLS ingress.

### B. magneto: the database image (`apps/nextcloud/image/mariadb/`)

- `FROM mariadb:12.3`, pinned like WordPress's (12.3 is `mariadb:lts` and the top of Nextcloud 35's supported range).
- The clouve-ops sshd kit from `apps/wordpress/image/mariadb/` (only the comments that name WordPress change), and WordPress's wrapper entrypoint with the buffer-pool sizing below added.
- `ENV MARIADB_AUTO_UPGRADE=1`, set in the image because a later manifest can't reach running deployments.
- `/etc/mysql/conf.d/nextcloud.cnf`:
  - `transaction_isolation=READ-COMMITTED`, `binlog_format=ROW`;
  - `character_set_server=utf8mb4`, `collation_server=utf8mb4_bin`, `innodb_file_per_table=1`;
  - `innodb_log_file_size=256M` (clears the serverinfo advisor's warning below 128 MB);
  - `max_connections=200`, `skip_name_resolve=1`.
- The wrapper writes `innodb_buffer_pool_size` = a quarter of `memory.max` (128 MB to 4 GB) at each start.

### C. magneto: manifests

The environment for `nextcloud` in `clv-docker-compose.yml`, with every value quoted and non-empty:

| Variable | Value | Type |
|---|---|---|
| `NEXTCLOUD_DB_HOST` | `nextcloud-mariadb` | containerReference |
| `NEXTCLOUD_DB_NAME` | `nextcloud` | static |
| `NEXTCLOUD_DB_USER` | `nextcloud` | static |
| `NEXTCLOUD_DB_PASSWORD` | `nextcloud-mariadb-password` | secret |
| `NEXTCLOUD_URL` | `http://localhost` | applicationUrl |
| `NEXTCLOUD_ADMIN_USER` | `{user.firstName}_{user.lastName}` | applicationUsername |
| `NEXTCLOUD_ADMIN_EMAIL` | `{user.userEmail}` | applicationUsername (shown with the password, since email sign-in works) |
| `NEXTCLOUD_ADMIN_PASSWORD` | `nextcloud-admin-password` | applicationPassword |

- `NEXTCLOUD_DB_*` names pass through to the agent unchanged, and `_DB_HOST/_DB_NAME/_DB_USER` are the names the persona composer can render. No `_PORT` names, since the agent drops them.
- `nextcloud-mariadb` gets `MYSQL_DATABASE`, `MYSQL_USER` (static), `MYSQL_PASSWORD: nextcloud-mariadb-password` (the same placeholder, so the same generated value) and `MYSQL_ROOT_PASSWORD: nextcloud-mariadb-root-password`.
- Metadata:
  - `nextcloud`: purpose `Frontend`, `isPublic: true`, `memoryBase: 2`, `cpuBase: 1`, port `'80:80'`, volume `nextclouddata:/var/www/html` at 20 GB.
  - `nextcloud-mariadb`: purpose `Database`, `memoryBase: 1`, `cpuBase: 0.5`, health check disabled as in the other apps, volume `dbdata:/var/lib/mysql` at 10 GB.
- `x-clouve-bundle-metadata`: `appVersion: 35.0.2`, `appTitle: Nextcloud with AI Assistant`, `adminPath: /settings/admin`, and an `appDescription` of at most 1000 characters (humanized, claims limited to what ships).
- `x-clouve-agent`: `enabled: true`, `skills.url: https://github.com/Clouve/magneto-skills.git?plugins=nextcloud`, `advanced.sidecarPullTimeout: 600`. No `CLOUVE_OPS_PASSWORD`, `MAGNETO_AGENT_*` or `CLV_SIDECAR_*`: the platform adds them.

The local `docker-compose.yml` follows WordPress's shape:
- `nextcloud` first, then `nextcloud-mariadb` (container name contains `mariadb`, `healthcheck.sh --connect --innodb_initialized`), then `magneto-agent`.
- `NEXTCLOUD_URL: http://${TEST_DOMAIN:-t1.test.clv}:${TEST_PORT:-8080}`, port `${TEST_PORT:-8080}:80`.
- `CLOUVE_OPS_PASSWORD` on all three; the agent with `CLV_SIDECAR_HOSTS/NAMESPACES: nextcloud,nextcloud-mariadb` and the LLM pass-through variables.

### D. magneto: the persona (`image/context/nextcloud/CONTEXT.md.tpl`)

- The same four sections as the other personas: Operator Persona & Domain, Cross-container shell access (clouve-ops), Default Operating Posture, Skill Maintenance.
- Braces only around names the composer renders: `${NEXTCLOUD_HOST}`, `${NEXTCLOUD_DB_HOST}`, `${NEXTCLOUD_DB_NAME}`, `${NEXTCLOUD_DB_USER}`.
- Passwords are named in backticks and fetched in the two-part form. Each ssh command carries its own password, as `SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh …`, with no `export SSHPASS`: the assistant's shell keeps no variable from one command to the next. (Changed during the integration run; `tests/persona-hosts.test.sh` holds the persona to it.)
- `occ` is run as `sudo -u www-data php /var/www/html/occ … -n`.
- The posture rules:
  - user data is private;
  - the image re-asserts its settings (do not fight them);
  - core comes from the image;
  - destructive commands are gated;
  - no SQL writes;
  - no server-side encryption;
  - capacity is paid;
  - never expose the AI key;
  - clouve-ops is root-equivalent.

### E. magneto: README, logo, docs and tests

- `apps/nextcloud/README.md` (humanized) and `logo.png` (256×256, rendered from the official `logo.svg` with the image's ImageMagick).
- Repo docs:
  - `CLAUDE.md`: Nextcloud in the app list and test commands, plus the twin-manifest paragraph rewritten as retired.
  - `README.md`: the "Basic (AI-disabled) Twin Manifest" section rewritten the same way.
  - `DEVELOPER_GUIDE.md`: app lists.
  - The WordPress manifest's header comment.
- `tests/persona-hosts.test.sh`: add `nextcloud` to the database-password case, plus `NEXTCLOUD_DB_PASSWORD` and `NEXTCLOUD_ADMIN_PASSWORD` sentinels.
- New `tests/nextcloud-image.test.sh`, run inside `nextcloud:35.0.2-apache` with no network (as the Moodle test runs in its base image), since the name cleanup needs the image's PHP intl: it sources `lib.sh` and checks the admin-name cleanup, URL parsing, `trusted_domains` merging with a fake `occ`, the sizing math, and `healthcheck.sh` states with fake `curl`, `flock` and `valkey-cli`. `tests/nextcloud-mariadb.test.sh` builds the database image and checks its settings and buffer-pool sizing. `tests/nextcloud-manifest.test.sh` checks the manifest against the platform's rules.

### F. magneto-skills: the `nextcloud` plugin

The plugin's layout:
```
plugins/nextcloud/
├── .claude-plugin/plugin.json
├── install.sh                     # default-mysql-client; openssh-client, sshpass, jq, curl if missing
└── skills/nextcloud/
    ├── SKILL.md                   # type devops, version 0.1.0, authoredAgainst: nextcloud v35.0.2
    ├── learnings.md
    ├── reference/                 # README index + topic files
    ├── playbooks/
    └── scripts/
```

The skill uses three channels:
1. `occ` over SSH into the Nextcloud container, the main one.
2. HTTP to `${NEXTCLOUD_HOST}` with the public `Host:` header, only for what `occ` can't do: the owner's shares, and the probes.
3. TCP MySQL, for read-only diagnostics.

Each script has a usage line and exit codes, never uses `set -x`, and loads its secrets with the repo's loader line:

| Script | Runs in | Does |
|---|---|---|
| `scripts/occ.sh` | agent | Runs one `occ` command as www-data over SSH with safe quoting (`printf %q`), `-n --no-warnings`, stdin closed. `--password-stdin` passes a password as `NC_PASS` through the SSH channel's stdin and `sudo --preserve-env`, so it never appears in a command line. |
| `scripts/verify-health.sh` | agent | Read-only report: SSH to both siblings, `occ status`, `status.php` and the login page over HTTP, database over TCP, Valkey, cron freshness (`lastcron`), background-jobs mode, setup checks by severity, disk use, the URL settings against `NEXTCLOUD_URL`. GREEN/AMBER/RED, exit 0/2/3. |
| `scripts/run-in-nextcloud.sh` | agent | Sends `backup.sh` or `restore.sh` into the Nextcloud container and runs it there as root, either waiting for it (`sudo bash -s --`, the Odoo pattern) or detached with `--detach`, so a long run outlives the chat session and a dropped SSH session. (The assistant's Bash tool gives a command 2 minutes unless the call asks for up to 10, and then moves it to the background rather than stopping it; what ends a plain run early is the session or the connection ending.) `--status <job>` shows the log's tail and whether the job finished. |
| `scripts/backup.sh` | Nextcloud container, sent by `run-in-nextcloud.sh` | `mariadb-dump --single-transaction --default-character-set=utf8mb4`, `config/` (0600), `custom_apps/` and `themes/`, and with `--with-data` the users' files (previews and the backups folder excluded) after a free-space check. Maintenance mode is on for the dump unless `--no-maintenance`. Writes `data/clouve-backups/<UTC time>/` with a manifest and checksums. Credentials come from `config.php`, because `sudo` drops the env. Never prunes on its own. |
| `scripts/restore.sh` | same | Restores a backup made by `backup.sh`: maintenance on, empty the database and import the dump, put back `config.php` (keeping the backup's `secret`, `passwordsalt` and `instanceid`), apps and themes, and the data when included. Then `maintenance:data-fingerprint`, `files:scan --all` only when the data was restored whole, maintenance off. Refuses without the confirm flag. |
| `scripts/share-as-admin.sh` | agent | Creates, lists or revokes shares of an admin's own files through the files_sharing OCS API. It mints an app password with `occ user:auth-tokens:add` into a variable (never printed), calls OCS with `sendMail=false` by default, and deletes the token in a trap. Refuses accounts outside the `admin` group. A link password, when asked for, is generated and saved like `temp-password.sh` does. |
| `scripts/temp-password.sh` | agent | Gives an account a strong temporary password without showing it. It makes 20 characters from an unambiguous alphabet (passes Nextcloud's password policy), sets it with `occ.sh --password-stdin` (`user:add --password-from-env` with `--create`, else `user:resetpassword --password-from-env`), and writes it to `~/nextcloud-passwords/<uid>-<UTC date>.txt` (mode 600) in the agent user's home, which the Files pane shows. It prints only the file name. `--remove <file>` deletes a handed-over file. |

#### Passwords and the chat

Anything the assistant prints goes to the AI model and stays in the chat history. So:
- A new account gets an email invite when mail works, or `temp-password.sh` when it doesn't (decision 11). The playbook asks the admin which they want, and recommends email once a test message has arrived.
- The admin's own lockout is fixed by resetting their password back to the one on the Clouve dashboard. The two-part form is piped into `occ.sh --password-stdin`, so the value is never printed.
- SMTP credentials go into Nextcloud's own form (decision 12). The assistant checks the result with `config:list system`, which redacts them, and with the log.
- Users create their own app passwords for desktop and phone clients, usually through the clients' browser login. The assistant never mints one for another person.
- The assistant never asks for a password in chat. If someone pastes one anyway, it uses it only for that task and suggests changing it afterwards.

#### References, playbooks and limits

Each reference fact comes from the 35.0.2 source, with links to the `v35.0.2` tag:

| File | Covers |
|---|---|
| `shell-access.md` | the channels; how to run `occ`; `-n` defaults and lying exit codes; commands missing in maintenance mode |
| `stack-and-runtime.md` | containers, volumes, paths, processes; what the image does at every start (the do-not-fight list); 50 MB / 60 s limits |
| `configuration.md` | config.php vs fragments; managed keys; reading config without printing secrets; mail; retention; previews |
| `users-and-groups.md` | id rules, create/disable/delete consequences, quotas and their traps, passwords, 2FA, app passwords, transfer of ownership |
| `files-and-sharing.md` | data layout, `files:*`, scan traps, trash and versions, share types and permissions, sharing policy keys, `share:list`, Team folders and their ACLs |
| `apps.md` | shipped vs store apps, install/update/remove, upgrade compatibility, what can't run on Clouve |
| `backup-restore.md` | what a backup is, the two scripts, restore order, `secret`, the scan trap |
| `upgrade.md` | image-driven upgrades, one major at a time, the start-time recovery, what to check after |
| `security.md` | brute force (429 after 10 failures), rate limits, password policy, 2FA, logs, `config:list` vs `get`, encryption risks |
| `cron-and-background-jobs.md` | how cron runs here, the maintenance window, stuck jobs |
| `http-api.md` | OCS and WebDAV from the agent: Host header, `OCS-APIRequest`, app passwords, password confirmation |
| `data-model.md` | key tables, read-only diagnostic queries, the never-write rule |
| `troubleshooting.md` | symptom → cause → fix |

The playbooks:
- onboard users and groups (email invite, or a temporary password in a private file);
- offboard a user (disable, transfer, then delete only with ack);
- set up team folders;
- share files and manage links;
- install or update an app;
- configure email (the admin fills in Nextcloud's form; the assistant tests and reads the log);
- harden a fresh install;
- diagnose problems;
- recover a stuck upgrade or maintenance mode;
- back up / restore;
- fix files that are out of sync;
- regain admin access (reset to the dashboard password over stdin; brute-force and 2FA resets);
- free up space.

The skill states what it can and can't do up front:

| | Operations |
|---|---|
| Works out of the box | Users, groups, Team folders, quotas, 2FA resets; first passwords by email invite or a private file; listing all shares and sharing the admin's own files; apps from the store; system and app settings; maintenance mode, repairs, indices, background jobs, logs, brute-force resets; health checks, backups and restores; recovery after a stuck upgrade |
| Needs the customer or extra setup | SMTP (the admin fills in Nextcloud's form), external storage, LDAP, desktop and mobile clients, custom domains and plan changes (Clouve dashboard), other users' own shares |
| Not available on this deployment | Office editing server, Talk high-performance backend, Client Push, antivirus, full-text search, ExApps, the web updater, reading the container's stdout logs, restarting the pod |

Every flow enforces these gates. "Ack" means the exact command is shown and the user says yes:

| Action | Gate |
|---|---|
| `user:delete` | suggest disable and transfer first; ack; never in maintenance mode |
| `group:delete`, `groupfolders:delete` | list what goes (shares, apps restricted to the group, the folder's files); ack |
| `versions:cleanup`, `trashbin:cleanup`, `files:delete --skip-trash` | always scoped to named users or paths; ack |
| Quota below current usage | warn that it blocks that user's downloads and purges trash and versions; ack |
| `files:scan --all` | only when the data volume is complete; ack |
| Third-party app install | read its info.xml and source, backup, ack |
| Maintenance mode on | announce (users get 503); ack |
| A setting the image re-asserts | refuse; explain where it comes from |
| `config:system:get` / `config:app:get` of a secret, `config:list --private` | refuse |
| Printing any password, or asking for one in chat | refuse; use an email invite, `temp-password.sh`, or Nextcloud's own forms |
| A password in a command line (`--value=`, `-p`) | refuse; pass it on stdin (`--password-stdin`, `NC_PASS`) |
| `encryption:*` | decline by default; explain the data-loss risks |
| SQL writes | refuse; use `occ` or the API |
| Reading a user's file contents | only when asked by that user or the admin, with ack |
| Restore | fresh backup of the current state first; ack |
| CPU, memory or volume changes | refuse; the plan is paid |

### G. magneto-skills: repo-level files

- `.claude-plugin/marketplace.json`: the `nextcloud` entry between `moodle` and `odoo`, same description as `plugin.json` and `SKILL.md`.
- `README.md`: a Plugins table row. `CHANGELOG.md`: an "Unreleased" entry.
- `CLAUDE.md`: `NEXTCLOUD_` in the list of agent-side secret prefixes.
- `tests/skills-env-values.test.sh`: `NEXTCLOUD` in the prefix list and `nextcloud` in the `learnings.md` loop.
- New tests:
  - `tests/nextcloud-scripts.test.sh`: runs the scripts against fake `ssh`, `sshpass`, `curl`, `mysql` and `php` binaries, as `moodle-verify-health.test.sh` does.
  - `tests/nextcloud-skill-commands.test.sh`: fails on an `occ` call that isn't the approved form, `config:list --private`, `config:system:get` of a secret key, an unscoped `versions:cleanup`, a password passed as an argument (`--value=` on a password key, `user:resetpassword` without `--password-from-env`), or `$SKILL_DIR`.

## Verification

1. Builds: `./build.sh nextcloud` builds both images (amd64). Also a `docker buildx build --platform linux/arm64` of each without pushing.
2. Static checks: `./check-manifests.sh`; `bash tests/persona-hosts.test.sh`; `bash tests/nextcloud-image.test.sh`; `shellcheck` on every new script; magneto-agent's `context-composer.test.sh` with magneto beside it.
3. Local run (`./start.sh nextcloud`):
   - the install completes, with Calendar, Contacts and Team folders installed;
   - `status.php`, the login page and an admin login work;
   - `occ setupchecks` leaves only info items (email, 2FA, phone region);
   - Valkey answers, and cron runs within 5 minutes;
   - SSH as clouve-ops works into both containers.
4. URL change: `./test.sh apps/nextcloud` passes.
5. Failure drills:
   - kill the container during `occ upgrade` and restart (recovery hook);
   - start with a half-installed volume (refuses to start; no web installer);
   - stop the database (probe fails, then recovers).
6. Skills checks: `claude plugin validate .`; `bash tests/skills-env-values.test.sh`; the two new tests; `shellcheck`.
7. Agent integration (local compose):
   - stage the plugin into the agent container by hand, as the stager would;
   - run its `install.sh` and check the composed `CLAUDE.md`;
   - then run `verify-health.sh`, `occ.sh`, `temp-password.sh` (create, sign in as that user, remove the file), a backup/restore round trip, `share-as-admin.sh` (a link share) and a Team folder setup.
8. Rig e2e:
   - `./build-e2e.sh nextcloud --push`;
   - publish a private listing on app.clouve.dev and start a trial;
   - pods Ready, credentials shown, login over https, setup checks;
   - the agent fetches the persona; skill staged by hand; `verify-health.sh` GREEN;
   - remove the trial and the listing.
9. Review: an independent code review of both change sets, a secrets review, the humanizer pass on prose, and a check that only intended files are staged.

## Risks

1. Valkey inside the app container is a new pattern for magneto. If it dies, Nextcloud requests fail until the restart loop brings it back (seconds), and the probe catches a stuck loop. Accepted for the cost saving (decision 4).
2. The pod can be Ready before Apache listens. The probe reports healthy while the init lock is held, so during a first install or upgrade the ingress can return 502 for a minute or two. The alternative, a liveness kill mid-upgrade, is worse.
3. The credentials panel shows the raw name (`José_García`), while Nextcloud's login may be `Jose_Garcia`. Email sign-in works, and the persona tells the assistant to confirm the real login with `occ user:list`.
4. Uploads are capped at 50 MB per request. Browser uploads chunk at 40 MiB, because the image keeps `files.chunked_upload.max_size` there at every start. A desktop client or WebDAV tool that sends bigger single requests gets 413 until its chunk size is lowered. Documented in the skill and the README. The ingress limit itself is a platform setting.
5. The first start depends on the app store. A failure is non-fatal, but the first-start apps float with the store's current versions. Each first-start app install is bounded at 300 s, but an `occ upgrade` that downloads an app has no time limit under occ (`lib/private/Installer.php:238`), so a stalled store download during an upgrade holds the init lock while the probe reports healthy. The official entrypoint's own upgrade can't be bounded.
6. The skill reaches tenants only from `main`. Until AJ merges magneto-skills, a deployment of this listing gets no skill and no persona section.
7. Platform issues found on the way, not fixed here and reported to AJ:
   - the "Upgrade" action recreates nothing for Tropo listings;
   - a paid install with a custom domain in its form likely stays at 0 replicas;
   - clones of apps sorting after `magneto-agent` likely get the wrong `MAGNETO_AGENT_HOST`;
   - `skills.git.token` is replaced by a random string;
   - `./test.sh` passes vacuously for Moodle, Gibbon and Odoo;
   - existing skills cite an undefined `$SKILL_DIR`.

## Calls made without asking (for review)

- Valkey rather than Redis 8, for its BSD license.
- No `overwritehost`, so both hosts keep working (see A).
- `trusted_proxies` set to the private ranges the image's Apache already trusts.
- Adaptive Apache workers, preview concurrency and InnoDB buffer pool from the container's memory.
- `updatechecker=false` (core updates come from the image), `serverid=1`, `files_external_allow_create_new_local=false`, `hide_disabled_user_shares=yes`, and 40 MiB upload chunks (`files.chunked_upload.max_size`, set again at every start).
- HSTS without `includeSubDomains`, and the vhost-level `.well-known` fix.
- `MARIADB_AUTO_UPGRADE=1` in the database image.
- Backups stay on the data volume under `data/clouve-backups/`. That name can never become a user id, because Nextcloud refuses ids that match an existing data-folder entry. Backups are never pruned automatically.
- Design and plans live in `magneto/docs/superpowers/`, as the Odoo work did.
- A seventh script, `run-in-nextcloud.sh` (added while writing the plans): a backup with users' files can run for a long time, a plain run ends when its session or SSH connection does (the assistant's Bash tool moves a command past its time limit to the background, but can't keep it going when the session ends), and a restore cut off half-way would leave a broken instance.
- A restore that fails after it has started leaves maintenance mode on and a `RESTORE-IN-PROGRESS` marker that `verify-health.sh` reports, so nobody writes into a half-restored instance.

## Appendix: ground truth (Nextcloud 35.0.2 and the platform)

Server paths are relative to `https://github.com/nextcloud/server/blob/v35.0.2/`. `docker:` is `https://github.com/nextcloud/docker/tree/master/35/apache` (`35.0.2` as of 2026-10-23). "Probed" means observed on a stock `nextcloud:35.0.2-apache` instance with `mariadb:12.3` during research.

#### Host, proxy and probes
- Trusted-domain check, before routing: `lib/OC.php:937-976`. `localhost`, `127.0.0.1` and `[::1]` are always trusted (`lib/private/Security/TrustedDomainHelper.php:72-75`). A non-empty `overwritehost` trusts every host (`:59-62`).
- An untrusted host gets 400, and `status.php` returns `{"error": "Trusted domain error.", "code": 15}` (`lib/OC.php:952-957`; probed).
- `status.php` returns 200 in maintenance mode and with an upgrade pending, and 500 when the database is down (`status.php:25-51`; probed).
- `ForwardedForHeaders` errors when `trusted_proxies` is empty and `X-Forwarded-Host` is present (`apps/settings/lib/SetupChecks/ForwardedForHeaders.php:68-73`).
- The image's Apache rewrites `REMOTE_ADDR` from `X-Real-IP` for 10/8, 172.16/12 and 192.168/16 (`docker:Dockerfile:138-145`), so Nextcloud ignores `X-Forwarded-Proto` unless `overwriteprotocol` is set.

#### Config loading
- Fragments merge after `config.php` and win (`lib/private/Config.php:201-258`). Writes serialise the whole merged cache (`:281-332`).
- The image's fragments read `getenv()` at runtime (`docker:config/*.config.php`). `sudo` and SSH sessions lack the container env. Probed: PHP prints "Failed to set memory limit to 0 bytes" and runs at 128 MB.

#### Install and upgrade
- The entrypoint copies `version.php` before installing or upgrading, and only installs or upgrades when the volume's version is older (`docker:entrypoint.sh:176-212`). Hooks run via `su -p` as www-data; a failing hook stops the start (`:14-20,43-47`).
- An install cut off after the admin user exists never recovers, and the next start serves the web installer on any Host with the DB password in its initial state. Removing `config/CAN_INSTALL` closes that (`core/Controller/SetupController.php:48-51`).
- A killed `occ upgrade` leaves `maintenance=true`, the old `version` and `loglevel=0`. `maintenance:mode --off` followed by `occ upgrade` recovers it; the other order can leave maintenance on, because the Updater only turns off a maintenance mode it turned on itself (`lib/private/Updater.php:78-129`).
- In maintenance mode or with an upgrade pending, only core commands load (`lib/private/Console/Application.php:85-151`).

#### Cron
- `cron.php` skips silently when not installed, in maintenance mode or with an upgrade pending. It must run as the owner of `config.php`, and its first CLI run sets `backgroundjobs_mode=cron` (`core/Service/CronService.php:71-140`).
- BusyBox crond needs root-owned crontabs and passes its own environment to jobs (probed).

#### Caching
- Without Redis, the distributed cache falls back to APCu and locking to the database (`lib/private/Memcache/Factory.php:56-107`, `lib/private/Server.php:868-887`). APCu isn't shared between Apache and CLI processes (probed).

#### Database
- `SupportedDatabase` accepts MariaDB 10.11 to 12.3, MySQL 8.4 to 9.7 and PostgreSQL 14 to 18 (`apps/settings/lib/SetupChecks/SupportedDatabase.php:20-27`).
- The serverinfo advisor warns below `innodb_log_file_size` 128 MB. MariaDB 12.3's default is 96 MB (probed).

#### Users and files
- User ids allow `a-zA-Z0-9`, space and `_.@-'`, up to 64 characters, and not the name of an existing data-folder entry (`lib/private/User/Manager.php:747-858`).
- `user:delete` is immediate and permanent and bypasses the trash. With no quota, trash and versions may grow until the volume is full. `files:scan` drops entries for missing files, and shares go with them (`lib/private/User/User.php:256-336`; `apps/files_trashbin/lib/Trashbin.php:865-890`; `lib/private/Files/Cache/Scanner.php:243-247`).
- A quota below usage blocks the owner's reads too (`lib/private/Files/Storage/Wrapper/Quota.php:125-134`).

#### Sharing
- `ShareAPIController` acts only as the authenticated user, with no admin override (`apps/files_sharing/lib/Controller/ShareAPIController.php:1597-1601`).
- The unified Sharing API is off unless `sharing.unified_api_enable` (`lib/private/Sharing/SharingManager.php:160-163`).
- `occ share:list` lists every share (`apps/files_sharing/lib/Command/ListShares.php`).

#### Team folders
- groupfolders 23.0.1 needs Nextcloud 35 exactly (`appinfo/info.xml`).
- `groupfolders:delete` removes the folder and its files after a y/N prompt, which `-n` answers no. Permissions are `read write share delete` (`lib/Command/Delete.php`, `lib/Command/Group.php:23-27`).

#### Uploads
- The chunk size of browser uploads is the system key `files.chunked_upload.max_size`, 100 MiB when unset (`apps/files/lib/Service/ChunkedUploadConfig.php:16-21`). `lib/private/Template/JSConfigHelper.php:262-264` hands it to the web UI, and the files app's capabilities advertise it (`apps/files/lib/Capabilities.php:44-47`). The app key `files max_chunk_size` is read only by the migration `apps/files/lib/Migration/Version2003Date20241021095629.php`, which moved it to the system key once. Probed: after `config:app:set files max_chunk_size` both `ChunkedUploadConfig::getMaxChunkSize()` and the capabilities still give 100 MiB, and after `config:system:set files.chunked_upload.max_size --type=integer --value=41943040` both give 40 MiB. The web UI's uploader (in `dist/files-main.js`) treats a value of 0 or less as no chunking and sends the whole file in one request.

#### Previews
- Preview concurrency defaults follow the host's CPU count (`lib/private/Preview/Generator.php:289-314`).
- Probed: 24 parallel previews of 24-megapixel JPEGs peaked at 1.03 GiB.

#### Platform
- Probes, ConfigMaps and Secrets: `thermo/app/internal/generator/templates/deployment.yaml.tmpl:59-163`. Secrets are random 10-character values keyed by placeholder: `thermo/templates/manifests/__defaults__/.agent-config/launch/kube/secrets.yaml.tmpl:12`.
- The agent's env projection and secret routing: `magneto-agent/image/installer/chat/marketplace/sidecar-env-fetcher.sh:139-283`. The persona allow-list: `context-composer.sh:60-75`.
- Custom-domain rewrite: `strato/app/helpers/apply_dns.go:683-882`. Clones: `strato/clv-agent/k8s/manifests/clone_rename_resources.jq`.
- The ingress body limit: `thermo/app/internal/generator/templates/ingress.yaml.tmpl:10`. Client IPs are kept on cloud clusters (ingress-nginx `controller-v1.12.1` cloud manifest, `externalTrafficPolicy: Local`).
