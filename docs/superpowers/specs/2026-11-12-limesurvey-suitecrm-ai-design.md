# LimeSurvey 7, SuiteCRM 8.10 and the Customer Kit, each with the AI Assistant: design

Date: 2026-11-12. Status: reviewed; section 14 holds the review's changes and overrides anything above it that differs. Research behind it: three reports written the same day (LimeSurvey 7, SuiteCRM 8.10.2, the rig flow), every fact tested or cited.

## 1. Why

LimeSurvey and SuiteCRM are the last two Clouve apps with a database that have no AI Assistant, and both images are
behind upstream: LimeSurvey is on 6.16.1 while upstream is on 7.x, and SuiteCRM is on 8.9.1 while upstream is on
8.10.2. AJ asked on 2026-11-12 to upgrade LimeSurvey to its latest version and enable the AI Assistant on it, then
widened the request: "Can we upgrade SuiteCRM as well and enable AI Assistant for it first, then apply the same to the
bundle?" So this covers three listings: LimeSurvey, SuiteCRM, and the Customer Kit (`bundles/crm-kit`, slug
`customer-kit` on prod), which runs both with Clouve's SuiteCRM plugin for LimeSurvey.

## 2. AJ's decisions (2026-11-12)

1. LimeSurvey moves to the newest 7.x release available when the image is built, pinned to the exact version. If
   upstream has released a version that the upstream Docker image doesn't ship yet, the build puts LimeSurvey's own
   release into the image and checks its checksum.
2. SuiteCRM moves to 8.10.2, pinned.
3. An existing install upgrades itself the first time it starts on the new image. It saves the old code and a
   database dump first, keeps uploads, settings and anything the customer added, and puts the old version back and
   keeps running if the upgrade fails.
4. The LimeSurvey assistant drafts surveys from a description and leaves them inactive for review, manages admin
   accounts, permissions and participant lists, sends invitations only after a yes, exports and summarizes responses
   on request, and runs the server: email setup, themes, plugins, backups, restores, updates and diagnosis.
5. The SuiteCRM assistant adds and updates accounts, contacts, leads and opportunities, imports a CSV, answers
   questions about the pipeline, manages users and roles, and runs the server: email setup, modules, backups,
   restores, updates and diagnosis. A delete or a bulk change needs a yes and a backup first.
6. The Customer Kit gets both upgraded apps and the AI Assistant with both skills, after the two apps are done.
7. The AI Assistant costs $100 a month on every plan of all three listings. Plan prices don't change.
8. The work goes through UAT and prod after release 4.5.6, as its own listing update, with one stop for AJ's go
   before prod. The build session ends at the rig sign-off, and a saved prompt does the rest.
9. After the prod listings are live, the website's `llms.txt` line that names the apps with the AI Assistant adds
   the three.

## 3. Constraints

- Capacity never changes: each container keeps its `cpuBase`, `memoryBase` and volume sizes. Plan prices and listing
  titles stay as they are.
- Prod has no running LimeSurvey, SuiteCRM or Customer Kit deployment (read on 2026-11-12). Two paused trials exist
  (one LimeSurvey, one Customer Kit). Nothing here touches them, but they are why the in-place upgrade has to work on
  real old volumes. Today nothing moves a running deployment to a newer listing version: its first manifest is
  final, and a rebuilt image reaches it only when the tag it pins is pushed again and its pod restarts. Release
  4.5.6's Upgrade (its row #100) renders a deployment from a newer listing version, and that is how an existing
  install will meet these images. So the upgrade has to work both ways: with the old manifest and only the image
  changed, and with the new manifest.
- The images also run without the AI Assistant. The `clouve-ops` sshd starts only when the platform sets
  `CLOUVE_OPS_PASSWORD`.
- A new volume on a cluster is an empty disk that belongs to root (README, "Volumes on a cluster"). LimeSurvey has a
  nested volume, `/var/www/html/upload` inside `/var/www/html`.
- The platform turns `x-clouve-healthcheck` into a liveness probe and a readiness probe with the same settings. For
  both apps that is a first probe after 30 seconds and a restart after 5 failures 15 seconds apart, so a container
  that doesn't answer for about 105 seconds is restarted. An upgrade can take longer than that.
- Passwords never go through the chat, onto a command line or into a log.
- No commit before 4.5.6 is on prod. This work is staged in worktrees under `~/.cache/limesurvey-suitecrm-ai/wt/`.

## 4. Not in scope

- A new MariaDB major version for either app. Each database image stays on the major version its installs run and
  gets an exact tag.
- An AI Assistant for ownCloud.
- Changes to thermo, meso, iono, strato or the Magneto Agent.
- Explainer videos for the three listings.

## 5. LimeSurvey: the image

Facts below were tested on this machine on 2026-11-12 unless marked otherwise.

### 5.1 Version and base

- LimeSurvey 7.10.0, build 261109, released 2026-11-09. It fixes six security issues that 7.9.1 has (one rated high),
  and four of them also affect 6.16.x. LimeSurvey 6 has had no support since 2026-08-31.
