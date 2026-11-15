# LimeSurvey

LimeSurvey 7.10.0 (build 261109) with a MariaDB 11.8 database, packaged for Clouve. The image installs a new site by
itself, upgrades a LimeSurvey 6 install in place the first time it starts on it, and runs the `clouve-ops` SSH
channel that Clouve's AI Assistant uses. It also runs without the assistant: the sshd starts only when the platform
sets `CLOUVE_OPS_PASSWORD`.

## What is in the image

The runtime (PHP 8.4, Apache on port 8080) is upstream's Docker image, `martialblog/limesurvey:7.9.1-261102-apache`.
The LimeSurvey code is upstream's own release zip, checked against its published SHA-256 in the build. Upstream's
Docker image trails each release by about a week, so the zip is the source of the code.

The code is kept in `/clouve/limesurvey/package`. `/var/www/html` is a volume, and the entrypoint fills it from the
package. `/var/www/html/upload` is a second volume inside the first.

The build changes two files of the package and stops when either change fails:

- `application/helpers/update/updates/Update_700.php` gets upstream's fix `6487164b`
  (`image/Update_700-fix-6487164b.patch`). Without it, the database update from 6 to 7 drops the answers of one
  question, and still reports success, when a ranking question's old column names collide with another question's.
  7.10.0 doesn't have the fix. A release that has it skips the patch.
- `application/config/version.php` gets `updatable` set to false. The zip carries a build number, which turns the
  in-app updater (ComfortUpdate) on, and that updater would put code on the volume that is newer than the image.

Apache's configuration, its log, run and lock folders and everything under `/clouve` belong to root in this
image, so PHP code can't change them. An Apache drop-in (`image/installer/apache-clouve.conf`) adds these rules:

- It denies web access to three folders under the web root: `clouve/` (the image's state files and the upgrade's
  backup), `node_modules/` and `installer/`. Apache reads no `.htaccess` file in them.
- In `upload/` PHP is off, a file with a PHP extension gets 403, and no `.htaccess` file is read. LimeSurvey loads
  an uploaded plugin's code itself, so plugins in `upload/plugins/` work as before. A plugin that serves a PHP file
  of its own straight from `upload/plugins/` gets 403. The files that participants upload with their answers
  (`upload/surveys/.../fu_...`) are denied by the drop-in, as LimeSurvey's own `.htaccess` did.
- The access log, which is the container's log, leaves out the query string and the Referer. So participant tokens
  (`?token=`), prefilled answers and password-reset keys in a query string are not logged. A request line reads
  `"GET /index.php/123456 HTTP/1.1"`. The path is still logged, and with it anything that is part of the path: the
  admin's password link (`/index.php/admin/authentication/sa/newPassword/param/<key>`) and hand-written token
  addresses such as `/index.php/<sid>/tk-<token>`. Requests of the health check (a User-Agent with `check`,
  `health` or `probe`) are not logged, as in the base image. The error log has no Referer either.
- TLS ends at the ingress. A request it received over HTTPS (`X-Forwarded-Proto: https`) counts as HTTPS, so
  LimeSurvey marks its session and CSRF cookies Secure. A request from inside the cluster, such as a probe or the
  Customer Kit's SuiteCRM, stays on plain HTTP.

One line in the web root's own `.htaccess`, which only `www-data` can write, can still open the denied folders to
the web. That is why `clouve/` is also root's with mode 700: Apache's own user can't read the backup.

`/clouve/limesurvey/image-build` names the build: the version, the build number and 12 hex digits of a SHA-256
over every file of the installer and of the package (`image/installer/build-id.sh`). An image with a fix to the
installer or to LimeSurvey's own code has another build, and a failed upgrade is tried again by an image whose
build differs. `/clouve/limesurvey/package-stats` holds the package's number of files and folders and its size,
which the upgrade checks the volume against.

