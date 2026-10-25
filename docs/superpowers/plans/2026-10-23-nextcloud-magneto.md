# Nextcloud app (magneto) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `apps/nextcloud/` in magneto: a Nextcloud 35.0.2 image and a MariaDB 12.3 image that run safely on Clouve, with the marketplace manifest, the local compose, the AI Assistant persona, docs and tests.

**Architecture:** Our root entrypoint wraps the official `nextcloud:35.0.2-apache` entrypoint. It cleans and maps the platform's env, writes PHP and Apache limits as literal files, starts Valkey, the clouve-ops sshd and cron, waits for the database, then hands over. Entrypoint hooks re-assert the settings that must live in `config.php` at every start, apply first-install defaults, and recover an interrupted upgrade. A Command probe reads `status.php` on localhost and stays healthy while the init lock is held.

**Tech Stack:** Docker (Debian trixie), bash, PHP 8.5 CLI (inside the image), Apache prefork, Valkey 8.1, MariaDB 12.3, Docker Compose, Clouve `clv-docker-compose.yml` extensions.

**Spec:** `docs/superpowers/specs/2026-10-23-nextcloud-design.md` (read sections A to E and the appendix before starting).

**Companion plans:** `docs/superpowers/plans/2026-10-23-nextcloud-skill.md` (magneto-skills plugin) and `docs/superpowers/plans/2026-10-23-nextcloud-integration.md` (agent integration, rig test, review).

## Global Constraints

- Work in `/home/aj/Projects/magneto` on `develop`. Stage with `git add <exact files>` at the end of each task. Never commit, never switch branches, never unstage (no `git reset`, `git restore --staged`, `git rm --cached` or `git stash`).
- Base images are pinned: `FROM nextcloud:35.0.2-apache` and `FROM mariadb:12.3`. If a later `--push` build fails with `429 Too Many Requests` on one of them, change only that line to `mirror.gcr.io/library/<same image:tag>` and add a one-line comment saying why.
- Names: containers and images `nextcloud` and `nextcloud-mariadb`; `build.config` holds `APP_IMAGE="nextcloud"`, `MARIADB_IMAGE="nextcloud-mariadb"`, `MARIADB_NAME="MariaDB"`; installer files live at `/clouve/nextcloud/installer/` in the image.
- Manifest env names, values and types are exactly the spec's table in section C. Every value is quoted and non-empty. No env name ends in `_PORT`.
- Valkey socket: `/run/clouve/valkey/valkey.sock`. Private temp dir for secret-bearing files: `/run/clouve/tmp` (mode 700, owner www-data).
- URL-change log line, exactly: `Nextcloud URL has changed: <old> -> <new>`.
- Probe: `type: Command`, `path: /clouve/nextcloud/installer/healthcheck.sh`, `port: 80`, `initialDelay: 60`, `interval: 30`, `timeout: 15`, `failureThreshold: 15`, `successThreshold: 1`.
- The clouve-ops kit is copied from WordPress: `apps/wordpress/image/installer/{clouve-ops-sshd.conf,start-clouve-ops-sshd.sh}` to `apps/nextcloud/image/installer/`, and `apps/wordpress/image/mariadb/{clouve-ops-sshd.conf,start-clouve-ops-sshd.sh}` to `apps/nextcloud/image/mariadb/`. Only comment lines that name WordPress may change, to name Nextcloud.
- No secret ever reaches a log, stdout, a command line or a persona: the DB and admin passwords are never echoed, and secret values reach `occ` only through a mode-600 JSON file passed to `occ config:import <file>` and deleted right after.
- Shell scripts start with `#!/bin/bash` (hooks and the probe: `#!/bin/sh` is fine where they use no bashisms), pass `shellcheck`, and never use `set -x`.
- New tests go in `tests/` and find the code relative to their own path. Image tests run inside `nextcloud:35.0.2-apache` with `--network none`; they never need the internet.
- Prose docs get the humanizer pass (`humanizer:humanizer`, file mode); prove code blocks and tables unchanged with a hash of those parts before and after.
- Never print `thermo/Dockerfile`. This plan changes nothing outside the magneto repo.

## Review Focus

1. Admin names that aren't plain ASCII or arrive HTML-escaped (`O&apos;Brien`, `José`, Cyrillic, empty, or the unfilled `{user.firstName}_{user.lastName}`) must still give a valid Nextcloud login, so the first install never fails on the name. Pinned in Task 2's tests.
2. A URL that changes and changes back (Clouve host, then a custom domain, then the Clouve host again) keeps every host in `trusted_domains`, logs the exact change line each time, and keeps `overwriteprotocol` in step with the scheme. Pinned in Task 4's tests and Task 9's `./test.sh` run.
3. Restarts at the worst moment: the container killed during `occ upgrade`, a volume with a half-finished install, the database down at boot. The result is recover, refuse or wait-then-exit, never the web installer, and never a probe kill mid-upgrade. Pinned in Task 3's probe tests, Task 4's hook tests and Task 10's drills.
4. `occ` run by clouve-ops over SSH through `sudo` (no container env) sees the same PHP memory limit and the same Valkey and URL settings as Apache, and prints clean JSON. Pinned in Task 9.
5. Memory limits from tiny to none (512 MiB, 1 GiB, 2 GiB, 16 GiB, unlimited, cgroup v1) keep Apache workers, preview concurrency and the InnoDB buffer pool inside their bounds. Pinned in Task 1's and Task 2's tests and Task 10.

---

### Task 1: Database image

**Files:**
- Create: `apps/nextcloud/image/mariadb/Dockerfile`, `apps/nextcloud/image/mariadb/nextcloud.cnf`, `apps/nextcloud/image/mariadb/entrypoint.sh`
- Create (copied): `apps/nextcloud/image/mariadb/start-clouve-ops-sshd.sh`, `apps/nextcloud/image/mariadb/clouve-ops-sshd.conf`
- Test: `tests/nextcloud-mariadb.test.sh`

**Interfaces:**
- Produces: an image whose `ENTRYPOINT` is `/usr/local/bin/clouve-entrypoint.sh` and `CMD` is `["mariadbd"]`. At each start the wrapper writes `/etc/mysql/conf.d/zz-clouve-memory.cnf` with `innodb_buffer_pool_size = <N>M`, where N is a quarter of the cgroup memory limit in MB clamped to 128..4096, or 256 when there is no limit. The image sets `ENV MARIADB_AUTO_UPGRADE=1`.

- [ ] **Step 1: Write the failing test** `tests/nextcloud-mariadb.test.sh` (needs Docker; builds `apps/nextcloud/image/mariadb` as `clouve-test/nextcloud-mariadb:test`, removes its containers and image in an EXIT trap). It starts three containers with `MARIADB_DATABASE=nextcloud MARIADB_USER=nextcloud MARIADB_PASSWORD=pw MARIADB_ROOT_PASSWORD=rootpw`: `--memory 512m`, `--memory 2g`, and no limit. The 2g one also gets `CLOUVE_OPS_PASSWORD=opspw`. It waits up to 120 s for `healthcheck.sh --connect --innodb_initialized`, then asserts with `mariadb -uroot -prootpw -N -e "SELECT ..."` inside each container:

```bash
expect_var transaction_isolation READ-COMMITTED
expect_var binlog_format ROW
expect_var character_set_server utf8mb4
expect_var collation_server utf8mb4_bin
expect_var innodb_file_per_table 1
expect_var innodb_log_file_size 268435456
expect_var max_connections 200
expect_var skip_name_resolve 1
expect_pool 512m 134217728
expect_pool 2g   536870912
expect_pool none 268435456
expect_version_prefix 12.3.
expect_env_in_image MARIADB_AUTO_UPGRADE 1
expect_sshd_listening 2g        # bash -c '</dev/tcp/127.0.0.1/22' inside the container
expect_log_contains none 'CLOUVE_OPS_PASSWORD is unset'
expect_clouve_ops_sudoers 2g    # /etc/sudoers.d/clouve-ops is "clouve-ops ALL=(ALL) NOPASSWD: ALL", mode 440
```

Print PASS/FAIL lines like `tests/persona-hosts.test.sh` and exit 1 on any failure.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/nextcloud-mariadb.test.sh`
Expected: FAIL at the build step (no Dockerfile yet).

- [ ] **Step 3: Copy the clouve-ops kit**

```bash
cp apps/wordpress/image/mariadb/clouve-ops-sshd.conf apps/nextcloud/image/mariadb/
cp apps/wordpress/image/mariadb/start-clouve-ops-sshd.sh apps/nextcloud/image/mariadb/
```

Then change only the comment lines that name WordPress or `wordpress` to Nextcloud and `nextcloud`.

- [ ] **Step 4: Write `nextcloud.cnf`** with exactly:

```ini
[mysqld]
transaction_isolation  = READ-COMMITTED
binlog_format          = ROW
character_set_server   = utf8mb4
collation_server       = utf8mb4_bin
innodb_file_per_table  = 1
innodb_log_file_size   = 256M
max_connections        = 200
skip_name_resolve      = 1
```

- [ ] **Step 5: Write `entrypoint.sh`**: WordPress's `mariadb/entrypoint.sh` plus the sizing, before the sshd line. The memory limit comes from `/sys/fs/cgroup/memory.max` (cgroup v2; `max` means none), else `/sys/fs/cgroup/memory/memory.limit_in_bytes` (v1; 2^60 bytes or more means none). Write the file as `[mysqld]` plus the one line, then background `start-clouve-ops-sshd.sh` and `exec /usr/local/bin/docker-entrypoint.sh "$@"`.

- [ ] **Step 6: Write the Dockerfile**: `FROM mariadb:12.3`, the labels and the pinning comment from WordPress's `mariadb/Dockerfile`, `ENV MARIADB_AUTO_UPGRADE=1`, the same apt line (`openssh-server sudo less vim-tiny diffutils`) and clouve-ops user, `COPY` of the two kit files, `nextcloud.cnf` to `/etc/mysql/conf.d/nextcloud.cnf` and `entrypoint.sh` to `/usr/local/bin/clouve-entrypoint.sh`, `chmod +x`, `ENTRYPOINT ["/usr/local/bin/clouve-entrypoint.sh"]`, `CMD ["mariadbd"]`.

- [ ] **Step 7: Run the test again**

Run: `bash tests/nextcloud-mariadb.test.sh`
Expected: every line PASS, exit 0. Then `shellcheck apps/nextcloud/image/mariadb/*.sh tests/nextcloud-mariadb.test.sh`: no findings.

- [ ] **Step 8: Stage**

```bash
git add apps/nextcloud/image/mariadb tests/nextcloud-mariadb.test.sh
```

---

### Task 2: Shared shell functions (`lib.sh`) and the image test harness

**Files:**
- Create: `apps/nextcloud/image/installer/lib.sh`
- Test: `tests/nextcloud-image.test.sh`

**Interfaces:**
- Produces (bash functions, sourced; each prints its result on stdout, except `nc_warn`, which prints on stderr):
  - `nc_log MSG...` prints `[nextcloud] MSG` on stdout; `nc_warn MSG...` prints `[nextcloud] WARNING: MSG` on stderr.
  - `nc_decode_entities STRING`: PHP `html_entity_decode($s, ENT_QUOTES | ENT_HTML5, 'UTF-8')`.
  - `nc_clean_admin_user RAW`: a valid Nextcloud uid (algorithm below).
  - `nc_url_scheme URL`: `https` or `http`, lowercase; empty when the URL has neither.
  - `nc_url_host URL`: the host without port, path or userinfo, lowercase.
  - `nc_memory_limit_mb`: the cgroup limit in MB (integer), empty when unlimited. Reads `${NC_CGROUP_ROOT:-/sys/fs/cgroup}/memory.max`, else `${NC_CGROUP_ROOT:-/sys/fs/cgroup}/memory/memory.limit_in_bytes`; `max` or 2^60 bytes and up means unlimited.
  - `nc_apache_workers MEM_MB`: 150 when MEM_MB is empty, else MEM_MB / 50 clamped to 10..150 (integer division).
  - `nc_preview_concurrency MEM_MB`: prints `NEW ALL`: `4 8` when empty; `1 2` below 1536; `2 4` below 3584; else `4 8`.
  - `nc_missing_trusted_domains JSON HOST...`: prints, one per line, each HOST (compared case-insensitively) that isn't among the values of JSON (a JSON array or object, as `occ config:system:get trusted_domains --output=json` prints it; empty input means none).

`nc_clean_admin_user` algorithm (in this order; PHP via `php -r` for steps 2 and 3):
1. If RAW contains `{user.` or `[user.`, print `admin`.
2. Decode HTML entities (as `nc_decode_entities`).
3. Transliterate with `Transliterator::create('Any-Latin; Latin-ASCII')`.
4. Replace every character outside `[A-Za-z0-9 _.@'-]` with `_`.
5. Collapse every run of spaces and underscores that contains an underscore into one `_` (`preg_replace('/[ _]*_[ _]*/', '_', $s)`), then trim spaces and `_` at both ends.
6. Remove a leading `null_` or `undefined_` and a trailing `_null` or `_undefined` (case-insensitive), and treat a whole `null` or `undefined` as empty.
7. Cut to 64 characters, then trim trailing spaces and `_` again.
8. Print `admin` when the result is empty, `.`, `..`, or one of `.htaccess files_external __groupfolders .ncdata owncloud.log nextcloud.log updater.log audit.log`; otherwise the result.

- [ ] **Step 1: Write the failing test** `tests/nextcloud-image.test.sh`. When `NC_TEST_IN_IMAGE` is unset it re-runs itself inside the base image:

```bash
docker run --rm --network none -e NC_TEST_IN_IMAGE=1 \
  -v "$REPO/apps/nextcloud/image/installer:/clouve/nextcloud/installer:ro" \
  -v "$SELF:/test.sh:ro" --entrypoint bash nextcloud:35.0.2-apache /test.sh
```

Inside, it sources `/clouve/nextcloud/installer/lib.sh` and checks (`eq "<expected>" "$(fn args)" "<label>"`):

