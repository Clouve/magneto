# Nextcloud with AI Assistant

This directory holds the Nextcloud bundle for the Clouve marketplace: a Nextcloud 35 image, a MariaDB image and the manifests that describe them. It is meant for small teams and businesses that want their own file sync and share service: staff accounts, Team folders, links for clients, calendars and contacts. The people who talk to the AI Assistant are business owners and office managers, not developers, and the assistant must not lose their files or lock them out.

The listing is called "Nextcloud with AI Assistant". There is one manifest, and the customer chooses the AI Assistant when they install. The assistant is the Magneto Agent container, which the platform adds to the deployment. It works through the `nextcloud` plugin in the `magneto-skills` repo and the persona in `image/context/nextcloud/CONTEXT.md.tpl`.

## Overview

- Nextcloud 35.0.2, from `nextcloud:35.0.2-apache` (Debian 13, PHP 8.5, Apache prefork), for amd64 and arm64.
- MariaDB 12.3, the newest release that Nextcloud 35 supports.
- Valkey 8.1, a Redis-compatible cache, inside the Nextcloud container. It adds no container and no price.
- An SSH server and a `clouve-ops` account in both containers, which the AI Assistant uses to run `occ` and other commands.

Both base images are pinned to an exact tag. A floating tag would let a newer release ship under the volumes of running deployments at the next rebuild, and a new image upgrades the data as soon as it starts. Raise a tag on purpose, and never to `latest`. If a `--push` build fails with `429 Too Many Requests` on a base image, change only that `FROM` line to `mirror.gcr.io/library/<image:tag>` and say why in a one-line comment.

The Nextcloud image extends the official one, as the packaging guide describes. The official `/entrypoint.sh` stays where it is, and `installer/entrypoint.sh` gets the container ready and then calls it. The official entrypoint copies the code onto the volume, installs or upgrades Nextcloud, runs the hooks in `/docker-entrypoint-hooks.d/` and starts Apache.

## Containers, ports and volumes

| Container | Built from | Port | Volume | Size |
|---|---|---|---|---|
| `nextcloud` | `nextcloud:35.0.2-apache` | 80, public | `nextclouddata` at `/var/www/html` | 20 GB |
| `nextcloud-mariadb` | `mariadb:12.3` | 3306, internal | `dbdata` at `/var/lib/mysql` | 10 GB |

The `nextclouddata` volume holds the code, `config/`, `custom_apps/`, `themes/` and the users' files in `data/`. The sizes are for the smallest plan, and larger plans multiply them. The app asks for `memoryBase: 2` and `cpuBase: 1`, and the database for `memoryBase: 1` and `cpuBase: 0.5`. The app gets more memory because of previews: in a test, 24 photo previews generated at once peaked at about 1 GB. The database has no health check in the manifest, as in the other apps.

The third container, `magneto-agent`, is not in the manifest. The platform adds it to deployments that use the AI Assistant. The local `docker-compose.yml` lists it, so a local run has the same three containers.

## Environment variables

The meaning of each type is in the packaging guide (`../../README.md`, "Environment Variable Types"). Every value is quoted and non-empty, and no name ends in `_PORT`, because the agent drops those.

### nextcloud

| Variable | Manifest value | Type | Used for |
|---|---|---|---|
| `NEXTCLOUD_DB_HOST` | `nextcloud-mariadb` | `containerReference` | The database host |
| `NEXTCLOUD_DB_NAME` | `nextcloud` | `static` | The database name |
| `NEXTCLOUD_DB_USER` | `nextcloud` | `static` | The database user |
| `NEXTCLOUD_DB_PASSWORD` | `nextcloud-mariadb-password` | `secret` | The database password |
| `NEXTCLOUD_URL` | `http://localhost` | `applicationUrl` | The address people use. The platform sets it to the deployment's URL, and to a custom domain once one is added |
| `NEXTCLOUD_ADMIN_USER` | `{user.firstName}_{user.lastName}` | `applicationUsername` | The admin login, cleaned as described below |
| `NEXTCLOUD_ADMIN_EMAIL` | `{user.userEmail}` | `applicationUsername` | The admin's email. It is shown with the password, because email sign-in works |
| `NEXTCLOUD_ADMIN_PASSWORD` | `nextcloud-admin-password` | `applicationPassword` | The admin password at the first install |

### nextcloud-mariadb

| Variable | Manifest value | Type | Used for |
|---|---|---|---|
| `MYSQL_DATABASE` | `nextcloud` | `static` | The database to create |
| `MYSQL_USER` | `nextcloud` | `static` | The database user |
| `MYSQL_PASSWORD` | `nextcloud-mariadb-password` | `secret` | The user's password. It is the same placeholder as `NEXTCLOUD_DB_PASSWORD`, so both containers get one generated value |
| `MYSQL_ROOT_PASSWORD` | `nextcloud-mariadb-root-password` | `secret` | The root password |

The platform also sets `CLOUVE_OPS_PASSWORD` on all three containers, and `MAGNETO_AGENT_*` and `CLV_SIDECAR_*` on the agent. None of them is in the manifest. `NEXTCLOUD_DB_*` reach the agent unchanged, and the persona refers to `NEXTCLOUD_DB_HOST`, `NEXTCLOUD_DB_NAME` and `NEXTCLOUD_DB_USER` in braces, because those are the names the agent can fill in.

The image also reads `PHP_MEMORY_LIMIT` and `PHP_UPLOAD_LIMIT`. The official image defines both as `512M`, and the manifest leaves them alone.

## The admin login

Nextcloud logins allow letters, digits, spaces and `_ . @ ' -`, up to 64 characters. The platform fills `NEXTCLOUD_ADMIN_USER` from the customer's first and last name, and the first install must not fail on whatever arrives. So the entrypoint cleans the name first:

1. A value that still holds `{user.` is an unfilled template, and the login is `admin`.
2. It decodes HTML entities. The platform sends `O'Brien` as `O&apos;Brien`.
3. It transliterates to ASCII with PHP's intl extension, so `José` becomes `Jose`.
4. It replaces every other disallowed character with `_`, collapses runs of spaces and underscores, and trims both ends. A leading hyphen goes too, because `occ` would read a login such as `-x` as an option.
5. It drops a leading `null_` or `undefined_` and a trailing `_null` or `_undefined`, which an empty first or last name leaves behind.
6. It cuts the result to 64 characters. An empty result, or a name Nextcloud refuses (`.`, `..`, `.htaccess` and a few more), becomes `admin`.

| The platform sends | The login is |
|---|---|
| `José_García` | `Jose_Garcia` |
| `Anne_O&apos;Brien` | `Anne_O'Brien` |
| `Иван_Петров` | `Ivan_Petrov` |
| `{user.firstName}_{user.lastName}` unfilled, or nothing | `admin` |

The Clouve dashboard can show the customer's own spelling, so `occ user:list` is the way to see the real login. The customer can also sign in with their email, which the first install saves for the admin.

## What the start-up does

`installer/entrypoint.sh` runs as root and stays PID 1 until its last line. It never writes a password to a log or a command line. The one exception is upstream: during the first install, the official entrypoint passes the admin and database passwords to `occ maintenance:install` as arguments, so anyone who can list processes inside the container sees them while the install runs. Apache isn't running yet at that point. The script does these things in order:

1. It runs itself a second time. The first run puts the cleaned login in `NEXTCLOUD_ADMIN_USER` and the decoded email in `NEXTCLOUD_ADMIN_EMAIL`, sets a marker variable and calls `exec` on itself. The AI Assistant reads this container's environment from `/proc/1/environ` as soon as sshd answers, and that file shows the environment a program was started with, not what it exported later. Only a new `exec` puts the cleaned values there, so the assistant reads the real login and not the customer's spelling. This happens before sshd starts.
2. A missing `NEXTCLOUD_DB_*` variable stops the start. Before the first install only (no `version.php` on the volume yet), a missing `NEXTCLOUD_ADMIN_PASSWORD` stops it too, because the official entrypoint would otherwise copy the code, skip the install and never install on a later start. On that first start the script also copies the database settings into the `MYSQL_*` variables the official entrypoint reads. Later starts don't get the copies, so the password isn't in PID 1's environment twice. On any start, if the volume's top folder is root's, it becomes www-data's with mode 1777, as it is in the image. A new Kubernetes disk starts with a top folder of root's (mode 755, holding only `lost+found`), while Docker fills a new volume from the image, so only a cluster install needs this. Without it, www-data couldn't make the init lock in step 9, and the official entrypoint's read-only open of the lock would stop every start.
3. PHP's limits go into `conf.d/zz-clouve.ini` as plain values: `memory_limit`, `upload_max_filesize` and `post_max_size` from `PHP_MEMORY_LIMIT` and `PHP_UPLOAD_LIMIT`, and `apc.shm_size=64M`. The official `nextcloud.ini` reads them from the environment, which `occ` run through `sudo` doesn't have. Without this file `occ` would run at 128 MB and print a warning on stdout that breaks `--output=json`.
4. Apache's worker count and the preview concurrency follow the container's memory limit (see "Memory limits").
5. Valkey starts, and the script waits up to 30 seconds for a `PING`. It also makes `/run/clouve/tmp` (mode 700, owned by www-data), the private folder for files that carry a secret. If a restore was cut off, it leaves a note for the hooks in `/run/clouve` (see "Starts that were cut off").
6. The clouve-ops sshd starts in the background when `CLOUVE_OPS_PASSWORD` is set, and then the script removes that variable from its own environment. Starting it this early is deliberate: the assistant can fetch its persona while Nextcloud installs.
7. The script waits up to 5 minutes for the database with a plain PDO connection, and exits 1 if nothing answers. Then, if `config.php` exists, it makes the database settings in that file match `NEXTCLOUD_DB_*` (see "Clones and custom domains").
8. If a backup was cut off, the script turns maintenance mode off and removes the backup's marker (see "Starts that were cut off").
9. www-data makes the init lock file (`nextcloud-init-sync.lock`) a plain file of its own, so the hooks, which run as www-data, can take the lock too. Root never creates anything at that path, because the folder is www-data's (on a new disk, step 2 makes it so): a link swapped in at the right moment would otherwise make root create a file wherever it pointed. The official entrypoint only opens it, read-only.
10. Cron starts in the background (see "Cron").
11. `exec /entrypoint.sh apache2-foreground` hands over to the official entrypoint, and Apache becomes PID 1. While a restore is cut off and the image's Nextcloud is not the code on the volume, the script starts Apache on the volume's code instead, without the official entrypoint, so no upgrade runs on a half-restored database and the assistant can still reach the pod. The start after the restore upgrades as usual.

The official entrypoint runs as root on www-data's `/var/www/html`, so the build changes two of its lines (`installer/patch-official-entrypoint.sh`, which fails the build when either line isn't there as expected). It opens the init lock read-only, where `9>` would create, truncate and follow a symlink. And it runs the volume's `version.php`, which is PHP that www-data can change, as www-data through upstream's own `run_as`, and stops the start unless that prints a version number.

### Hooks

The official entrypoint runs these four as www-data, with the container's environment. A hook that exits with a failure stops the start, and the container restarts.

