# SuiteCRM

SuiteCRM 8 for the Clouve marketplace: an app image and its MariaDB image. The app image installs a new site by
itself, upgrades an existing site in place when the image carries a newer SuiteCRM, runs SuiteCRM's scheduled
jobs, and has the `clouve-ops` SSH channel that the AI Assistant works through.

| Part | Version |
| --- | --- |
| SuiteCRM | 8.10.2 |
| PHP | 8.3, with Apache 2.4 |
| MariaDB | 12.3 |

## What is in this folder

```
suitecrm/
├── clv-docker-compose.yml       # marketplace manifest
├── docker-compose.yml           # local runs
└── image/
    ├── Dockerfile               # the app image
    ├── build.config
    ├── context/suitecrm/        # the AI Assistant's persona
    ├── installer/
    │   ├── entrypoint.sh        # runs at every start, then becomes Apache
    │   ├── lib.sh               # shared functions
    │   ├── install.sh           # a new install
    │   ├── upgrade.sh           # the in-place upgrade and the way back
    │   ├── loops.sh             # the scheduler and the Messenger worker
    │   ├── release-scheduler.sh # releases a held scheduler
    │   ├── patch-keep-list.sh   # what SuiteCRM's upgrade must not delete
    │   ├── keep-list.php        # reads the keep-list SuiteCRM has compiled
    │   ├── settings.php         # database settings, site address, scheduler setting
    │   ├── scheduler-setting.php # switches the scheduler on or off
    │   ├── cron-user.php        # makes www-data an allowed cron user
    │   ├── install-args.php     # hands the installer its options
    │   ├── standin-router.php   # answers the health check during long work
    │   ├── build-id.sh          # works out the image's build id
    │   ├── apache-clouve.conf   # Apache behind the ingress
    │   └── clouve-ops-sshd.conf, start-clouve-ops-sshd.sh
    └── mariadb/                 # the database image
```

## Run it locally

From the magneto folder:

```bash
./build.sh suitecrm
./start.sh suitecrm
```

SuiteCRM answers at http://t1.test.clv:8080 (the address in `docker-compose.yml`). Sign in as `admin` with the
password `Admin@123`. `./start.sh` makes each new volume the way a cluster does: an empty disk that belongs to
root. `./stop.sh suitecrm --cleanup` removes the volumes.

## Settings

The app container:

| Variable | What it is |
| --- | --- |
| `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME`, `DATABASE_USER`, `DATABASE_PASSWORD` | The database. The port is 3306 when it isn't set. The others are required. The password can hold any character. |
| `SUITECRM_URL` | The site's address, for example `https://crm.example.com`. Required. It needs `http://` or `https://` and a host name. A value without them is left out with a warning, and the address SuiteCRM has stays. |
| `SUITECRM_ADMIN_USER`, `SUITECRM_ADMIN_PASSWORD` | The first admin. Read only by a new install. |
| `SUITECRM_INSTALL_DEMO_DATA` | `yes`, `true` or `1` installs SuiteCRM's demo records with a new install. Anything else doesn't. |
| `CLOUVE_OPS_PASSWORD` | Set by the platform when the deployment has the AI Assistant. Without it no sshd starts. |

The entrypoint also puts `SUITECRM_DB_HOST`, `SUITECRM_DB_PORT`, `SUITECRM_DB_NAME`, `SUITECRM_DB_USER` and
`SUITECRM_DB_PASSWORD` into PID 1's environment, with the values of the `DATABASE_*` variables. The AI Assistant
reads them from there.

The database container takes `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` and `MYSQL_ROOT_PASSWORD`, as the
official MariaDB image does, and `CLOUVE_OPS_PASSWORD`.

## What happens at every start

The entrypoint runs as root and ends by becoming Apache, which is PID 1 from then on.

1. It checks the variables and starts the `clouve-ops` sshd, when `CLOUVE_OPS_PASSWORD` is set. The password
   then leaves its environment, so Apache, PHP and the background jobs never have it.
2. It sizes Apache's worker limit from the container's memory limit: the limit minus 450 MB, divided by 90 MB,
   and at least 4. That is 6 workers at 1 GB and 17 at 2 GB.