```bash
eq "John_Smith"      "$(nc_clean_admin_user 'John_Smith')"
eq "Jose_Garcia"     "$(nc_clean_admin_user 'José_García')"
eq "O'Brien_Smith"   "$(nc_clean_admin_user 'O&apos;Brien_Smith')"
eq "Mary Ann_Lee"    "$(nc_clean_admin_user 'Mary Ann_Lee')"
eq "Dmitrij_Ivanov"  "$(nc_clean_admin_user 'Дмитрий_Иванов')"
eq "Tom_Co_Ltd"      "$(nc_clean_admin_user 'Tom &amp; Co_Ltd')"
eq "John"            "$(nc_clean_admin_user 'John_null')"
eq "admin"           "$(nc_clean_admin_user '')"
eq "admin"           "$(nc_clean_admin_user '_')"
eq "admin"           "$(nc_clean_admin_user 'undefined_undefined')"
eq "admin"           "$(nc_clean_admin_user '{user.firstName}_{user.lastName}')"
eq "a@b.example"     "$(nc_clean_admin_user 'a@b.example')"
eq 64                "$(nc_clean_admin_user "$(printf 'a%.0s' {1..70})" | tr -d '\n' | wc -c)"
matches '^[A-Za-z0-9 _.@'"'"'-]+$' "$(nc_clean_admin_user '王_小明')"
eq "x&y'z"           "$(nc_decode_entities 'x&amp;y&apos;z')"
eq https             "$(nc_url_scheme 'https://ABC.clouve.app')"
eq http              "$(nc_url_scheme 'http://t1.test.clv:8080')"
eq ""                "$(nc_url_scheme 'ftp://x')"
eq abc.clouve.app    "$(nc_url_host 'https://ABC.clouve.app')"
eq t1.test.clv       "$(nc_url_host 'http://t1.test.clv:8080/')"
eq cloud.example.com "$(nc_url_host 'https://user@cloud.example.com/path')"
# cgroup fixtures under a temp NC_CGROUP_ROOT
eq 1024 "$(cg2 1073741824; nc_memory_limit_mb)"
eq ""   "$(cg2 max; nc_memory_limit_mb)"
eq 2048 "$(cg1 2147483648; nc_memory_limit_mb)"
eq ""   "$(cg1 9223372036854771712; nc_memory_limit_mb)"
eq 150 "$(nc_apache_workers '')";  eq 10 "$(nc_apache_workers 256)"
eq 20  "$(nc_apache_workers 1024)"; eq 40 "$(nc_apache_workers 2048)"
eq 150 "$(nc_apache_workers 16384)"
eq "4 8" "$(nc_preview_concurrency '')";   eq "1 2" "$(nc_preview_concurrency 1024)"
eq "2 4" "$(nc_preview_concurrency 2048)"; eq "2 4" "$(nc_preview_concurrency 3072)"
eq "4 8" "$(nc_preview_concurrency 4096)"
eq "abc.clouve.app" "$(nc_missing_trusted_domains '["localhost","localhost"]' localhost abc.clouve.app)"
eq ""               "$(nc_missing_trusted_domains '{"0":"localhost","3":"ABC.clouve.app"}' localhost abc.clouve.app)"
eq $'localhost\nx.example' "$(nc_missing_trusted_domains '' localhost x.example)"
```

`cg2`/`cg1` write a fixture file under a fresh `NC_CGROUP_ROOT` (v2: `memory.max`; v1: `memory/memory.limit_in_bytes`, with no `memory.max`). Later tasks append their own sections to this file.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/nextcloud-image.test.sh`
Expected: FAIL, `lib.sh` not found.

- [ ] **Step 3: Implement the functions in `apps/nextcloud/image/installer/lib.sh`** to the interfaces above. PHP snippets read their input from an env var or argv, never from string interpolation into PHP code.

- [ ] **Step 4: Run the test again**

Run: `bash tests/nextcloud-image.test.sh`
Expected: all PASS, exit 0. `shellcheck apps/nextcloud/image/installer/lib.sh tests/nextcloud-image.test.sh`: clean.

- [ ] **Step 5: Stage**

```bash
git add apps/nextcloud/image/installer/lib.sh tests/nextcloud-image.test.sh
```

---

### Task 3: Valkey and the health check

**Files:**
- Create: `apps/nextcloud/image/installer/valkey.conf`, `apps/nextcloud/image/installer/start-valkey.sh`, `apps/nextcloud/image/installer/healthcheck.sh`
- Test: `tests/nextcloud-image.test.sh` (new section)

**Interfaces:**
- Produces:
  - `start-valkey.sh` (root, backgrounded by the entrypoint) creates `/run/clouve/valkey` (owner www-data, mode 700) and loops forever: `runuser -u www-data -- valkey-server /clouve/nextcloud/installer/valkey.conf`, logging `[valkey] exited with <rc>; restarting in 1 s` to stderr between runs.
  - `healthcheck.sh` exits 0 (healthy) or 1. Overrides for tests: `NC_HEALTH_LOCK` (default `/var/www/html/nextcloud-init-sync.lock`), `NC_HEALTH_SOCK` (default `/run/clouve/valkey/valkey.sock`), `NC_HEALTH_URL` (default `http://127.0.0.1/status.php`).
- `valkey.conf`, exactly:

```
port 0
unixsocket /run/clouve/valkey/valkey.sock
unixsocketperm 700
daemonize no
save ""
appendonly no
maxmemory 128mb
maxmemory-policy allkeys-lru
databases 1
logfile ""
```

`healthcheck.sh` logic, in order:
1. If the lock file exists and `flock -n "$NC_HEALTH_LOCK" true` fails (an install, upgrade or recovery holds it), exit 0.
2. If `valkey-cli -s "$NC_HEALTH_SOCK" ping` doesn't print `PONG`, exit 1.
3. `body=$(curl -fsS -m 10 -H 'Host: localhost' "$NC_HEALTH_URL")`, exit 1 on failure.
4. Exit 0 when the body contains `"installed":true`, else exit 1.

- [ ] **Step 1: Add the failing tests**: a section in `tests/nextcloud-image.test.sh` that puts fake `flock`, `valkey-cli` and `curl` first on `PATH`. Each fake answers per a `FAKE_*` env var. The section asserts the exit code of `healthcheck.sh` for:

| Case | Lock | valkey-cli | curl | Expected |
|---|---|---|---|---|
| install running | held | no answer | fails | 0 |
| normal | absent | PONG | `{"installed":true,"maintenance":false,...}` | 0 |
| maintenance | free | PONG | `{"installed":true,"maintenance":true,...}` | 0 |
| upgrade pending | free | PONG | `{"installed":true,"needsDbUpgrade":true,...}` | 0 |
| Valkey down | free | (nothing) | ok | 1 |
| Apache down or DB 500 | free | PONG | exits 22 | 1 |
| not installed | free | PONG | `{"installed":false,...}` | 1 |

- [ ] **Step 2: Run** `bash tests/nextcloud-image.test.sh`. Expected: the new cases FAIL (no `healthcheck.sh`).

- [ ] **Step 3: Write `valkey.conf`, `start-valkey.sh` and `healthcheck.sh`** to the interfaces above.

- [ ] **Step 4: Run** `bash tests/nextcloud-image.test.sh`. Expected: all PASS. `shellcheck` on the two scripts: clean.

- [ ] **Step 5: Stage**

```bash
git add apps/nextcloud/image/installer/{valkey.conf,start-valkey.sh,healthcheck.sh} tests/nextcloud-image.test.sh
```

---

### Task 4: Settings re-asserted at every start, and the entrypoint hooks

**Files:**
- Create: `apps/nextcloud/image/installer/nextcloud-config.sh`
- Create: `apps/nextcloud/image/installer/hooks/pre-installation/10-clouve.sh`, `.../hooks/post-installation/10-clouve.sh`, `.../hooks/post-upgrade/10-clouve.sh`, `.../hooks/before-starting/10-clouve.sh`
- Test: `tests/nextcloud-image.test.sh` (new section)

