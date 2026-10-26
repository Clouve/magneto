# New-disk volumes: start every magneto app the way a cluster does

Date: 2026-10-26. Status: for AJ's approval.

## Why

On 2026-10-26 the first Nextcloud install on GKE (UAT, CLOUVEINC8-66, namespace org-8-tkt-265) crash-looped with exit
code 2. Its volume at `/var/www/html` was a new persistent disk whose top folder belonged to root (mode 755, with
`lost+found` in it), so www-data could not make the init lock. Every local run and every test had used Docker named
volumes instead. Docker fills a new named volume with a copy of the image's folder at that path: the files, the owner
and the mode. Kubernetes never does. The fix is in magneto develop 416b887, and the details are in
`apps/nextcloud/README.md`.

The cause was general, not Nextcloud's. Tropo writes a plain PersistentVolumeClaim for each volume, with no storage
class (so the cluster default: `standard-rwo`, pd-balanced, ext4 on GKE), no init container and no securityContext or
fsGroup. So on its first start every magneto container sees each volume as an empty filesystem: the top folder is
root's with mode 755, `lost+found` (root's, mode 700) is in it, and nothing the image keeps at that path is there.

Some images already cope, each in its own way. The Magneto Agent and AI Studio seed their volumes from snapshots in the
image and write a sentinel file. The official WordPress entrypoint gives a root-owned folder to www-data. Moodle's
entrypoint changes ownership as root at every start. Nextcloud now does what WordPress does. None of this is written
down as a packaging rule, and nothing local shows what the cluster does, so a new app or a change to an old one can
pass every check on this machine and still fail on its first cluster start.

A first look at the other apps (2026-10-26, files only, nothing run yet) shows LimeSurvey's image keeping all 22,703
files of its code inside `/var/www/html`, a volume path, and ownCloud keeping 3 files at its volume path `/mnt/data`.
On a new cluster disk those folders would start empty.

## What AJ decided (2026-10-26)

AJ chose "the test, the rules and the audit, plus cluster-like local starts":

1. `./start.sh` creates every new named volume shaped like a new cluster disk, by default. Volumes that already exist
   are left as they are.
2. A test starts any app or bundle on such volumes and fails unless every container passes its platform probe in time
   and stays up.
3. The test runs on every app and both bundles now, and whatever fails gets fixed in its image, each fix with a test.
   (Later the same day AJ took n8n off the marketplace: it now lives only on the `n8n` branch, and develop has 9
   apps.)
4. The packaging rules go into magneto's README.md and CLAUDE.md, and the test is required before any UAT or prod
   push.