To move to the next LimeSurvey release, change the three `ARG` lines at the top of `image/Dockerfile` (version,
build number, checksum). Then change the same values, and the release's database version, in the tests: `VERSION`,
`BUILD`, `DB_VERSION` and `SHA256` in `tests/limesurvey-image.test.sh`, `VERSION` and `DB_VERSION` in
`tests/limesurvey-entrypoint.test.sh` and `tests/limesurvey-apache.test.sh`, `NEW_VERSION` and `NEW_DB` in
`tests/limesurvey-upgrade.test.sh` (its checks also spell out the version), and the version and the database
version in `tests/crm-kit.test.sh`. Change `appVersion` in `clv-docker-compose.yml` here and in `bundles/crm-kit/`.
Then run the tests below.

## Run it locally

```bash
./build.sh limesurvey        # from the repository root
./start.sh limesurvey
```

LimeSurvey answers at http://localhost:8080. The admin account and its made-up password are in
`docker-compose.yml`, and so is the made-up `CLOUVE_OPS_PASSWORD` for local runs.

## Variables

| Variable | Default | What it does |
| --- | --- | --- |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD` | `limesurvey-mariadb`, `3306`, `limesurvey`, `limesurvey`, none | The database. Written into `config.php` at every start. `DB_PASSWORD` is required. |
| `DB_TYPE` | `mysql` | Only `mysql` works (MySQL and MariaDB). |
| `DB_TABLE_PREFIX` | `lime_` | The table prefix. Written into `config.php` at install only. Every start also uses it to find LimeSurvey's tables, so it has to stay what it was at install. |
| `DB_MYSQL_ENGINE` | `InnoDB` | The engine for a new install's tables. |
| `ADMIN_USER`, `ADMIN_NAME`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` | `admin`, `Administrator`, `admin@example.com`, none | The first admin account, used at install only. `ADMIN_PASSWORD` is required at every start. |
| `PUBLIC_URL` | empty | The site's address. Written into `config.php` (`publicurl`) at every start, and its host goes into `allowed_hosts.php`. A value that doesn't begin with `http://` or `https://` is written as it is, with a warning in the log. |
| `LISTEN_PORT` | `8080` | Apache's port. |
| `DB_WAIT_SECONDS` | `300` | How long a start waits for the database before it stops with status 1. |
| `INSTALL_DEMO_DATA` | unset | `true` imports the demo survey once. |
| `ENABLE_SUITECRM_INTEGRATION`, `SUITECRM_*` | unset | The Customer Kit's link to SuiteCRM (see below). |
| `CLOUVE_OPS_PASSWORD` | unset | Set by the platform when the deployment has the AI Assistant. Starts the `clouve-ops` sshd. |
| `URL_FORMAT`, `SHOW_SCRIPT_NAME`, `BASE_URL`, `HOST_INFO`, `TABLE_SESSION`, `DEBUG`, `DEBUG_SQL`, `ENCRYPT_*` | as upstream | Used once, when `config.php` and `security.php` are first written. |

Upstream's `*_FILE` variables aren't read, because upstream's entrypoint doesn't run.

## What a start does

`image/installer/entrypoint.sh` runs as root and becomes Apache at its last line. Upstream's entrypoint never runs:
it passes the admin's password to `console.php` on a command line, and it starts Apache whatever the install or the
database update did.

1. It stops with status 1 when `DB_PASSWORD` or `ADMIN_PASSWORD` is missing. Then it runs itself a second time with
   `LIMESURVEY_DB_USER` and the database settings in its environment, because the AI Assistant reads PID 1's
   environment once, as soon as the sshd answers.
2. It starts the `clouve-ops` sshd and drops `CLOUVE_OPS_PASSWORD` from its own environment, so nothing started
   later has it. Apache's PHP could otherwise read it.
3. It gives each volume's top folder to `www-data` when the folder is root's, as on a new cluster disk. Then it
   makes sure the image's state folder is safe (see "The state folder").