**Interfaces:**
- Consumes: `lib.sh` (Task 2).
- Produces:
  - `nextcloud-config.sh`: runs as www-data with the container env. Reads `NEXTCLOUD_URL`, `NEXTCLOUD_DB_HOST`, `NEXTCLOUD_DB_NAME`, `NEXTCLOUD_DB_USER`, `NEXTCLOUD_DB_PASSWORD`, and optionally `CLV_PREVIEW_CONCURRENCY_NEW` and `CLV_PREVIEW_CONCURRENCY_ALL`. `OCC` overrides the occ command (default `php /var/www/html/occ`) and `NC_TMP_DIR` the private temp dir (default `/run/clouve/tmp`). Exits 1 only when `$OCC status --output=json` fails; other failures are logged with `nc_warn`, and the script goes on.
  - The four hooks, each an executable `10-clouve.sh` run by the official entrypoint as www-data.

`nextcloud-config.sh`, in order:
1. **Database.** Read `dbhost`, `dbname`, `dbuser` and `dbpassword` with `$OCC config:system:get <key>`. When any differs from its env var, write `{"system":{"dbhost":…,"dbname":…,"dbuser":…,"dbpassword":…}}` with PHP `json_encode` to `mktemp "$NC_TMP_DIR/db.XXXXXX"` (umask 077), run `$OCC config:import <file>`, delete the file, and log `[nextcloud] database settings updated` with no values.
2. **URL.** `old=$($OCC config:system:get overwrite.cli.url)` (empty when unset). When it differs from `NEXTCLOUD_URL`, log `Nextcloud URL has changed: <old> -> <new>` and run `config:system:set overwrite.cli.url --value=<NEXTCLOUD_URL>`.
3. **Scheme.** When it is `https`, run `config:system:set overwriteprotocol --value=https`; when `http`, run `config:system:delete overwriteprotocol`.
4. **Trusted domains.** For each host from `nc_missing_trusted_domains "$($OCC config:system:get trusted_domains --output=json)" localhost "$(nc_url_host "$NEXTCLOUD_URL")"`, run `config:system:set trusted_domains <i> --value=<host>`. The index `<i>` starts at the highest existing index plus 1.
5. **Proxies.** `config:system:set trusted_proxies 0 --value=10.0.0.0/8`, then `1 --value=172.16.0.0/12` and `2 --value=192.168.0.0/16`, only for indexes whose current value differs.
6. **Cache.** `config:system:set memcache.distributed --value='\OC\Memcache\Redis'` and the same for `memcache.locking`; `config:system:set redis host --value=/run/clouve/valkey/valkey.sock`; `config:system:set redis port --type=integer --value=0`.
7. **Previews.** When both `CLV_PREVIEW_CONCURRENCY_*` are set, `config:system:set preview_concurrency_new --type=integer --value=<NEW>`, and the same for `preview_concurrency_all` with `<ALL>`.

The hooks:
- `pre-installation`: `rm -f /var/www/html/config/CAN_INSTALL`.
- `post-installation` always exits 0 and logs each failure with `nc_warn`. It runs, in order:
  - `nextcloud-config.sh`;
  - `user:setting "$NEXTCLOUD_ADMIN_USER" settings email "$NEXTCLOUD_ADMIN_EMAIL"`, only when the email contains `@`;
  - `background:cron`;
  - `config:system:set maintenance_window_start --type=integer --value=1`;
  - `maintenance:repair --include-expensive`;
  - `config:system:set trashbin_retention_obligation --value="auto, 30"` and `config:system:set versions_retention_obligation --value="auto, 365"`;
  - `app:disable app_api`;
  - `config:system:set files_external_allow_create_new_local --type=boolean --value=false`;
  - `config:app:set files_sharing hide_disabled_user_shares --value=yes`;
  - `config:system:set updatechecker --type=boolean --value=false`;
  - `config:system:set serverid --type=integer --value=1`;
  - (superseded by the final review: Nextcloud 35 reads the system key `files.chunked_upload.max_size`, which `nextcloud-config.sh` now re-asserts at every start; the app key `files max_chunk_size` is dead);
  - `app:install calendar`, then `contacts`, then `groupfolders`, each on its own.
- `post-upgrade` always exits 0: `db:add-missing-indices`, `db:add-missing-columns`, `db:add-missing-primary-keys`, `maintenance:repair --include-expensive`, each with failures logged.
- `before-starting`:
  1. `json=$($OCC status --output=json --no-warnings | tail -n 1)`. When `installed` isn't true, print `[nextcloud] Nextcloud is not installed; refusing to start. See apps/nextcloud/README.md, "A half-finished first install".` and exit 1.
  2. When `needsDbUpgrade` is true: remember `maintenance`, run `flock /var/www/html/nextcloud-init-sync.lock $OCC upgrade --no-interaction`, then `maintenance:mode --off` if maintenance was on before, and `config:system:set loglevel --type=integer --value=2` when `loglevel` reads 0.
  3. Run `nextcloud-config.sh`, and exit with its status.

- [ ] **Step 1: Add the failing tests**: a section with a fake `occ` script set as `OCC`. It appends each argv line to `$LOG`. It answers `status --output=json` from `FAKE_STATUS_JSON` and `config:system:get <key>` from files under `$STATE/<key>` (exit 1 when absent). `config:system:set/delete` and `config:import` write back into `$STATE` (`config:import` also copies its file to `$LOG.import`). Cases:
  - First start: state `overwrite.cli.url=http://localhost`, `trusted_domains=["localhost"]`, no db keys; env `NEXTCLOUD_URL=https://abc.clouve.app`, `NEXTCLOUD_DB_PASSWORD=s3cret`. Assert that:
    - stdout has `Nextcloud URL has changed: http://localhost -> https://abc.clouve.app`;
    - `$LOG` has `config:system:set overwriteprotocol --value=https` and `config:system:set trusted_domains 1 --value=abc.clouve.app`;
    - the import file held `"dbpassword":"s3cret"` and no longer exists in `NC_TMP_DIR`;
    - `s3cret` appears nowhere in stdout, stderr or `$LOG`'s argv lines.
  - Same env again: no URL line, no `config:import`, no `trusted_domains` set.
  - `NEXTCLOUD_URL=https://cloud.example.com`: the change line, `trusted_domains 2 --value=cloud.example.com`, and `abc.clouve.app` still present.
  - Back to `https://abc.clouve.app`: the change line, and no new trusted_domains entry.
  - `NEXTCLOUD_URL=http://t1.test.clv:8080`: `config:system:delete overwriteprotocol` and `trusted_domains … --value=t1.test.clv`.
  - `before-starting` with `FAKE_STATUS_JSON` `installed:false`: exit 1, and the refusal line on stdout.
  - `before-starting` with `installed:true,maintenance:true,needsDbUpgrade:true` and `loglevel=0`: `$LOG` shows `upgrade --no-interaction`, then `maintenance:mode --off`, then `config:system:set loglevel --type=integer --value=2`. A fake `flock` on `PATH` runs its command.
  - `post-installation` with a failing `app:install contacts`: exit 0, a WARNING line, and `app:install groupfolders` still run.

- [ ] **Step 2: Run** `bash tests/nextcloud-image.test.sh`. Expected: the new section FAILS.

- [ ] **Step 3: Write `nextcloud-config.sh` and the four hooks** to the interfaces above.

- [ ] **Step 4: Run** `bash tests/nextcloud-image.test.sh`. Expected: all PASS. `shellcheck` on every new file: clean.

- [ ] **Step 5: Stage**

```bash
git add apps/nextcloud/image/installer/nextcloud-config.sh apps/nextcloud/image/installer/hooks tests/nextcloud-image.test.sh
```

---

### Task 5: The persona