He chose this over a fix in the platform (Tropo copying each image's folder into a new volume, as Docker does), so this
work changes magneto only.

After the design review he decided three more things:

5. The push requirement is enforced. The test records a pass for the exact source of each app it ran, and
   `build-uat.sh` and `build-prod.sh` refuse to push an app whose current source has no recorded pass. A flag overrides
   that in an emergency. Pushing an app doesn't require the bundles that use it to pass.
6. A fix may treat a volume as new when its top folder is root's. A working install never leaves its top folder root's,
   so a root-owned folder means a new disk, or a first start that broke halfway, and the fix repairs both. It only
   changes the folder's owner and mode, or adds files that are missing, never what is already there. Each fix says in
   its code why its app never leaves that folder root's. This is the rule Nextcloud's fix (416b887) already follows.
7. The check that a fix leaves existing installs alone installs the app with its last local build first (the previous
   dated tag on this machine, for example `:2026.10.22`), not with the image tenants run on prod. No registry access
   is needed.

## Goals

- A local start gives an app's containers the same volumes a cluster gives them on a first install.
- One command tells whether an app or bundle starts on new cluster disks, and why not when it doesn't.
- Every app and bundle in the repository passes it, or has a written reason and a decision from AJ.
- No app reaches UAT or prod without having passed it on the source being pushed.
- Whoever packages the next app, a person or a Claude session, finds the rules and the check where they already look:
  the README's packaging spec, CLAUDE.md, the start script and the push scripts.

## Non-goals

- No change to Tropo, thermo or strato.
- No image pushes to dev, UAT or prod and no listing changes as part of this work. AJ decides per app once the fixes
  are in.
- Only volumes. Other differences between a local run and a cluster (service DNS names, how secrets arrive, the
  ingress) are out of scope.
- The Magneto Agent's own seeding. It has its own tests in magneto-agent, so the new test leaves the agent's service
  out unless asked to include it.
- No gate on dev or rig pushes (`build-dev.sh`, `build-e2e.sh`, plain `build.sh --push`).

## Anti-goals

- A start that changes or deletes a volume that already exists. Local data stays as it is.
- A fix that changes what a working install has. Tenant pods pull `:latest` with pull policy Always at every restart,
  so a fixed image reaches prod tenants without a new install. A fix acts only when a volume is in a state a working
  install never leaves it in (decision 6), and then changes only that state.
- A silent fallback. If the start script cannot shape a new volume, it stops with an error. It never falls back to
  Docker's copy without saying so.
- A recorded pass for source the test didn't run. A pass counts only for the images the test built from that source.
- A check slow or flaky enough that people skip it.

## The model: what a new cluster disk looks like, and how to make one in Docker

On a cluster, each volume is its own filesystem. Its top folder is `root:root`, mode 755, and holds only `lost+found`
(mode 700, root's). A nested mount, like LimeSurvey's `/var/www/html/upload` inside `/var/www/html`, is a second disk of
the same shape.

To give a container the same thing locally, the volume has to exist before Compose creates the container, and it must
not be empty, since Docker only copies the image's folder into an empty volume. Checked on 2026-10-26 with Docker
Compose 5.6.1:

1. `docker compose config --format json` names the project, each volume's full name and each service's mounts.
2. `docker volume create` with Compose's own labels (`com.docker.compose.project`, `com.docker.compose.volume`,
   `com.docker.compose.version`) makes a volume that Compose adopts without its "already exists but was not created by
   Docker Compose" warning, and that `docker compose down -v` removes.
3. A throwaway container (`mirror.gcr.io/library/alpine:3.20`) runs `chown 0:0 /v && chmod 755 /v && mkdir -m 700
   /v/lost+found` on it.
4. Mounted at the app's path, the volume then shows `root:root 755` and `lost+found`, and none of the image's files.

## Part 1: one shared helper

A sourced shell file, `lib/new-disk-volumes.sh`, with one function that takes the Compose arguments (project name and
files), finds the named volumes the services use (type `volume`, not `external`), creates each one that doesn't exist
yet as a new disk, prints one line for each volume it made, and returns non-zero with a clear message when anything
fails. Volumes that exist are never touched. The start script, `test.sh` and the new tests all use it, so there is one
definition of a new disk.

My calls:
- The JSON from `docker compose config` is read with python3 and its standard library only. Magneto's tests already
  need python3, and macOS and Linux both have it. `start.sh` says so clearly when python3 is missing.
- The helper and the start script changes run on bash 3.2, the version macOS ships.

## Part 2: the start script (AJ's decision)

- `./start.sh <app or bundle>` calls the helper before `docker-compose up -d`, also after `--cleanup`.
- My call: a `--docker-volumes` flag skips the helper, so Docker copies the image's folder into new volumes as before.
  It is for comparing the two behaviours while debugging, and its help text says that a cluster never does this.
- My call: `test.sh` (the URL change test) gets the same default and the same flag, so no local path still starts on
  Docker's copies by default.
- `stop.sh`, `logs.sh` and `status.sh` don't change.

## Part 3: the test

`tests/new-disk-start.test.sh <app or bundle>... | --all`

- Images. My call: it builds each app target first with `./build.sh <app>` (host platform; a cached build takes about
  a second), so what it tests is the current source. `--no-build` uses the images already on this machine instead, and
  such a run records no pass. A bundle uses the images of the apps it contains as they are on this machine, and the
  test prints each image's age.
- Each run uses its own Compose project name and an override that drops published ports and fixed container names
  (Compose's `!reset`, checked on 2026-10-26), so a run never collides with a local stack of the same app or with
  another run. All volumes come from the helper. The `magneto-agent` service is left out unless `--with-agent` is given.
- My call: the override also gives each container the CPU and memory of the smallest plan, from `cpuBase` and
  `memoryBase` in `x-clouve-metadata` (for Nextcloud: 1 CPU and 2 GB, what its UAT pod got), so the timings mean what
  they mean on a cluster. There is no swap beyond the memory limit either, since GKE nodes have none.
- Health is judged the way the platform judges it. Each service's probe comes from `x-clouve-healthcheck` in the same
  folder's `clv-docker-compose.yml`, matched by service name:
  - HTTP: asked of the container's IP address, as the kubelet asks the pod's (so the Host header is the IP), from a
    throwaway container on the project's network. As the kubelet does, it follows redirects to the same host (up to
    10) and judges the last answer, 200 to 399; a redirect to another host passes at once. (The first version passed
    any first 3xx; the final review found that the kubelet follows same-host redirects, so a redirect to a page that
    fails would have passed here and failed on the cluster.)
  - TCP: the port accepts a connection;
  - Command: `docker exec <container> /bin/sh -c "<path>"` exits 0, as Tropo runs it.
  A service whose probe is off, or that has none, must be running and must not restart.
- Deadline: Tropo uses the probe for both liveness and readiness, so a container that hasn't passed by `initialDelay +
  failureThreshold × interval` would be restarted by Kubernetes. My call: that is each container's deadline, counted
  from that container's own start, and nothing gets more than the 10 minutes the platform's launch job waits for every
  pod. The test probes every 5 seconds. A restart or an exit before the first pass is a failure, and so is a first
  pass after the deadline: Kubernetes, which starts every pod at once, would have restarted the container by then.
  (Compose can hold the probes back while it waits for a dependency's own health check.)
- Once every container has passed, a settle period (90 seconds by default) follows: no container may restart or exit,
  and each probe must keep passing, as the platform counts it. A probe may fail for as long as Kubernetes lets it
  (`failureThreshold` failures in a row, so `failureThreshold × interval` seconds) and then pass again, which the
  output notes; one that fails for longer fails the run. A probe still failing when the period ends gets the rest of
  that time, and passes or fails as it would on the platform.
  Nextcloud's probe, for one, passes during the whole install and then fails for a few seconds before Apache starts
  (found 2026-10-26: the first rule, any failed probe fails the run, failed a healthy Nextcloud).
- Output, per container: PASS with the time to healthy against its deadline, or FAIL with the reason, the exit code,
  the last 30 log lines and any log lines that look like permission errors.
- It always removes what it made: containers, volumes, override file and network.
- Exit status: 0 when every target passes, 1 when one fails, 2 without Docker or without an image.

`--upgrade-from <tag>` (decision 7; my call that it is an option of the same test): the app first installs with its
images at `<tag>` on new disks and must pass, as above. The test then notes each volume's top folder (owner and mode),
removes the containers but keeps the volumes, starts the current images on the same volumes, and checks that every
probe passes again, nothing restarts, and each top folder's owner and mode are as before. It is required for every app
a fix touches, and optional otherwise, so the usual pre-push run stays short.

A second, fast test, `tests/new-disk-volumes.test.sh`, checks the helper itself with a throwaway image and Compose
project. A new volume has the new-disk shape and Compose's labels and none of the image's files. An existing volume
keeps what it has. An external volume is skipped. `--docker-volumes` gives Docker's copy. `down -v` removes the
volumes. A failure stops the start with a message. It also checks the recorded pass and the push gate (Part 6) with a
throwaway app folder.

## Part 4: the audit and the fixes

1. Run the test on the 9 apps (ai-studio, gibbon, limesurvey, moodle, nextcloud, odoo, owncloud, suitecrm,
   wordpress) and the 2 bundles (crm-kit, education-kit).
2. For each failure, find the cause, fix it in the app's image along the rules below, rebuild, and run the test again.
   The test is the regression test for "starts on a new disk". An app that has its own test file gets a check there
   too.
3. Every fix also passes `--upgrade-from` with the app's last local build, and says in its code why the app never
   leaves the folder it acts on root's (decision 6).
4. A finding that needs more than an image change, for example a different volume layout in a manifest or a change in
   Tropo, stops for AJ.

## Part 5: the rules and where they live

A new section in `README.md` (the packaging spec), "Volumes on a cluster", with the model above and these rules:

1. The entrypoint starts as root, and before anything runs as the app's user it makes each volume's top folder
   usable for that user. It acts when the folder is root's, which a working install never leaves it, and it does not
   change ownership through a whole volume at every start.
2. Files that the app needs at a volume path are not shipped at that path. They live elsewhere in the image (for
   example `/usr/src/<app>`) and the entrypoint copies them in when they are missing, as WordPress and Nextcloud do, or
   it seeds the volume from a snapshot and writes a sentinel, as the Magneto Agent and AI Studio do.
3. `lost+found` counts as empty. A first-start check ignores it, and an engine that refuses a data folder that isn't
   empty keeps its data in a subfolder (PostgreSQL's `PGDATA=/var/lib/postgresql/data`).
4. When the upstream image runs as a user other than root, the image starts as root and drops to that user after the
   ownership is right. It never relies on the ownership the image gives the folder.
5. A nested volume is a disk of its own and follows the same rules.
6. A fix for an app that already has installs changes only what a working install never has, and proves it with
   `--upgrade-from`.
7. `./start.sh` starts every new app on new disks, and the push scripts refuse to push an app to UAT or prod until
   `tests/new-disk-start.test.sh <app>` has passed on its current source.

`CLAUDE.md` gets the short version of the rules, the two test commands, the start script's default and flag, and the
push gate. `DEVELOPER_GUIDE.md` documents the new flags.

## Part 6: the push gate (decision 5)

- A passing app run records its pass in `~/.cache/magneto/new-disk-passes/<app>` (my call: a per-user cache, never in
  the repository, so a record belongs to the machine that ran the test). The record holds a hash of the app's source,
  the time, the settle period of the run and the images tested. A pass counts for a push only from a full run (a
  settle of 90 s or more).
- The test builds with `REGISTRY` unset, so its tags are the ones the compose files run, and records a pass only when
  every image of the build's own registry (`r.clv.zone/e2eorg/...`) that it judged is the one the build just made.
- The source hash covers every file under `apps/<app>/` that git tracks, or would track (tracked files and untracked
  files that aren't ignored, so uncommitted changes count), by path and content. My call.
- `build-uat.sh` and `build-prod.sh` turn the gate on (my call: they set a variable that `build.sh` reads, so `build.sh`
  resolves the targets as it always does). With `--push`, `build.sh` then checks every app it is about to push before
  building anything. An app without a matching record stops the whole push, with the command to run.
- `--skip-new-disk-check` pushes anyway, and says so in the output.
- Only an app's own run records a pass for that app. A bundle run records nothing, and pushing an app needs no bundle
  pass.

## Left to the builder

- Names of internal functions, the override file's location, the record's format and the log wording.
- The exact list of patterns that count as permission errors in the output.
- How the test finds which images a bundle uses.
- Whether the audit runs the targets one after another or several at once.
