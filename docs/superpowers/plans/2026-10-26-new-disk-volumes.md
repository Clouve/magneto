# New-disk volumes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every local start and every pre-push check gives magneto's containers the volumes a cluster gives them (an empty disk: root's top folder, `lost+found`, none of the image's files), and no app reaches UAT or prod without passing that check on its current source.

**Architecture:** One sourced bash helper (`lib/new-disk-volumes.sh`) defines a new disk and makes missing Compose volumes in that shape; `start.sh`, `test.sh` and the new runner all call it. The runner (`tests/new-disk-start.test.sh` + `tests/lib/new_disk_start.py`) starts an app or bundle on new disks and judges each container with the platform's own probe and deadlines. A second helper (`lib/new-disk-passes.sh`) records passes by source hash, and `build.sh` refuses UAT and prod pushes without one. Then the audit runs the check on every app and bundle and each failure gets a fix in its image.

**Tech Stack:** bash (3.2-compatible for `lib/` and `start.sh`/`build.sh`), Docker + Docker Compose v2 or later (5.6.1 here), python3 (stdlib for `lib/`; PyYAML allowed in tests), `mirror.gcr.io/library/alpine:3.20`.

**Spec:** `docs/superpowers/specs/2026-10-26-new-disk-volumes-design.md` (approved by AJ 2026-10-26, with decisions 1-7).

## Global Constraints