**Files:**
- Create: `apps/nextcloud/image/context/nextcloud/CONTEXT.md.tpl` (mode 0644)
- Modify: `tests/persona-hosts.test.sh` (the sentinel env at lines 69-75 and the case list at line 96)

**Interfaces:**
- Produces: a persona the agent appends under `## Skill: nextcloud`. It renders with `NEXTCLOUD_HOST`, `NEXTCLOUD_DB_HOST`, `NEXTCLOUD_DB_NAME` and `NEXTCLOUD_DB_USER` only.

- [ ] **Step 1: Extend the test first**: add `NEXTCLOUD_DB_PASSWORD="$SENTINEL_PW-nextcloud-db"` and `NEXTCLOUD_ADMIN_PASSWORD="$SENTINEL_PW-nextcloud-admin"` to `render()`'s env, and `nextcloud` to the `gibbon|moodle|odoo|wordpress` case.

- [ ] **Step 2: Run** `bash tests/persona-hosts.test.sh`. Expected: unchanged results for the existing personas, no nextcloud lines yet (no template).

- [ ] **Step 3: Write `CONTEXT.md.tpl`.** Use `apps/wordpress/image/context/wordpress/CONTEXT.md.tpl` as the skeleton, with the same four `###` sections and the Skill Maintenance text adapted to `~/.claude/skills/nextcloud/`. It must contain:
  - who the users are (owners and office managers of a small business);
  - the hosts `${NEXTCLOUD_HOST}` (Apache on :80) and `${NEXTCLOUD_DB_HOST}` (MariaDB, schema `${NEXTCLOUD_DB_NAME}`, user `${NEXTCLOUD_DB_USER}`). The DB password is named as `` `NEXTCLOUD_DB_PASSWORD` `` and fetched as `${NEXTCLOUD_DB_PASSWORD:-$(clv-secret NEXTCLOUD_DB_PASSWORD)}`;
  - exactly `export SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}"`, then `sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST}` and `sshpass -e ssh clouve-ops@${NEXTCLOUD_DB_HOST}`;
  - occ as `sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "sudo -u www-data php /var/www/html/occ status --output=json -n"`, and the skill's `occ.sh` as the preferred way;
  - the first-install admin login is `NEXTCLOUD_ADMIN_USER` (cleaned by the image), and `occ user:list` confirms it;
  - what the image re-asserts at every start (the list in spec section A) and that hand edits to those keys revert;
  - the posture rules from spec section D, numbered, ending with the 9-out-of-10 confidence rule.
  It must not contain a bare `${…PASSWORD}` reference (a password appears only in the two-part `${NAME:-$(clv-secret NAME)}` form), `printenv`, `{user.` or `{org.`.

- [ ] **Step 4: Run** `bash tests/persona-hosts.test.sh`. Expected: all PASS, including the new nextcloud lines. Then the agent's composer test with magneto checked out beside it:

```bash
bash ../magneto-agent/tests/installer/chat/marketplace/context-composer.test.sh
```

Expected: PASS for the nextcloud persona (every non-secret `${VAR}` renders, no secret placeholder).

- [ ] **Step 5: Stage**

```bash
git add apps/nextcloud/image/context tests/persona-hosts.test.sh
```

---

### Task 6: App image (Dockerfile, root entrypoint, Apache)

**Files:**
- Create: `apps/nextcloud/image/Dockerfile`, `apps/nextcloud/image/build.config`, `apps/nextcloud/image/installer/entrypoint.sh`, `apps/nextcloud/image/installer/apache-clouve.conf`, `apps/nextcloud/image/installer/apache-wellknown.inc`
- Create (copied): `apps/nextcloud/image/installer/start-clouve-ops-sshd.sh`, `apps/nextcloud/image/installer/clouve-ops-sshd.conf`

**Interfaces:**
- Consumes: Tasks 2 to 5.
- Produces: an image with `ENTRYPOINT ["/clouve/nextcloud/installer/entrypoint.sh"]` and `CMD ["apache2-foreground"]`. The hooks sit at `/docker-entrypoint-hooks.d/<phase>/10-clouve.sh` (executable) and the persona at `/clouve/context/nextcloud/CONTEXT.md.tpl`.

`entrypoint.sh` (root; `set -eu`; sources `lib.sh`), in order:
1. Export `NEXTCLOUD_ADMIN_USER="$(nc_clean_admin_user "${NEXTCLOUD_ADMIN_USER:-admin}")"` and `NEXTCLOUD_ADMIN_EMAIL="$(nc_decode_entities "${NEXTCLOUD_ADMIN_EMAIL:-}")"`. When `/var/www/html/version.php` doesn't exist, also export `MYSQL_HOST`, `MYSQL_DATABASE`, `MYSQL_USER` and `MYSQL_PASSWORD` from `NEXTCLOUD_DB_HOST`, `NEXTCLOUD_DB_NAME`, `NEXTCLOUD_DB_USER` and `NEXTCLOUD_DB_PASSWORD`. Never set `NEXTCLOUD_TRUSTED_DOMAINS` or any `OVERWRITE*`, `TRUSTED_PROXIES`, `REDIS_*` or `SMTP_*` variable.
2. Write `/usr/local/etc/php/conf.d/zz-clouve.ini`: `memory_limit=${PHP_MEMORY_LIMIT:-512M}`, `upload_max_filesize=${PHP_UPLOAD_LIMIT:-512M}`, `post_max_size=${PHP_UPLOAD_LIMIT:-512M}`, `apc.shm_size=64M`, as literal values.
3. `mem=$(nc_memory_limit_mb)`. Write `/etc/apache2/conf-enabled/zz-clouve-mpm.conf` as `<IfModule mpm_prefork_module>` with `ServerLimit` and `MaxRequestWorkers` both set to `$(nc_apache_workers "$mem")`. Export `CLV_PREVIEW_CONCURRENCY_NEW` and `CLV_PREVIEW_CONCURRENCY_ALL` from `nc_preview_concurrency "$mem"`. Log the three numbers.
4. `mkdir -p /run/clouve/tmp` (owner www-data, mode 700). Start `start-valkey.sh &`, then wait up to 30 s for `valkey-cli -s /run/clouve/valkey/valkey.sock ping` to print `PONG`, else exit 1.
5. Start `start-clouve-ops-sshd.sh &`.
6. Wait up to 300 s for the database, else exit 1. Each try, every 5 s, is `php -r` doing `new PDO("mysql:host=" . getenv('NEXTCLOUD_DB_HOST') . ";dbname=" . getenv('NEXTCLOUD_DB_NAME'), getenv('NEXTCLOUD_DB_USER'), getenv('NEXTCLOUD_DB_PASSWORD'))`. Credentials go only through the env, never in argv or a log.
7. `touch /var/www/html/nextcloud-init-sync.lock` and `chown www-data:www-data` it.
8. Start cron in the background: `( until grep -q "'installed' => true" /var/www/html/config/config.php 2>/dev/null; do sleep 10; done; exec busybox crond -f -L /dev/stdout ) &`.
9. `exec /entrypoint.sh "$@"`.

`apache-clouve.conf`: `Header always set Strict-Transport-Security "max-age=15552000"`.

`apache-wellknown.inc` (inserted after `<VirtualHost *:80>` in `/etc/apache2/sites-available/000-default.conf`):

```apache
	RewriteEngine On
	RewriteCond %{HTTP:X-Forwarded-Proto} =https
	RewriteRule ^/\.well-known/(carddav|caldav)$ https://%{HTTP_HOST}/remote.php/dav/ [R=301,L]
```

