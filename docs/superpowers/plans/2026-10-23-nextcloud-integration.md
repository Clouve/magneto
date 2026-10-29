# Nextcloud integration, rig test and close-out Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the magneto app and the magneto-skills plugin work together, first on a local `./start.sh nextcloud` and then as a real trial on the kind rig. Then review both change sets, clean up everything temporary, and report to AJ.

**Architecture:** This plan adds no new product code. The skill isn't on GitHub's `main` yet, so in both places it is loaded into the agent container by hand, the way the agent's plugin stager would. Every script then runs against a real Nextcloud. Fixes found here go back into the files of Plans 1 and 2, with their tests re-run and the files re-staged.

**Tech Stack:** Docker Compose, the kind rig (`kind-cluster-1`, app.clouve.dev through the tunnel), the vids rig helpers in `/home/aj/Projects/vids/recording/rig/pub/`, curl, kubectl.

**Spec:** `/home/aj/Projects/magneto/docs/superpowers/specs/2026-10-23-nextcloud-design.md` (Verification steps 7 to 9; decision 9).

**Depends on:** `docs/superpowers/plans/2026-10-23-nextcloud-magneto.md` and `docs/superpowers/plans/2026-10-23-nextcloud-skill.md`, both finished, with their tests passing.

## Global Constraints

- **Staging.** Both repos stay on `develop`. Stage with `git add <exact files>`. Never commit, push a branch, switch branches or unstage.
- **What leaves this machine.** The only pushes are the two images to the rig's Harbor (`r.clv.zone/e2eorg`). Nothing is published to dev, UAT or prod. The rig listing stays private and is purged at the end, and the trial is deleted. Ask AJ before making anything public, even briefly.
- **Secrets.**
  - Never print a secret: a `clv-secret` value, `~/.docker/config.json`, a kubeconfig, a Harbor robot secret, a Kubernetes Secret's data, the dashboard password, or a temporary password from a `~/nextcloud-passwords/` file.
  - When a check needs a password, read it into a variable or a mode-600 file and pass it on stdin or in curl's `-K -` config.
  - Never `set -x` around the skill's scripts.
  - Never plain `docker inspect` a `devenv-*` container (it prints secrets).