4. It starts a stand-in for the health check on port 8080 (`standin-router.php`, on PHP's built-in server). The
   stand-in answers `GET /` with 200 and a short page, and everything else with 503 and `Retry-After`. It runs until
   Apache takes the port. The platform restarts a container that doesn't answer for about 105 seconds, and a first
   copy of 22,000 files or an upgrade can take longer than that.
5. When the AI Assistant's skill has a restore under way (`clouve/backups/RESTORE-IN-PROGRESS`), it waits until
   that marker is gone (see "A restore that the skill has under way").
6. It waits for the database.
7. `site.sh` looks at the code on the volume, the package and the database, and installs, upgrades, waits for
   repair or refuses (see the table). Then it brings the settings in step with the environment: the database
   settings and `publicurl` in `config.php`, `localhost` and the host of `PUBLIC_URL` in `allowed_hosts.php`, and
   the upload volume's folder skeleton.
8. It stops the stand-in and becomes Apache.

`entrypoint.sh`, `site.sh`, `install.sh` and `upgrade.sh` run as root, because the state folder is root's.
Everything that reads, writes or runs a file of the web root runs as `www-data`: the copy of the code, every PHP
command, the edits of `config.php`. Root only renames top-level entries between the web root and its own folder,
and it never reads a file that `www-data` could have swapped for a link. No script puts a password on a command
line or in the log: the database client gets its password in `MYSQL_PWD`, and PHP reads its values from the
environment (`console-install.php` hands LimeSurvey's own installer the admin's password in-process).

The first admin's password (`ADMIN_PASSWORD`), the database password and, in the Customer Kit, SuiteCRM's two
passwords stay in Apache's environment. The AI Assistant reads this container's settings from there, and PHP that
can read them is already a LimeSurvey superadmin's. `CLOUVE_OPS_PASSWORD` is the one that is taken out.

| What the start finds | What it does |
| --- | --- |
| No code on the volume, no tables in the database | Installs a new site. |
| `clouve/install-in-progress` | An install was cut off. Clears it and installs again. When the database holds tables without that install's token, or the stamp is not a file of root's, it drops nothing, installs nothing and waits for repair. |
| Code and database at the package's version | Nothing. |
| Code at the package's version and an empty database | Installs into the database, under the same stamp as a new install, and keeps `security.php`. |
| Older code | Upgrades in place (next section). |
| An upgrade state file that says `backup`, `upgrade` or `restore` | Picks the upgrade up where it is safe to. |
| Newer code than the package | Ends the container with status 1. This needs a newer image. |
| No code, but tables in the database | Waits for repair. A volume was lost or swapped, and a new install would make new encryption keys that can't read the old answers. |
| Code of another version than the package's and an empty database | Waits for repair. |
| Code, and tables that don't include LimeSurvey's settings table | Waits for repair. Nothing is installed over them. |
| The package's code on an older database, with no upgrade under way | Waits for repair. With Apache up, anyone could start the database update from the browser. |
| A database newer than the code on the volume | Waits for repair. LimeSurvey itself doesn't notice old code on a newer database. |
| `DBUpdateIncomplete` in the database and no upgrade of this image under way | Waits for repair. There is no backup of ours to go back to. |
| Code, a database with data, and no `security.php` | Waits for repair. LimeSurvey would make new encryption keys. |

The site's own facts decide these: the version file on the volume, `DBVersion` and a `DBUpdateIncomplete` row. A
missing state file never means that nothing is under way.

### Waiting for repair, and ending

A start that must not run LimeSurvey either ends the container or waits for repair.

It ends the container, with status 1, when nobody can put the site right from inside: a missing password, a
database that never answers, code on the volume that is newer than the image. A new install that failed ends it
too, and the next start clears that install and installs again.

In every other case it waits for repair, because a container that stops and starts in a loop leaves nobody a way
in. Apache doesn't start. The stand-in page says "LimeSurvey needs attention from Clouve support", the
`clouve-ops` sshd is up, and the container runs until someone restarts it. The log has one line that starts with
`[clouve-upgrade] FAILED limesurvey <from> -> <to>:` and says what was found, and `clouve/needs-attention` holds
the same reason for the AI Assistant, which can't read the container's log. To the platform a waiting container looks healthy, so that log line is what
an alert has to look for. A stop request ends the wait at once, with status 0. The runbook below has the steps.

### The state folder

`/var/www/html/clouve` holds the image's state files and the upgrade's backup. It is root's with mode 700.
Everything the image writes there is root's too, folders with mode 700 and files with mode 600, so PHP code can
read neither the database dump nor a state file, and can plant nothing inside. The old code inside an upgrade's `code/` folder keeps its own owners.

The web root itself is `www-data`'s, so PHP code can still rename the folder and put one of its own in its place.
At every start the entrypoint therefore uses the folder only when it is a real folder of root's. Anything else (a
link, a file, a folder of another owner) is renamed to `clouve.untrusted-<UTC time>` without being read, a new
folder is made, and the log says so. Root's scripts then work from inside the folder, so a swap while they run
changes nothing either. Below it, the image acts only on a state file, a dump or an old code folder that is
root's and no link. A volume from a build of this image that kept the folder as `www-data`'s loses its upgrade
state once this way. No such volume exists outside tests.