| Hook | Runs | What it does |
|---|---|---|
| `pre-installation` | Before the first install | Deletes `config/CAN_INSTALL`, so a half-finished install can never show the web installer. `occ maintenance:install` works without it. |
| `post-installation` | Once, after the first install | Runs `nextcloud-config.sh`, then the first-install settings below. It always exits 0. |
| `post-upgrade` | After the official entrypoint has upgraded Nextcloud | Runs `db:add-missing-indices`, `db:add-missing-columns`, `db:add-missing-primary-keys` and `maintenance:repair --include-expensive`, then writes the version to the marker `clouve post_upgrade_done`. It always exits 0. |
| `before-starting` | At every start, before Apache | Refuses to start when Nextcloud isn't installed. While a restore is cut off it stops nothing: when `occ status` fails or `nextcloud-config.sh` fails, it warns and goes on, so Apache starts and the assistant can reach the pod. Finishes an upgrade that was cut off. Runs `nextcloud-config.sh`. Runs the first-install settings again if a first start was cut off before they were done, and the post-upgrade steps if a start was cut off during them or they never ran for this version. |

The first install sets these, one step at a time. A step that fails logs a warning and the next one runs, because a first install that worked must not turn into a failed start over one setting:

- the admin's email, so email sign-in works;
- background jobs by cron, with the window for heavy daily jobs at 01:00 to 06:00 UTC (`maintenance_window_start=1`), and `maintenance:repair --include-expensive`;
- trash kept at most 30 days and file versions at most 365 days (`trashbin_retention_obligation` as `auto, 30`, `versions_retention_obligation` as `auto, 365`);
- AppAPI (`app_api`) disabled, because Clouve can't run external apps;
- `files_external_allow_create_new_local` off, `files_sharing hide_disabled_user_shares` set to `yes`, the update checker off (the version comes from the image) and `serverid` 1;
- Calendar, Contacts and Team folders (the `groupfolders` app), installed from the Nextcloud app store. If an earlier install left one of them in `custom_apps/`, the hook enables that copy instead. If the store can't be reached, the start goes on without them, and the AI Assistant can add them later. Each install or enable is stopped after 5 minutes. Run from `occ`, Nextcloud sets no time limit on the download itself, so a download server that stalls would otherwise hold up the first start indefinitely.

The last steps write two markers: the version to the app config value `clouve post_upgrade_done`, because a fresh install needs none of the post-upgrade steps, and the current time to `clouve first_install_done`. A first start cut off before then leaves no marker, so at a later start the `before-starting` hook runs the same steps again under the init lock and writes the markers when they are done. If the start was cut off during the repair, maintenance mode is still on, and the hook turns it off first.

### Starts that were cut off

`occ maintenance:repair` turns maintenance mode on for its whole run and puts back the value it found only at the end. A container killed during a repair leaves maintenance mode on with no upgrade pending: Nextcloud answers every page with 503, and the health check still passes, so nothing restarts it. The first-install settings and the post-upgrade steps both run that repair, so each writes a marker when it finishes, and a later start finishes whatever was left undone:

- `clouve first_install_done` (app config) is missing after a first start cut off during the first-install settings. The `before-starting` hook turns maintenance mode off if it is on, and runs the settings again under the init lock. With that marker missing, Apache hasn't served since the install, so nobody can have turned maintenance mode on deliberately.
- `clouve post_upgrade_done` (app config) holds the version whose post-upgrade steps last ran to the end. The steps delete it first and write it last, so a start cut off during them always leaves it missing, and the `before-starting` hook then turns maintenance mode off if it is on and runs them again under the init lock. (If the steps can't delete the marker, they don't run at all.) When the next start is itself an upgrade, `occ upgrade` keeps the maintenance mode it finds on, so the `post-upgrade` hook turns it off first when the marker is missing. If it can't, the steps still run but write no marker, so a later start tries again. A marker that names another version means the steps never began for this one, as after an upgrade that the AI Assistant finished at runtime with `occ.sh --init-lock upgrade`. The hook then runs them and leaves maintenance mode as it is: someone else turned it on, maybe on purpose. The `post-upgrade` hook, too, leaves maintenance mode alone when it finds the marker there.
- A repair that dies on the way, such as an app's repair step that throws an Error (occ doesn't catch one), leaves maintenance mode on too. The steps then turn it off again. If they can't, they write no marker, so the next start tries again.
- `data/clouve-backups/BACKUP-IN-PROGRESS` belongs to the AI Assistant's `backup.sh`. It writes the file, with the backup's name on the first line, just before it turns maintenance mode on, and removes it just after it turns maintenance mode off. It holds an exclusive `flock` on the file all that time. It writes no marker when it leaves maintenance mode alone (with `--no-maintenance`, or when maintenance mode was already on). A marker still there at a start, with nobody holding its lock, means the backup died with the old container. The root entrypoint, which can enter the root-only backups folder, then turns maintenance mode off, removes the marker and logs one line that names the backup. A marker that is locked belongs to a backup the AI Assistant started in this container, and the root entrypoint leaves it and maintenance mode alone. It reads the name only from a file root owns, and never uses it as a path. While an upgrade is pending, it waits for a later start.
- `data/clouve-backups/RESTORE-IN-PROGRESS` is there after a restore that was cut off or failed half way. Then none of the above runs, so nobody gets into a half-restored instance, and an upgrade to a newer image waits too (step 11). The start still goes on when occ can't run, and the health check counts the pod as healthy, so the assistant can reach it to finish or undo the restore. The hooks run as www-data and can't see into the backups folder, so the root entrypoint leaves a note at `/run/clouve/restore-cut-off` for them.

Don't edit or delete the two `clouve` markers. Without `clouve first_install_done`, the next start applies the first-install defaults again, over any change made since.