The Dockerfile (after `FROM nextcloud:35.0.2-apache`):
- **Packages and user.** Labels, then `apt-get update && apt-get install -y --no-install-recommends openssh-server sudo valkey-server mariadb-client && rm -rf /var/lib/apt/lists/*`, then WordPress's clouve-ops user and sudoers lines.
- **Installer.** `COPY installer /clouve/nextcloud/installer`; `chmod +x` on its scripts and hooks; copy each `hooks/<phase>/10-clouve.sh` into `/docker-entrypoint-hooks.d/<phase>/`; install `clouve-ops-sshd.conf` as `/etc/ssh/sshd_config.d/clouve-ops.conf`.
- **Apache.** Install `apache-clouve.conf` as `/etc/apache2/conf-available/clouve.conf` and `a2enconf clouve`. Insert `apache-wellknown.inc` with `sed -i '/<VirtualHost \*:80>/r …'`. Then `grep -q 'remote.php/dav/ \[R=301' …000-default.conf && apache2ctl -t`, so the build fails if the insert didn't apply.
- **Persona and start.** `COPY context/ /clouve/context/`, then `ENTRYPOINT` and `CMD` as above.

- [ ] **Step 1: Copy the clouve-ops kit** from `apps/wordpress/image/installer/` (comment lines naming WordPress changed to Nextcloud only), and write `build.config`.

- [ ] **Step 2: Write the remaining files** to the interfaces above.

- [ ] **Step 3: Build**

Run: `./build.sh nextcloud`
Expected: both images build (amd64), `✓` lines for `r.clv.zone/e2eorg/nextcloud` and `r.clv.zone/e2eorg/nextcloud-mariadb`.

- [ ] **Step 4: Smoke-check the image contents**

```bash
docker run --rm --entrypoint sh r.clv.zone/e2eorg/nextcloud -c '
  apache2ctl -t && for p in pre-installation post-installation post-upgrade before-starting; do test -x /docker-entrypoint-hooks.d/$p/10-clouve.sh || exit 1; done &&
  grep -c "remote.php/dav/ \[R=301" /etc/apache2/sites-available/000-default.conf &&
  valkey-server --version && mariadb-dump --version && id clouve-ops &&
  test -f /clouve/context/nextcloud/CONTEXT.md.tpl && stat -c %a /clouve/context/nextcloud/CONTEXT.md.tpl'
```

Expected: `Syntax OK`, `1`, the two versions, the clouve-ops id line, and `644`.

- [ ] **Step 5: Run every test so far**

Run: `bash tests/nextcloud-image.test.sh && bash tests/nextcloud-mariadb.test.sh && bash tests/persona-hosts.test.sh`
Expected: all pass. `shellcheck apps/nextcloud/image/installer/*.sh`: clean.

- [ ] **Step 6: Stage**

```bash
git add apps/nextcloud/image
```

---

### Task 7: Manifests

**Files:**
- Create: `apps/nextcloud/clv-docker-compose.yml`, `apps/nextcloud/docker-compose.yml`
- Test: `tests/nextcloud-manifest.test.sh`

**Interfaces:**
- Produces: the marketplace manifest the publish wizard uploads, and the local compose `./start.sh nextcloud` and `./test.sh apps/nextcloud` use.

`clv-docker-compose.yml` (header comment in the WordPress style without the twin sentences; `appDescription` per Step 3):

```yaml
version: '3.8'
services:
  nextcloud:
    image: nextcloud
    ports:
      - '80:80'
    environment:
      NEXTCLOUD_DB_HOST: nextcloud-mariadb
      NEXTCLOUD_DB_NAME: nextcloud
      NEXTCLOUD_DB_USER: nextcloud
      NEXTCLOUD_DB_PASSWORD: nextcloud-mariadb-password
      NEXTCLOUD_URL: http://localhost
      NEXTCLOUD_ADMIN_USER: '{user.firstName}_{user.lastName}'
      NEXTCLOUD_ADMIN_EMAIL: '{user.userEmail}'
      NEXTCLOUD_ADMIN_PASSWORD: nextcloud-admin-password
    x-clouve-environment-types:
      NEXTCLOUD_DB_HOST: containerReference
      NEXTCLOUD_DB_NAME: static
      NEXTCLOUD_DB_USER: static
      NEXTCLOUD_DB_PASSWORD: secret
      NEXTCLOUD_URL: applicationUrl
      NEXTCLOUD_ADMIN_USER: applicationUsername
      NEXTCLOUD_ADMIN_EMAIL: applicationUsername
      NEXTCLOUD_ADMIN_PASSWORD: applicationPassword
    volumes:
      - nextclouddata:/var/www/html
    x-clouve-metadata:
      containerName: nextcloud
      purpose: Frontend
      protocol: TCP
      isPublic: true
      memoryBase: 2
      cpuBase: 1
    x-clouve-bundle-metadata:
      appVersion: 35.0.2
      appTitle: Nextcloud with AI Assistant
      appDescription: <Step 3>
      adminPath: /settings/admin
    x-clouve-healthcheck:
      enabled: true
      type: Command
      path: /clouve/nextcloud/installer/healthcheck.sh
      port: 80
      initialDelay: 60
      interval: 30
      timeout: 15
      failureThreshold: 15
      successThreshold: 1
    healthcheck:
      test: ["CMD", "/clouve/nextcloud/installer/healthcheck.sh"]
      interval: 30s
      timeout: 15s
      retries: 15
      start_period: 60s
    x-clouve-volumes:
      - name: nextclouddata
        size: 20
        description: Nextcloud code, configuration, apps and users' files
  nextcloud-mariadb:
    image: nextcloud-mariadb
    ports:
      - '3306:3306'
    environment:
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: nextcloud-mariadb-password
      MYSQL_ROOT_PASSWORD: nextcloud-mariadb-root-password
    x-clouve-environment-types:
      MYSQL_DATABASE: static
      MYSQL_USER: static
      MYSQL_PASSWORD: secret
      MYSQL_ROOT_PASSWORD: secret
    volumes:
      - dbdata:/var/lib/mysql
    x-clouve-metadata:
      containerName: nextcloud-mariadb
      purpose: Database
      protocol: TCP
      isPublic: false
      memoryBase: 1
      cpuBase: 0.5
    x-clouve-healthcheck:
      enabled: false
      type: TCP
      path: /
      port: 3306
      initialDelay: 30
      interval: 10
      timeout: 5
      failureThreshold: 3
      successThreshold: 1
    x-clouve-volumes:
      - name: dbdata
        size: 10
        description: Nextcloud's MariaDB database files
volumes:
  nextclouddata:
    driver: local
  dbdata:
    driver: local
x-clouve-agent:
  enabled: true
  skills:
    url: https://github.com/Clouve/magneto-skills.git?plugins=nextcloud
    git:
      token: ''
      username: ''
  advanced:
    sidecarPullTimeout: 600
```