- **Rig rules** (from memory):
  - If app.clouve.dev times out while `https://clouve.dev/health` answers 200, restart the rig's rathole client without asking.
  - If the arm64 half of a push fails with "Security violation", re-register QEMU (`docker run --privileged --rm tonistiigi/binfmt --install all`).
  - A `429` on a public base image means using `mirror.gcr.io` for that line (Plan 1's rule).
  - If thermo stalls for minutes, check the rig's Ethernet link before anything else.
  - Never use Xvfb displays `:98` or `:99`.
- **Rig helpers.** Read `/home/aj/Projects/vids/recording/rig/README.md` and the `pub/` sources before using them. Drive them from a scratchpad script that imports them, and never edit files in the vids repo.
- **Paid capacity.** Never change a deployment's CPU, memory or volume sizes, including the test trial's.
- **Prose.** Any prose written here (fixes, the final report) gets the humanizer pass.

## Review Focus

1. **The agent's real environment.** The variable and secret names the skill assumes (`NEXTCLOUD_HOST`, `NEXTCLOUD_MARIADB_HOST`, `NEXTCLOUD_DB_*`, `NEXTCLOUD_URL`, `NEXTCLOUD_ADMIN_*`, `CLOUVE_OPS_PASSWORD`) exist with those spellings on a real agent, locally and on Kubernetes. Pinned in Task 1 Step 3 and Task 2 Step 6.
2. **Restore keeps the host's own settings.** A restore of a backup made under an older URL keeps the current `overwrite.cli.url`, `dbpassword` and the merged `trusted_domains`. That is the merge the hermetic tests could only fake. Pinned in Task 1 Step 6.
3. **The 50 MB ingress cap.** A single upload request over 50 MB gets 413 on the rig, and a 40 MiB-chunked upload of the same file succeeds. Pinned in Task 2 Step 5.
4. **`sudo --preserve-env=NC_PASS` on the real image.** It passes the password through to `occ`, so `temp-password.sh` and the admin reset work, and the person can sign in with the result. Pinned in Task 1 Step 4 and Task 2 Step 6.
5. **Probes on a real pod.** They keep a pod Ready through maintenance mode and a first install. Pinned in Task 2 Steps 3 and 6.

---

### Task 1: Local agent integration

**Files:** none new. Fixes go to the files of Plans 1 and 2.

**Interfaces:**
- Consumes: magneto's `apps/nextcloud` (Plan 1) and magneto-skills' `plugins/nextcloud` (Plan 2).
- Produces: a record of each check's result in `/tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/e2e/local.md`, for the final report.

- [ ] **Step 1: Start the stack**

```bash
cd /home/aj/Projects/magneto && ./build.sh nextcloud && ./start.sh nextcloud --cleanup
```

Wait until `nextcloud_app` is `healthy` and the agent's logs show the persona fetched (`/clouve/context/nextcloud/CONTEXT.md.tpl` exists in `nextcloud_magneto_agent`).

- [ ] **Step 2: Stage the skill by hand, as the plugin stager does**

```bash
docker exec nextcloud_magneto_agent rm -rf /clouve/skills/nextcloud
docker exec nextcloud_magneto_agent mkdir -p /clouve/skills/nextcloud
docker cp /home/aj/Projects/magneto-skills/plugins/nextcloud nextcloud_magneto_agent:/clouve/skills/nextcloud/plugin
docker exec nextcloud_magneto_agent sh -c 'chmod -R a+rX /clouve/skills/nextcloud && grep -qx nextcloud /clouve/skills/.active || echo nextcloud >> /clouve/skills/.active'
docker exec -w /clouve/skills/nextcloud/plugin nextcloud_magneto_agent bash install.sh
docker exec -u admin nextcloud_magneto_agent bash -lc 'ls -l ~/.claude/skills/nextcloud && grep -c "Skill: nextcloud" ~/.claude/CLAUDE.md'
```

Expected:
- `install.sh` reports that the packages are present, or installs them;
- the symlink points at `/clouve/skills/nextcloud/plugin/skills/nextcloud`;
- the count is `1`.

`admin` is `MAGNETO_AGENT_USERNAME` in the local compose.

- [ ] **Step 3: Check the composed persona and the environment.** As `admin` in the agent:
  - `~/.claude/CLAUDE.md` renders `nextcloud` and `nextcloud-mariadb` as hosts, `nextcloud` as schema and user, and the per-command `SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh` lines with all four `-o` options (`ConnectTimeout=10` included), and no `export SSHPASS`.
  - It has no `{user.`, and none of the compose file's password values. Grep for each value without printing it: `grep -c -F -f <(printf '%s\n' "$value") ~/.claude/CLAUDE.md` is `0`.
  - `compgen -e | grep -i -e nextcloud -e clouve_ops` lists names only, and includes every plain name in Plan 2's Global Constraints.
  - `clv-secret --list | grep -i -e nextcloud -e clouve_ops` includes `NEXTCLOUD_DB_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD` and `CLOUVE_OPS_PASSWORD`.
  - If a name differs, fix it in the skill (all files, through Plan 2's tests) before going on.

- [ ] **Step 4: Run the scripts against the instance.** As `admin`, using the absolute paths. Record each result.
  1. `verify-health.sh` gives `Overall: GREEN`. AMBER is acceptable only for setup checks that need HTTPS or a public host; list them.
  2. `occ.sh group:add 'Sales & Ops'`, then `occ.sh group:list --output=json`, which shows it.
  3. `temp-password.sh --create --display-name 'Mary Ann Lee' --email mary@example.com --group 'Sales & Ops' 'Mary Ann'` prints one `Saved …` line. The file is mode 600 in a mode-700 folder.
  4. Sign in as `Mary Ann` with that file's password over HTTP from the host, reading the file into a variable without printing it. Use the same flow as Plan 1 Task 9 Step 4: GET `/login` for the token, then POST. Expected: 303 to `/apps/dashboard/`.
  5. **Team folder.**
     - `occ.sh groupfolders:create Sales` prints an id.
     - `occ.sh groupfolders:group <id> 'Sales & Ops' read write share`, then `occ.sh groupfolders:quota <id> "1 GB"`.
     - `groupfolders:list --output=json` shows the group and the quota.
     - The capabilities endpoint advertises `files.chunked_upload.max_size` = `41943040` (see Task 2 Step 5).
     - A WebDAV `PROPFIND` as `Mary Ann` lists `Sales` in her files.
  6. `temp-password.sh --remove <file name>` deletes the file.
  7. **Link share.**
     - `share-as-admin.sh --as admin create --path /Documents --type link --expire <today + 7 days> --password` prints a `url` and a password file name.
     - An anonymous `curl` of the URL shows the password page (200).
     - The public WebDAV endpoint with the token and the file's password lists the folder.
     - `list` shows the share, and `delete` removes it.
     - `occ.sh user:auth-tokens:list admin --output=json` has no `clouve-ai-assistant-temporary` entry.
     - (Optional) Also a user share: `share-as-admin.sh --as admin create --path /Documents --type user --with 'Mary Ann' --permissions 1` prints a line with `share_type=user`, `list --path /Documents` shows it, share-files-and-links step 3's per-type `share:list` count includes it, and `delete <id>` removes it.
  8. **Admin reset.** `printf '%s\n' "${NEXTCLOUD_ADMIN_PASSWORD:-$(clv-secret NEXTCLOUD_ADMIN_PASSWORD)}" | …/occ.sh --password-stdin user:resetpassword --password-from-env -- "${NEXTCLOUD_ADMIN_USER}"` exits 0, and the admin login with the compose password still works.
  9. **Brute-force reset** (regain-admin-access step 2). From the host, send 11 sign-ins with a wrong password for a made-up login, with the flow of item 4, then sign in as the admin with the compose password: that answer is 429. Read the address Nextcloud recorded from the `Login failed` lines with step 2's second log filter. `occ.sh security:bruteforce:attempts --output=json -- '<ip>'` shows more than 10 attempts, `occ.sh security:bruteforce:reset -- '<ip>'` exits 0, `attempts` then reads 0, and the admin's sign-in answers 303 again.
  10. **A person's quota** (onboard-users-and-groups step 4). `occ.sh user:setting -- 'Mary Ann' files quota "5 GB"`, then `occ.sh user:info --output=json -- 'Mary Ann' | jq '.quota'` prints `"5 GB"`, and after 5 minutes `.storage.quota` reads 5368709120 (`user:setting` leaves the cached storage figures alone, and they last 5 minutes). A test-only demonstration of the trap the skill forbids: on a scratch account made with `temp-password.sh --create`, set `files quota "5 GiB"` the same way; after 5 minutes `.storage.quota` reads 5, when `storage` is not empty, which is why the skill never writes GiB. Delete the scratch account and remove its password file afterwards.
  11. **Email invite with no mail server, then a delete** (onboard-users-and-groups step 3a, offboard-user step 8). The local stack has no mail server. `occ.sh user:add --generate-password --email=mail-test@example.com --display-name='Mail Test' -- 'mail-test'` prints `Welcome email sent to mail-test@example.com` and exits 0, and step 3a's log read prints a `Sending mail to "..." failed` line for that address. Then `occ.sh user:delete -- 'mail-test'` prints `The specified user was deleted`, `occ.sh user:info -- 'mail-test'` exits 1 with `user not found`, and a second `occ.sh user:delete -- 'mail-test'` prints `User does not exist` and exits 0.
  12. **The database steps after an upgrade** (recover-stuck-upgrade-or-maintenance A8), on the fresh instance. `occ.sh db:add-missing-indices` prints nothing, `occ.sh db:add-missing-columns` and `occ.sh db:add-missing-primary-keys` print `Done.`, all three exit 0, and `occ.sh setupchecks --output=json` names none of "Database missing indices", "Database missing columns" or "Database missing primary keys".
  13. **Read-only repairs and jobs** (fix-files-out-of-sync steps 1 and 6, and troubleshooting.md, "Cron is not running"). Take the storage number of the admin's files from step 1's query, with `home::admin` and `files`. `occ.sh files:repair-tree --dryRun --storage-id=<number>` prints `Found 0 file entries with an invalid path`, and the same command with `--dry-run` fails with `The "--dry-run" option does not exist.` `occ.sh background-job:list --limit=5 --output=json` and `occ.sh background-job:running --output=json` both print JSON that jq reads.

- [ ] **Step 5: Back up, change things, restore.**
  1. Upload `before.txt` to the admin's files over WebDAV.
  2. `run-in-nextcloud.sh --detach backup.sh --with-data`. Poll `--status <job>` until `finished, exit 0`, then `run-in-nextcloud.sh backup.sh --list` shows it with `with_data true`.
  3. Upload `after.txt`, and create the user `after-user` with `temp-password.sh --create`.
  4. `run-in-nextcloud.sh --detach restore.sh --backup <name> --yes-replace-current-data`, then poll until finished.
  5. Expected:
     - `before.txt` is there; `after.txt` and `after-user` are gone;
     - the admin can sign in, and maintenance is off;
     - no `RESTORE-IN-PROGRESS` marker;
     - `verify-health.sh` is GREEN;
     - the Team folder from Step 4 is back.
  6. Remove the leftover `after-user` password file with `--remove`.

- [ ] **Step 6: Run the restore merge drill (Review Focus 2).**
  1. `./stop.sh nextcloud`, then `TEST_DOMAIN=t2.test.clv ./start.sh nextcloud`. The log shows `Nextcloud URL has changed: http://t1.test.clv:8080 -> http://t2.test.clv:8080`.
  2. Re-stage the skill (Step 2), since `/clouve` isn't persistent.
  3. Restore the backup from Step 5, which was made under `t1`.
  4. Expected:
     - `overwrite.cli.url` is `http://t2.test.clv:8080`;
     - `trusted_domains` holds `localhost`, `t1.test.clv` and `t2.test.clv`;
     - `occ status` works, so the `dbpassword` was kept;
     - the login page answers 200 for `Host: t2.test.clv:8080`.

- [ ] **Step 6b: Run the checks the reviews queued.** Plan 2's reviews checked these by reading the code and with fakes only; run each on the local instance and record the result. Destructive drills run only here, never on the rig.
  - **The real channel.** clouve-ops' login shell is bash, and `sudo -n --preserve-env=NC_PASS -u www-data` passes `NC_PASS` (Step 4 items 3, 4 and 8 show it). verify-health.sh's six image-facing items (task-5-report.md).
  - **The mysql client.** The skill's documented `MYSQL_PWD … mysql --no-defaults …` line, read-only, logs in against the 12.3 sibling with the agent's real client, with its TLS defaults; `mysql --help` lists `--ssl-mode`. data-model.md's read-only queries, the two `SHOW` statements included, and fix-files-out-of-sync's index query (`MD5()` over the storage id, the `IN (s.id, MD5(s.id))` match, `-N` printing `NULL` for a folder with no row).
  - **Long runs.** Note the agent's Claude Code version. A long `occ.sh` call (a large `files:scan`) that passes its timeout moves to the background and reports back; then kill the agent-side ssh of another and confirm with `ps` in the container that `php` goes on.
  - **Backups and restores.** The round trip's details: `mariadb-dump` and `mariadb` across 11.8 and 12.3 with `--skip-ssl`, the options-file escaping, a detached job outliving the SSH session. A cut-off restore (stop it after the start) and its recovery from the backup taken before it, as restore-from-backup's recovery section says (backup.sh refuses meanwhile). A real stuck upgrade (cut an `occ upgrade` off) and its recovery as recover-stuck-upgrade-or-maintenance says. The backup copy on the agent (free space first, the `SHA256SUMS` check), R2's marker read, the guarded listings with real root ownership, and `find -execdir` under sudo's `secure_path`. The www-data measuring `find`. Valkey's cache right after a restore: whether cached names and groups outlive it.
  - **Shares and Team folders.** `share:list` with shares from two providers (a user share and an email share): the object form under a filter, rows lost unfiltered, and the per-type counts right. `dav:move-calendar -f` renaming to `personal-1`. `groupfolders:permissions --disable` deleting the managers.
  - **Apps.** The store lookup against the real list, the openssl check of a real release (the agent's OpenSSL 3), `app:update --showonly` refreshing Nextcloud's copy and the cached-list comparison over real SSH, the folder an incompatible install leaves, and the `rm -rf` fallback on a cut copy.
  - **Settings and logs.** Typed `config:app:set` writes read back with their types, the forced 2FA setup at the next sign-in, the email form in a browser (also with `mail_smtpmode` `null`), and the windowed log reads on a real `nextcloud.log` (they assume the default `logdateformat`).
  - **The image's marker trust.** With `data/clouve-backups` made by www-data and a `RESTORE-IN-PROGRESS` of its own in it, a restart logs "It is ignored." and handles maintenance mode as usual.
  - Every result goes into `local.md`. A finding goes back into the owning file of Plan 1 or 2, with its tests re-run and the file re-staged.

- [ ] **Step 7: Stop and clean up.** Run `./stop.sh nextcloud --cleanup`. Re-run every test of Plans 1 and 2 if any fix was made, and re-stage the fixed files.

---

### Task 2: Rig end-to-end test

**Files:** a throwaway driver script in `/tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/e2e/`; results in `…/scratchpad/e2e/rig.md`.

**Interfaces:**
- Consumes: the rig (`kubectl --context kind-cluster-1`), app.clouve.dev, Harbor `r.clv.zone/e2eorg`, and the vids helpers `pub/login.py`, `publish.py`, `visibility.py`, `warm.py`, `purge.py` and `logout.py`, plus the `rig-*.mjs` deployment steps.
- Produces: one private listing and one trial, both removed in Step 8.

- [ ] **Step 1: Check the rig**

```bash
kubectl --context kind-cluster-1 get nodes
curl -s -o /dev/null -w '%{http_code}\n' https://app.clouve.dev/
curl -s https://clouve.dev/health | jq -r .status
ls /proc/sys/fs/binfmt_misc/ | grep -c qemu
```

Expected: nodes `Ready`, `200`, `ok`, and a non-zero count.

- [ ] **Step 2: Push the images**

Run: `cd /home/aj/Projects/magneto && ./build-e2e.sh nextcloud --push`
Expected: both images pushed, and `docker buildx imagetools inspect r.clv.zone/e2eorg/nextcloud:latest` (and the same for `nextcloud-mariadb`) lists `linux/amd64` and `linux/arm64`.

A `401` means the stored login is for another Harbor project. Stop and ask AJ for an `e2eorg` robot login, and never print the stored one.

- [ ] **Step 3: Publish a private listing and start a trial.**
  - **Publish.** From the scratchpad driver:
    - sign in the personas with `pub/login.py`;
    - publish `apps/nextcloud/clv-docker-compose.yml` with `logo.png` as Clouve Inc. (`pub`), the same way `publish.py` does for a catalogue entry;
    - have the reviewer (`fta`) approve it;
    - set it `PRIVATE` with `visibility.py`;
    - run `warm.py` (authenticated) before any other read.
  - **Trial.** Start one from the publisher's org, which can see its own private listing. If the platform only offers trials on public listings, stop and ask AJ.
  - Note the deployment id, namespace (`org-<org>-tkt-<id>`) and URL.
  - **Watch the pods.** Through the first install, `kubectl get pods -w` shows the Nextcloud pod Ready before the install finishes (the init lock), and no restart (`RESTARTS 0`).

- [ ] **Step 4: Check the deployment.**
  - The dashboard shows the login (`<First>_<Last>` cleaned), the email and the password.
  - Sign in over HTTPS at `<URL>/login` with that login, then with the email, each with a fresh cookie jar: 303, then 200 on the dashboard.
  - `<URL>/status.php` has `"installed":true`.
  - `curl -sI <URL>/.well-known/caldav` gives a `301` with `Location: https://<host>/remote.php/dav/`.
  - The response headers include `Strict-Transport-Security`.
  - `occ setupchecks --output=json` (through the agent's `occ.sh` in Step 6): record every non-success item. Only info items are expected (email, 2FA, phone region and similar). Anything else is a bug to fix or to explain in the report.

- [ ] **Step 5: Check the upload cap (Review Focus 3).** As the admin, over HTTPS with an app password the admin makes for this test (a scratch token from `occ.sh user:auth-tokens:add`, deleted after):
  - **Single request.** A `PUT` of a 60 MB random file to `remote.php/dav/files/<uid>/big-single.bin` gets `413`.
  - **Advertised chunk size.** `GET /ocs/v2.php/cloud/capabilities?format=json` as the admin: `.ocs.data.capabilities.files.chunked_upload.max_size` is `41943040`. The web UI and the desktop client chunk at whatever this says, so a bigger value means every upload over 50 MB fails. (Nextcloud 35 reads the system key `files.chunked_upload.max_size`; the old app key `files max_chunk_size` is dead.)
  - **Chunked.** The same file, sent the way the web UI and the desktop client send it, in chunks of the advertised size, succeeds: `MKCOL remote.php/dav/uploads/<uid>/<id>`, then `PUT` the chunks `00001` (40 MiB) and `00002` (the rest), then `MOVE …/.file`. Every request carries the `Destination` header, and the `PUT`s also carry `OC-Total-Length`. Expected: 201 or 204, and a `PROPFIND` shows the right size. On local disk Nextcloud assembles the chunks itself; its native v2 path needs object storage, which this app doesn't use.
  - Delete the test file and the token afterwards.

- [ ] **Step 6: Check the AI Assistant on the trial.**
  - **Persona.** The agent pod has `/clouve/context/nextcloud/CONTEXT.md.tpl`.
  - **Stage the skill.** Same as Task 1 Step 2, with `kubectl cp` and `kubectl exec -c <agent container>`, and the agent user from the pod's env (`MAGNETO_AGENT_USERNAME`, read by name only).
  - **Environment.** Check the env and secret names as in Task 1 Step 3 (Kubernetes host names: `tkt-<id>-nextcloud` and `tkt-<id>-nextcloud-mariadb`).
  - **Scripts.** As the agent user:
    - `verify-health.sh` gives GREEN;
    - `occ.sh status --output=json`;
    - the `temp-password.sh` round trip, signing in over HTTPS this time, then `--remove`;
    - a `share-as-admin.sh` link share, created, fetched anonymously over HTTPS (the URL uses the public host and `https`), listed and deleted;
    - `run-in-nextcloud.sh --detach backup.sh` and `--status` until finished.
  - **Maintenance mode.** Turn it on (`occ.sh maintenance:mode --on`), wait two probe periods (60 s), and check that the pod is still `Ready` and `ssh clouve-ops@${NEXTCLOUD_HOST}` still resolves and works. Then turn it off.
  - **A long download through the Files pane** (back-up step 5 sends the user there for a backup copy). Make a 200 MB file in the agent user's home (`head -c 200M /dev/urandom > ~/download-test.bin`) and note its `sha256sum`. Download it through the AI Assistant's Files pane at the public HTTPS address, as the user would, with the transfer slowed so that it takes more than 3 minutes (the rig browser's network throttling, or `curl --limit-rate` with the pane's session). Expected: the whole file arrives, with the same sum. Record the time it took. The skill says that the ingress caps request bodies at 50 MB and times out after 60 seconds, and nothing yet shows how a longer download fares; back-up.md's wording waits for this result. Delete the file afterwards.

- [ ] **Step 7: Write up.** Record every result in `rig.md`, with the deployment and listing ids, and nothing secret.

- [ ] **Step 8: Remove the trial and the listing.**
  - Cancel and delete the trial with the rig deployment steps.
  - Wait until `kubectl get ns org-<org>-tkt-<id>` reports NotFound.
  - Purge the listing with `purge.py <serviceName>` as the super admin, then `warm.py`.
  - End the helper sessions with `pub/logout.py`.
  - Expected: no namespace, no listing in the catalogue, no saved cookies. The pushed images stay in `e2eorg`.

---

### Task 3: Review

**Files:** fixes only.

- [ ] **Step 1: Run an independent code review** of each repo's staged changes (`git diff --cached`): the `code-review` skill at `high`, or superpowers:requesting-code-review with a fresh reviewer. Give it the spec and the three plans. Fix every confirmed finding in place, re-run the owning tests, and re-stage. List the findings and what was done in the report.

- [ ] **Step 2: Review for secrets**, in both repos:

```bash
git diff --cached | grep -nE '^\+.*(password|passwd|secret|token|key)[^ ]*[=:] *["'"'"']?[A-Za-z0-9+/_-]{12,}' || echo clean
git diff --cached | grep -nE '^\+.*set -x' || echo 'no set -x'
```

Check every hit by hand: test fixtures and the local compose's documented dev passwords are expected; remove anything else. Also confirm that none of the values used in Tasks 1 and 2 appear in a staged file: grep for each from a variable, never printing it.

- [ ] **Step 3: Audit the claims.** Compare `SKILL.md`'s capability table and each playbook's promises with what Tasks 1 and 2 exercised. Word down, or test, anything that wasn't. Make sure the magneto README, the listing's `appDescription` and `SKILL.md` agree on what ships: the pre-installed apps, the email flow, the upload cap.

- [ ] **Step 4: Check consistency.**
  - The test commands named in magneto `CLAUDE.md` and in the README exist and pass.
  - Versions match: plugin 0.1.0, the CHANGELOG, `appVersion` 35.0.2 and `authoredAgainst`.
  - The spec's file list matches what's staged; update the spec where the build differs, and say so in the report.
  - The skill's links into magneto still fit. In magneto-skills, re-run `python3 -I /tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/11/linkcheck.py plugins/nextcloud` (the commit-pinned magneto-agent link is accepted). For each magneto file that a Plan 3 fix changed, check that the skill's `Clouve/magneto/blob/develop/...#Lx-Ly` links into it still point at the lines they describe: 224 links cite the staged files by line, and the checker only tests that a range lies inside the file.

- [ ] **Step 5: Humanize.** Run the humanizer on every prose file staged in both repos that hasn't had its pass yet, with the hash check on code blocks and tables. Search the new prose for em and en dashes.

---

### Task 4: Clean up and report

**Files:**
- Modify: `/home/aj/.claude/projects/-home-aj-Projects/memory/project_nextcloud_app_and_skill.md` and its `MEMORY.md` line.
- Deleted (temporary only):
  - `/home/aj/Projects/magneto/.research/{nextcloud-server,nextcloud-docker,nextcloud-documentation,nextcloud-groupfolders}`;
  - the spike containers `ncspike-app` and `ncspike-db`, the network `ncspike`, and their volumes;
  - `/tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/research/`.

- [ ] **Step 1: Delete the research clones and the spike.**

```bash
rm -rf /home/aj/Projects/magneto/.research/{nextcloud-server,nextcloud-docker,nextcloud-documentation,nextcloud-groupfolders}
ls -A /home/aj/Projects/magneto/.research
docker rm -f ncspike-app ncspike-db; docker network rm ncspike
docker volume ls -q | grep -i ncspike | xargs -r docker volume rm
```

Expected: `.research` is empty (the folder itself stays, since AJ keeps it for clones), and no `ncspike` container, network or volume is left. Delete the scratchpad's `research/` folder once the report no longer needs it; keep `e2e/` until the report is sent.

- [ ] **Step 2: Do the final staging audit, per repo.**
  - Run `git status --short` and `git diff --cached --stat`.
  - Compare with `/tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/status-before.txt`, taken before Plan 1 started. It lists only this work's spec and plans in magneto, and nothing in magneto-skills. Any other entry that appears now must be a file the plans name.
  - Every new entry must be a file the plans name, fully staged (nothing in the second status column), with nothing untracked.

- [ ] **Step 3: Update the memory.** Rewrite `project_nextcloud_app_and_skill.md` with the outcome:
  - what's staged in each repo;
  - the rig test result;
  - what AJ has left to do: review, commit, merge magneto-skills to `main` so tenants get the skill, and publish the listing to dev, UAT and prod;
  - the open platform issues.
  Then update its `MEMORY.md` line (no longer IN PROGRESS).

- [ ] **Step 4: Write the report to AJ.** Plain words, outcome first. It covers:
  - **The changes, per repo,** with file paths.
  - **The main decisions,** including the calls made while building: the seventh script, `run-in-nextcloud.sh`, and anything the review changed.
  - **Every check and its result:** tests, builds, the local run, the drills, and the rig test.
  - **Limitations:**
    - the skill reaches tenants only from `main`;
    - the 50 MB cap for clients;
    - the first-start apps come from the store;
    - Valkey runs inside the app container.
  - **The platform issues from the spec's Risks, item 7.**
  - **What's left for AJ.**
  Run the humanizer on it before sending.