When the folder was moved aside and the code and the database agree, the start goes on. When they don't agree, it
waits for repair, and the log line names the folder that was moved aside: if that folder holds an upgrade's backup,
it is the way back, so keep it.

### A restore that the skill has under way

The AI Assistant's LimeSurvey skill writes `clouve/backups/RESTORE-IN-PROGRESS` before its `restore.sh` changes the
database and removes it when the restore is whole. A container that restarts in between finds a half-loaded
database. The entrypoint then decides nothing: it logs one line, shows "LimeSurvey is being restored" on the
stand-in page, writes `clouve/needs-attention` with `kind=restore`, keeps the sshd up and waits, for as long as
it takes. When the marker is gone, it removes the note and the same container goes on with a normal start. A start that waits for repair does the same when a restore comes and goes.

### Who owns config.php and security.php

Both belong to `www-data` with mode 600. `config.php` holds the database password and `security.php` the encryption
keys, so neither is readable by other accounts. The earlier image left them as root's with mode 644. That protected
nothing, because the folder they are in belongs to `www-data`, which can replace any file in it. A start now makes
them `www-data`'s, and root never reads or runs a file on the volume.

`security.php` must never be lost or replaced. With other keys, encrypted answers, encrypted participant data and
the stored SMTP password can't be read. The upgrade keeps the file, and a backup has to include it.

### Tables of existing installs stay MyISAM

The earlier image never passed `DB_MYSQL_ENGINE` on, so its installs have MyISAM tables and `'mysqlEngine' =>
'MyISAM'` in `config.php`. The image leaves both as they are. New installs get InnoDB.

## The in-place upgrade

`image/installer/upgrade.sh` runs before Apache starts, behind the stand-in. With new code on an old database,
LimeSurvey lets anyone start the database update from the browser, so the update is finished before Apache is up.