- magneto only: no change to Tropo, thermo or strato.
- No image pushes to dev, UAT or prod, no listing changes.
- Never stage-and-commit: `git add` only; AJ commits (his standing rule). Every "Stage" step below is `git add` of the task's files and nothing else.
- A volume that already exists is never changed or deleted by the helper.
- No silent fallback: when a new volume can't be shaped, the start stops with an error.
- New-disk shape: top folder `0:0` mode `755`, holding `lost+found` (`0:0`, mode `700`), made before Compose creates the container, with labels `com.docker.compose.project`, `com.docker.compose.volume`, `com.docker.compose.version`; shaper image `mirror.gcr.io/library/alpine:3.20` (override `ND_SHAPER_IMAGE`).
- `lib/*.sh`, `start.sh` and `build.sh` changes run on bash 3.2: no `mapfile`, associative arrays, `${x,,}`, `[[ -v ]]`, `local -n`, GNU-only tool flags.
- `lib/` reads JSON with python3's standard library only. Tests may need PyYAML (as `tests/nextcloud-manifest.test.sh` does).
- Probes as Kubernetes runs them: HTTP passes on a first response of 200-399, redirects not followed; TCP passes on connect; Command is `docker exec <c> /bin/sh -c "<path>"`, exit 0. Probe off or missing: the container must be running and never restart.
- Deadline per container: `initialDelay + failureThreshold × interval` seconds from its own start, capped at 600. Probe every 5 s. A restart or exit before the first pass fails. Settle period 90 s after all pass.
- Container limits in the runner: `cpus = cpuBase`, `mem_limit = memoryBase` GB, from `x-clouve-metadata`.
- `magneto-agent` is not started by the runner unless `--with-agent`.
- Pass records: `${MAGNETO_NEW_DISK_PASS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/magneto/new-disk-passes}/<app>`; source hash over the files `git ls-files -co --exclude-standard` lists under `apps/<app>/`, path and content. Only an app run that built the app records; bundle runs, `--no-build` runs and `--upgrade-from` runs record nothing.
- Push gate: on only when `NEW_DISK_GATE=1` (exported by `build-uat.sh` and `build-prod.sh`) and `--push`; checks every app before any build; `--skip-new-disk-check` overrides and prints that it did.
- Fix guard (decision 6): act when the top folder is root's; change only owner and mode or add missing files; a code comment says why the app never leaves that folder root's; each fix passes `--upgrade-from <last local dated tag>`.
- New prose in README.md, CLAUDE.md and DEVELOPER_GUIDE.md goes through the humanizer (AJ's rule); no em or en dashes.

## Review Focus

1. Volumes that existed before this change (made by Compose, with data, possibly with Docker's copy in them): untouched, and no Compose warning on the next start. Pinned in Task 1 ("an existing volume keeps what it has") and Task 2 ("start.sh again: existing volume untouched").
2. A volume with an explicit `name:`, or `external: true`: the resolved name is used, and an external volume is never made or changed. Pinned in Task 1.
3. macOS: bash 3.2 and no GNU tools. Pinned in Task 1 and Task 4: `bash -n` and a functional call of each `lib/` file under `mirror.gcr.io/library/bash:3.2`, and `bash -n start.sh build.sh` there too.
4. The shaper can't run (image pull blocked, registry rate limit): no half-made volume, a message that names `--docker-volumes`, and nothing started. Pinned in Task 1 (helper) and Task 2 (start.sh).
5. A probe that can never pass (wrong port, missing command): the runner fails at that container's deadline with the probe's last result and never runs past the 600 s cap. Pinned in Task 3 (self-check 14).

---

### Task 1: The new-disk volume helper

**Files:**
- Create: `lib/new-disk-volumes.sh`
- Create: `tests/new-disk-volumes.test.sh` (section 1 now; sections 2-4 come in Tasks 2-4)

**Interfaces:**
- Produces (all in `lib/new-disk-volumes.sh`, sourced, defines functions only, changes no shell options):
  - `nd_compose ARGS...`: runs `docker compose ARGS...` when `docker compose version` works, else `docker-compose ARGS...`.
  - `nd_compose_volumes [COMPOSE_ARGS...]`: prints one line per named volume that a service mounts (mount type `volume`, top-level entry not `external`), each once: `<full name>\t<project>\t<key>`, from `nd_compose COMPOSE_ARGS config --format json` read by python3.
  - `nd_make_new_disk FULL_NAME PROJECT KEY`: `docker volume create` with the three labels (version from `nd_compose version --short`), then the shaper runs `chown 0:0 /v && chmod 755 /v && mkdir -m 700 /v/lost+found`. On any failure it removes that volume and returns 1.
  - `prepare_new_disk_volumes [COMPOSE_ARGS...]`: for each volume from `nd_compose_volumes` that `docker volume inspect` doesn't find, `nd_make_new_disk`, then prints `  New volume <full name>: shaped like a new cluster disk (root's top folder, lost+found, none of the image's files)`. Returns 1 at the first failure, after printing `✗ <what failed>: <the command's error>`. Exit 0 and no output when every volume exists.

- [ ] **Step 1: Write the failing test, section 1.** The file follows `tests/build-prune.test.sh`'s style (pass/fail/assert_eq helpers, `FAILED`, colored summary, exit 1 on failure, exit 2 without Docker). Fixture: a temp dir; an image `nd-test-image:latest` built from `mirror.gcr.io/library/alpine:3.20` with `/data/seed.txt` and `/data/up`, `chown -R 1000:1000 /data`, `chmod 750 /data`; a compose file (project `ndt1`) with service `app` (`sleep infinity`, mounts `data:/data` and `up:/data/up`), service `other` (mounts `data:/data`), volume `named` with `name: nd-test-explicit` mounted by `other` at `/n`, and volume `ext` with `external: true` mounted at `/e` (the test creates `ext` first and writes `/marker` into it). Every resource is named `nd-test-*` or `ndt1_*` and removed on exit. Checks:
  - `prepare_new_disk_volumes -p ndt1 -f <file>` exits 0 and prints exactly three "New volume" lines: `ndt1_data`, `ndt1_up`, `nd-test-explicit` (shared `data` once; `ext` absent).
  - after `up -d`: `stat -c '%u:%g %a' /data` in `app` is `0:0 755`; `/data` lists `lost+found` and `up` and no `seed.txt`; `/data/lost+found` is `0:0 700`; `/data/up` is `0:0 755` with `lost+found`.
  - `docker volume inspect ndt1_data` labels: project `ndt1`, volume `data`, a version.
  - `up -d` output has no "already exists".
  - `/e/marker` is still there.
  - write `/data/kept.txt`, `down` (no `-v`), run `prepare_new_disk_volumes` again: no output, exit 0, and after `up -d` `/data/kept.txt` is there.
  - `down -v` leaves no `ndt1_*` volume.
  - `ND_SHAPER_IMAGE=nd-test-missing:none prepare_new_disk_volumes -p ndt2 -f <file>`: exit 1, output has `✗`, and no `ndt2_*` volume exists afterwards.
  - under `mirror.gcr.io/library/bash:3.2` (`bash -n` only catches syntax; `${x,,}` or `mapfile` fail when they run): `bash -n /lib/new-disk-volumes.sh` exits 0; the file has none of `mapfile`, `readarray`, `declare -A`, `local -A`, `local -n`, `declare -n`, `${name,,}`, `${name^^}`, `[[ -v`, `|&`, `&>>`; and with stub `docker` and `python3` scripts on PATH (the python3 stub prints two canned volume lines, the docker stub records its calls and reports no volume as existing), `prepare_new_disk_volumes` exits 0, prints both "New volume" lines and calls `volume create` twice.

- [ ] **Step 2: Run it to see it fail.** `bash tests/new-disk-volumes.test.sh` → section 1 FAILs (the lib file doesn't exist).

- [ ] **Step 3: Implement `lib/new-disk-volumes.sh`** with the four functions above. The python3 snippet gets the JSON on stdin and prints the tab-separated lines; volume full names come from the JSON's `volumes.<key>.name`.

- [ ] **Step 4: Run it to see it pass.** `bash tests/new-disk-volumes.test.sh` → all section 1 checks PASS. `shellcheck -x lib/new-disk-volumes.sh tests/new-disk-volumes.test.sh` → clean.

- [ ] **Step 5: Stage** `lib/new-disk-volumes.sh tests/new-disk-volumes.test.sh`.

### Task 2: start.sh and test.sh start on new disks

**Files:**
- Modify: `start.sh` (usage header lines 5-18; option loop lines 104-116; insert before `docker-compose up -d` at line 171)
- Modify: `test.sh` (usage header; argument handling; `docker_compose_up()` at line 233)
- Modify: `tests/new-disk-volumes.test.sh` (section 2)

**Interfaces:**
- Consumes: `prepare_new_disk_volumes` (Task 1).
- Produces: `./start.sh [target] [--cleanup] [--docker-volumes]`; `./test.sh <app-path> [domain1] [domain2] [port] [--docker-volumes]` (the flag may appear anywhere; the other arguments keep their positions).
- start.sh, without `--docker-volumes`: sources `"$SCRIPT_DIR/lib/new-disk-volumes.sh"`; if `python3 -c 'import json'` fails, prints `✗ start.sh needs python3 to make new volumes like new cluster disks (or start with --docker-volumes)` and exits 1; runs `prepare_new_disk_volumes` in `$WORK_DIR` (after the `--cleanup` block); on failure prints `✗ Could not make the new volumes like new cluster disks, so nothing was started. --docker-volumes starts on Docker's copies of the image instead, which a cluster never does.` and exits 1. With `--docker-volumes`: prints `⚠ --docker-volumes: new volumes get Docker's copy of the image's files, owner and mode. A cluster never does this.` and skips the helper.
- test.sh: the same two branches inside `docker_compose_up()`, same messages with `test.sh` in place of `start.sh`.

- [ ] **Step 1: Write the failing test, section 2.** A temp magneto tree with copies of `start.sh`, `stop.sh` and `lib/`, and `apps/ndapp/docker-compose.yml` (one service on `nd-test-image`, mounting `ndapp_data`-to-be at `/data`). Checks:
  - `./start.sh ndapp`: exit 0, prints the "New volume" line, `/data` is `0:0 755` with `lost+found`, no `seed.txt`.
  - `./start.sh ndapp` again: exit 0, no "New volume" line, a file written before is still there.
  - `./stop.sh ndapp --cleanup` then `./start.sh ndapp --docker-volumes`: prints the ⚠ line; `/data` is `1000:1000 750` and holds `seed.txt`.
  - `./start.sh ndapp --cleanup`: the volume is a new disk again.
  - with a `python3` stub that exits 127 first on PATH: `./start.sh ndapp` (after `stop.sh --cleanup`) exits 1, prints the python3 message, and no `ndapp` container exists.
  - with `ND_SHAPER_IMAGE=nd-test-missing:none`: exit 1, prints the "Could not make" message, no container, no half-made volume.
  - `bash -n test.sh` exits 0, and `docker_compose_up` in `test.sh` contains a call of `prepare_new_disk_volumes` and the `--docker-volumes` branch (a grep contract; `test.sh` runs against real apps in Task 6).
  - under `mirror.gcr.io/library/bash:3.2`: `bash -n start.sh` exits 0.

- [ ] **Step 2: Run it to see it fail.** `bash tests/new-disk-volumes.test.sh` → section 2 FAILs.

- [ ] **Step 3: Implement** the start.sh and test.sh changes above. test.sh removes `--docker-volumes` from its arguments before it reads the positional ones.

- [ ] **Step 4: Run it to see it pass.** `bash tests/new-disk-volumes.test.sh` → sections 1-2 PASS; `shellcheck start.sh test.sh` reports nothing new compared with `git show HEAD:start.sh | shellcheck -` (and the same for test.sh).

- [ ] **Step 5: Stage** `start.sh test.sh tests/new-disk-volumes.test.sh`.

### Task 3: The runner

**Files:**
- Create: `tests/new-disk-start.test.sh` (entry point)
- Create: `tests/lib/new_disk_start.py` (one target per call)
- Modify: `tests/new-disk-volumes.test.sh` (section 3: the runner's self-checks)

**Interfaces:**
- Consumes: `prepare_new_disk_volumes` (Task 1), called from Python as `bash -c '. "$1"/lib/new-disk-volumes.sh && shift && prepare_new_disk_volumes "$@"' _ <repo> <compose args>`.
- Produces:
  - `bash tests/new-disk-start.test.sh [--no-build] [--with-agent] [--upgrade-from TAG] [--settle SECONDS] (TARGET... | --all)`. A TARGET is an app or bundle name, or a path to a folder with `docker-compose.yml` (and normally `clv-docker-compose.yml`). `--all` = every `apps/*` and `bundles/*` with a `docker-compose.yml`. Without `--no-build`, an app target is built first with `${NEW_DISK_BUILD_CMD:-$REPO/build.sh} <target>`; bundles and path targets without an `image/` folder are never built. Prints each image's creation time. Needs Docker, python3 and PyYAML (exit 2 otherwise). Exit 0 when every target passes, 1 when one fails, 2 on a setup error (no Docker, missing image, unknown target).
  - `python3 -I tests/lib/new_disk_start.py --dir DIR --project NAME --repo REPO [--with-agent] [--upgrade-from TAG] [--settle S]`, with `NEW_DISK_PROBE_EVERY` (default 5) and the deadline cap 600. Exit codes as above for one target. It writes its override (ports `!reset []`, `container_name: !reset null`, `cpus`, `mem_limit`, and with `--upgrade-from` each locally built image's `:TAG`) to a temp file, runs `up -d` for every service except `magneto-agent` (unless `--with-agent`), probes, settles, reports, and always runs `down -v` and removes the override.
  - Output lines the tests read: `  PASS <service>: healthy after <n> s (deadline <d> s, <probe>)`, `  FAIL <service>: <reason>` where the reason is one of `exited with code <c> after <n> s`, `restarted <k> time(s)`, `not healthy within <d> s (last probe: <result>)`, `failed its probe during the settle period (<result>)`, `top folder of <volume> changed from <a> to <b>`; for each FAIL up to 30 `    log: ` lines and any `    permission: ` lines (log lines matching `Permission denied|Operation not permitted|cannot create|Read-only file system|EACCES|EPERM`); last line `PASS <target>` or `FAIL <target>`.
  - `--upgrade-from TAG`: phase 1 runs the images at `TAG` (only images that have that tag locally; others unchanged) and must pass; the runner records each volume's top folder as `%u:%g %a` (read through `$ND_SHAPER_IMAGE` with the volume mounted read-only), stops the containers without removing volumes, runs phase 2 with the current images, and fails on any changed top folder.

- [ ] **Step 1: Write the failing test, section 3.** Fake apps in temp folders, each a `docker-compose.yml` plus a `clv-docker-compose.yml` with `x-clouve-healthcheck` and `x-clouve-metadata`, all on images built from alpine by the test; runner calls use `--no-build --settle 3` and `NEW_DISK_PROBE_EVERY=1`. Checks:
  1. good app (root writes `/data/ok`, serves HTTP 200 on 8080, HTTP probe): `PASS <target>`, exit 0.
  2. app whose image ships `/data/seed.txt` and exits 3 without it: `FAIL app: exited with code 3`.
  3. app with `USER 1000` that exits 4 when `touch /data/x` fails: FAIL, and a `permission:` line with `Permission denied`.
  4. app whose probe passes only after 20 s, with `initialDelay 1, failureThreshold 2, interval 3`: `FAIL app: not healthy within 7 s`.
  5. app that passes, then exits after 4 s with `restart: unless-stopped`: `FAIL app: restarted` (or `exited with code`) during the settle.
  6. HTTP 302 with a `Location` elsewhere: PASS. HTTP 500: FAIL with `last probe: HTTP 500`.
  7. Command probe `exit 1`: FAIL. `exit 0`: PASS.
  8. probe `enabled: false`: PASS while running; the same app exiting after 2 s: FAIL.
  9. `ports: ["18093:8080"]` and `container_name: ndtest_fixed`, while another container named `ndtest_fixed` runs and holds port 18093: PASS.
  10. a `magneto-agent` service in the compose file: no container for it; with `--with-agent` there is one.
  11. the app container's `HostConfig.NanoCpus` is `cpuBase × 1e9` and `HostConfig.Memory` is `memoryBase × 1073741824`.
  12. after each run: no container, volume or network of that run's project, and no override file left.
  13. `--upgrade-from old`: image `:old` makes `/data` `1000:1000`; `:latest` leaves it: PASS. A `:latest` that runs `chown 0:0 /data`: `FAIL app: top folder of ... changed from 1000:1000 755 to 0:0 755`.
  14. a TCP probe on a port nothing listens on, deadline 7 s: FAIL with `last probe:`, and the call returns in under 60 s.

- [ ] **Step 2: Run it to see it fail.** `bash tests/new-disk-volumes.test.sh` → section 3 FAILs (no runner yet).

- [ ] **Step 3: Implement `tests/new-disk-start.test.sh` and `tests/lib/new_disk_start.py`.** HTTP and TCP probes run in a throwaway `$ND_SHAPER_IMAGE` container on the target container's first network (from `docker inspect`): `wget -S -O /dev/null -T <timeout> http://<service>:<port><path>` and the first `HTTP/` line, or `nc -z -w <timeout> <service> <port>`. Restart counts and exit codes come from `docker inspect`. The deadline clock starts at each container's `State.StartedAt`.

- [ ] **Step 4: Run it to see it pass.** `bash tests/new-disk-volumes.test.sh` → sections 1-3 PASS. Then the real check on one app: `bash tests/new-disk-start.test.sh nextcloud` → `PASS nextcloud`.

- [ ] **Step 5: Stage** `tests/new-disk-start.test.sh tests/lib/new_disk_start.py tests/new-disk-volumes.test.sh`.

### Task 4: Pass records and the push gate

**Files:**
- Create: `lib/new-disk-passes.sh`
- Modify: `tests/new-disk-start.test.sh` (record a pass)
- Modify: `build.sh` (usage text; option loop at lines 389-433; the `--all` branch before "Discover all targets" at line 486; the single-target path before line 605; the recursive `BUILD_CMD` at line 511)
- Modify: `build-uat.sh`, `build-prod.sh` (`export NEW_DISK_GATE=1`)
- Modify: `tests/new-disk-volumes.test.sh` (section 4)

**Interfaces:**
- Produces (in `lib/new-disk-passes.sh`, bash 3.2, python3 stdlib for hashing):
  - `nd_pass_dir`: prints the record folder (see Global Constraints).
  - `nd_source_hash APP_DIR`: prints the sha256 of every listed file's relative path, a NUL byte and its content, in byte order of path; returns 1 with a message when APP_DIR isn't in a git work tree.
  - `nd_record_pass APP HASH [IMAGE_REF...]`: writes `<dir>/<APP>` with `source=<HASH>`, `time=<UTC, ISO 8601>` and one `image=<ref> <image id>` line per ref.
  - `nd_has_pass APP APP_DIR`: exit 0 when the record's `source` equals `nd_source_hash APP_DIR`, else 1.
- The runner: for an app target it built, it computes the hash before the build and calls `nd_record_pass` after the target passes; it prints `  Recorded a new-disk pass for <app> (source <first 12 hex>)`.
- build.sh: `--skip-new-disk-check`. When `NEW_DISK_GATE=1` and `--push`, it sources `lib/new-disk-passes.sh` there and only there (a copy of build.sh without `lib/`, as in `tests/build-prune.test.sh`, keeps working without the gate), and before any docker call checks every app target (all of them under `--all`). A failure prints, per app, `✗ <app>: no new-disk pass for its current source. Run: bash tests/new-disk-start.test.sh <app>`, then `(or push anyway with --skip-new-disk-check)`, and exits 1. With `--skip-new-disk-check` it prints `⚠ Pushing without the new-disk check (--skip-new-disk-check)` and continues; under `--all` it passes the flag on to each recursive call.

- [ ] **Step 1: Write the failing test, section 4.** A temp git repo (`git init`, a commit) with copies of `build.sh`, `build-uat.sh`, `build-prod.sh`, `build-dev.sh`, `build-e2e.sh` and `lib/`, fake apps `apps/alpha` and `apps/beta` with `image/Dockerfile` and `image/build.config`, `docker` stubbed as in `tests/build-prune.test.sh`, and `MAGNETO_NEW_DISK_PASS_DIR` in the temp dir. Checks:
  - `nd_source_hash apps/alpha`: same twice; changes after editing a tracked file; changes after adding an untracked file; unchanged after changing a file that `.gitignore` lists; unchanged after a change in `apps/beta`.
  - `nd_has_pass alpha apps/alpha`: 1 without a record; 0 after `nd_record_pass alpha "$(nd_source_hash apps/alpha)"`; 1 after editing alpha.
  - `NEW_DISK_GATE=1 ./build.sh alpha --push` without a pass: exit 1, output names `bash tests/new-disk-start.test.sh alpha` and `--skip-new-disk-check`, and the stub recorded no docker call.
  - with a pass for alpha's current source: the stub recorded a `buildx` call.
  - `--skip-new-disk-check`: proceeds and prints the ⚠ line.
  - `NEW_DISK_GATE=1 ./build.sh --all --push` with a pass for alpha only: exit 1 before any docker call, and the output names beta.
  - no gate without `NEW_DISK_GATE` (plain `build.sh`, `build-dev.sh`, `build-e2e.sh`) and none without `--push`.
  - `build-uat.sh` and `build-prod.sh` run their `build.sh` with `NEW_DISK_GATE=1` (a stub `build.sh` in the copy prints it).
  - the runner with `NEW_DISK_BUILD_CMD` set to a stub and a fake app inside the temp repo: a PASS writes a record whose `source` equals `nd_source_hash` of that app; a `--no-build` PASS writes none; a bundle (no `image/`) PASS writes none.
  - under `mirror.gcr.io/library/bash:3.2`: `bash -n /lib/new-disk-passes.sh` and `bash -n build.sh` exit 0; neither file's gate code uses the bash-4 constructs listed in Task 1; and with stub `git` and `python3` scripts on PATH, `nd_record_pass` then `nd_has_pass` exit 0 and a changed stub hash makes `nd_has_pass` exit 1.
  - `bash tests/build-prune.test.sh` still passes.

- [ ] **Step 2: Run it to see it fail.** `bash tests/new-disk-volumes.test.sh` → section 4 FAILs.

- [ ] **Step 3: Implement** `lib/new-disk-passes.sh`, the runner's recording, the build.sh gate and the two wrappers.

- [ ] **Step 4: Run it to see it pass.** `bash tests/new-disk-volumes.test.sh` → sections 1-4 PASS; `bash tests/build-prune.test.sh` PASS; shellcheck reports nothing new on `build.sh`, `build-uat.sh`, `build-prod.sh`, `lib/new-disk-passes.sh`.

- [ ] **Step 5: Stage** `lib/new-disk-passes.sh tests/new-disk-start.test.sh build.sh build-uat.sh build-prod.sh tests/new-disk-volumes.test.sh`.

### Task 5: The rules and the docs

**Files:**
- Modify: `README.md` ("## Volume Management": new subsection "### Volumes on a cluster" with the spec's model and rules 1-7, and Best Practices item 4 pointing to it; "## Testing Your Application": new subsection "### Testing on new cluster disks" with both test commands and `--upgrade-from`; the Table of Contents if it lists subsections)
- Modify: `CLAUDE.md` (Start / Stop: the default and `--docker-volumes`; testing: both commands; Build Images: the push gate and `--skip-new-disk-check`; a short "Volumes on a cluster" rule list that points to the README section)
- Modify: `DEVELOPER_GUIDE.md` (start.sh and test.sh flags; the gate in the build section)

- [ ] **Step 1: Write the text.** Rules exactly as the spec's Part 5 states them; examples named from the repo (Nextcloud `nc_claim_new_volume`, WordPress's official entrypoint, Moodle's chown, the Magneto Agent's `init.sh` seeding).

- [ ] **Step 2: Humanizer pass** (embedded mode) on every new paragraph, then `grep -nP '[\x{2013}\x{2014}]'` on the three files' added lines: none.

- [ ] **Step 3: Verify.** `bash tests/nextcloud-manifest.test.sh` PASS (it reads README headings); every README Table of Contents link resolves to a heading.

- [ ] **Step 4: Stage** `README.md CLAUDE.md DEVELOPER_GUIDE.md`.

### Task 6: The audit

**Files:**
- Modify: this plan (append the results table and one Task 7.N per failing app)

- [ ] **Step 1: Run the check on every target.** `bash tests/new-disk-start.test.sh --all 2>&1 | tee <scratchpad>/audit.log`. Expected: an exit status and one PASS/FAIL block per target. Targets may also run one per process at the same time (each run has its own project name).

- [ ] **Step 2: Run `./test.sh apps/wordpress`** once on new disks (the real `test.sh` path from Task 2), then `./stop.sh wordpress --cleanup`.

- [ ] **Step 3: Write the table** (target, container, PASS/FAIL, time against deadline, reason) into this plan under "Audit results", and add a Task 7.N for each FAIL in the shape of the template below. A failure whose fix needs more than an image change stops for AJ instead.

### Task 7.N template: fix `<app>` (one per failing app)

**Files:** the app's `image/` files; its own `tests/<app>-*.test.sh` when it has one.

- [ ] **Step 1: The failing check.** Copy the runner's FAIL lines for the app into this task. When the app has its own test file, add a check there that fails for the same cause, and see it fail.
- [ ] **Step 2: Fix it in the image** along the rules: act when the volume's top folder is root's, change only owner and mode or add missing files, keep shipped files outside volume paths and copy them in when missing, ignore `lost+found`. The code comment says why the app never leaves that folder root's.
- [ ] **Step 3: Verify.** `bash tests/new-disk-start.test.sh <app>` → `PASS <app>`; the app's own tests pass; `bash tests/new-disk-start.test.sh <app> --upgrade-from <tag>` → PASS, where `<tag>` is the newest dated tag of the app's image before today (`docker images r.clv.zone/e2eorg/<app>`); bundles containing the app → PASS.
- [ ] **Step 4: Stage** the app's changed files.

### Task 8: Final verification

- [ ] **Step 1:** `bash tests/new-disk-volumes.test.sh` and `bash tests/new-disk-start.test.sh --all` → all PASS; every other `tests/*.test.sh` → PASS.
- [ ] **Step 2:** `./start.sh nextcloud` (the whole stack, the Magneto Agent included) on new disks → every container running after 3 minutes with no restarts; then `./stop.sh nextcloud --cleanup`.
- [ ] **Step 3:** One fresh reviewer (most capable model) reads the spec, this plan and `git diff --cached`, and reports bugs and gaps; fix what it confirms, with tests.
- [ ] **Step 4:** Everything staged, nothing committed; report to AJ with the suggested commit message.

## Audit results

Run 2026-10-26 on develop after 85ff70b (n8n removed, so 9 apps and 2 bundles), each app built from the current source
first, three targets at a time, every volume a new disk, at the smallest plan's CPU and memory. Every target passed, so
Task 7 adds no fix tasks.

| Target | Container | Result | Healthy after (deadline) | Probe |
|---|---|---|---|---|
| ai-studio | ai-studio | PASS | 20 s (310 s) | TCP :22 |
| gibbon | gibbon | PASS | 20 s (510 s) | HTTP :80/index.php |
| gibbon | gibbon-mysql | PASS | running (600 s) | off |
| limesurvey | limesurvey | PASS | 15 s (105 s) | HTTP :8080/ |
| limesurvey | limesurvey-mariadb | PASS | running (600 s) | off |
| moodle | moodle | PASS | 56 s (510 s) | HTTP :80/ |
| moodle | moodle-mysql | PASS | running (600 s) | off |
| nextcloud | nextcloud | PASS | 15 s (510 s) | command: healthcheck.sh |
| nextcloud | nextcloud-mariadb | PASS | running (600 s) | off |
| odoo | odoo | PASS | 15 s (360 s) | HTTP :8069/web/health |
| odoo | odoo-postgres | PASS | running (600 s) | off |
| owncloud | owncloud | PASS | 10 s (105 s) | command: /usr/bin/healthcheck |
| owncloud | owncloud-mariadb, owncloud-redis | PASS | running (600 s) | off |
| suitecrm | suitecrm | PASS | 20 s (105 s) | HTTP :80/ |
| suitecrm | suitecrm-mariadb | PASS | running (600 s) | off |
| wordpress | wordpress | PASS | 0 s (60 s) | HTTP :80/ |
| wordpress | wordpress-mariadb | PASS | running (600 s) | off |
| crm-kit | limesurvey, suitecrm | PASS | 5 s, 11 s (105 s) | HTTP |
| crm-kit | limesurvey-mariadb, suitecrm-mariadb | PASS | 11 s (60 s) | command: healthcheck.sh |
| education-kit | gibbon, moodle | PASS | 16 s, 47 s (510 s) | HTTP |
| education-kit | gibbon-mysql, moodle-mysql | PASS | running (600 s) | off |

Notes from the settle period, both inside what the platform tolerates: Nextcloud failed its probe for 5 s (the gap
between its install and Apache's start; it may for 450 s), WordPress refused connections for 5 s after its first pass
(it may for 30 s). `./test.sh apps/wordpress` also passed on new disks.

A look at the files alone had flagged LimeSurvey (22,703 files of code at its volume path) and ownCloud: both already
copy their files in from elsewhere in the image (LimeSurvey from `/clouve/limesurvey/package`), so only a real start
tells.