`docker-compose.yml` follows `apps/wordpress/docker-compose.yml`:
- **Services.** `nextcloud` (container `nextcloud_app`, image `r.clv.zone/e2eorg/nextcloud`, port `${TEST_PORT:-8080}:80`); `nextcloud-mariadb` (container `nextcloud_mariadb`, image `r.clv.zone/e2eorg/nextcloud-mariadb`, healthcheck `healthcheck.sh --connect --innodb_initialized`); `magneto-agent` (container `nextcloud_magneto_agent`, port `${MAGNETO_AGENT_PORT:-8081}:80`). The app service comes first and the agent last.
- **App env.** `NEXTCLOUD_URL: http://${TEST_DOMAIN:-t1.test.clv}:${TEST_PORT:-8080}`, admin `admin` / `Admin@123`, email `admin@example.com`.
- **Shared password.** `CLOUVE_OPS_PASSWORD: clouve_ops_dev_password` on all three.
- **Agent env.** WordPress's `MAGNETO_AGENT_USERNAME: admin` and its two password lines, `MAGNETO_AGENT_SKILLS: https://github.com/Clouve/magneto-skills.git?plugins=nextcloud`, the LLM pass-through variables, and `CLV_SIDECAR_HOSTS` and `CLV_SIDECAR_NAMESPACES` both `nextcloud,nextcloud-mariadb`.
- **Volumes.** `nextcloud_data:/var/www/html`, `db_data:/var/lib/mysql`, and the agent's four volumes.

- [ ] **Step 1: Write the failing test** `tests/nextcloud-manifest.test.sh`. It runs `python3 -I` with PyYAML and asserts, on `clv-docker-compose.yml`:
  - every env var has an `x-clouve-environment-types` entry and the types above;
  - every value is a non-empty string, and no name ends in `_PORT`;
  - the two secret placeholders are shared exactly (`nextcloud-mariadb-password` on both containers);
  - no `CLOUVE_OPS_PASSWORD`, `MAGNETO_AGENT_*` or `CLV_SIDECAR_*` anywhere;
  - container names, purposes, `memoryBase` 2/1, `cpuBase` 1/0.5, volume names equal to their `x-clouve-volumes` names, and sizes 20/10;
  - the health-check fields exactly as in Global Constraints;
  - `appVersion` `35.0.2`, `appTitle` `Nextcloud with AI Assistant`, `adminPath` `/settings/admin`, and `appDescription` of 10 to 1000 characters with no `"`, `'`, `{{` or `}}`;
  - `x-clouve-agent` as above.

  On `docker-compose.yml` it asserts: service order (nextcloud before magneto-agent), a DB `container_name` containing `mariadb`, `CLOUVE_OPS_PASSWORD` on all three, `TEST_DOMAIN`/`TEST_PORT` in the app's port and URL, and agent `CLV_SIDECAR_*` both `nextcloud,nextcloud-mariadb`.

- [ ] **Step 2: Run** `bash tests/nextcloud-manifest.test.sh`. Expected: FAIL, no manifests.

- [ ] **Step 3: Write both files.** The `appDescription` is in plain words, at most 1000 characters, and claims only what ships:
  - a hosted Nextcloud for small teams, with files, Team folders, calendars and contacts;
  - an AI Assistant that adds and removes staff accounts, sets up Team folders and permissions, shares the admin's files and links, installs and updates Nextcloud apps, sets quotas, helps set up email, takes and restores backups, fixes setup warnings, and finds out why something is slow or broken;
  - it shows the command and waits for a yes before anything destructive;
  - Calendar, Contacts and Team folders come pre-installed;
  - the AI-usage, no-API-key and data-ownership sentences, the same wording as `apps/wordpress/clv-docker-compose.yml`.

  Run it through `humanizer:humanizer` before saving.

- [ ] **Step 4: Run** `bash tests/nextcloud-manifest.test.sh && ./check-manifests.sh`. Expected: all PASS; `check-manifests.sh` reports `0 problem(s)`.

- [ ] **Step 5: Stage**

```bash
git add apps/nextcloud/clv-docker-compose.yml apps/nextcloud/docker-compose.yml tests/nextcloud-manifest.test.sh
```

---

### Task 8: README, logo and repo docs

**Files:**
- Create: `apps/nextcloud/README.md`, `apps/nextcloud/logo.png`
- Modify:
  - `CLAUDE.md`: the project overview list, a "Testing the Nextcloud image" block, and the "Compose Files Per App" paragraph;
  - `README.md`: the "Basic (AI-disabled) Twin Manifest" section;
  - `DEVELOPER_GUIDE.md`: the app lists;
  - `apps/wordpress/clv-docker-compose.yml`: header comment lines 5-7.

**Interfaces:** none (docs only).

- [ ] **Step 1: Render the logo.** Render `/home/aj/Projects/magneto/.research/nextcloud-docker/logo.svg` to a 256×256 PNG with a transparent background, using the image's ImageMagick:

```bash
docker run --rm --network none -v /home/aj/Projects/magneto/.research/nextcloud-docker:/in:ro -v "$PWD/apps/nextcloud:/out" \
  --user "$(id -u):$(id -g)" --entrypoint php nextcloud:35.0.2-apache -r '
  $i = new Imagick(); $i->setBackgroundColor(new ImagickPixel("transparent")); $i->setResolution(300,300);
  $i->readImage("/in/logo.svg"); $i->setImageFormat("png32"); $i->thumbnailImage(256,256,true,true); $i->writeImage("/out/logo.png");'
file apps/nextcloud/logo.png
```

Expected: `PNG image data, 256 x 256`. If Imagick has no SVG delegate, use `rsvg-convert` from a throwaway `alpine` container with network instead, and say so in the task report.

- [ ] **Step 2: Write `apps/nextcloud/README.md`.** Use the shape of `apps/owncloud/README.md`, with the content of spec sections A to C:
  - containers, ports and volumes;
  - environment variables and their types;
  - what the start-up does and which settings it re-asserts;
  - cron, Valkey and the health check;
  - local use (`./build.sh nextcloud`, `./start.sh nextcloud`, URLs, local credentials);
  - the 50 MB upload cap and the 40 MiB chunks;
  - "A half-finished first install": the manual reset is to stop, drop and recreate the database, clear `config/config.php` and `data/`, and delete `version.php`;
  - upgrades: one Nextcloud major at a time, image-driven;
  - the tests.
  Run the humanizer on it.

- [ ] **Step 3: Edit the repo docs.**
  - `CLAUDE.md`: add Nextcloud to the overview's app list. Add a `### Testing the Nextcloud image` block listing `bash tests/nextcloud-image.test.sh`, `bash tests/nextcloud-mariadb.test.sh` and `bash tests/nextcloud-manifest.test.sh`, one line each on what they check. The image and database tests need Docker; the manifest test needs only `python3` with PyYAML, like `check-manifests.sh`. Rewrite the `clv-docker-compose-basic.yml` bullet: the twins were retired on 2026-10-18; each app has one manifest, and the AI Assistant is chosen at install.
  - `README.md`: replace the twin section with a short note to the same effect, and drop "Currently: …".
  - `DEVELOPER_GUIDE.md`: add `nextcloud` wherever the app list names the apps.
  - `apps/wordpress/clv-docker-compose.yml`: delete the three header lines about `clv-docker-compose-basic.yml`.

  Make your edits first. Then hash the code blocks and tables of `CLAUDE.md`, `README.md` and `DEVELOPER_GUIDE.md` with `python3 -I /tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/md-fixed-parts.py <file> | sha256sum`, run the humanizer on the prose you added or changed, and hash again. Each file's two hashes must match.

- [ ] **Step 4: Check the diff**

Run: `git diff -- CLAUDE.md README.md DEVELOPER_GUIDE.md apps/wordpress/clv-docker-compose.yml`
Expected: only the edits above; the WordPress manifest diff is three deleted comment lines.

- [ ] **Step 5: Stage**

```bash
git add apps/nextcloud/README.md apps/nextcloud/logo.png CLAUDE.md README.md DEVELOPER_GUIDE.md apps/wordpress/clv-docker-compose.yml
```