It keeps everything in `clouve/upgrade-<from>-to-<to>/` on the code volume (root's, mode 700, files 600):

| File | What it is |
| --- | --- |
| `state` | `phase=` backup, upgrade, restore, failed or done, the step within the phase (`step=`, `rstep=`), both versions, the image's build and the maintenance mode from before (`maint=`) |
| `db.sql.gz` | The database dump |
| `backup-complete` | Written once the dump is checked: its SHA-256, the table count and the database version |
| `db-touched` | Written and synced before the upgrade's first write to the database. A restore loads the dump only when this file is there. It goes when the dump is loaded again, or when the state says done |
| `reserve` | 256 KB that the upgrade gives up when the volume is full, so that it can still write its state |
| `active-plugins`, `plugins-left-off` | The added plugins that were on before the update, and those left off after it |
| `code/` | The old code |
| `updatedb.log` | What LimeSurvey's database update printed |

Beside the folder, in `clouve/`:

| File | What it is |
| --- | --- |
| `upgrade-attempts` | How often this build has begun to change the site |
| `upgrade-failed` | This build gave up, and why. No start tries again until the file is removed or the image's build differs |
| `upgrade-skipped` | The last start did not try the upgrade, and why (too little space, too few inodes, the backup could not be made). The site is on the old version. It never stops a retry: the next start checks again, and the file goes when an upgrade runs |
| `needs-attention` | The container waits and starts no LimeSurvey, and why. It has five `key=value` lines: `reason` (the words of the `[clouve-upgrade] FAILED` line), `since` (UTC), `from`, `to` and `kind`, which is `repair` when a person has to repair the site and `restore` while the skill's restore is under way. A new start, the end of the wait and a stop request remove it. The SuiteCRM image's `tmp/clouve-backup/needs-attention` has the same keys |

The steps:

1. Check that the code volume has the space for the new code beside the old and for the dump, and one free inode
   for every file and folder of the new code, with a tenth to spare. With too little, nothing changes, the old
   version runs, `upgrade-skipped` says why, and the next start checks again. Old cache files under `tmp/` are the
   usual reason for too few inodes.
2. Dump the database and check the dump (gzip's own test, `mariadb-dump`'s last line, one `CREATE TABLE` for every
   table). Only then is the backup stamped complete. A backup that can't be made skips the upgrade in the same way.
3. Move the old code into `code/`, copy the package in, and put back `config.php`, `security.php`,
   `allowed_hosts.php` and the plugins an admin added under `plugins/`. Top-level files the package doesn't ship
   stay where they are. `upload/` is never moved and nothing in it is changed: the upgrade only adds what the
   package's `upload/` has and the volume lacks. Edits an admin made inside LimeSurvey's own files are not
   carried over. The attempt counts from this step on.
4. Write `db-touched`, switch LimeSurvey's maintenance mode on and run `console.php updatedb`. The update counts as
   done when it ends with status 0, `DBVersion` is the package's and the database has no `DBUpdateIncomplete` row.
5. Switch the SuiteCRM plugin back on when it was on before. LimeSurvey's update switches every added plugin off.
   The others stay off and are named in the log and in `plugins-left-off`.
6. Put maintenance mode back to what the admin had before (`soft` or `hard`, otherwise off), flush the caches, and
   set the state to `done`. The backup folder stays.

Every change of the state file is checked. One that fails, as on a full volume, stops the step before anything
else changes, and Apache never starts while the state says `backup`, `upgrade` or `restore`.

When a step fails, the old version is put back. The database is loaded from the dump only when `db-touched` is
there, so only when the upgrade had begun to write to it. Then its tables are dropped, the dump is loaded and the
result is checked. Without the marker the database is never emptied: it only has to be at the old version. When
the copy of the new code fails, as on a volume that fills up, the half-copied code is removed, the old code goes
back by renames, which need no space, and the database is left alone. The upgrade is then tried once more. After
two attempts the image writes `clouve/upgrade-failed` and starts the old version, which runs on this image's PHP.

A container that is killed in the middle is picked up at the next start from the state file. A killed backup is
thrown away and made again. A killed upgrade is finished when the database update had completed: the code and the
database are both at the version the state names as its target. That holds for a later image with a newer
LimeSurvey too, which then upgrades from there. Otherwise the old version is put back and the upgrade runs again.
A killed restore runs again. A dump that no longer matches `backup-complete` is never loaded: when the database
needs it, the start waits for repair and keeps the state.

A stop request (`docker stop`, a pod that is deleted) during an upgrade ends the container at once and cleanly,
and the attempt is not counted: the next start picks the upgrade up as after a kill. Two steps run to their end
first, because cutting them off costs a reload of the whole database: the database update, and a restore's
emptying and loading. If the platform's patience runs out before they are through, it kills the container, and
the next start handles that as any kill.

Every phase logs a line that starts with `[clouve-upgrade]`, and each failure logs
`[clouve-upgrade] FAILED limesurvey <from> -> <to>: <reason>`.

On this machine's disk an upgrade of a small site takes about 3 seconds. On a network disk the copy of the code is
the slow part, and the database update copies every response table once. On the local kind cluster's disk on
2026-11-12, the Customer Kit's 6.16.1 site with a few responses upgraded in 1.8 seconds, and the new pod served
7.10.0 27 seconds after it started, 24 of them spent waiting for the database's own start. Nothing restarted. No
upgrade has been timed on a GKE network disk yet.

## The database image

`image/mariadb/` is MariaDB 11.8 with `MARIADB_AUTO_UPGRADE=1`, tini as PID 1, a rebuilt gosu and the `clouve-ops`
sshd. Its wrapper refuses a data directory that a newer MariaDB line wrote (it reads `mariadb_upgrade_info`).
MariaDB itself would start on such files without complaint, and going back to an older line isn't supported.

## The SuiteCRM plugin

`image/installer/SuiteCRMIntegration/` is Clouve's plugin that turns survey responses into SuiteCRM leads and
cases. It is in the package, so it is on every volume. With `ENABLE_SUITECRM_INTEGRATION=true` (the Customer Kit)
every start copies the plugin from the package and runs `configure-suitecrm-plugin.sh`, which registers the plugin
when LimeSurvey has no row for it and writes its connection settings from `SUITECRM_URL`, `SUITECRM_ADMIN_USER`,
`SUITECRM_ADMIN_PASSWORD` and `SUITECRM_DB_*`. Both passwords are stored encrypted. A start never changes whether
the plugin is switched on. The script also has the plugin's own code make its two tables or bring an earlier
install's table of mappings up to date, and it clears a mark that says the plugin is faulty, which the earlier
image could leave and which keeps LimeSurvey from loading the plugin. See the plugin's own README for the rest,
and `bundles/crm-kit/README.md` for the Customer Kit and `tests/crm-kit.test.sh` for the test of the real pair.

## Limits

- The image has no PHP IMAP extension (Debian 13 dropped it), so LimeSurvey's bounce processing doesn't work.
- The image has no sendmail. Email needs SMTP settings in LimeSurvey.
- Nothing in the image limits RemoteControl or the REST API. They are as LimeSurvey ships them: RemoteControl off
  until an admin switches it on.

## What the SuiteCRM plugin allows

In short (the plugin's own README has the rest):

- It writes to the SuiteCRM modules Leads and Cases only, and only to fields that SuiteCRM lists for them. A
  mapping to anything else is refused when it is saved and again when a response is sent. The rest of the response
  still goes to SuiteCRM, and the log line about the refused mapping has ids only, never the answers.
- Saving a mapping needs the right to change the survey's content. The settings page and the connection endpoints
  need the global "settings: update" right. The endpoints that change something take POST with LimeSurvey's CSRF
  token only.
- The settings page never shows a stored password or the OAuth2 client secret. An empty field means "keep".
- Its status says so when SuiteCRM no longer has the OAuth2 client that LimeSurvey holds, and points to
  "Initialize OAuth2".
- It follows no redirect, so `SUITECRM_URL` has to be SuiteCRM's own address.
- Its sync log keeps a response's content only for a sync that failed, and rows older than 90 days go at the next
  write.
- A start leaves one `survey_enabled` setting for a survey that has several, as the earlier image's demo import
  left them. The survey's link to SuiteCRM stays on when any of them said on, and the log names the survey and
  what was kept.

## Tests

```bash
bash tests/limesurvey-image.test.sh        # what both images hold
bash tests/limesurvey-entrypoint.test.sh   # a new install and what every start does
bash tests/limesurvey-apache.test.sh       # what Apache serves, denies and logs on a running site
bash tests/limesurvey-upgrade.test.sh      # real 6.16.1 and 6.17.18 sites: upgraded, failed, killed, stopped, on a full disk
bash tests/limesurvey-plugin.test.sh       # the SuiteCRM plugin on LimeSurvey 7, against a stand-in for SuiteCRM
bash tests/new-disk-start.test.sh limesurvey
```

Each `limesurvey-*` test builds the images it needs, or takes `--image limesurvey=<ref> --image
limesurvey-mariadb=<ref>`. `new-disk-start.test.sh` builds with `./build.sh` and takes `--no-build` instead. The
upgrade test takes case names (its header lists them) and `--snapshot 6.16.1=<volume>` to keep the old site it
makes for the next run. Its `runbook` case runs three code blocks of the runbook below as they are written here:
the two under "A damaged dump" and the one under "Go back to the old version after a finished upgrade". The
shared tests `ssh-host-keys`, `db-image-zombies`, `db-image-gosu`, `app-ops-password` and `installer-db-password`
cover both images too.

## Runbook for staff

These steps need a root shell in the LimeSurvey container and nothing else. No AI Assistant is needed. A container
that waits for repair is up, so `kubectl exec` (or the `clouve-ops` SSH account and `sudo -i`) gets you in. When
the container has stopped, start the same image on the same volumes with its entrypoint replaced by
`sleep infinity` and work in that one: `command: ["sleep", "infinity"]` in Kubernetes, where `command` is the
entrypoint, and `--entrypoint sleep <image> infinity` in Docker. With Docker's own meaning of command
(`docker run <image> sleep infinity`) the entrypoint still runs. Take the health check off that pod, because
nothing answers on port 8080.

Every block below begins in the state folder with the database settings the entrypoint would use:

```bash
cd /var/www/html/clouve
export DB_HOST="${DB_HOST:-limesurvey-mariadb}" DB_PORT="${DB_PORT:-3306}" DB_NAME="${DB_NAME:-limesurvey}"
export DB_USERNAME="${DB_USERNAME:-limesurvey}" DB_TABLE_PREFIX="${DB_TABLE_PREFIX:-lime_}"
. /clouve/limesurvey/installer/lib.sh
```

The block under "A damaged dump" talks to the database and needs the container's `DB_*` variables, `DB_PASSWORD`
among them. A `kubectl exec` shell has them. A shell that came in over the `clouve-ops` SSH account has none, and
the default host above is not the database's name on a cluster. So in such a shell, take them from PID 1 first:

```bash
while IFS= read -r -d '' kv; do case "$kv" in DB_*=*) export "$kv" ;; esac; done < /proc/1/environ
```

### Read where an upgrade is

```bash
kubectl logs <pod> -c limesurvey | grep -F '[clouve-upgrade]'
cat /var/www/html/clouve/upgrade-*/state
cat /var/www/html/clouve/upgrade-failed /var/www/html/clouve/upgrade-skipped /var/www/html/clouve/needs-attention 2>/dev/null
```

`phase=done` means the site is on the new version. `phase=failed` and an `upgrade-failed` file mean the old version
is back and running. `upgrade-skipped` means the last start did not try, and the site is on the old version.
`backup`, `upgrade` or `restore` mean the last start was cut off, or it waits for repair: then
`needs-attention` is there too, and the page says that the site needs attention. A `db-touched` file in the folder
means the upgrade has written to the database, and that only the dump brings the old database back.

### Try a failed upgrade again

Read the reason in `upgrade-failed` and in `updatedb.log`, fix the cause, then:

```bash
rm /var/www/html/clouve/upgrade-failed
```

Restart the container. An image with a different build tries again by itself. An upgrade that was skipped
(`upgrade-skipped`) needs nothing removed: free the space or the inodes it names and restart.

### Go back to the old version after a finished upgrade

The backup folder of a finished upgrade holds the old code and the database from before the upgrade. Going back
loses everything that was written to the site since the upgrade: responses, surveys, settings. Uploaded files
stay. In a root shell of the running container:

```bash
/clouve/limesurvey/installer/go-back.sh --yes-lose-what-was-written-since
```

Then restart the container. The script changes nothing in the site. It checks the dump against its stamp, sets the
folder's state to `restore`, writes `db-touched` and fills `upgrade-attempts`. The next start then does what every
restore does: it empties the database, loads the dump, removes the new code, moves the old code back and checks
the versions. After that it writes `upgrade-failed`, so the old version stays, on this image's PHP, until that file
is removed. Putting the files back by hand instead is not enough: the next start would see older code and upgrade
it again, and a dump loaded without emptying the database first leaves the tables that LimeSurvey 7 made.

### Remove the kept backup

After someone has checked the upgraded site, and only when `state` says `phase=done`:

```bash
rm -rf /var/www/html/clouve/upgrade-*-to-*
```

That frees about 520 MB of old code and the dump. The folder is the only way back to the old version that is
stored with the site, so keep a copy of `db.sql.gz` elsewhere if the site matters. Never remove a folder whose
state says anything but `done` or `failed`, and never one that has a `db-touched` file.

### When a start waits for repair

The container is up, the page says "LimeSurvey needs attention from Clouve support", and the last
`[clouve-upgrade] FAILED` line and `clouve/needs-attention` say what was found. Put it right, then restart the
container: the start goes on from the state file. What each stop leaves:

| The log says | What is on the volume and in the database | What to do |
| --- | --- | --- |
| `... is not the backup that was stamped complete` | State `restore`, `db-touched` is there. The database is as the cut-off update left it. The new code is on the volume and the old code in `code/`. Nothing was loaded. | The steps under "A damaged dump" below. |
| `the restore could not empty the database`, `the restore could not load the dump` | State `restore`, `db-touched` is there. Some or all tables are dropped, or the dump is partly loaded. The dump itself is whole. | Fix what the line names (the database's disk, its connection), then restart. The restore runs again from the dump. |
| `after the restore the database is at version ...` | State `restore`. The dump was loaded, and the result is not what the stamp recorded. | Compare the database with `backup-complete`. Restart to load the dump again. |
| `the database is at version ..., not at the version it had before the upgrade` | State `upgrade` or `restore`, no `db-touched`. The image loads nothing, because its marker doesn't say that the upgrade changed the database. | Put the database back from a backup taken before the upgrade, then restart. |
| `the restore could not remove the new code`, `found <name> both on the volume and in ...`, `could not move <name> back`, `after the restore the code on the volume is ...` | State `restore`. The database is the old one again. The code is partly moved: old entries are in `code/` or back in the web root, never lost. | Fix what the line names (rights or space on the code volume), then restart. The restore goes on where it was. |
| `... can't be written (is the code volume full?), so the restore was not started` | The state is as the upgrade left it. Nothing was dropped, loaded or moved. | Free space on the code volume, then restart. |
| `... can't be written (is the code volume full?), so the old code was not moved back` | State `restore`. The database is the old one again. The new code is removed, and the old code is all in `code/`. | Free space on the code volume, then restart. The restore goes on where it was. |
| `.../code is not a folder of root's, so nothing is moved back from it` | State `restore`. The new code is removed. `code/` in the backup folder is a link or is not root's, so the image doesn't use it. | Find out what replaced `code/`. The restore goes on only when it is a real folder of root's that holds the old code. |
| `... can't be written ... The upgrade itself is complete` | State `upgrade`, step `finishing` or `updating`. The site is whole on the new version. | Free space, then restart. The start records the upgrade as done and loads nothing. |
| `gave up ..., but ... can't be written` | State `restore`. The old version is back, whole, with its data. | Free space, then restart. |
| One of the rows of the table under "What a start does" (no code but tables, the package's code on an older database, a newer database, `DBUpdateIncomplete`, no `security.php`, ...) | Nothing was changed. | Put the volume and the database back together: restore the one that is wrong from a backup. If the log names a `clouve.untrusted-...` folder, look there for an upgrade's backup first. |

If a site shows LimeSurvey's maintenance page after a cut-off upgrade was repaired by hand, switch it off as
`www-data`: `php application/commands/console.php setmaintenancemode off` in `/var/www/html`.

### A damaged dump

The start waits with `is not the backup that was stamped complete`: the upgrade was cut off during or after the
database update, and the dump in the backup folder no longer matches its stamp, so the image loads nothing. The
old code is safe in the folder. Put the database back from a dump of your own that was taken before the upgrade
(the platform's backup), then tell the image that the database is the old one again by removing the marker. Here
the dump is at `/root/before-upgrade.sql.gz`:

```bash
cd /var/www/html/clouve
export DB_HOST="${DB_HOST:-limesurvey-mariadb}" DB_PORT="${DB_PORT:-3306}" DB_NAME="${DB_NAME:-limesurvey}"
export DB_USERNAME="${DB_USERNAME:-limesurvey}" DB_TABLE_PREFIX="${DB_TABLE_PREFIX:-lime_}"
. /clouve/limesurvey/installer/lib.sh
gzip -t /root/before-upgrade.sql.gz && ls_drop_all_tables && gzip -dc /root/before-upgrade.sql.gz | ls_mysql "$DB_NAME"
ls_db_version
rm upgrade-*-to-*/db-touched
```

`ls_db_version` has to print the old version's number (640 for LimeSurvey 6.16.1). Then restart the container. The
start checks that the database is at the old version, removes the new code, moves the old code back, throws the
damaged backup away, makes a new one and upgrades again. To keep the old version running instead, fill the
attempt counter before the restart. The start then puts the old version back, gives up, and writes
`upgrade-failed` itself:

```bash
printf 'build=%s\ncount=2\nreason=kept on the old version by hand\n' "$(cat /clouve/limesurvey/image-build)" > /var/www/html/clouve/upgrade-attempts
```

### When the container ends instead

The last `[limesurvey] ERROR` line says why. Nothing on the volume or in the database was changed, except by a new
install that failed, which the next start clears. Code on the volume that is newer than the image needs an image
of that LimeSurvey version or later.