- Upstream's Docker image trails by about a week, because upstream tags a release only when the next one ships. So
  the image is built in two stages:
  - runtime: `FROM martialblog/limesurvey:7.9.1-261102-apache` (PHP 8.4, Debian 13, Apache on 8080);
  - code: the official zip `limesurvey7.10.0+261109.zip` from `download.limesurvey.org/latest-master/`, checked
    against its published SHA-256 (`05b72d1d…f9db`) in the build, unpacked to `/clouve/limesurvey/package`. The
    code that the base image keeps in `/var/www/html` isn't used.
- `ARG`s name the version, the build number and the checksum, so the next bump changes three lines. When upstream's
  image ships the same version as the zip, the two stay as they are: the zip is the source of the code either way.
- The build patches two files in the package and fails if either patch doesn't apply:
  - `application/helpers/update/updates/Update_700.php` gets upstream's fix `6487164b` (14 lines, on master, not
    in 7.10.0). Without it the 6-to-7 database update drops the answers of one question, and still reports success,
    when a ranking question's column names collide with another question's. The step is skipped once the pinned
    release contains the fix, and a test proves the fix is in the package either way.
  - `application/config/version.php` sets `updatable` to false. The zip carries a build number, which turns the
    in-app updater (ComfortUpdate) on, and that updater would put code on the volume that is newer than the image.
- The image keeps `default-mysql-client` and `wget`, and adds `openssh-server` and `sudo` for the ops channel.

### 5.2 What the entrypoint does, in order

The entrypoint starts as root and Apache starts last. Everything that runs LimeSurvey's PHP before that runs as
`www-data`.

1. Check the required variables. Export `LIMESURVEY_DB_USER` (from `DB_USERNAME`), so the AI Assistant's persona can
   show the database user. Export `DB_MYSQL_ENGINE=InnoDB`, which the old entrypoint set but never exported: new
   installs get InnoDB tables, and existing installs keep the MyISAM tables they have.