---

### Task 9: Local run, URL change and the SSH view of `occ`

**Files:** none new. Fixes found here go into the files of Tasks 1 to 7 (re-run those tests and re-stage).

- [ ] **Step 1: Build and start**

```bash
./build.sh nextcloud && ./start.sh nextcloud
```

Then wait for `docker logs nextcloud_app` to show `resuming normal operations` and `docker inspect -f '{{.State.Health.Status}}' nextcloud_app` to say `healthy` (at most 10 minutes).

- [ ] **Step 2: Check the instance.** Each line must hold:
  - `docker exec -u www-data nextcloud_app php occ status --output=json` has `"installed":true,"maintenance":false,"needsDbUpgrade":false`;
  - `docker exec -u www-data nextcloud_app php occ app:list --output=json | jq -r '.enabled | keys[]'` includes `calendar`, `contacts`, `groupfolders`, and not `app_api`;
  - `curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' http://localhost:8080/login` is `200`;
  - `docker exec -u www-data nextcloud_app php occ config:system:get overwrite.cli.url` is `http://t1.test.clv:8080`;
  - `docker exec -u www-data nextcloud_app php occ config:system:get memcache.locking` is `\OC\Memcache\Redis`;
  - `docker exec nextcloud_app valkey-cli -s /run/clouve/valkey/valkey.sock ping` is `PONG`;
  - `docker exec -u www-data nextcloud_app php occ setupchecks --output=json | jq` shows no `error` items except the ones that need web or HTTPS context, and the task report lists the severities;
  - within 6 minutes of start, `docker exec -u www-data nextcloud_app php occ config:app:get core lastcron` is within the last 300 s and `backgroundjobs_mode` is `cron`;
  - `/usr/local/etc/php/conf.d/zz-clouve.ini` and `/etc/apache2/conf-enabled/zz-clouve-mpm.conf` exist with the expected numbers.

- [ ] **Step 3: Check `occ` through the clouve-ops channel, as the agent will run it.**

```bash
docker exec nextcloud_magneto_agent bash -c 'export SSHPASS=clouve_ops_dev_password;
  sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@nextcloud "sudo -n -u www-data php /var/www/html/occ status --output=json -n" | jq -e .installed;
  sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@nextcloud "sudo -n -u www-data php -r \"echo ini_get(\\\"memory_limit\\\");\"";
  sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@nextcloud "sudo -n -u www-data php /var/www/html/occ config:system:get memcache.locking";
  sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@nextcloud-mariadb "sudo -n true && echo db-ok"'
```

Expected: `true`, `512M` (no "Failed to set memory limit" line anywhere), `\OC\Memcache\Redis`, and `db-ok`.

- [ ] **Step 4: Check a real admin login**

Use the local credentials (`admin` / `Admin@123`) over HTTP: GET `/login` for the `requesttoken`, then POST it with a cookie jar. Expected: a 303 to `/apps/dashboard/`, then a 200 on the dashboard.

- [ ] **Step 5: Run the URL-change test**

Run: `./stop.sh nextcloud && ./test.sh apps/nextcloud`
Expected: `✓ TEST PASSED`, with `Nextcloud URL has changed: http://t1.test.clv:8080 -> http://t2.test.clv:8080` in the excerpt.

- [ ] **Step 6: Stop and clean up**

Run: `./stop.sh nextcloud --cleanup`
Expected: the containers and volumes are gone.

---

### Task 10: Failure drills and memory sizing

**Files:** none new (fixes go back to Tasks 2 to 7, with their tests re-run).

- [ ] **Step 1: An interrupted upgrade resumes.** On a fresh `./start.sh nextcloud`, once it's healthy, put the instance into the state a killed `occ upgrade` leaves:

```bash
docker exec -u www-data nextcloud_app php occ maintenance:mode --on
docker exec -u www-data nextcloud_app php -r '
  $f="/var/www/html/config/config.php"; include $f;
  $CONFIG["version"]="35.0.1.0"; $CONFIG["loglevel"]=0;
  file_put_contents($f, "<?php\n\$CONFIG = ".var_export($CONFIG,true).";\n");'
docker restart nextcloud_app
```

Expected:
- the log shows `occ upgrade` running from the before-starting hook;
- then `occ status --output=json` shows `"maintenance":false,"needsDbUpgrade":false`;
- `config:system:get loglevel` prints `2`;
- the health check never reported unhealthy for 15 consecutive runs while it ran.

- [ ] **Step 2: A half-finished install refuses to start.**

```bash
docker exec -u www-data nextcloud_app php -r '
  $f="/var/www/html/config/config.php"; include $f; unset($CONFIG["installed"]);
  file_put_contents($f, "<?php\n\$CONFIG = ".var_export($CONFIG,true).";\n");'
docker restart nextcloud_app
```

Expected:
- the container exits after `Nextcloud is not installed; refusing to start`;
- `curl` on port 8080 never returns the installer page while it's up;
- `/var/www/html/config/CAN_INSTALL` doesn't exist.

Then `./stop.sh nextcloud --cleanup`.

- [ ] **Step 3: Database down, then back.** With a healthy instance:
  - `docker stop nextcloud_mariadb`, then `docker exec nextcloud_app /clouve/nextcloud/installer/healthcheck.sh; echo $?` prints `1`;
  - `docker start nextcloud_mariadb`, and within 60 s the same command prints `0`.

- [ ] **Step 4: Valkey dies and comes back.**
  - `docker exec nextcloud_app sh -c 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = valkey-server ] && kill ${p#/proc/}; done; true'`
  - Within 5 s, `valkey-cli -s /run/clouve/valkey/valkey.sock ping` prints `PONG` again, and the log has the `[valkey] exited` line.

- [ ] **Step 5: Memory sizing.** Run the app container with `--memory 1g` (a temporary `docker-compose.override.yml` in a scratch copy, or `docker update --memory 1g --memory-swap 1g nextcloud_app` plus a restart). Then:
  - `zz-clouve-mpm.conf` says `MaxRequestWorkers 20`;
  - `occ config:system:get preview_concurrency_new` / `_all` print `1` and `2`.

  Repeat with `2g`: `40`, `2` and `4`. Then check that Apache honours the cap: with `1g`, fire 40 concurrent slow requests (`curl` to `/status.php` in a loop) and count `apache2` processes in the container: at most 21 (20 workers plus the parent).

- [ ] **Step 6: Clean up.** Run `./stop.sh nextcloud --cleanup` and remove any scratch override. Stage any fixes, re-running their tests.

---

### Task 11: arm64 builds

**Files:** none.

- [ ] **Step 1: Check that QEMU is registered**

Run: `ls /proc/sys/fs/binfmt_misc/ | grep qemu-aarch64`
Expected: `qemu-aarch64`. If it's missing, run `docker run --privileged --rm tonistiigi/binfmt --install all`.

- [ ] **Step 2: Build both images for arm64 without pushing**

```bash
docker buildx build --builder multiplatform-builder --platform linux/arm64 -o type=cacheonly apps/nextcloud/image
docker buildx build --builder multiplatform-builder --platform linux/arm64 -o type=cacheonly apps/nextcloud/image/mariadb
```

Expected: both finish without errors.

- [ ] **Step 3: Final check of this plan's changes**

Run: `git status --short` and `git diff --cached --stat`
Expected: only the files named in Tasks 1 to 8, plus the spec and the plan docs. Nothing unstaged, nothing untracked under `apps/nextcloud` or `tests`.