3. It gives the volume's top folder to `www-data` when it is root's, as on a new cluster disk.
4. It starts the stand-in for the health check (below) and waits for the database, up to 5 minutes.
5. It decides what the volume holds and acts on it (the table below).
6. It writes the database settings and the site address from the environment into SuiteCRM's own files
   (`public/legacy/config.php` and `.env.local`), so a copied or restored deployment and a rotated database
   password work at the next start. It makes `www-data` an allowed cron user, removes `config_si.php` if one is
   left (SuiteCRM's installer writes the admin's and the database's passwords into it), and closes the OAuth2
   keys, the key that encrypts stored mail passwords and the settings files to other users.
7. It starts the two background loops and becomes Apache.

| What the volume and the database hold | What the start does |
| --- | --- |
| The AI Assistant's restore is under way (`tmp/clouve-backup/restore-in-progress`) | It waits until the marker is gone, then decides |
| No SuiteCRM, and no tables in the database | A new install |
| No SuiteCRM, but tables in the database | It stops and changes nothing. SuiteCRM's installer drops the database it installs into. |
| An install that was cut off | It clears what that install left and installs again |
| The image's version, finished | Nothing to do |
| An older version | The in-place upgrade |
| An upgrade that was cut off | It picks the upgrade up from its state file or its backup |
| An upgrade that failed twice | The old version runs. This build of the image doesn't try again. |
| A newer version | It stops and changes nothing |
| Between two versions, with no backup the image can trust | It waits for a person, with SuiteCRM not started |
| SuiteCRM on the volume, and a database without SuiteCRM's tables | It waits for a person, with SuiteCRM not started |

Everything that writes into the install, or runs SuiteCRM's PHP, runs as `www-data`. Root reads text only. Root
changes the install in two places, both in the upgrade: it renames the customer's upload folders out of
SuiteCRM's reach and back, and a way back removes the upgraded code as root. No password is on a command line
or in the log: the database clients read an options file of mode 600, and SuiteCRM's installer gets its options
inside the PHP process.

### What the image trusts

SuiteCRM's whole tree belongs to `www-data`, `tmp/` included. SuiteCRM's own permission reset and a start of the
earlier image give everything in it to `www-data`. The image keeps its state in `tmp/clouve-backup`, a folder
of root's, and follows three rules:

- It reads that folder only while it is a real folder of root's that nobody else can write in. Anything else
  at that name is never read and never used. The entrypoint moves it aside to
  `tmp/clouve-backup.untrusted-<UTC time>`, changes nothing in it, and logs how staff put it back.
- A missing state never means that nothing is under way. The site's own facts decide: `VERSION` on the volume,
  the version row in the database, and the tables. A site between two versions with no backup the image can
  trust is not started.
- Root runs no file that `www-data` can write. `settings.php`, `cron-user.php`, `scheduler-setting.php` and
  `keep-list.php` load SuiteCRM's files, so they run as `www-data` and refuse to run as root.

### When the container waits for a person

Some sites must not be started, and no restart can repair them: a site between two versions without a backup,
a damaged backup, a database without tables, upload folders that are gone. The container then stays up. The
stand-in shows a page that says "SuiteCRM needs attention", the sshd answers, and the log has a line that
starts with `[clouve-upgrade] FAILED suitecrm` and says what was found. To the platform such a container looks
healthy, so that line is what an alert has to look for. The runbook below has the step for each case. When the
step is done, the waiting container sees it within seconds and goes on. Upload folders that were put back are
the exception: the container doesn't watch them, so that step ends with a restart. A restart also does the same
in every other case.

The AI Assistant can't read the container's log, so the waiting container also leaves a note in the state folder,
`tmp/clouve-backup/needs-attention`. It is root's with mode 600 and has one `key=value` per line:

| Key | What it holds |
| --- | --- |
| `reason` | What was found, in the words of the `[clouve-upgrade] FAILED` line. It never holds a password |
| `since` | When the wait began, in UTC |
| `from` | The version on the volume, as the line names it (`unfinished` for a site between two versions) |
| `to` | The image's version |
| `kind` | `repair` when a person has to repair the site, `restore` while the AI Assistant's restore is under way |

The note is there only while the container waits: the entrypoint writes it when the wait begins and removes it
when the wait ends or the container stops, and a new start removes one that was left behind. The LimeSurvey
image's `clouve/needs-attention` has the same five keys. One wait has no note: while a state folder that was moved
aside (`tmp/clouve-backup.untrusted-<time>`) is on the volume and no state folder is there, the image makes no new
one. Staff put the old folder back with `mv`, and a new folder of that name would turn that step into a move into
it. The moved-aside folder's own name then says why the container waits.

### A stop request

A stop request ends the start within seconds, with exit status 0. That is SIGTERM, or SIGWINCH, which is this
image's stop signal. The entrypoint passes the request on to an install or an upgrade that is under way. The
next start clears a stopped install and installs again, and picks a stopped upgrade up from its state file. A
try that was stopped doesn't count as a failed one.

### The stand-in for the health check

The platform asks `GET /` on port 80 and restarts a container that doesn't answer for about 105 seconds. A
database that starts slowly, an install or an upgrade on a network disk can take longer. So at every start,
from before the wait for the database until Apache takes over, PHP's built-in server answers on port 80 with
one file from the image. It runs as `nobody`, or as root where the container can't give `nobody` the right to
bind port 80. `GET /` and `HEAD /` get a short page and status 200, and every
other request gets 503 with `Retry-After`, so an API caller never takes the page for an answer. Every answer
has the header `X-Clouve-Standin: suitecrm`, which tells a tool that waits for SuiteCRM itself that this is not
it yet. The entrypoint stops the stand-in and waits for the port before Apache starts. The stand-in runs with
an empty environment, so it holds no password.

The page says one of three things: "SuiteCRM is starting", "SuiteCRM is being restored" while the AI Assistant's
restore is under way, and "SuiteCRM needs attention" when the container waits for a person.

## A new install

`install.sh` copies the package from the image to the volume as `www-data`, runs SuiteCRM's installer as
`www-data`, removes `config_si.php`, makes the OAuth2 key pair for the API, switches the scheduler on and
removes its stamp. On the volume everything is `www-data`'s, folders 2755 and files 0644, as SuiteCRM's install
guide asks. In the image the package is root's. The stamp, `/var/www/html/.clouve-install-in-progress`, is
there from the first step to the last. A start that finds it knows the install never finished, clears the
volume and installs again. It refuses when the database holds more than one user: a cut-off install has made
only the admin, and a database that people have worked in is not dropped on the stamp's word. An install with
demo records (`SUITECRM_INSTALL_DEMO_DATA`) makes users of its own, so there the user count is not checked.

## The upgrade from an older version

It runs at the first start on a newer image, before Apache starts. SuiteCRM's own procedure is two console
commands. `upgrade.sh` wraps them:

1. It checks that the volume has room for the package, the backup and SuiteCRM's own working copies, and that
   every file in the install is `www-data`'s. SuiteCRM's commands run as `www-data` and can't replace a file of
   root's. When a check fails it doesn't upgrade, the old version keeps running, and
   `tmp/clouve-backup/upgrade-skipped` has the reason, the two versions and the time. The next start checks
   again, and the note goes when an upgrade runs.
2. It makes a backup in `tmp/clouve-backup/<from>-to-<to>/` on the volume: `code.tar.gz` (the code and the
   settings) and `db.sql.gz` (a dump of the database). The customer's files stay where they are and are not in
   the archive: `public/legacy/upload`, `uploads/` or `media/`, and `public/media-upload/` or `public/media/`.
   So do `tmp/`, `cache/` and `logs/`. The script checks the backup before it relies on it and writes the
   checksums into the file `complete`, with a fingerprint of the database: its tables, columns and indexes,
   and each table's checksum. The folder is root's, mode 700.
3. It moves the customer's upload folders out of SuiteCRM's reach. SuiteCRM 8.9.1's upgrade code deletes
   `uploads/` and `public/media-upload/`, where 8.9 keeps email attachments and file fields, unless its
   keep-list names them, and the backup doesn't hold those folders. So before SuiteCRM's first command the
   script renames them, under both their 8.9 and their 8.10 names, into `tmp/clouve-backup/aside/`, and
   renames them back before the second command. A rename on one disk is one step, and the state file says how
   far it got, so a stop at any point puts them back. The image's two marker files get a copy there and stay
   in the install: the earlier image installs anew, and drops the database, when it starts on a volume
   without `.suitecrm_initialized`.
4. As a second layer it adds what the installed version's keep-list forgets, `lost+found` among it, and
   checks that the list still names the legacy uploads, the customisations and the settings files. SuiteCRM
   reads the list from its compiled cache, so the script removes the cache, starts SuiteCRM's kernel and reads
   the list from the compiled container, which is what the upgrade command gets. It runs the command only when
   that list names every entry. SuiteCRM's own `cache:clear` is not enough for this: it rebuilds nothing when
   the cache was written in the same second.
5. It runs `suitecrm:app:upgrade` and `suitecrm:app:upgrade-finalize` as `www-data`.
6. The upgrade counts as done when both commands ended well, `VERSION` and the database's version row say the
   new version, and SuiteCRM's own `suitecrm:version` prints it.
7. When a try fails, it goes back. It removes the upgraded code as root, so that a file of root's in the tree
   can't stop it half-way, unpacks the old code as `www-data` and gives the media folders their old names. The
   two marker files stay in place all the way. It
   leaves the database alone only when that is proven: SuiteCRM's second command never started, and the
   database's fingerprint is the one the backup recorded. From SuiteCRM 8.10 on the first command can change
   the database too. In every other case it drops the database's tables and loads the dump. Then it tries once
   more.
8. After two failed tries the old version runs. The script writes the failure to
   `tmp/clouve-backup/upgrade-failed`, and this build of the image doesn't try again while that file exists. A
   newer build tries by itself.
9. When going back fails, it changes nothing more and the container exits with a failing status. Apache never
   starts on old code with a half-changed database, and the next start goes back again.
10. When there is nothing good to go back to, the container waits for a person (above).

SuiteCRM's upgrade removes what it doesn't know at the top of the install, in `public/` and in
`public/legacy/`: every file and folder that the new package doesn't ship and its keep-list doesn't name. A
site-verification file in `public/` is one example. The script can't keep such files, because it can't know
which are the customer's. It logs their names before the first command, and they are in the backup's
`code.tar.gz`.

The container can stop at any moment. The file `tmp/clouve-backup/state` names the phase, and the next start
does what is safe there:

| Phase | What it means | What the next start does |
| --- | --- | --- |
| `backup` | Stopped while the backup was written. Nothing in the site changed. | Removes the unfinished backup and starts over, whichever version the image has |
| `upgrade` | Stopped after the backup | If the upgrade had finished, it cleans up. If not, it goes back and upgrades again. |
| `restore` | Stopped while going back | Goes back again |
| `failed` | Two tries failed and the old version was put back | Starts the old version |
| `as-is` | Staff's own `upgrade.sh --finish-as-is` was cut off | Waits for a person |

In the phase `upgrade` the key `step` says how far the try got: `prepare`, `aside` (the upload folders are
being moved out), `files` (SuiteCRM's first command), `back` (the folders are in place again) and `finalize`
(SuiteCRM's second command).

When the state file is gone and the complete backup is still there, the start goes back from that backup and
upgrades again. A half-upgraded site is never treated as a version of its own: it is never started and never
backed up.

The upgrade keeps one backup until someone removes it. A later upgrade removes it once its own backup is
complete.

The log has a line that starts with `[clouve-upgrade]` for every phase. What needs someone's attention is
logged as `[clouve-upgrade] FAILED suitecrm <from> -> <to>: <reason>`.

On the local kind cluster's disk on 2026-11-12, the Customer Kit's 8.9.1 site upgraded in 22 seconds (9 for the
backup, 13 for SuiteCRM's own two commands), and the new pod served 8.10.2 42 seconds after it started. The
stand-in held the probes and nothing restarted. In the same start the database image's own upgrade of MariaDB
12.1 files to 12.3 took under 2 seconds. No upgrade has been timed on a GKE network disk yet.

After an upgrade to 8.10, SuiteCRM lists seven Manual Migration Tasks under Admin, Migrations. An admin starts
them there. Until then SuiteCRM still finds the files in their old places.

## Scheduled jobs and the Messenger worker

Two background loops run next to Apache. Each loop is a small shell of root's, because it reads root's state
folder. What it starts is SuiteCRM's own command, as `www-data`:

- the scheduler: `bin/console schedulers:run` once a minute. Workflows, scheduled reports, inbound mail,
  campaign email, reminders and search indexing all depend on it.
- the Messenger worker: `bin/console messenger:consume internal-async`, capped at 256 MB. SuiteCRM 8.10 needs it
  for its asynchronous tasks, the Manual Migration Tasks among them. It runs only on 8.10 or later.

Neither is PID 1. When one fails it logs a line and tries again later, with a longer wait after each failure.

The scheduler runs only while SuiteCRM's own settings switch it on. The setting is one line in
`public/legacy/config_override.php`, written through SuiteCRM's Configurator:

```php
$sugar_config['clouve']['scheduler'] = 'on';
```

A new install sets it, and so does a release (the runbook below). The image this one replaces never ran a
scheduled job: its installer ran as root, and SuiteCRM then refuses to run jobs for `www-data`. An install made
by that image may hold queued campaign email and workflows that have never run, and it has no such line. So its
scheduler is held until someone has looked at what is queued and releases it. The setting is in SuiteCRM's
settings and not in the image's state folder, so nothing done to that folder releases a held scheduler.

Three more things hold the scheduler, whatever the setting says:

- the file `tmp/clouve-backup/scheduler-held`. The AI Assistant's restore writes it, because a restore brings
  the queue back as it was when the backup was made.
- a state folder that is not root's, in place or moved aside as `tmp/clouve-backup.untrusted-<time>`. A hold
  file in it can't be read.
- the two pause files below.

Both loops stand still while `tmp/clouve-backup/restore-in-progress` exists (the AI Assistant's restore) or
`tmp/clouve-backup/loops-paused` (staff's own pause). A command that is running then is ended, and the loop goes
on when the file is gone.

## Behind the ingress

TLS ends at the ingress and the pod serves plain HTTP. `apache-clouve.conf` does two things:

- A request with `X-Forwarded-Proto: https` counts as HTTPS. Without that the session cookie has no Secure
  flag and `/logout` redirects to `http://`.
- Apache takes the client's address from `X-Forwarded-For` when the peer has a private address (10.0.0.0/8,
  172.16.0.0/12, 192.168.0.0/16), which is what the ingress has. SuiteCRM's sign-in throttle then counts people.
  Without it, 50 failed sign-ins from anywhere lock everyone out for half an hour.

The same file has four more rules:

- The access log, which is the container's log, has each request's method and path, without the query string
  and without the Referer. Password-reset links and API tokens travel in both. A value that is part of the
  path is still logged.
- Apache's error lines, which also go to the container's log, are written without the Referer.
- In the folders where uploads land (`public/legacy/upload`, `public/media` and `public/media-upload`) no PHP
  file is run or served, and no `.htaccess` file is read. Other files in the two media folders are served as
  before.
- The web root gives no folder listing.

Apache's log, run and lock folders are root's in this image. Apache's parent process is root and opens files
there at every start and reload, and the base image leaves those folders to `www-data`.

## The build

The build fetches nothing unchecked. SuiteCRM's zip and the PHP extension installer are checked against a
SHA-256 each. The `imap` extension needs three Debian 12 packages that Debian 13 no longer ships. The Dockerfile
fetches them over HTTPS and checks each against its SHA-256, for amd64 and for arm64. The compilers the base
image built PHP with are removed once the extensions are built.

`/clouve` and everything under it is root's, the package included, so `www-data` can change nothing that root
reads or runs. The build id in `/clouve/suitecrm/BUILD` covers the installer, the Dockerfile, the package, PHP's
settings and Apache's configuration (`build-id.sh`). An upgrade that failed twice is tried again by an image
whose id differs.

## The database image

`image/mariadb` builds on `mariadb:12.3` and sets `MARIADB_AUTO_UPGRADE=1`, so MariaDB upgrades a data
directory from an older version at the first start. tini is PID 1. The wrapper reads which MariaDB last used the data
directory (`mariadb_upgrade_info`) and refuses to start when that was a newer release line than the image's.
MariaDB itself would start on such files without complaint, and going back a line is not supported.

SuiteCRM's own list of supported databases ends at MariaDB 11.8. 12.3 passed an install, an upgrade and the
tests here. The pin can't be lower: the image had no pin before, and the installs it made hold 12.x files.

## Tests

From the magneto folder:

```bash
bash tests/suitecrm-image.test.sh         # what the two images hold
bash tests/suitecrm-entrypoint.test.sh    # a new install, restarts, the background jobs
bash tests/suitecrm-upgrade.test.sh       # a real 8.9.1 site through the upgrade, and every way it can stop
bash tests/suitecrm-self-upgrade.test.sh  # a site this image installed, upgraded to a rehearsal package
bash tests/new-disk-start.test.sh suitecrm
```

## Staff runbook

Everything here works without the AI Assistant. The commands run in the app container as root, for example
through `kubectl exec -n <namespace> <suitecrm pod> -- <command>`.

Two rules apply to all of it:

- Never remove `tmp/clouve-backup` or a `tmp/clouve-backup.untrusted-<time>` folder to get past a message. It
  can hold the only backup of the site as it was before an upgrade, and the customer's upload folders.
- Never change the owner of `tmp/clouve-backup`. It has to stay root's. SuiteCRM's permission reset
  (`find . ! -user www-data -exec chown ...`) changes it: leave `tmp/clouve-backup` out, or put the folder
  back as described below.

### Read the state of an upgrade

```bash
cat /var/www/html/VERSION                           # the code on the volume
cat /var/www/html/tmp/clouve-backup/state           # the phase and the step of an upgrade that is under way
cat /var/www/html/tmp/clouve-backup/upgrade-failed  # why the last upgrade failed, if it did
cat /var/www/html/tmp/clouve-backup/upgrade-skipped # why the last start did not try an upgrade
cat /var/www/html/tmp/clouve-backup/needs-attention # why the container waits, while it waits
ls -la /var/www/html/tmp/                           # the state folder, and any folder that was moved aside
ls -la /var/www/html/tmp/clouve-backup/             # the kept backup, aside/, the hold and pause files
```

The container's log says the same: look for `[clouve-upgrade]`. The output of SuiteCRM's own commands is in
`tmp/clouve-backup/upgrade-console.log` and `logs/upgrade.log`.

The version the database records, which is what proves a finished upgrade:

```bash
cd /var/www/html && sudo -u www-data php bin/console dbal:run-sql \
  "SELECT value FROM config WHERE category = 'info' AND name = 'suitecrm_version'"
```

SuiteCRM 8.9 has no such row.

### The upgrade was not tried

The log has a `[clouve-upgrade] FAILED` line that says "Nothing was changed and <version> keeps running", and
`upgrade-skipped` has the reason. The old version runs. Fix what the reason names and restart:

- "not enough free space on the volume": free space or give the volume more room.
- "files in the install are not www-data's": a command run as root left them there. The line names up to
  five. Give them to `www-data`, leaving root's own folders out:

  ```bash
  cd /var/www/html
  find . \( -path ./lost+found -o -path './tmp/clouve-*' \) -prune -o ! -user www-data \
    -exec chown -h www-data:www-data {} +
  ```

- "the backup could not be made": the reason says which part failed.

### Try a failed upgrade again

Read `upgrade-failed` and fix what it names. Then:

```bash
rm /var/www/html/tmp/clouve-backup/upgrade-failed
```

Restart the container. The upgrade runs again, from a new backup. A newer build of the image tries again by
itself, without this step.

### The container waits and the page says "SuiteCRM needs attention"

SuiteCRM was not started. The log's last `[clouve-upgrade] FAILED` line says why. When the step is done, the
container goes on by itself within seconds, except after upload folders were put back, which takes a restart. A
restart also does the same in every other case.

#### The state folder was moved aside

The line names a folder `tmp/clouve-backup.untrusted-<time>` on the volume and says that it "was not root's any
more". The start that moved the folder also logged a `[suitecrm] WARNING` line that says "is not a folder that
only root can change". Something gave the folder to another owner: SuiteCRM's permission reset, or a start of the
earlier image. The image has read nothing in it. Look at what is in it. It should hold only `state`, a backup
folder `<from>-to-<to>` with `code.tar.gz`, `db.sql.gz` and `complete`, `upgrade-console.log`, perhaps
`upgrade-failed` or `upgrade-skipped`, perhaps the hold and pause files (`scheduler-held`, `restore-in-progress`,
`loops-paused`), perhaps a `needs-attention` note, and perhaps `aside/` with the customer's upload folders and a
copy of the two marker files. Then
give it back to root, close it and give it its name again:

```bash
cd /var/www/html/tmp
ls -laR clouve-backup.untrusted-<time> | head -n 60
chown -hR root:root clouve-backup.untrusted-<time>
chmod -R go= clouve-backup.untrusted-<time>
mv clouve-backup.untrusted-<time> clouve-backup
```

The image gives the upload folders in `aside/` back to `www-data` when it puts them in place.

A finished site with such a folder on the volume starts, with a warning, and its scheduler is held until the
folder is put back or removed. Remove the folder only when the site runs the image's version, the customer has
checked it, and the folder holds no `aside/`.

#### The site is between two versions and there is no backup

The line says "an upgrade was cut off, and the volume holds no backup that this image can trust". `VERSION`
already says the new version and the database has no record of a
finished upgrade. If a `tmp/clouve-backup.untrusted-<time>` folder is there, put it back as above: the backup
is in it. Without one there are two ways out:

- Restore the deployment from a backup taken before the upgrade. This is the safe way.
- Finish the upgrade on the site as it is. Take a backup of the deployment first: there is no way back from
  this but that backup. Then:

  ```bash
  /clouve/suitecrm/installer/upgrade.sh --finish-as-is
  ```

  It runs SuiteCRM's two commands on the code and the database as they are. When it ends with a `DONE` line,
  the waiting container starts SuiteCRM. When it fails, nothing is put back: run it again or restore.

#### The backup is damaged

The line says "there is no good backup to go back to", and then why: a checksum no longer matches ("is damaged
(its checksum changed)"), or the backup folder or one of its three files is missing or not root's ("there is no
complete backup in ..."). The image loaded nothing from it. The files and the database are as the cut-off upgrade
left them. Restore the deployment from a backup taken before the upgrade.

#### Upload folders are gone

The line says "the backup recorded uploads/, and neither uploads/ nor media/ is on the volume", or the same about
`public/media-upload/` and `public/media/`. The old code and the database are back, but files the customer
uploaded are missing, and the upgrade's backup never held them. Restore `uploads/` and `public/media-upload/`
from a backup of the deployment, then restart the container. The waiting container doesn't watch those folders.

#### The database has no tables

The line says "has no SuiteCRM tables". The volume holds SuiteCRM, and the database is
empty, was lost, or is another one. Restore the database, or set the container's database settings right.

### The page says "SuiteCRM is being restored"

The AI Assistant's restore is under way, or was cut off: `tmp/clouve-backup/restore-in-progress` exists. A
container that starts meanwhile waits and starts nothing, and both background loops stand still. While it waits,
`tmp/clouve-backup/needs-attention` says so with `kind=restore`. Let the
restore finish, or run it again. Remove the marker by hand only when it is certain that no restore is running
and the site is whole:

```bash
rm /var/www/html/tmp/clouve-backup/restore-in-progress
```

### The container exits during an upgrade

The log's last `[clouve-upgrade] FAILED` line says why.

- "going back to <old version> failed": the way back could not finish, most often because the database didn't answer or the
  volume is full. Nothing is lost: the backup is complete. Fix the cause and restart. The next start goes back
  again.
- "the state file ... is of an upgrade to" another version: an image with another SuiteCRM started on a volume
  where an upgrade was under way. Start the image that began the upgrade, let it finish or go back, then change
  the image.

### Go back by hand

The upgrade goes back by itself. These are its steps, for a volume it can't finish on, and for going back
from an upgrade that finished, while its backup is still kept. They need a shell in a container of this image
with the volume mounted and SuiteCRM not running, and the database reachable. On a cluster that is a pod of
this image with `command: ["sleep", "infinity"]`, the deployment's environment and its volume. `B` is the
backup folder, `D` the database's name. What the customer changed after the backup was made is lost: records
in the database, and settings.

```bash
cd /var/www/html
B=tmp/clouve-backup/8.9.1-to-8.10.2
D=${DATABASE_NAME:-suitecrm}
sha256sum "$B/code.tar.gz" "$B/db.sql.gz"; grep sha256 "$B/complete"   # the checksums must match

# Upload folders that a cut-off upgrade had moved out of the install come back first.
A=tmp/clouve-backup/aside
for f in uploads media .suitecrm_initialized .suitecrm_url; do
  if [ -e "$A/$f" ] && [ ! -e "$f" ]; then mv "$A/$f" "$f"; chown -hR www-data:www-data "$f"; fi
done
for f in media-upload media; do
  if [ -e "$A/public__$f" ] && [ ! -e "public/$f" ]; then mv "$A/public__$f" "public/$f"; chown -hR www-data:www-data "public/$f"; fi
done

# The database: drop every table, then load the dump. The options file keeps the password off the command line.
umask 077
pw=${DATABASE_PASSWORD//\\/\\\\}
printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' "$DATABASE_HOST" "${DATABASE_PORT:-3306}" \
  "$DATABASE_USER" "${pw//\"/\\\"}" > /root/db.cnf
mysql --defaults-extra-file=/root/db.cnf -N -B -e "SELECT CONCAT('DROP ', IF(table_type = 'VIEW', 'VIEW', 'TABLE'),
  ' IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = '$D'" > /root/drop.sql
(echo 'SET FOREIGN_KEY_CHECKS = 0;'; cat /root/drop.sql) | mysql --defaults-extra-file=/root/db.cnf "$D"
gzip -dc "$B/db.sql.gz" | mysql --defaults-extra-file=/root/db.cnf "$D"
rm -f /root/db.cnf /root/drop.sql
umask 022

# The files: everything goes except the customer's files, tmp/, cache/, logs/ and the image's two marker files
# (the earlier image installs anew on a volume without .suitecrm_initialized). A folder named <name>.clouve-aside
# holds the customer's files too: the upgrade left it there when it could not merge them back. Then the archive
# comes back.
find . -mindepth 1 -maxdepth 1 ! -name tmp ! -name cache ! -name logs ! -name lost+found \
  ! -name public ! -name uploads ! -name media ! -name '*.clouve-aside' ! -name .suitecrm_initialized \
  ! -name .suitecrm_url -exec rm -rf {} +
find public -mindepth 1 -maxdepth 1 ! -name legacy ! -name media-upload ! -name media \
  ! -name '*.clouve-aside' -exec rm -rf {} +
find public/legacy -mindepth 1 -maxdepth 1 ! -name upload -exec rm -rf {} +
chown -h www-data:www-data . public public/legacy
sudo -u www-data tar -xzpf - < "$B/code.tar.gz"

# 8.10 renames the media folders. A version before 8.10 looks in the old places.
if grep -q '^had_uploads=yes' "$B/complete" && [ -d media ] && [ ! -e uploads ]; then
  sudo -u www-data mv media uploads
fi
if grep -q '^had_public_media_upload=yes' "$B/complete" && [ -d public/media ] && [ ! -e public/media-upload ]; then
  sudo -u www-data mv public/media public/media-upload
fi
rm -rf tmp/package
find cache -mindepth 1 -maxdepth 1 -exec rm -rf {} +

# The state: failed, so the next start runs the old version and doesn't upgrade again. The whole file is
# written, because after a finished upgrade there is none.
from=${B##*/}; from=${from%-to-*}; to=${B##*-to-}
printf 'phase=failed\nfrom=%s\nto=%s\nbuild=%s\nattempts=2\nreason=put back by hand\n' "$from" "$to" \
  "$(cat /clouve/suitecrm/BUILD)" > tmp/clouve-backup/state
echo "put back by hand on $(date -u +%Y-%m-%dT%H:%M:%SZ)" > tmp/clouve-backup/upgrade-failed
chmod 600 tmp/clouve-backup/state tmp/clouve-backup/upgrade-failed
```

Then start the container the usual way. Its log says `suitecrm stays on <old version>`. To let it upgrade
again later, remove `upgrade-failed`. A newer build of the image upgrades by itself.

### Remove the kept backup

Once the customer has checked the upgraded site:

```bash
rm -rf /var/www/html/tmp/clouve-backup/*-to-*
```

Leave the other files in `tmp/clouve-backup/` where they are. The backup holds the old code, the settings with
the database password, and every record in the database. Removing it changes nothing else: a held scheduler
stays held.

### Release the held scheduler

First look at what would run. In the app container:

```bash
cd /var/www/html
q() { sudo -u www-data php bin/console dbal:run-sql "$1"; }
q "SELECT name, status, last_run FROM schedulers WHERE deleted = 0"       # the jobs, and which are active
q "SELECT COUNT(*) FROM emailman WHERE deleted = 0"                       # campaign email waiting to be sent
q "SELECT name, status, run_when, flow_run_on FROM aow_workflow WHERE deleted = 0 AND status = 'Active'"
q "SELECT name, status FROM inbound_email WHERE deleted = 0"              # mailboxes that would be read
q "SELECT COUNT(*) FROM reminders WHERE deleted = 0 AND email_sent = 0"   # reminders that would be mailed
```

Tell the customer what is queued. They can switch a job off under Admin, Scheduler, remove queued campaign
email under Campaigns, and set a workflow to inactive, before anything runs. When they agree:

```bash
/clouve/suitecrm/installer/release-scheduler.sh
```

It removes `tmp/clouve-backup/scheduler-held` if that file is there and switches the scheduler on in SuiteCRM's
settings. The scheduler starts within a minute and logs "the scheduler runs". It needs no restart, and the
release holds through restarts and upgrades. The script refuses while a state folder that is not root's is on
the volume: put that folder back first.

To hold the scheduler again:

```bash
cd /var/www/html && sudo -u www-data php /clouve/suitecrm/installer/scheduler-setting.php off
```

### Pause the background loops

For work on the database or the files while SuiteCRM runs:

```bash
touch /var/www/html/tmp/clouve-backup/loops-paused   # both loops stand still within seconds
rm /var/www/html/tmp/clouve-backup/loops-paused      # and go on
```

The folder `tmp/clouve-backup` has to exist and be root's. On a site that never upgraded, make it first:
`mkdir -m 700 /var/www/html/tmp/clouve-backup`.

### The Manual Migration Tasks

An upgrade to 8.10 leaves seven tasks under Admin, Migrations: contact, lead and prospect photos, note
attachments, document revision files, and Google Calendar sync data and users. An admin starts each one there.
They need the Messenger worker:

```bash
ps -eo user,args | grep '[m]essenger:consume'      # one php process of www-data
cd /var/www/html && sudo -u www-data php bin/console messenger:stats
cd /var/www/html && sudo -u www-data php bin/console dbal:run-sql \
  "SELECT name, status FROM manual_migration_tasks WHERE deleted = 0"
```

A task shows `initial` until an admin starts it. One that was started and makes no progress means the worker
is not running. The container's log says why, in lines about "the Messenger worker".

### The container exits at start

- "the volume holds no SuiteCRM, but the database ... already has ... table(s)": the volume was lost or swapped,
  or the deployment points at another deployment's database. The image doesn't install, because SuiteCRM's
  installer would drop that database. Put the volume back or restore it. Only when the database really is to be
  made again, empty it first.
- "the volume holds SuiteCRM ..., which is newer than this image's": run the image the deployment had before,
  or a newer one.
- "an install into another database ... was cut off on this volume": start the container with the database it
  was installing into, or remove `/var/www/html/.clouve-install-in-progress` once it is certain that this
  database may be dropped and made again.
- "says that an install was cut off here, but the database ... holds ... users": the install stamp is there
  next to a database that people have worked in. Nothing was changed. If this is a working site, remove
  `/var/www/html/.clouve-install-in-progress`.
- From the database container, "refusing to start": the data directory was last used by a newer MariaDB line
  than the image's. Run the database image the deployment had before.