2. Start the `clouve-ops` sshd in the background and unset `CLOUVE_OPS_PASSWORD` (README, "The clouve-ops SSH
   channel"). Without the variable there is no sshd.
3. Make each volume's top folder usable: `/var/www/html` and `/var/www/html/upload` go to `www-data` when they are
   root's. `lost+found` counts as empty.
4. Wait for the database.
5. Decide what the volume holds, from `application/config/version.php` on the volume, the same file in the package,
   and `DBVersion` in the database:
   - no code: a new install. Copy the package in.
   - the same version: nothing to do.
   - older code: upgrade (5.3).
   - newer code, or a database newer than the code: stop with a clear message and don't start Apache. LimeSurvey
     itself doesn't notice old code on a newer database and would write to tables that no longer exist.
   - a `DBUpdateIncomplete` row, or the upgrade's own marker: an upgrade was cut off. Pick it up (5.3).
6. A missing `upload/` skeleton is copied from the package (the nested volume starts empty on a cluster).
7. Install a new site, or run `updatedb`, as `www-data`, with no password on a command line: the admin's and the
   database's passwords reach PHP through the environment.
8. Keep `publicurl` in step with `PUBLIC_URL` (as today), and write `application/config/allowed_hosts.php` with
   `localhost` and the host of `PUBLIC_URL`, keeping any other entries. LimeSurvey 7 writes that file itself at the
   first admin sign-in, with whatever host that request used, and then answers 400 on the admin pages for any other
   host. The health check's `/` isn't affected.
9. The SuiteCRM plugin, when `ENABLE_SUITECRM_INTEGRATION` is `true` (section 9), and the demo survey, as today.
10. Start Apache as PID 1.

An Apache drop-in in the image denies web access to `/var/www/html/clouve/` (the upgrade's backups) and to the
package's `node_modules/` and `installer/` folders. It comes from the image, so it holds whichever LimeSurvey code is
on the volume.

### 5.3 The in-place upgrade

It runs when the volume's code is older than the package, before Apache starts. That order matters: with new code on
an old database, LimeSurvey lets anyone start the database update from the browser without signing in.

1. While it runs, a stand-in answers the health check on port 8080 with a short "upgrading" page, so that
   Kubernetes doesn't restart the container halfway (the probe allows about 105 seconds, and copying 22,000 files to
   a network disk plus the update of every response table can take longer).
2. Check free space for the old code (about 520 MB) and the dump. Too little: don't upgrade, say why, keep running
   the old version.
3. Save a database dump to `/var/www/html/clouve/upgrade-<from>-to-<to>/db.sql.gz`, then move the old code into the
   same folder. Kept in place: `application/config/config.php`, `security.php` and `allowed_hosts.php`, plugins the
   customer added under `plugins/`, the Clouve markers, and anything at the top level that the package doesn't
   ship. `upload/` is its own volume and isn't touched. `tmp/` starts empty.
4. Copy the new code in, and take `plugins/SuiteCRMIntegration` from the package.
5. Run `console.php updatedb` as `www-data`. Success means exit 0, `DBVersion` equal to the package's, and no
   `DBUpdateIncomplete` row.
6. On success: switch the SuiteCRM plugin back on if it was on before (the update switches every added plugin
   off), flush the asset caches, write the version stamp, and keep the backup folder. The AI Assistant's skill says
   how to remove it once the customer has checked the site.
7. On failure: drop the database's tables, load the dump, move the old code back, record the failure in
   `clouve/upgrade-failed`, and start the old version. The next start doesn't try again until that file is gone, so
   a broken upgrade can't loop. The log says what failed, and the skill has the playbook for it.
8. A start that finds the upgrade cut off (the container was killed in the middle) restores from the backup first,
   then runs the upgrade again from step 2.

Version 6 code runs on the new image's PHP 8.4, which is what makes step 7 safe (tested).

### 5.4 Tests

- `tests/limesurvey-image.test.sh`: the package is 7.10.0 with the checksum line in the Dockerfile, the `Update_700`
  fix and `updatable` false are in it, the Apache drop-in denies the three paths, no SSH host keys ship, the persona
  is at `/clouve/context/limesurvey/`.
- `tests/limesurvey-upgrade.test.sh`: a real 6.16.1 site (built from this repo's earlier Dockerfile on
  `martialblog/limesurvey:6.16.1-251125-apache`) with a survey, responses, an added plugin and a custom theme starts
  on the new image and comes up on 7.10.0 with all of it; the health check never fails during the upgrade; a second
  start doesn't upgrade again; a forced failure of `updatedb` ends on a working 6.16.1 with its data and the
  `upgrade-failed` file; a container killed mid-upgrade recovers at the next start; a volume with newer code refuses
  to start; the ranking-collision survey keeps its answers.
- `tests/limesurvey-entrypoint.test.sh`: no password on a command line or in the log, `CLOUVE_OPS_PASSWORD` not in
  Apache's environment, `allowed_hosts.php` after a `PUBLIC_URL` change, InnoDB on a new install, root-owned new
  disks.
- The shared tests gain the two images: `ssh-host-keys`, `db-image-zombies`, `db-image-gosu`, `app-ops-password`,
  `persona-hosts`, `persona-ssh-commands`, `listing-ai-copy`, `dockerfile-base-tags`, and
  `new-disk-start.test.sh limesurvey` with `--upgrade-from` the 6.16.1 build.

### 5.5 The database image

`limesurvey-mariadb` stays on MariaDB 11 with an exact tag (11.8, which is what `mariadb:11` is today and what the
installs' data files were made by), and becomes the same shape as `wordpress-mariadb`: tini as PID 1, the rebuilt
gosu, the `clouve-ops` sshd started detached, no SSH host keys, `CLOUVE_OPS_PASSWORD` kept from `mariadbd`.

## 6. SuiteCRM: the image

### 6.1 Version and base

- SuiteCRM 8.10.2 (2026-07-31), the newest release. 8.9.1 lacks 49 published security fixes. The build downloads
  `SuiteCRM-8.10.2.zip` and checks its SHA-256 (`ac4693d1…f5a8`, the digest GitHub shows for the asset). The zip
  already holds `vendor/` and the built front end, so the Composer stage, git and the `composer install` step go.
- `FROM php:8.3-apache`. PHP 8.2 loses security support on 2026-12-31, and 8.3 is the one version that both 8.9.1
  (which runs the first half of an upgrade) and 8.10.2 support. The extension installer is pinned to a release
  instead of `latest`. The `imap` extension is added, since checking inbound mailboxes is one of the scheduled jobs.
- The zip is kept in the image twice over: unpacked at `/clouve/suitecrm/app` for new installs, and as the zip at
  `/clouve/suitecrm/SuiteCRM-8.10.2.zip`, because SuiteCRM's own upgrade command takes the package as a zip.
- The package's `config/services/system/upgrades.yaml` gets the image's own entries on its keep-list (`clouve`,
  `.suitecrm_initialized`, `.suitecrm_url`), so a later upgrade from this version keeps them.
- An Apache drop-in sets `HTTPS=on` when the ingress says the request came over HTTPS
  (`SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on`). Without it the session cookie has no Secure flag and `/logout`
  redirects to `http://`. SuiteCRM's own `TRUSTED_PROXIES` setting does nothing in 8.10.2.
- Apache's worker count is sized from the container's memory limit at start, as Nextcloud's is. The Customer Kit
  gives this container 1 GB, and one worker takes 75 to 90 MB.

### 6.2 What the entrypoint does, in order

1. Check the variables, export `SUITECRM_DB_HOST`, `SUITECRM_DB_NAME` and `SUITECRM_DB_USER` (from `DATABASE_*`) for
   the persona, start the `clouve-ops` sshd and unset `CLOUVE_OPS_PASSWORD`.
2. Make the volume's top folder usable (`/var/www/html` goes to `www-data` when it is root's).
3. Wait for the database.
4. Decide what the volume holds, from `VERSION` on the volume, the image's version, and the row
   `info / suitecrm_version` in SuiteCRM's `config` table (8.10.2 writes it as the last step of an install or an
   upgrade; 8.9.1 has no such row):
   - no code: a new install, run as `www-data` with upstream's permissions (folders 2755, files 0644), with no
     password on a command line, and `config_si.php` (which keeps the admin's and the database's passwords in
     clear text) removed afterwards;
   - the image's version, finished: nothing to do;
   - an older version: upgrade (6.3);
   - a newer version: stop with a clear message;
   - `VERSION` at the image's version without the `config` row, or the upgrade's own marker: an upgrade was cut
     off. `VERSION` flips early in the copy, so it never proves a finished upgrade. Pick it up (6.3).