### Settings kept in step with the environment

`nextcloud-config.sh` runs at every start from the `before-starting` hook, and once more after the first install. Nextcloud writes `config.php` only when a value changes, so a restart that changes nothing leaves the file alone.

| Setting | Value |
|---|---|
| `dbhost`, `dbname`, `dbuser`, `dbpassword` | From `NEXTCLOUD_DB_*`. A clone gets a new database host in its environment and keeps the old one in `config.php`. |
| `overwrite.cli.url` | `NEXTCLOUD_URL`. A change logs `Nextcloud URL has changed: <old> -> <new>`, the line `./test.sh` looks for. |
| `overwriteprotocol` | `https` when the URL is https. Removed when it is http, so local runs work. |
| `trusted_domains` | `localhost` and the URL's host, each added when missing. Nothing is removed, so a custom domain leaves the Clouve host working. |
| `trusted_proxies`, indexes 0 to 2 | `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`, the ranges the image's Apache already trusts for `X-Real-IP`. |
| `memcache.distributed`, `memcache.locking` | `\OC\Memcache\Redis`, which talks to Valkey. |
| `redis` | `host` is `/run/clouve/valkey/valkey.sock` and `port` is `0`, a unix socket. |
| `preview_concurrency_new`, `preview_concurrency_all` | From the memory limit (see "Memory limits"). |
| `files.chunked_upload.max_size` | `41943040` (40 MiB) when it is unset, 0 or less (chunking off) or above 50 MiB. A value from 1 byte to 50 MiB stays (see "Uploads"). |

A hand edit of these keys reverts at the next restart, with two exceptions: `trusted_domains` only gets its two entries back and keeps any extra ones, and a chunk size from 1 byte to 50 MiB stays. `overwritehost` stays unset on purpose. It would make every Host trusted, but once a customer adds a custom domain whose DNS isn't live yet, logins on the Clouve host would redirect to a host that doesn't resolve.

The database password reaches `occ` only through a mode 600 JSON file in `/run/clouve/tmp`, which `occ config:import` reads and the script deletes right after. The next start deletes any such file that a killed run left behind. The script exits 1 only when `occ` won't start. Every other failure is a warning, and the script goes on with the next setting.

### Clones and custom domains

When a customer adds a custom domain, the platform replaces the Clouve host with the new one in the app's environment and restarts the app, and the ingress keeps serving both hosts. The next start sets `overwrite.cli.url`, adds the new host to `trusted_domains` and keeps the old one. A later change back adds nothing and logs the change line again. `./test.sh apps/nextcloud` runs that round trip locally.

A clone copies the volumes and rewrites the environment to new hosts, but `config.php` on the copied volume still names the old database. `occ` can't start against a database it can't reach, not even for `config:system:set`. So once the database answers, the entrypoint fixes the four database settings in `config.php` with a short PHP script that doesn't use `occ`, before the official entrypoint runs. The script runs as www-data and never as root, because `config.php` is code that www-data can change. It replaces the file by rename, so a failure leaves `config.php` as it was, and the file keeps its owner and mode. `nextcloud-config.sh` runs the same repair when `occ status` fails.

### Memory limits

At every start the entrypoint reads the container's memory limit (cgroup v2 `memory.max`, then v1; `max` or no file means no limit). Apache's `MaxRequestWorkers` is the limit in MB divided by 50, at least 10 and at most 150, and `ServerLimit` matches it. `preview_concurrency_new` and `preview_concurrency_all` are 1 and 2 below 1536 MB, 2 and 4 below 3584 MB, and 4 and 8 from there up.

| Memory limit | Apache workers | `preview_concurrency_new` / `_all` |
|---|---|---|
| 512 MB | 10 | 1 / 2 |
| 1 GB | 20 | 1 / 2 |
| 2 GB | 40 | 2 / 4 |
| 4 GB | 81 | 4 / 8 |
| 8 GB or more, or no limit | 150 | 4 / 8 |

The database wrapper reads its own limit the same way and sizes InnoDB's buffer pool at a quarter of it, between 128 MB and 4096 MB (256 MB with no limit).

## Cron, Valkey and the health check

### Cron

Background jobs run from cron every 5 minutes. BusyBox `crond` runs the image's crontab for www-data (`*/5 * * * * php -f /var/www/html/cron.php`), and its jobs inherit the container's environment.

The entrypoint starts `crond` in the background, but only once `config.php` says `'installed' => true` and the volume's `version.php` is identical to the image's. On a start that upgrades, `config.php` already says installed while the official entrypoint is still copying the new code over the old, and `cron.php` must not run on that mix. `version.php` is the last file the copy writes. After that, `cron.php` skips itself until `occ upgrade` is done.

### Valkey

Valkey listens on a unix socket, `/run/clouve/valkey/valkey.sock` (mode 700, owned by www-data), and has no TCP port. It keeps nothing on disk, is capped at 128 MB and drops the least recently used key when it fills, because it holds only cache entries and short file locks. `start-valkey.sh` restarts it a second after any exit and logs one `[valkey] exited` line each time.

Web requests, cron and the assistant's `occ` commands share this one cache and lock store. Without a shared cache, `occ` changes reach the web pages late: mounts after up to 5 minutes, group names after 10 and user display names after up to 24 hours.

### The health check

The platform has no startup probe, so `x-clouve-healthcheck` is both the liveness and the readiness probe, with the same numbers. It is a command and not an HTTP check, because kubelet sends the pod's IP as the Host header and Nextcloud answers any host outside `trusted_domains` with HTTP 400. The platform runs it as `sh -c /clouve/nextcloud/installer/healthcheck.sh`, and sh is dash, so the script stays POSIX. It reports:

1. Healthy while a restore is cut off, whatever else is true: the assistant's `RESTORE-IN-PROGRESS` says so, when it is a file of root's in a folder only root can write to. The root entrypoint's note in `/run/clouve` doesn't count: it is for the hooks, and it stays until the next start, also after a restore that the assistant finished without one. Nextcloud can't work while a restore is cut off, a restart can't help, and a pod that isn't Ready has no address for the assistant.
2. Healthy while the init lock is held, whatever else is true. The official entrypoint holds the lock during an install and an upgrade, the `before-starting` hook takes it to recover an interrupted upgrade, and the assistant's backups, restores and long `occ` jobs take it too. A container killed halfway through such a job is worse off than one that waits. The lock file is www-data's, so the probe asks it as www-data, with a shared lock that it gives up after 3 seconds, and only on a plain file: it never creates the file, it follows a link there only with www-data's rights, and liveness and readiness, which run at the same moment, never take the lock from each other. Only flock's "held" counts. For the same reason the build makes the official entrypoint open the lock read-only.
3. Unhealthy when Valkey doesn't answer `PING` within 3 seconds.
4. Otherwise it fetches `http://127.0.0.1/status.php` with `Host: localhost`, and it is healthy when the answer is HTTP 200 and the JSON says `"installed":true`. Maintenance mode and a pending upgrade also answer 200, so they count as healthy. A database that is down answers HTTP 500, and no answer at all is unhealthy.

The agent-enabled siblings sit behind headless Services, so a pod that isn't Ready drops out of DNS and the assistant loses its SSH connection to it. That is why a pod in maintenance mode has to stay healthy: it is the one the assistant needs to fix. Reporting healthy under the init lock has a cost on Kubernetes: during a first install or an upgrade the pod is Ready before Apache listens, so the ingress can return 502 for a minute or two. A liveness kill in the middle of an upgrade would be worse. A failing probe prints its reason on stderr, which kubelet shows in the probe-failed event.

The manifest numbers are `initialDelay` 60, `interval` 30, `timeout` 15, `failureThreshold` 15 and `successThreshold` 1. A container that never passes is restarted after about 8.5 minutes.

### Reloading Apache

Valkey's restart loop and `crond` ignore SIGHUP. Apache, once it is PID 1, answers an ungraceful restart (`apache2ctl restart` or `kill -HUP 1`) by sending SIGHUP to every process in its process group, and in this container that is every process the entrypoint started. Never run either command here. If Apache has to reload, run `apache2ctl graceful`, and only when PID 1 is apache2. While an install or an upgrade runs, Apache is not up yet, and `graceful` then starts an Apache of its own.

## The AI Assistant's SSH channel

Both images ship `openssh-server`, `sudo` and a `clouve-ops` account with passwordless sudo, so the assistant has effective root in the containers, held back only by the safety rules in its persona and skill. The password is `CLOUVE_OPS_PASSWORD`. The platform generates it and sets it on all three containers, and `start-clouve-ops-sshd.sh` applies it with `chpasswd` and runs `sshd -D`. The script starts sshd only when the variable is set.

- Each container makes its own SSH host keys when it starts (`ssh-keygen -A`). The images contain none, so no two deployments share a host key. A container that starts from the image again makes new keys. That happens at every restart on Kubernetes, and on Docker when the container is recreated (a plain `docker restart` keeps them). A saved key would then be stale, so the persona has the assistant connect with `UserKnownHostsFile=/dev/null` and `StrictHostKeyChecking=accept-new`: it saves no key and accepts the current one.
- Both entrypoints remove `CLOUVE_OPS_PASSWORD` from their own environment right after they start the SSH kit. The kit was forked with the variable and keeps its own copy, which it gives to `chpasswd`, so the removal doesn't wait for it. The password logs in as `clouve-ops`, who has passwordless sudo, and any process that could read it could get root. In the nextcloud container, every www-data process inherits the entrypoint's environment (Apache's PHP, the hooks, cron jobs), so any Nextcloud app's PHP could read it. Valkey starts before that point, so the subshell that launches it drops the variable first. In the database container, mariadbd would carry it, and anything running as `mysql` can read mariadbd's environment. The official MariaDB entrypoint already drops its own passwords before it starts mariadbd. The assistant doesn't need the variable from either container, because its environment reader skips it.
- `sudo` resets the environment, so `occ` run over SSH has none of the container's variables. That is why PHP's limits are plain values in `zz-clouve.ini`, and why the cache, URL and database settings live in `config.php`. `occ` then sees the same limits and settings as Apache, prints clean JSON with `--output=json` and uses the same Valkey. The assistant runs it as `sudo -u www-data php /var/www/html/occ ... -n`.

## Apache

The image adds two things to Apache's configuration when it is built, and the entrypoint adds a third at every start.

- An HSTS header, `max-age=15552000` without `includeSubDomains`. It is for Nextcloud's setup check, which falls back to `http://localhost` when it can't reach the public URL. The ingress sends its own header on TLS hosts.
- A rewrite rule inside `<VirtualHost *:80>` (`apache-wellknown.inc`) that sends `/.well-known/caldav` and `/.well-known/carddav` to `https://<host>/remote.php/dav/`. It applies only when `X-Forwarded-Proto` is `https`, so local http runs keep the stock redirect. Without it, calendar and contacts apps behind the TLS ingress are redirected to `http://`. A file in `conf-enabled` has no effect on this, so the Dockerfile inserts the rule into the default site and fails the build if the insert doesn't apply.
- `conf-enabled/zz-clouve-mpm.conf`, which the entrypoint writes at every start from the container's memory limit. It sets `ServerLimit` and `MaxRequestWorkers` (see "Memory limits").

## Uploads

The platform's ingress caps a request body at 50 MB and gives up on a connection that stays quiet for 60 seconds, and TLS ends there. That is no limit on a long transfer: a 200 MiB download through the AI Assistant's Files pane that took almost 4 minutes arrived whole on the test cluster. Nextcloud's default upload chunk is 100 MiB, which the cap would refuse. So at every start `nextcloud-config.sh` sets the system key `files.chunked_upload.max_size` to 40 MiB (41943040 bytes) when it is unset, above 50 MiB, or 0 or less. A value of 0 or less turns chunking off: the web UI then sends each file as one request, and anything over 50 MiB would get HTTP 413 too. With 40 MiB, the web UI uploads large files in chunks that fit. A value an admin sets from 1 byte to 50 MiB stays. Nextcloud 35 reads only this key: the older app key `files max_chunk_size` has no effect. A desktop or WebDAV client that sends bigger single requests gets HTTP 413 until its chunk size is lowered. The cap belongs to the platform, not to the image. PHP (`upload_max_filesize` and `post_max_size`, 512M) and Apache (`LimitRequestBody`, 1 GiB) both allow more.

## A half-finished first install

The official entrypoint copies `version.php` onto the volume before it runs `occ maintenance:install`. If the first start is cut off, or the install fails, the volume holds `version.php` but `config.php` doesn't say `'installed' => true`. The entrypoint then treats the code as installed and never tries the install again, and Nextcloud would show its web installer to any host, with the database password in the page source.

The image refuses to let that happen:

- The `pre-installation` hook deletes `config/CAN_INSTALL` before every first install, so the web installer has no way to open.
- At every start the `before-starting` hook asks `occ status`. When Nextcloud isn't installed, it logs `Nextcloud is not installed; refusing to start. See apps/nextcloud/README.md, "A half-finished first install".` and exits 1. The container stops and restarts, over and over, and Apache never starts.

An install can't be finished by hand from that state. Reset it, and only when nobody has used the instance: the reset deletes everything in the database and in the data folder. If the instance has users or files you want to keep, don't reset it. Restore from a backup instead.

1. Stop the Nextcloud container and leave the database running.
2. Drop the `nextcloud` database and create it again, empty. The server's defaults (utf8mb4, `utf8mb4_bin`) apply, and the `nextcloud` user keeps its privileges.
3. On the Nextcloud volume, delete `config/config.php` and everything in `data/` and `custom_apps/`. The first install downloads Calendar, Contacts and Team folders into `custom_apps/`. The next install enables a copy it finds there as it is, instead of downloading the store's current release.
4. Delete `version.php` from the volume, last. With it gone, the next start installs from scratch.
5. Start the Nextcloud container.

For a local run:

```bash
docker stop nextcloud_app
docker exec nextcloud_mariadb sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mariadb -uroot -e "DROP DATABASE nextcloud; CREATE DATABASE nextcloud"'
docker run --rm --volumes-from nextcloud_app --entrypoint sh r.clv.zone/e2eorg/nextcloud -c '
  cd /var/www/html && rm -f config/config.php &&
  find data custom_apps -mindepth 1 -delete &&
  rm -f version.php'
docker start nextcloud_app
```

When there is nothing to keep locally, `./start.sh nextcloud --cleanup` is quicker: it removes all the volumes and starts again.

On a Clouve deployment the reset is an operator task, done with `kubectl` against the deployment's database and volume. The AI Assistant is told not to attempt it and to ask for help from Clouve.

## Upgrades

The Nextcloud version comes from the image. Nothing re-applies a newer manifest to a running deployment, and only a new image reaches it, so any setting added later needs a default in the image.

To upgrade, raise the tag on the `FROM` line of `image/Dockerfile` and `appVersion` in `clv-docker-compose.yml`. They must name the same version, and `tests/nextcloud-manifest.test.sh` checks that. Then build and publish the images like any other app. Take a backup first; the AI Assistant has a script for it in its skill.

- One major version at a time. When the image is more than one major ahead of the volume (35 to 37, say), the official entrypoint prints an error and exits, and it refuses to downgrade. Go through each major in turn: 34 to 35, then 35 to 36.
- At the next start the official entrypoint copies the new code over the old and deletes the files it doesn't know, except `config/`, `data/`, `custom_apps/`, `themes/` and `version.php`. Don't keep your own files elsewhere in `/var/www/html`. Then it runs `occ upgrade`, and the `post-upgrade` hook adds the indexes, columns and primary keys the new version expects and runs the expensive repairs.
- Every `occ upgrade` (the official entrypoint's, or the recovery's below) also updates each enabled app that has a newer release in the app store, with no time limit on the download when it runs from `occ` (`lib/private/Installer.php:238`). A download server that stalls then holds the init lock and keeps the site down while the probe reports healthy, and the image can't put a limit on the official entrypoint's own upgrade.
- The web updater is off (the official image disables it), and so is the update checker.
- The database image upgrades itself the same way: `MARIADB_AUTO_UPGRADE=1` is set in the image, and the official MariaDB entrypoint runs `mariadb-upgrade` when a newer engine starts on an older data directory.

### An upgrade that is cut off

The official entrypoint copies `version.php` before it runs `occ upgrade`, so a killed upgrade is never retried. It leaves maintenance mode on, the old version in `config.php` and log level 0. The `before-starting` hook finds this at the next start, because `occ status` says `needsDbUpgrade`, and finishes the job:

- It first turns maintenance mode off, and sets the log level back to 2 if it was 0. Nobody can use Nextcloud in the meantime: Apache isn't running yet, and while an upgrade is pending, Nextcloud's pages only say that it needs `occ upgrade`.
- It runs `occ upgrade` again while holding the init lock, so the health check counts the start as healthy for as long as the upgrade takes. `occ upgrade` then works as it does from the official entrypoint: it turns maintenance mode on, turns it off once the upgrade has worked, and puts back the log level it found. Run with maintenance mode already on, it would leave it on, and a second kill during the slow steps below would leave Nextcloud in maintenance mode with no pending upgrade for the next start to finish. So if maintenance mode doesn't go off before the upgrade, the hook tries again once the upgrade has worked.
- When the upgrade works, it runs the post-upgrade steps (the same four commands as the `post-upgrade` hook) under the same lock. A start cut off during them leaves the marker `clouve post_upgrade_done` missing, and the next start runs them again (see "Starts that were cut off").
- When the upgrade fails, it stays pending. Maintenance mode is on if the upgrade itself failed, and off if `occ upgrade` never got that far (flock couldn't open the lock file, or PHP died while occ started). Either way nobody can use Nextcloud until the upgrade is done. The hook logs a warning, sets the log level back if a crash left it at 0, and the start goes on. The pod stays reachable, so the AI Assistant can SSH in and find the cause. Then, as rule 4 of its persona says, it turns maintenance mode off (and the log level from 0 back to 2) and runs the upgrade under the init lock. The order matters: a successful `occ upgrade` that starts with maintenance mode on leaves it on.
- While `data/clouve-backups/RESTORE-IN-PROGRESS` exists, a restore was cut off. The hook then leaves the pending upgrade and maintenance mode alone, because finishing either one would let people into a half-restored instance. It learns of the marker from the root entrypoint's note, because www-data can't see into the backups folder.

## The database image

`image/mariadb/` builds `nextcloud-mariadb` from `mariadb:12.3`, the newest MariaDB that Nextcloud 35 supports (10.11 to 12.3).

- `/etc/mysql/conf.d/nextcloud.cnf` sets what Nextcloud needs: `READ-COMMITTED` isolation, the `ROW` binlog format, utf8mb4 with the `utf8mb4_bin` collation, one file per table, a 256M redo log (the server info check warns about anything below 128M), 200 connections and no name resolution.
- The wrapper `entrypoint.sh` writes `innodb_buffer_pool_size` to `/etc/mysql/conf.d/zz-clouve-memory.cnf` at every start (see "Memory limits"), starts the clouve-ops sshd, removes `CLOUVE_OPS_PASSWORD` from its own environment and then runs the official MariaDB entrypoint. If it can't write the file, MariaDB starts with its default pool.
- `MARIADB_AUTO_UPGRADE=1` is set in the image, not the manifest, for the reason given under "Upgrades".
- The clouve-ops sshd kit is copied from the WordPress images, with only the comments that name WordPress changed.

## Running locally

```bash
cd magneto
./build.sh nextcloud    # builds nextcloud and nextcloud-mariadb for this machine
./start.sh nextcloud    # starts nextcloud, nextcloud-mariadb and magneto-agent
```

The first start copies Nextcloud onto the volume, installs it and downloads the three apps, which takes about a minute. Watch `docker logs -f nextcloud_app` for `resuming normal operations`. A `healthy` status doesn't mean Nextcloud is ready yet, because the health check reports healthy while an install or upgrade holds the init lock.

| What | Where | Login |
|---|---|---|
| Nextcloud | http://localhost:8080 | `admin` / `Admin@123`, email `admin@example.com` |
| AI Assistant | http://localhost:8081 | `admin` / `Admin@123` |
| Database | `nextcloud-mariadb`, inside the compose network | `nextcloud` / `nextcloud_password`, root password `root_password` |
| clouve-ops over SSH | between the three containers | `clouve-ops` / `clouve_ops_dev_password` |

`NEXTCLOUD_URL` is `http://${TEST_DOMAIN:-t1.test.clv}:${TEST_PORT:-8080}`, so Nextcloud's own address is `http://t1.test.clv:8080` unless you set `TEST_DOMAIN` and `TEST_PORT`. Use `http://localhost:8080` in the browser: `localhost` is always a trusted domain, and `t1.test.clv` works only where that name resolves to your machine. These logins are for local runs only. On a Clouve deployment the platform generates the passwords and shows the login on the dashboard.

The AI Assistant needs model access, which a local run takes from your shell. A Clouve deployment uses a managed key and never reads these:

```bash
export MAGNETO_AGENT_LLM_BASE_URL=https://llm.example.com MAGNETO_AGENT_LLM_KEY=<litellm-key>
# or: export ANTHROPIC_API_KEY=<your-anthropic-key>
./start.sh nextcloud
```

Commands you are likely to need:

```bash
docker exec -u www-data nextcloud_app php occ status --output=json
docker exec -u www-data nextcloud_app php occ app:list
./stop.sh nextcloud                # stop and keep the data
./stop.sh nextcloud --cleanup      # stop and delete the volumes
./test.sh apps/nextcloud           # change the URL and check the log line
./test.sh apps/nextcloud custom.domain.com custom2.domain.com 8090
```

## Files

```
nextcloud/
├── README.md                       # This file
├── logo.png                        # 256x256, rendered from Nextcloud's logo.svg
├── docker-compose.yml              # Local run: nextcloud, nextcloud-mariadb and magneto-agent
├── clv-docker-compose.yml          # Marketplace manifest
└── image/
    ├── Dockerfile                  # The Nextcloud image
    ├── build.config                # Image names for build.sh
    ├── context/nextcloud/
    │   └── CONTEXT.md.tpl          # The AI Assistant's persona
    ├── installer/
    │   ├── entrypoint.sh           # Root wrapper around the official entrypoint
    │   ├── lib.sh                  # Shared functions: admin name, URLs, sizing, occ helpers
    │   ├── nextcloud-config.sh     # The settings kept in step with the environment
    │   ├── healthcheck.sh          # The liveness and readiness probe
    │   ├── patch-official-entrypoint.sh  # The build's two edits to the official entrypoint
    │   ├── start-valkey.sh         # Starts Valkey and restarts it when it exits
    │   ├── valkey.conf
    │   ├── start-clouve-ops-sshd.sh
    │   ├── clouve-ops-sshd.conf
    │   ├── apache-clouve.conf      # The HSTS header
    │   ├── apache-wellknown.inc    # The CalDAV and CardDAV discovery redirect
    │   └── hooks/                  # pre-installation, post-installation, post-upgrade, before-starting
    └── mariadb/
        ├── Dockerfile              # The database image
        ├── entrypoint.sh           # Sizes the buffer pool, starts the ops sshd, runs the official entrypoint
        ├── nextcloud.cnf
        ├── start-clouve-ops-sshd.sh
        └── clouve-ops-sshd.conf
```

## Tests

Run these from the repo root:

```bash
bash tests/nextcloud-image.test.sh       # needs Docker
bash tests/nextcloud-entrypoint.test.sh  # needs Docker and the image that ./build.sh nextcloud builds
bash tests/nextcloud-mariadb.test.sh     # needs Docker
bash tests/nextcloud-manifest.test.sh    # needs only python3 with PyYAML
```

- `nextcloud-image.test.sh` runs inside `nextcloud:35.0.2-apache` with no network, with the installer folder mounted read-only. It checks `lib.sh` (the admin-name cleanup, URL parsing, the memory sizing, the `trusted_domains` merge, the repair of `config.php`, the markers, a backup that was cut off, a new disk's top folder of root's, and the init lock file, also while a www-data process swaps a link in and out), `valkey.conf`, `start-valkey.sh`, `healthcheck.sh` (every state, first with fake `flock`, `valkey-cli` and `curl`, then with the real ones), `patch-official-entrypoint.sh` (on this image's own `/entrypoint.sh`, which it then runs: `version.php` runs as www-data and has to give a version number), and `nextcloud-config.sh` and the four hooks against a fake `occ`. The fake's repair turns maintenance mode on while it runs, as the real one does, so a start killed during it leaves maintenance mode on, and the next start has to turn it off. A last section runs the same scripts against a real SQLite install, kills a real repair half way with the help of a test app whose repair step waits, and takes about a minute and a half. `NC_TEST_SKIP_REAL=1` skips it.
- `nextcloud-entrypoint.test.sh` runs the image that `./build.sh nextcloud` builds (`r.clv.zone/e2eorg/nextcloud`). It first checks that the image's installer, hooks and persona match the checkout, and stops when they don't. Then it starts the image with no network and a database host that doesn't resolve, so `installer/entrypoint.sh` stays in its wait for the database, and checks what the entrypoint did up to there: `/proc/1/environ` holds the cleaned login and the decoded email; the `MYSQL_*` copies reach the processes it starts only before the first install; Valkey is started without `CLOUVE_OPS_PASSWORD`, and of root's processes only PID 1 and its own subshells still show it, so nothing started after the sshd has it, while `clouve-ops` still logs in over SSH. A first start without `NEXTCLOUD_ADMIN_PASSWORD` exits 1, prints no value and leaves no `version.php`. On a volume whose top folder is root's, with mode 755 and `lost+found` in it (a new Kubernetes disk), the start gives the folder to www-data with mode 1777, leaves `lost+found` alone and lets www-data make the init lock. A later start leaves a folder of www-data's with mode 755 as it is. With a restore marker in the root-only backups folder, the entrypoint leaves the note in `/run/clouve` that www-data can see, and a restart after the marker is gone removes it. In the image's `/entrypoint.sh`, the init lock is opened read-only and `version.php` is read through `run_as`. The test names its containers and volumes `nc-tf-ep-*` and removes them when it exits.
- `nextcloud-mariadb.test.sh` builds the database image and starts it with a 512 MiB limit, with a 2 GiB limit and `CLOUVE_OPS_PASSWORD`, and with no limit. It checks Nextcloud's settings, the buffer pool, MariaDB 12.3, `MARIADB_AUTO_UPGRADE=1` and the clouve-ops sshd, including that mariadbd's environment has no `CLOUVE_OPS_PASSWORD` while clouve-ops can still log in. It also runs the wrapper alone against made-up cgroup trees. The build needs network access, and the test removes its `nc-t1-*` containers, volumes and image when it exits.
- `nextcloud-manifest.test.sh` checks both compose files against the platform's rules: the variables, values and types, the secrets, container names, ports, volumes, the probe, the listing text, `x-clouve-agent`, and that the local file's service order and names suit `./test.sh`. It also checks that this README still has the heading `## A half-finished first install`, which the `before-starting` hook's refusal message cites. It builds nothing and starts nothing.

Three more checks cover this app:

- `./check-manifests.sh` checks that the listing description fits the publish wizard's 1000 characters.
- `bash tests/persona-hosts.test.sh` renders the persona the way the agent does and checks that it never carries a password.
- `./test.sh apps/nextcloud` runs the URL-change round trip against a real local stack.

## References

- Nextcloud admin manual: https://docs.nextcloud.com/server/35/admin_manual/
- `occ` commands: https://docs.nextcloud.com/server/35/admin_manual/occ_command.html
- The official Docker image: https://github.com/nextcloud/docker
- The packaging guide: `../../README.md`