5. Keep the site's address in step with `SUITECRM_URL`: `site_url` and `host_name` in `public/legacy/config.php`.
   Today's code edits a `.env.local` line and a database row that don't exist, and leaves `host_name` stale.
6. Make `www-data` an allowed cron user (one line in `config_override.php`, written through SuiteCRM's own
   Configurator). Today's installer runs as root, which leaves only a placeholder there, so no scheduled job has
   ever run on any install: no workflows, reminders, inbound mail, campaign sending or search indexing.
7. Start two background loops as `www-data`: the scheduler (`bin/console schedulers:run` once a minute) and, new
   in 8.10, the Messenger worker (`messenger:consume internal-async`, restarted when it exits, capped at 256 MB).
8. Start Apache as PID 1. The whole-tree `chmod -R 755` at every start goes: it also reset the OAuth2 private key
   from 600 to 755 each time.

### 6.3 The in-place upgrade

SuiteCRM's own procedure is two console commands run as `www-data`, with no browser, no network and no Composer.
Three things go wrong when an entrypoint just runs them from 8.9.1, and the upgrade step covers each:

- 8.9.1's upgrade code deletes `uploads/` and `public/media-upload/` (email attachments and file fields) and every
  file in the install root that it doesn't know, the image's own markers included. Upstream fixed the first part
  in 8.9.2. The step adds those paths to the installed keep-list and clears the Symfony cache before the first
  command, and afterwards 8.10's migration renames the two folders to `media/` and `public/media/` as intended.
- `VERSION` isn't a completion marker (6.2).
- Without a terminal, the "these files will be deleted" prompt answers itself with yes.

The steps:

1. A stand-in answers the health check on port 80 while the upgrade runs.
2. Check free space, measured, not assumed: the package unpacked (about 450 MB), the zip copy, the code archive
   (the tree without the data folders the upgrade keeps in place) and the dump.
3. Write the marker `tmp/clouve-backup/upgrade-in-progress`. `tmp/` is on SuiteCRM's keep-list and isn't served
   (the web root is `public/`).
4. Back up into `tmp/clouve-backup/<from>-to-<to>/`: the code tree as a tar.gz (without `tmp/` and `cache/`) and a
   database dump. The database password goes in a mode-600 options file, never on a command line.
5. Patch the keep-list, clear the cache, copy the zip to `tmp/package/upgrade/`.
6. Run `suitecrm:app:upgrade -n -t SuiteCRM-8.10.2`, then `suitecrm:app:upgrade-finalize -n -t SuiteCRM-8.10.2`.
   Success means both exit 0, the `config` row says 8.10.2 and `bin/console suitecrm:version` prints it. Apache
   isn't up yet, so no HTTP check happens here; the tests ask `/session-status` once Apache serves.
7. On success: remove `tmp/package/upgrade` (591 MB), write the markers again, remove the in-progress marker, keep
   the backup.
8. On failure, or at a start that finds the in-progress marker: restore the code tree, drop the database's tables
   and load the dump (the upgrade adds tables that the dump doesn't drop), record it in
   `tmp/clouve-backup/upgrade-failed`, and start 8.9.1, which runs on PHP 8.3. No retry until that file is gone.

The upgrade leaves seven Manual Migration Tasks pending in Admin > Migrations. They need the Messenger worker, and
the skill has a playbook for them.

### 6.4 Tests

`tests/suitecrm-image.test.sh`, `tests/suitecrm-upgrade.test.sh` and `tests/suitecrm-entrypoint.test.sh`, on the
same pattern as LimeSurvey's (5.4): a real 8.9.1 site built from this repo's earlier Dockerfile, with records, a
second user with a role, a custom field, files in `uploads/` and `public/media-upload/`, an SMTP account and the
LimeSurvey plugin's OAuth2 client, starts on the new image and comes up on 8.10.2 with all of it; the health check
holds during the upgrade; a forced failure and a kill in the middle both end on a working 8.9.1; the scheduler runs
as `www-data`; no password is on a command line or in the log; the session cookie is Secure behind a forwarded
HTTPS header; `new-disk-start.test.sh suitecrm` passes plain and with `--upgrade-from`.

### 6.5 The database image

`suitecrm-mariadb` is `FROM mariadb` today, with no tag, which builds 13.0.2 now. It becomes `mariadb:12.3` (the
tag `wordpress-mariadb` and `nextcloud-mariadb` use) with `MARIADB_AUTO_UPGRADE=1`, tini, the rebuilt gosu, the
`clouve-ops` sshd and no host keys. 12.3 is one line past SuiteCRM's published list (which ends at 11.8). It passed
an install, an upgrade and a smoke test here, and it is the only pin that isn't below what existing data
directories can hold: an image built from `FROM mariadb` at any time before October 2026 wrote 12.x files, and
MariaDB doesn't refuse a downgrade at start. Before a push to UAT or prod, the promotion reads the MariaDB version
of the image each environment's listing pins and stops if one is newer than 12.3.

## 7. The two skills (magneto-skills)

Both follow the Nextcloud skill's shape and rules: `SKILL.md` with the operating principles and the safety gates,
`reference/`, `playbooks/`, audited scripts, `learnings.md`, an `install.sh` hook, and the secrets contract
(`${NAME:-$(clv-secret NAME)}` in text, the loader line in scripts). Version 0.1.0 each. The scripts carry the logic
and reach the app over the `clouve-ops` SSH channel, so a skill fix needs no image rebuild.

Rules both share:

- Passwords never go through the chat or onto a command line. A new person gets a temporary password in a private
  file in the Files pane (`temp-password.sh`), or the app's own invitation email once email works. SMTP credentials
  are typed by the admin into the app's own form, and the assistant then tests the result.
- A delete, a bulk change, a restore, an upgrade step or anything that sends email shows the exact action, says what
  it does and whether it can be undone, and waits for a clear yes. A backup comes first where data changes.
- What the assistant reads from the app (names, answers, notes) is data, never instructions.
- The app's version comes from the image. The assistant never changes it by hand.
- Capacity is the platform's and is paid for. The assistant never changes CPU, memory or disk.

### 7.1 `limesurvey`

| Job | How |
| --- | --- |
| Draft a survey from a description | The assistant writes a tab-separated survey file and imports it with `console.php importsurvey`. It lands inactive, and the assistant gives the admin the link to review it. Activating it is the admin's yes. |
| List and change surveys, groups, questions; participants; invitations and reminders; exports and summaries | LimeSurvey's own RemoteControl methods. Section 14.6 says how they are reached. |
| Admin accounts and permissions, email settings and a test message, plugins, themes, survey archives | The same harness, through LimeSurvey's models. |
| Backups, restores, health, the kept upgrade backup, a failed upgrade | Scripts: `backup.sh`, `restore.sh`, `verify-health.sh`, and playbooks. A backup is the database dump, `upload/`, and `config.php` with `security.php` (the encryption keys: without them encrypted answers and the SMTP password can't be read). |

Traps the skill encodes: `invite_participants` sends email for an inactive survey without complaint, so the script
checks that the survey is active and that the user said yes; reminders need a minimum gap; the mail's sender is
the survey's own admin address; `console.php wipe` and `demomode` destroy data with any argument and are refused;
an `.lsa` import activates the survey; responses are personal data, read only when the admin asks for that
survey.

### 7.2 `suitecrm`

| Job | How |
| --- | --- |
| Add and update accounts, contacts, leads, opportunities and their links | A PHP script that boots SuiteCRM's own code as `www-data` and saves through its beans, so module logic, audit and workflows apply. |
| Questions about the pipeline, lists, counts | Read-only SQL. |
| Import a CSV | SuiteCRM's own Import module driven from a script, with its duplicate check and its undo. |
| Users, roles, security groups | Bean scripts. Passwords on stdin, or SuiteCRM's own generated password by email. |
| Outgoing email | The admin fills in SuiteCRM's form; the assistant checks the account and sends a test message. |
| Modules, repair and rebuild, logs, scheduled jobs, the Manual Migration Tasks | Scripts for Module Loader packages and Quick Repair, and playbooks. |
| Backups, restores, health, a failed upgrade | `backup.sh`, `restore.sh`, `verify-health.sh`. A backup is the database dump and the install tree's customer parts: `public/legacy/upload`, `public/legacy/custom`, `media/`, `public/media/`, `extensions/`, `.env.local`, the config files, the OAuth2 keys and the blowfish key. |

Traps the skill encodes: a delete through the Import undo is permanent; the Import module creates missing accounts
by name and reads the header row as data unless it is stripped; SMTP authentication needs `auth_type = 'basic'`; in
the Customer Kit, changing the admin's password, the OAuth2 client named "LimeSurvey Integration" or the key pair
breaks the LimeSurvey link.

## 8. Personas, manifests and listing text

- Each app image carries its persona at `/clouve/context/<app>/CONTEXT.md.tpl`, on the WordPress and Nextcloud
  pattern: who the assistant is for, the hosts (`${LIMESURVEY_HOST}`, `${LIMESURVEY_DB_HOST}`, `${SUITECRM_HOST}`,
  `${SUITECRM_DB_HOST}`), the SSH commands with both host-key options, the passwords by name
  (`LIMESURVEY_DB_PASSWORD`, `SUITECRM_DB_PASSWORD`, fetched in the two-part form), the operating posture, and the
  skill-maintenance section.
- Each manifest gains `x-clouve-agent` with its skill (`?plugins=limesurvey`, `?plugins=suitecrm`) and
  `sidecarPullTimeout: 600`. Titles stay "LimeSurvey" and "SuiteCRM". `appVersion` becomes 7.10.0 and 8.10.2. Each
  description is rewritten to say what the assistant does, with the two sentences the listing rules require (paid
  plan: the price includes an AI usage allowance and more can be bought; free trial or free services: the
  customer's own Claude subscription), in at most 1,000 characters.
- Each `docker-compose.yml` gains the `magneto-agent` service for local runs, as WordPress's has.
- `tests/listing-ai-copy.test.sh`, `persona-hosts`, `persona-ssh-commands` and `check-manifests` cover the new
  entries.

## 9. The Customer Kit

- `bundles/crm-kit/clv-docker-compose.yml` gets both new versions and
  `x-clouve-agent` with `?plugins=limesurvey,suitecrm`, as the Education Kit has two skills. The capacity of its
  four containers doesn't change.
- Clouve's SuiteCRM plugin for LimeSurvey moves to LimeSurvey 7:
  - `config.xml` lists 7.0, so the plugin manager accepts it;
  - the upgrade switches it back on when it was on (5.3), and `configure-suitecrm-plugin.sh` activates a plugin
    row that exists but is off;
  - its AJAX endpoints require a signed-in admin with rights on the survey. Today they answer anyone, the sync log
    (which holds people's answers) included;
  - debug logging is off by default and never writes answers to `/tmp`;
  - the duplicate `survey_enabled` rows that switch the demo survey's link off are fixed.
- The field-mapping screen stays in LimeSurvey's classic question editor. LimeSurvey 7 opens its new editor by
  default, which has no place for plugin fields. The plugin's settings page says so and links to the setting, and
  the kit's assistant can read and set a question's mapping on request. A mapping screen in the new editor is a
  later piece of work.
- SuiteCRM 8.10.2 changes nothing the plugin uses (the token request and its three API calls answered 200 and 201
  after the upgrade).
- Each skill gets a short section for the kit: what the link needs from the other side, and what would break it.
- `tests/crm-kit.test.sh` starts the bundle on new disks, submits the demo survey and finds the lead in SuiteCRM;
  `new-disk-start.test.sh crm-kit` passes.
- devenv's E2E fixture `e2e-crm-kit` is built from this manifest. It stays a listing without the AI Assistant:
  the fixture drops the `x-clouve-agent` block, so AI-01, MKT-03 and PUB-02 keep their meaning.

## 10. Proof on the rig

Under the `rig` lock, with the suite's `e2eorg` login and its listing helpers, and never touching the two fixture
listings or the `:2026.10.12` tags:

1. Push the four images under a tag of this run's own, and the 6.16.1 and 8.9.1 builds under a second tag.
2. Publish three private listings in the publisher's organization (ca@ submits, fta@ stages and approves), with a
   $100 AI Assistant price.
3. New installs: a trial of each with the AI Assistant on. Running, the app answers, the assistant's container has
   the persona and the skill (loaded from this run's copy, since the skill isn't on `main`), and each skill's
   scripts work against the real pod: health, a backup, a draft survey, a new person, a record.
4. Upgrades, the way the Moodle 5.3 check did it: a listing of each app on a tag of this run's own that first
   holds the old build (the digests already in the rig's registry), a trial of it with data, then the new build
   pushed under the same tag and the pod deleted. The site comes up on the new version with the data made before.
   No upgrade is cut off on purpose on the rig; those drills run locally.
5. The assistant with a real model: one deployment of each app gets model access on the rig, and the assistant does
   one real task per app from a plain-English request, with the transcript kept (no secrets). The spend is capped
   and reported.
6. Clean up: deployments, listings, tags, files.

## 11. After the rig: commits, UAT, prod

A saved prompt in `claude/prompts/` does this part once 4.5.6 is on prod and no freeze marker exists:

1. Carry the staged work onto the new tips of `develop` (4.5.6 adds a password-rotate script to every app), run
   every suite again, commit one commit per repo and push.
2. UAT: check the MariaDB version of what UAT's listings pin, run the new-disk test plain and from UAT's pinned
   images, push dated tags, merge magneto-skills to `main`, publish the three listings' new versions, install each,
   and check the assistant and the upgrade.
3. Stop: email AJ the sign-off page (listing text, prices, UAT results) and wait for his go.
4. Prod: the same pushes and listing versions, the two paused trials left alone, then the website's `llms.txt`
   line through `./deploy.sh`.

## 12. Build order

1. SuiteCRM image and its database image. LimeSurvey image, its database image and the plugin's move to 7. These two
   run side by side in separate worktrees.
2. The `suitecrm` skill with SuiteCRM's persona, manifest and listing text. The `limesurvey` skill with the same
   for LimeSurvey.
3. The Customer Kit: manifest, the kit test, the E2E fixture.
4. Reviews (code, security, the skills' text) and one fix round.
5. The rig.
6. Docs (READMEs, CLAUDE.md, release note), the saved prompt, the sign-off page.

Every script, image and manifest change starts with a failing test.

## 13. Calls made here, and what is still a risk

Calls (AJ can overrule any of them):

- LimeSurvey's code comes from upstream's zip on upstream's runtime image, with one upstream fix applied early.
- New LimeSurvey installs get InnoDB tables; existing ones keep MyISAM.
- SuiteCRM moves to PHP 8.3 and gets the `imap` extension.
- SuiteCRM's scheduled jobs and its Messenger worker run from now on. They never ran before.
- `suitecrm-mariadb` is pinned to 12.3, one line past SuiteCRM's list.
- The upgrades keep one backup on the volume until someone removes it (about 600 MB for LimeSurvey; for SuiteCRM
  the code archive and the dump, without the customer's files, which stay in place).
- LimeSurvey 7's image has no `imap` extension (Debian 13 dropped it), so bounce processing doesn't work there. The
  skill says so.
- The plugin's mapping screen stays in the classic editor for now.
- The E2E fixture stays without the AI Assistant.

Risks:

- Upgrade times on a network disk aren't measured. The stand-in for the health check is what makes a slow upgrade
  safe, and the rig is where it is first seen on a cluster disk.
- A SuiteCRM install made from the command line has no migrations table, so its first upgrade runs every migration
  since 2020. They ran clean on small test data.
- The new LimeSurvey editor and the SuiteCRM browser UI were exercised by HTTP only, never in a real browser. The
  rig proof opens both.
- LimeSurvey releases about weekly. If a newer 7.x is out when the images are built for UAT, the saved prompt bumps
  the three build arguments and runs the upgrade tests again.

## 14. Changes after the design review

A reviewer checked this note against the research, the repos and the agent's code on 2026-11-12. These rules come
from that review. Where one differs from a section above, this section wins.

### 14.1 Upgrade state: one rule for both apps

Each upgrade keeps a small state file in its backup folder and moves through named phases. A restart at any point
reads the phase and does the one thing that is safe there.

| Phase found at start | What it means | What the start does |
| --- | --- | --- |
| none | no upgrade under way | the decision table |
| `backup` | killed while backing up; nothing in the site has changed | delete the partial backup, start the upgrade again |
| `upgrade` (backup stamped complete) | killed after the backup | test the success criteria first. If they hold, finish the clean-up. If not, restore from the backup and run the upgrade again |
| `restore` | killed during a restore | run the restore again |
| `failed` | the upgrade failed and the old version was put back | start the old version; no retry until the image's build differs from the one in the file, or someone removes the file |

- A backup is written under a temporary name, checked (the pipe's exit codes, `gzip -t`, the dump's last line, the
  archive's listing), renamed, and only then stamped complete. A restore happens only from a stamped backup, and a
  stamped backup is never overwritten.
- A restore is checked too (the tables are back, the version reads as the old one). If a restore fails, Apache
  doesn't start and the container exits non-zero with the state kept, so the platform shows a failing pod instead
  of a site running old code on a half-changed database.
- After two failed attempts at the same build the state becomes `failed`. The file records the build it failed
  on, so a later image with a fix tries again by itself.
- One backup is kept: when a newer upgrade has a complete backup of its own, the older folder goes.
- Backup folders are mode 0700 and their files 0600.
- Each phase logs one line that starts with `[clouve-upgrade]`, and a failure logs
  `[clouve-upgrade] FAILED <app> <from> -> <to>: <reason>`, for staff and for alerts.
- A test-only hook pauses the upgrade at a named step for a given time (an environment variable that does nothing
  when unset). The tests use it to stretch an upgrade past 105 seconds and to kill the container once in every
  phase, the backup first, and they assert the version the site ends on, not only that `/` answers.

### 14.2 New installs

- An install writes an `install-in-progress` stamp first and removes it last. A start that finds the stamp, on a
  volume it was installing, clears the unfinished install (code and the tables it made) and installs again.
- No code on the volume but tables in the database is refused with a clear message: a volume was lost or swapped,
  and installing over the data would, for LimeSurvey, also make new encryption keys that can't read the old
  answers.
- A new install also runs behind the stand-in when it can outlast the probe.
- Both stock installers take their passwords as arguments. The image hands them to PHP in-process (a small PHP
  wrapper builds the argument list from the environment). Each builder proves that route first, before building
  on it.

### 14.3 The stand-in for the health check

- It is not Apache. Stopping a temporary Apache signals every process in the container, sshd included. PHP's
  built-in server on the app's port, serving one router file from the image and no app code, is enough.
- It answers `GET /` with a short "being upgraded" page and status 200, and everything else with 503 and
  `Retry-After`, so a caller such as the LimeSurvey plugin never reads the page as an API reply.
- Before Apache starts, the entrypoint stops it by PID and waits for the port. A test covers the hand-over.

### 14.4 What the agent can see

- The agent reads each app's PID 1 environment once, when its sshd first answers. So the entrypoint works out the
  aliases first, re-executes itself with them (as Nextcloud's does), and only then starts the sshd. The aliases:
  `LIMESURVEY_DB_USER`; `SUITECRM_DB_HOST`, `SUITECRM_DB_NAME`, `SUITECRM_DB_USER` and `SUITECRM_DB_PASSWORD`
  (the password is already in that environment as `DATABASE_PASSWORD`). A test reads PID 1's environment while the
  entrypoint is still waiting for the database.
- The sshd is up during an install or an upgrade, because the agent gives up on an app whose port answers while
  its sshd doesn't. The skills' scripts refuse to run while an install or upgrade state file says work is under
  way, and say why.
- `tests/persona-hosts.test.sh` gains the two apps in its database-password check, and the skills repo's
  `tests/skills-env-values.test.sh` and `CLAUDE.md` gain the `LIMESURVEY_` and `SUITECRM_` prefixes.

### 14.5 Settings re-asserted at every start

- Both entrypoints write the database host, name, user and password from the environment into the app's own
  config at every start (LimeSurvey: `config.php`; SuiteCRM: `public/legacy/config.php` and `.env.local`), as
  Nextcloud's does. Today they are frozen at install. Release 4.5.6 adds a database password rotation, and a
  restored or copied deployment can come up with new secrets.
- In the Customer Kit, `configure-suitecrm-plugin.sh` re-asserts the plugin's connection settings (SuiteCRM's
  address, admin name and password, database settings) from the environment at every start, in the plugin's
  encrypted settings, without touching whether the plugin is on. Only the upgrade step switches the plugin back
  on, and only when it was on before. The upgrade writes the list of plugins that were active to its backup
  folder and logs the ones it leaves off.
- No script passes a password on a command line: `configure-suitecrm-plugin.sh` and `import-demo-data.sh` use an
  options file of mode 600 or `MYSQL_PWD`. `tests/installer-db-password.test.sh` covers both images.
- SuiteCRM: `config_si.php` is deleted at any start that finds it, before a backup can copy it. The OAuth2 private
  key is set to mode 600 once.

### 14.6 How the LimeSurvey skill reaches RemoteControl

The image doesn't change for this, and customers keep their own use of RemoteControl: nothing locks the endpoint
to the container. A spike decides between two routes before the skill is written:

1. Preferred: a PHP harness that the skill sends over SSH and runs as `www-data`. It starts LimeSurvey's web
   application class in the CLI (the console application refuses permission checks), acts as the site's main
   admin, and calls the RemoteControl handler's methods directly. No HTTP, no setting changed, nothing exposed.
2. Fallback: JSON-RPC to `localhost` inside the container. The script reads the `RPCInterface` setting; if it is
   `off` it switches it to `json` for the call and back afterwards, and if the customer has it on it leaves it
   alone. It signs in with a session made through LimeSurvey's own session model for the main admin and removes
   it afterwards. For the seconds the interface is on, the public endpoint asks for a password or that session
   key, as the admin sign-in page does.

### 14.7 SuiteCRM's scheduled jobs on an existing install

- A new install runs the scheduler from its first start.
- An install that existed before this image has never run a scheduled job. Starting them all at once could send
  queued campaign email and run workflows over old records with nobody's yes. So the upgrade writes
  `tmp/clouve-backup/scheduler-held`, and the scheduler loop doesn't run while that file exists. The log says so,
  the README tells staff how to look at what is queued and release it, and the skill has the same as a playbook.
- The Messenger worker starts only when the installed version is 8.10 or later, and both loops restart with a
  back-off when they exit.
- Apache's worker limit is (the memory limit minus 450 MB) divided by 90 MB, at least 4. At the Customer Kit's
  1 GB that is 6. A test starts the container at 1 GB and reads the limit and the memory in use.
- `mod_remoteip` in the same Apache drop-in takes the client's address from the ingress's header, trusting only
  private ranges, so SuiteCRM's login throttle counts people and not the ingress. A test reads the address PHP
  sees. If it can't be made right, it stays out and the report says so.

### 14.8 Backups: what is in them

- SuiteCRM's upgrade backup is the code and settings without the customer's files: it leaves out
  `public/legacy/upload`, `uploads/` (or `media/`), `public/media-upload/` (or `public/media/`), `cache/` and
  `tmp/`, which the upgrade keeps in place. A way back that finds the two media folders already renamed by the
  upgrade's migration names them back.
- The skills' full backups add what the first lists missed. SuiteCRM: added modules under
  `public/legacy/modules/<name>` and `public/extensions`. LimeSurvey: hand-added `plugins/` and
  `allowed_hosts.php`; the dump is taken under `setmaintenancemode hard-cli`, since existing installs have MyISAM
  tables; and a restore puts `security.php` back before any LimeSurvey code runs. Each skill's tests restore a
  backup onto an empty volume.
- LimeSurvey's space check covers the code volume. The database's disk is another volume that the app container
  can't measure, so the step logs the size of the response tables, and an update that runs out of space there is
  a failure like any other: the tables are dropped, the dump loaded.

### 14.9 The database images

- Each wrapper reads `mariadb_upgrade_info` (or `mysql_upgrade_info`) in the data directory and refuses to start
  when it names a newer MariaDB line than the image's, with a clear message. MariaDB itself starts on newer
  files without complaint, and that downgrade isn't supported.
- The upgrade tests make their old database from the version prod's installs have, not from today's `FROM
  mariadb`: `mariadb:12.1` for SuiteCRM (what `latest` was when prod's images were built) and `mariadb:11.8` for
  LimeSurvey. The saved prompt reads the real versions from the images UAT's and prod's listings pin, and from
  4.5.6's own pin for `suitecrm-mariadb` (its row #184), and never pins below any of them.
- In the Customer Kit the database containers have a 60-second command probe. The kit's test times MariaDB's own
  automatic upgrade against it.

### 14.10 The Customer Kit, the tests and installs without the assistant

- `tests/crm-kit.test.sh` also runs with `--upgrade-from`: both apps upgrade in one start, the plugin is on
  again, its OAuth2 client still works, and a survey response made afterwards becomes a lead.
- The LimeSurvey upgrade tests use two sources: the 6.16.1 build and a 6.17.18 build (what `6-apache` is today).
- An install made from a listing version without the AI Assistant has no assistant after an image-only upgrade.
  So each app's README has a short staff runbook that needs no assistant: reading the upgrade's state, the way
  back, removing the kept backup, releasing SuiteCRM's held scheduler, SuiteCRM's Manual Migration Tasks.
- On the rig, the model proof uses a trial in the publisher's organization and a model key made for that one
  deployment with a small budget, removed afterwards. No test listing is public and no seeded account pays.
