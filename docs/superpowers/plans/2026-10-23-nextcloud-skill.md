# Nextcloud skill (magneto-skills `nextcloud` plugin) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `nextcloud` plugin to magneto-skills: a DevOps skill that lets the AI Assistant run a Clouve Nextcloud 35.0.2 deployment for a small business (accounts, groups, Team folders, sharing, apps, settings, health checks, backups, troubleshooting) without losing files, locking anyone out, or putting a password in the chat.

**Architecture:** A self-contained plugin under `plugins/nextcloud/`: `plugin.json`, an idempotent `install.sh`, and `skills/nextcloud/` with `SKILL.md`, references, playbooks, `learnings.md` and seven audited scripts. Five scripts run in the agent container; two (`backup.sh`, `restore.sh`) run inside the Nextcloud container as root, sent there by `run-in-nextcloud.sh`. All app commands go through `occ` over the clouve-ops SSH channel. HTTP is used only for the admin's own shares and for probes, and TCP MySQL only for read-only diagnostics.

**Tech Stack:** Markdown (Anthropic skill bundle), JSON manifests, bash. Hermetic bash tests with fake binaries on `PATH`.

**Spec:** `/home/aj/Projects/magneto/docs/superpowers/specs/2026-10-23-nextcloud-design.md`. Read sections F and G, "Passwords and the chat", the gate table and the appendix before starting.

**Companion plans:** `docs/superpowers/plans/2026-10-23-nextcloud-magneto.md` (the image and manifests this skill runs against) and `docs/superpowers/plans/2026-10-23-nextcloud-integration.md` (runs every script against a real instance and on the rig).

## Global Constraints

- **Repo and branch.** Work in `/home/aj/Projects/magneto-skills` on `develop`. Stage with `git add <exact files>` at the end of each task. Never commit, never switch branches, never unstage (no `git reset`, `git restore --staged`, `git rm --cached` or `git stash`). Leave every file you didn't create or name here untouched.
- **Names.** The plugin directory, `plugin.json` `name`, `SKILL.md` `name` and the `marketplace.json` entry are all `nextcloud`. The `description` is identical, byte for byte, in all three (Task 1 fixes it).
- **Versions.** `plugin.json` and the marketplace entry are `0.1.0`. The `SKILL.md` frontmatter has `type: devops`, `version: 0.1.0` and `authoredAgainst: nextcloud v35.0.2`.
- **Paths in the agent.** The payload is staged at `/clouve/skills/nextcloud/plugin/`, so scripts are at `/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/<name>.sh`. Markdown always gives that literal absolute path, never `$SKILL_DIR` or a relative path in a command. Scripts find their siblings with `"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`.
- **The agent's environment.** Plain variables: `NEXTCLOUD_HOST`, `NEXTCLOUD_MARIADB_HOST`, `NEXTCLOUD_DB_HOST`, `NEXTCLOUD_DB_NAME`, `NEXTCLOUD_DB_USER`, `NEXTCLOUD_URL`, `NEXTCLOUD_ADMIN_USER` and `NEXTCLOUD_ADMIN_EMAIL`. Secrets, read through `clv-secret`: `NEXTCLOUD_DB_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD` and `CLOUVE_OPS_PASSWORD`. No variable ending in `_PORT` exists.
- **Secrets contract** (magneto-skills `CLAUDE.md`):
  - In Markdown, a secret is always written `${NAME:-$(clv-secret NAME)}`, and prose names it bare in backticks.
  - A script loads each one on its own line, above its first use: `: "${NAME:=$(clv-secret NAME)}"`, with no `2>/dev/null`.
  - Never `printenv` one, never print a value, never `set -x`.
  - Scripts that run in the Nextcloud container get no loader line; they read credentials from `config.php`.
- **SSH.** `sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 clouve-ops@<host>`. The containers make new SSH host keys at every start, so nothing pins them (the Magneto Agent's own fetchers don't either). `SSHPASS` is set only on the `sshpass` command itself (`SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh …`), never exported in a script. The clouve-ops login shell is bash, and it has `NOPASSWD: ALL`, so `sudo --preserve-env=NC_PASS` is allowed.
- **The one `occ` form.** Remote: `sudo -n -u www-data php /var/www/html/occ --no-interaction --no-warnings <args>`. From Markdown: `occ.sh` by its absolute path, or `sudo -u www-data php /var/www/html/occ … -n` over SSH as the persona shows. Never `php occ` as root, never `./occ`.
- **Passwords never reach a command line.** They travel on stdin (`occ.sh --password-stdin`, which sets `NC_PASS` for `--password-from-env`), in curl's `-K -` config on stdin, in `MYSQL_PWD` for the agent's `mysql`, or in a mode-600 `--defaults-extra-file` inside the container.
- **Ground truth.** Every Nextcloud fact in a reference or playbook comes from the 35.0.2 source and links to it. Server: `https://github.com/nextcloud/server/blob/v35.0.2/<path>#L<a>-L<b>`. Team folders: the `v23.0.1` tag of `nextcloud/groupfolders` (check that it exists in `/home/aj/Projects/magneto/.research/nextcloud-groupfolders`; if not, link the `stable35` branch). The research notes hold the citations:
  - `/tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/research/occ-commands.md`;
  - `…/research/http-apis.md`, `…/research/config-ops-security.md` and `…/research/platform-integration.md`;
  - `…/research/occ-list-35.0.2.txt`, the full command list.
  Every `occ` command and option a skill file uses must exist. `python3 -I /tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/check-occ-usage.py plugins/nextcloud` checks each call against the definitions dumped from a stock 35.0.2 instance (`research/defs-all-apps.txt`) and from groupfolders 23.0.1 (`research/defs-groupfolders.txt`), and must end `occ usage: 0 problem(s)`. The source clones are in `/home/aj/Projects/magneto/.research/` until Plan 3's cleanup.
- **Prose.** Every Markdown file gets the humanizer pass (`humanizer:humanizer`, file mode): no em or en dashes, plain words, sentence-case headings. Code blocks and tables must come out byte-identical. Prove it by hashing them before and after with `/tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/md-fixed-parts.py`.
- **Tests.** New tests go in `tests/` and are hermetic: fake binaries first on `PATH`, temp folders, no network, no Docker, no Nextcloud. They print `ok`/`FAIL` lines like `tests/moodle-verify-health.test.sh` and exit 1 on any failure. Every script passes `shellcheck` with no findings.
- **Honesty.** The skill claims only what the spec's capability table says works. For anything in its "needs the customer" or "not available" rows, the skill says so.

## Review Focus

1. **Odd names reach `occ` intact.** Uids, group names, display names and paths with spaces, quotes, `$`, `;`, `&`, newlines or non-ASCII letters each reach `occ` as one argument, unexpanded by the remote shell. Pinned in Task 2's quoting cases.
2. **No secret leaks, anywhere.** Temporary passwords, app passwords, link passwords and the database password never appear in stdout, stderr or any process's argv. Password files are mode 600 in a 700 folder. Pinned by the argv sweeps in Tasks 3, 4, 5 and 6.
3. **Interrupted runs leave a known state.**
   - `share-as-admin.sh` killed after minting its app password: the token is gone, through the trap and the leftover sweep at the next run.
   - `backup.sh` failing part-way: no partial backup folder, and maintenance mode back where it was.
   - `restore.sh` failing part-way: maintenance stays on, with a marker file that `verify-health.sh` reports.
   Pinned in Tasks 4 and 6, and the marker report in Task 5.
4. **Instance states the happy path skips.** Maintenance mode on, an upgrade pending, the Team folders app missing, and `occ` exiting 0 after doing nothing (`user:delete` of an unknown user, a declined prompt under `-n`). Scripts read the state back after each write, and playbooks tell the assistant to. Pinned in Tasks 3, 5 and 7 and the playbook rules in Task 10.
5. **Space and size limits.**
   - A backup with `--with-data` when free space is under 1.2 times the estimate refuses before writing anything.
   - Quotas are written as `"5 GB"`. The provisioning API's `5 GiB` means 5 bytes, so the skill never uses it.
   - The 50 MB request cap and the 40 MiB chunks are explained wherever uploads come up.
   Pinned in Task 6, static rule 9 in Task 7, and the claim audit in Task 11 (Step 3).

---

### Task 1: Plugin skeleton and repo wiring

**Files:**
- Create: `plugins/nextcloud/.claude-plugin/plugin.json`, `plugins/nextcloud/install.sh` (mode 755)
- Create: `plugins/nextcloud/skills/nextcloud/SKILL.md` (frontmatter, title and one-line intro only; Task 8 writes the body), `plugins/nextcloud/skills/nextcloud/learnings.md`
- Modify:
  - `.claude-plugin/marketplace.json`: the new entry between `moodle` and `odoo`.
  - `README.md`: a Plugins table row between `moodle` and `odoo`.
  - `CHANGELOG.md`: a first bullet under `## Unreleased`.
  - `CLAUDE.md`: add `NEXTCLOUD_` to the agent-side prefixes sentence in "Which names".
  - `tests/skills-env-values.test.sh`: lines 28, 94, 121 and 298.

**Interfaces:**
- Produces: the description string, used verbatim in three files:

```
Safely run a Nextcloud 35 file sync and share server on Clouve through occ over the clouve-ops SSH channel. It covers staff accounts and groups, Team folders, sharing and links, quotas, Nextcloud apps, email setup, backups and restores, setup warnings, background jobs, stuck upgrades and maintenance mode, and slow or broken pages. Use when the user runs the Clouve Nextcloud app or mentions "Nextcloud", `occ`, `config.php` in `/var/www/html/config`, Team folders or groupfolders, WebDAV, CalDAV or CardDAV sync, share links, or `oc_*` tables. Do not use for ownCloud, or for generic PHP, Apache or MySQL questions that aren't tied to a Nextcloud instance.
```

- [ ] **Step 1: Extend the env test first.** In `tests/skills-env-values.test.sh`:
  - add `NEXTCLOUD_` to the comment at line 28;
  - add `NEXTCLOUD_*` to the `case` at line 94 and `NEXTCLOUD` to `prefixes=` at line 121, so both read `CLOUVE_OPS|GIBBON|MOODLE|NEXTCLOUD|ODOO|WORDPRESS|AI_STUDIO` in that order;
  - make the loop at line 298 `{gibbon,moodle,nextcloud,odoo,wordpress}`.

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/skills-env-values.test.sh`
Expected: FAIL on the missing `plugins/nextcloud/skills/nextcloud/learnings.md`; every other line as before.

- [ ] **Step 3: Write the files.**
  - `plugin.json`: same shape as `plugins/wordpress/.claude-plugin/plugin.json`, with `name`, `version`, the description and `author`.
  - The marketplace entry: also `"category": "DevOps"` and `"tags": ["devops", "file-sharing", "nextcloud", "php", "mysql"]`.
  - `install.sh`: `plugins/wordpress/install.sh`'s structure, with `REQUIRED_PACKAGES=(default-mysql-client openssh-client sshpass jq curl)`, the `[nextcloud/install]` log prefix, and a header saying which script needs which package (`mysql` for `verify-health.sh` and the read-only queries; ssh and sshpass for every script; `jq` and `curl` for `share-as-admin.sh` and `verify-health.sh`).
  - `learnings.md`: the WordPress file's preamble, its Format, "What does NOT go here" (the "Secrets. Ever." line, naming `CLOUVE_OPS_PASSWORD`, `MAGNETO_AGENT_LLM_KEY`, the database passwords and Nextcloud app passwords) and Pruning sections, and no entries.
  - `SKILL.md`: the frontmatter from Global Constraints, `# Nextcloud DevOps Skill`, one intro sentence, and a line saying that passwords aren't in the environment, which names `clv-secret --list`.
  - `README.md` row: `` | `nextcloud` | DevOps | 0.1.0 | Safely run a Nextcloud 35 file sync and share server on Clouve: accounts and groups, Team folders, sharing, apps, email setup, backups and restores, health checks and troubleshooting. | ``
  - `CHANGELOG.md`: `- **nextcloud** (0.1.0): new DevOps plugin …`, one paragraph in the style of the wordpress 0.1.0 entry. Name the channels, the seven scripts, the password rules and the magneto app it pairs with, and end with "Tenants get it once it reaches `main`." Humanize it.
  - `CLAUDE.md`: the sentence becomes "…start with `CLOUVE_OPS_`, `GIBBON_`, `MOODLE_`, `NEXTCLOUD_`, `ODOO_`, `WORDPRESS_` or `AI_STUDIO_`."

- [ ] **Step 4: Validate**

Run: `claude plugin validate . && bash tests/skills-env-values.test.sh && shellcheck plugins/nextcloud/install.sh`
Also run this name and description check:

```bash
jq -r '.plugins[].name' .claude-plugin/marketplace.json | paste -sd' '
jq -e --arg d "$(jq -r .description plugins/nextcloud/.claude-plugin/plugin.json)" '.plugins[] | select(.name=="nextcloud") | .description == $d' .claude-plugin/marketplace.json
python3 -I -c 'import sys,re; t=open(sys.argv[1]).read(); m=re.search(r"^description: (.*)$", t, re.M); print(m.group(1))' plugins/nextcloud/skills/nextcloud/SKILL.md | diff - <(jq -r .description plugins/nextcloud/.claude-plugin/plugin.json)
```

Expected: validation passes; the env test is all `ok`; the names list is alphabetical with `nextcloud` between `moodle` and `odoo`; `true`; no diff. Also `python3 -I -c 'import yaml,sys; t=open(sys.argv[1]).read().split("---")[1]; print(yaml.safe_load(t)["name"])' plugins/nextcloud/skills/nextcloud/SKILL.md` prints `nextcloud` (the frontmatter parses as YAML; the description has no `: ` and no ` #`).

- [ ] **Step 5: Stage**

```bash
git add plugins/nextcloud .claude-plugin/marketplace.json README.md CHANGELOG.md CLAUDE.md tests/skills-env-values.test.sh
```

---

### Task 2: `occ.sh` and the scripts test harness

**Files:**
- Create: `plugins/nextcloud/skills/nextcloud/scripts/occ.sh` (mode 755)
- Test: `tests/nextcloud-scripts.test.sh`

**Interfaces:**
- Produces `occ.sh`:

```
Usage: occ.sh [--password-stdin] [--init-lock] [--] <occ arguments...>
```

- Env: `NEXTCLOUD_HOST`, plus `CLOUVE_OPS_PASSWORD` through the loader line.
- **The remote command.** `sudo -n -u www-data php /var/www/html/occ --no-interaction --no-warnings` followed by each argument quoted with `printf ' %q'`. With `--init-lock`, `flock /var/www/html/nextcloud-init-sync.lock` comes before `php`, so the probe treats the run as an upgrade in progress.
- **Without `--password-stdin`,** stdin is closed (`ssh -n`).
- **With `--password-stdin`,** `occ.sh` reads one line from its own stdin (exit 64 when it's empty) and sends it as the first line of the SSH channel. The remote command becomes `IFS= read -r NC_PASS && export NC_PASS && exec sudo -n --preserve-env=NC_PASS -u www-data …`.
- **Output.** `occ`'s stdout and stderr pass through untouched, and the exit code is `occ`'s.
- **Exit codes.** 64 for usage. 1 when `NEXTCLOUD_HOST` is unset. 255 when SSH fails, printed as `[nextcloud/occ] could not reach clouve-ops@<host>` on stderr.
- Produces the harness in `tests/nextcloud-scripts.test.sh`, which later tasks add sections to. Its fakes, in `$work/bin`, first on `PATH`:
  - `sshpass` checks `-e` and that `SSHPASS` equals the test's `CLOUVE_OPS_PASSWORD`. It records the target and the options to `$FAKE_CALLS`, then plays the container. It rewrites `/var/www/html` and `/run/clouve` in the remote command to temp folders, and runs it in a real `bash -c` with the fakes on `PATH` and its own stdin passed through.
  - `sudo` drops `-n`, `-u <user>` and `--preserve-env=<list>`, records whether `NC_PASS` reached it, and runs the rest.
  - `php` plays `occ` when its first argument ends in `/occ`. It appends the argv to `$FAKE_OCC_LOG` as one JSON array per line (`python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1:]))'`). When `--password-from-env` is among the args, it writes the SHA-256 of `NC_PASS` to `$FAKE_OCC_LOG.pass`. Its answers come from `$FAKE_OCC/<subcommand>` (stdout) and `$FAKE_OCC/<subcommand>.rc` (exit code); with no file, it prints nothing and exits 0.
  - `flock` records the lock path and runs its command.

- [ ] **Step 1: Write the harness and the failing `occ.sh` section.** Header comment in the style of `tests/moodle-verify-health.test.sh`. Cases:

```bash
# quoting: each pair is one argument and must arrive as exactly one argv entry
occ_args 'user:add' '--display-name=O'"'"'Brien "Bob" $HOME' '-g' 'Sales & Ops' '--password-from-env' '--' 'Mary Ann'
expect_occ_argv '["/var/www/html/occ","--no-interaction","--no-warnings","user:add","--display-name=O'"'"'Brien \"Bob\" $HOME","-g","Sales & Ops","--password-from-env","--","Mary Ann"]'
occ_args 'files:scan' '--path=/Mary Ann/files/It'"'"'s $5; rm -rf ~' ; expect_last_arg '--path=/Mary Ann/files/It'"'"'s $5; rm -rf ~'
occ_args 'group:add' $'two\nlines' ; expect_last_arg $'two\nlines'
occ_args 'user:info' 'Дмитрий' ; expect_last_arg 'Дмитрий'
# password on stdin: reaches occ as NC_PASS, never argv, never the fake logs
printf '%s\n' 'Tmp-pw-AbCdEf234567' | occ.sh --password-stdin user:resetpassword --password-from-env -- alice
expect_pass_sha "$(printf %s 'Tmp-pw-AbCdEf234567' | sha256sum | cut -d' ' -f1)"
expect_not_in_logs 'Tmp-pw-AbCdEf234567'      # $FAKE_CALLS, $FAKE_OCC_LOG, stdout, stderr
printf '' | occ.sh --password-stdin user:resetpassword --password-from-env -- alice ; expect_rc 64
# init lock wraps php
occ.sh --init-lock upgrade ; expect_flock '/var/www/html/nextcloud-init-sync.lock'
# exit code passes through; stdout untouched (JSON stays parseable)
FAKE_RC user:info 1 ; occ.sh user:info nobody ; expect_rc 1
FAKE_OUT status '{"installed":true}' ; expect_stdout_json '.installed == true'
# environment
env -u NEXTCLOUD_HOST occ.sh status ; expect_rc 1
occ.sh ; expect_rc 64
```

The names above are helpers the harness defines (`occ_args` runs `occ.sh` with the given args). The harness also runs the script with `CLOUVE_OPS_PASSWORD` unset and a fake `clv-secret` that prints the test password, and expects the same result.

- [ ] **Step 2: Run** `bash tests/nextcloud-scripts.test.sh`. Expected: FAIL, no `occ.sh`.

- [ ] **Step 3: Implement `occ.sh`** to the interface. Build the remote command with `printf -v` and `%q` into one string. Never pass a password to `ssh` or `sshpass` as an argument.

- [ ] **Step 4: Run** `bash tests/nextcloud-scripts.test.sh && shellcheck plugins/nextcloud/skills/nextcloud/scripts/occ.sh tests/nextcloud-scripts.test.sh && bash tests/skills-env-values.test.sh`. Expected: all pass.

- [ ] **Step 5: Stage**

```bash
git add plugins/nextcloud/skills/nextcloud/scripts/occ.sh tests/nextcloud-scripts.test.sh
```

---

### Task 3: `temp-password.sh`

**Files:**
- Create: `plugins/nextcloud/skills/nextcloud/scripts/temp-password.sh` (mode 755), `plugins/nextcloud/skills/nextcloud/scripts/lib/nextcloud-passwords.sh` (mode 644, sourced; the gibbon plugin's `scripts/lib/` is the precedent)
- Test: `tests/nextcloud-scripts.test.sh` (new section)

**Interfaces:**
- Consumes: `occ.sh --password-stdin` (Task 2).
- Produces, in `scripts/lib/nextcloud-passwords.sh`: `nc_generate_password` (prints the 20 characters), `nc_password_dir` (creates `~/nextcloud-passwords` mode 700 and prints its path) and `nc_write_private_file <name>` (writes stdin to `<dir>/<name>` with mode 600 under `umask 077`, refusing to overwrite; exit 1 on failure). `temp-password.sh` and Task 4's `share-as-admin.sh` source it with `. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/nextcloud-passwords.sh"`.
- Produces:

```
Usage: temp-password.sh [--create] [--display-name NAME] [--email ADDR] [--group GROUP]... <uid>
       temp-password.sh --remove <file>
```

- **The password.** 20 characters from `ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789`, from `/dev/urandom` through `LC_ALL=C tr -dc`. Mind SIGPIPE under `pipefail`.
- **The file.** `~/nextcloud-passwords/<safe uid>-<UTC YYYYmmdd-HHMMSS>.txt`. The safe uid replaces every character outside `A-Za-z0-9._@-` with `_`. The folder is mode 700 and the file 600, both created under `umask 077`. The file holds:
  - the login (the real uid), the temporary password, and the sign-in page `${NEXTCLOUD_URL}/login`;
  - the UTC time it was made;
  - "Ask them to change it after signing in (Settings > Security). Delete this file once it's handed over."
- **Order.** Write the file, then set the password. If `occ` fails, delete the file, show `occ`'s message (a policy failure, or an account that already exists) and exit 2.
- **Setting the password.**
  - With `--create`: `printf '%s\n' "$pw" | occ.sh --password-stdin user:add --password-from-env [--display-name=NAME] [-g GROUP]... -- <uid>`.
  - After a successful create with `--email`: `occ.sh user:setting <uid> settings email <addr>`. Not `--email` on `user:add`, which would also mail a reset link.
  - Without `--create`: `user:resetpassword --password-from-env -- <uid>`, after `occ.sh user:info <uid>` succeeds (exit 2 if the account doesn't exist).
- **Read-back.** `occ.sh user:info <uid> --output=json` must show the account (and the email, when given), else exit 2.
- **Output.** One line on stdout: `Saved the temporary password for <uid> to nextcloud-passwords/<file name> in the Files pane.` The password and the full path are never printed.
- **`--remove <file>`.** Accepts a bare file name or a path. It must resolve (with `realpath`) inside `~/nextcloud-passwords/` and end in `.txt`, else exit 64. It deletes the file with `shred -u` when present, else `rm -f`, and prints `Deleted nextcloud-passwords/<file name>.`
- **Exit codes.** 0 ok; 64 usage; 1 environment (`NEXTCLOUD_HOST` or `NEXTCLOUD_URL` unset); 2 Nextcloud refused, or the read-back failed; 3 the file couldn't be written (nothing changed in Nextcloud).

- [ ] **Step 1: Add the failing section.** Cases, with `HOME` set to a temp folder:
  - **Create.** `--create --display-name 'Mary Ann Lee' --email mary@example.com --group Staff 'Mary Ann'`, then:
    - a single file exists matching `Mary_Ann-[0-9]{8}-[0-9]{6}.txt`, mode `600`, in a folder of mode `700`;
    - its password line matches `^[A-HJ-NP-Za-km-z2-9]{20}$`;
    - the SHA-256 in `$FAKE_OCC_LOG.pass` equals that password's;
    - the password appears in no fake log, no argv, and not in stdout or stderr;
    - `$FAKE_OCC_LOG` has `user:add`, then `user:setting Mary Ann settings email mary@example.com`, then `user:info`, and no `--email` on `user:add`;
    - stdout is the one `Saved …` line.
  - **Reset.** No `--create`, with an existing user: `user:info`, then `user:resetpassword --password-from-env -- <uid>`, and the same file checks.
  - **Unknown user without `--create`**: exit 2, and no file left.
  - **Policy failure.** A fake `user:add` that exits 1 printing `Password is among the 1,000,000 most common ones.` gives exit 2, that message on stderr, and no file.
  - **Two runs** in the same second for the same uid don't overwrite each other: the second waits a second or adds `-2`. Pick one and assert it.
  - **`--remove`.** Removing the created file deletes it; `--remove ../../etc/passwd` and `--remove /tmp/x.txt` exit 64 and touch nothing.
  - **Environment.** No `NEXTCLOUD_URL` gives exit 1.

- [ ] **Step 2: Run** `bash tests/nextcloud-scripts.test.sh`. Expected: the new cases FAIL.

- [ ] **Step 3: Implement** to the interface.

- [ ] **Step 4: Run** the test, `shellcheck` and `bash tests/skills-env-values.test.sh`. Expected: all pass.

- [ ] **Step 5: Stage**

```bash
git add plugins/nextcloud/skills/nextcloud/scripts/temp-password.sh plugins/nextcloud/skills/nextcloud/scripts/lib/nextcloud-passwords.sh tests/nextcloud-scripts.test.sh
```

---

### Task 4: `share-as-admin.sh`

**Files:**
- Create: `plugins/nextcloud/skills/nextcloud/scripts/share-as-admin.sh` (mode 755)
- Test: `tests/nextcloud-scripts.test.sh` (new section, plus a fake `curl`)

**Interfaces:**
- Consumes: `occ.sh` (Task 2), plus the password generator and private-file writer from `scripts/lib/nextcloud-passwords.sh` (Task 3), sourced, not copied.
- Produces:

```
Usage: share-as-admin.sh --as <uid> create --path <path> --type link|user|group|email
                         [--with <uid|group|address>] [--permissions <1-31>] [--expire YYYY-MM-DD]
                         [--password] [--note <text>] [--label <text>] [--send-mail]
       share-as-admin.sh --as <uid> list [--path <path>]
       share-as-admin.sh --as <uid> delete <share id>
```

Steps, in order:
1. **Arguments.** `--with` is required for `user`, `group` and `email` and refused for `link`. `--permissions` is an integer 1..31. `--expire` matches `^[0-9]{4}-[0-9]{2}-[0-9]{2}$`. Anything else is exit 64.
2. **Admin check.** `occ.sh group:list --output=json admin` must give an `admin` key whose list holds `<uid>`, and `occ.sh user:info <uid> --output=json` must say `"enabled": true`. Else exit 2: `<uid> isn't an enabled admin; other people share their own files (see playbooks/share-files-and-links.md)`.
3. **Leftover sweep.** `occ.sh user:auth-tokens:list <uid> --output=json`, then `occ.sh user:auth-tokens:delete <uid> <id>` for every entry named `clouve-ai-assistant-temporary`. The `EXIT` trap does the same sweep, and the script also traps `INT`, `TERM` and `HUP`.
4. **Mint.** `occ.sh user:auth-tokens:add --name=clouve-ai-assistant-temporary -- <uid>` into a variable. Take the last line matching `^[A-Za-z0-9]{72}$`, else exit 3. Never print it.
5. **Call OCS.** `curl -sS -m 30 -K - <method> <url>`, where the URL is `http://${NEXTCLOUD_HOST}/ocs/v2.php/apps/files_sharing/api/v1/shares` (with `?format=json`, or `/<id>?format=json` for delete).
   - The config on curl's stdin holds `user = "<uid>:<token>"`, the headers `Host: <host of NEXTCLOUD_URL>`, `OCS-APIRequest: true` and `Accept: application/json`, and each field as a `data-urlencode = "<name>=<value>"` line.
   - Values in that config are quoted with `\` and `"` escaped.
   - Create sends `path`, `shareType` (link 3, user 0, group 1, email 4), `shareWith`, `permissions`, `expireDate`, `password`, `note`, `label`, and `sendMail` (`false` unless `--send-mail`). List sends `path`, plus `reshares=true` when given. Delete sends no data.
6. **Link password.** `--password` makes one with Task 3's generator, sends it as `password`, and after a successful create writes `~/nextcloud-passwords/share-<id>-<UTC YYYYmmdd-HHMMSS>.txt` (mode 600) holding the link URL, the password, and the expiry if any. If that write fails, delete the share again and exit 4.
7. **Output.** Parse with `jq`. Success is `.ocs.meta.statuscode == 200`.
   - Create prints `id`, `share_type`, `path`, `share_with`, `permissions`, `expiration`, and for links `url`. With `--password` it adds `password saved to nextcloud-passwords/<file>` and never the password.
   - List prints one line per share with the same fields.
   - Delete prints `deleted share <id>`.
   - Otherwise exit 3 with `.ocs.meta.message` and the HTTP code.
- **Exit codes.** 0 ok; 64 usage; 1 environment (`NEXTCLOUD_HOST` or `NEXTCLOUD_URL` unset); 2 refused (not an enabled admin); 3 Nextcloud refused, or no token; 4 the link password couldn't be saved (the share was deleted again).

- [ ] **Step 1: Add the failing section.** The fake `curl` reads its `-K -` config from stdin into `$FAKE_CURL_CFG.<n>` and records argv to `$FAKE_CALLS`. It answers from `$FAKE_CURL_RESPONSE` and `$FAKE_CURL_HTTP`. The fake `occ` answers `user:auth-tokens:add` with `app password:` and a fixed 72-character token, and keeps a token list that `user:auth-tokens:list` and `user:auth-tokens:delete` read and change. Cases:
  - **Link create.** `--as admin create --path /Docs/Q3 report.pdf --type link --expire 2026-12-31 --password`, then:
    - config 1 has `user = "admin:<token>"`, `Host: abc.clouve.app` (from `NEXTCLOUD_URL=https://abc.clouve.app`), `OCS-APIRequest: true`, `path=/Docs/Q3 report.pdf`, `shareType=3`, `sendMail=false` and a 20-character `password=`;
    - the token and that password are in no argv and not in stdout or stderr;
    - after exit, no `clouve-ai-assistant-temporary` token is left;
    - the password file exists with mode 600 and holds the URL from the response;
    - stdout has the `url` and `password saved to nextcloud-passwords/share-42-…txt`.
  - **Not an admin.** `--as bob` with `bob` outside `admin` gives exit 2, with no token minted and no curl call.
  - **Disabled admin.** `enabled: false` gives exit 2.
  - **Leftovers.** Two `clouve-ai-assistant-temporary` tokens exist before the run, and none after; a token named `cli` survives.
  - **Killed mid-run.** A fake `curl` that sends SIGTERM to the script's PID gives a non-zero exit, and the token is deleted.
  - **OCS error.** `statuscode 404` with message `Wrong path, file/folder does not exist` gives exit 3 with that message.
  - **Link-password file fails.** `HOME` read-only gives exit 4, and `$FAKE_CALLS` shows a DELETE of share 42.
  - **Usage.** `--type user` without `--with` is exit 64; `--type link --with x` is exit 64; `--permissions 99` is exit 64.
  - **Quoting.** A `--note` with `"` and `\` arrives in the config correctly escaped.

- [ ] **Step 2: Run** the test. Expected: the new cases FAIL.

- [ ] **Step 3: Implement** to the interface.

- [ ] **Step 4: Run** the test, `shellcheck` and `bash tests/skills-env-values.test.sh`. Expected: all pass.

- [ ] **Step 5: Stage**

```bash
git add plugins/nextcloud/skills/nextcloud/scripts/share-as-admin.sh tests/nextcloud-scripts.test.sh
```

---

### Task 5: `verify-health.sh`

**Files:**
- Create: `plugins/nextcloud/skills/nextcloud/scripts/verify-health.sh` (mode 755)
- Test: `tests/nextcloud-scripts.test.sh` (new section, plus fake `mysql`, `curl` answers, `df` and `valkey-cli`)

**Interfaces:**
- Consumes: `occ.sh` (Task 2); the Valkey socket `/run/clouve/valkey/valkey.sock` (owned by www-data, mode 700) from Plan 1; and the restore marker `/var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS`, which Task 6's `restore.sh` writes.
- Produces: `verify-health.sh [-h|--help]`. It is read-only. It prints `Nextcloud health report, <UTC time>`, the host lines, one `printf '%-26s %-4s %s'` line per check, then `Overall: GREEN`, `Overall: AMBER (one or more WARN)` or `Overall: RED (one or more FAIL)`. Exit 0, 2 or 3, and 1 when required env is missing.
- Env:
  - required: `NEXTCLOUD_HOST`, `NEXTCLOUD_URL`, `NEXTCLOUD_DB_HOST`, `NEXTCLOUD_DB_NAME`, `NEXTCLOUD_DB_USER`;
  - loader lines: `NEXTCLOUD_DB_PASSWORD`, `CLOUVE_OPS_PASSWORD`;
  - optional: `NEXTCLOUD_MARIADB_HOST`, which defaults to `NEXTCLOUD_DB_HOST`.

The checks, in order (`label`: rule):
1. **`ssh_nextcloud`.** `occ.sh status --output=json` answers; take its last line starting with `{`. On failure, FAIL and skip the checks that need that channel (2, 3, 8 to 13 and 15). Checks 4 to 7 and 14 still run.
2. **`installed`.** `installed` true, else FAIL.
3. **The status flags.**
   - `maintenance`: false is OK; true is WARN, "users see a maintenance page".
   - `needs_db_upgrade`: false is OK; true is FAIL, "see playbooks/recover-stuck-upgrade-or-maintenance.md".
   - `version`: OK, with `versionstring`.
4. **`http_status`.** `curl -s -m 15 -o <tmp> -w '%{http_code}' -H "Host: <URL host>" http://${NEXTCLOUD_HOST}/status.php`. A 200 with `"installed":true` is OK. A 400 is FAIL, "trusted domain error: <host> isn't in trusted_domains". Anything else is FAIL with the code.
5. **`http_login_page`.** `/login` with the same Host: 200 is OK, else FAIL.
6. **`database_tcp`.** `MYSQL_PWD=… mysql -h "$NEXTCLOUD_DB_HOST" -u "$NEXTCLOUD_DB_USER" "$NEXTCLOUD_DB_NAME" -N -e 'SELECT 1'` with the TLS flags below. 1 is OK, else FAIL. TLS flags: `--ssl-mode=DISABLED` when `mysql --help` lists `--ssl-mode`, else `--skip-ssl`.
7. **`ssh_database`.** `true` over SSH to the database host works: OK, else WARN (diagnostics only).
8. **`restore_marker`.** `sudo test -e …/RESTORE-IN-PROGRESS` over SSH. When present, FAIL, "a restore was interrupted; see playbooks/restore-from-backup.md".
9. **`valkey`.** `sudo -n -u www-data valkey-cli -s /run/clouve/valkey/valkey.sock ping` over SSH: `PONG` is OK, else FAIL.
10. **`cron_last_run`.** The age is the container's `date +%s` minus `occ.sh config:app:get core lastcron`. Up to 900 s is OK, up to 3600 s is WARN, more is FAIL; an empty value is FAIL, "never ran".
11. **`background_jobs_mode`.** `occ.sh config:app:get core backgroundjobs_mode`: `cron` is OK, else WARN.
12. **`setup_checks`.** `timeout 180 occ.sh setupchecks --output=json`. Skipped (WARN) in maintenance mode. Any `error` or `warning` severity is WARN, listing their `name`s (at most 8, then `+N more`). Otherwise OK with the info count.
13. **`disk_nextcloud`.** `df -P /var/www/html` over SSH: under 85% is OK, under 95% is WARN, else FAIL.
14. **`disk_database`.** `df -P /var/lib/mysql` on the database host: the same thresholds, and WARN when unreachable.
15. **`url_setting`.** `occ.sh config:system:get overwrite.cli.url` equals `NEXTCLOUD_URL`: OK, else WARN, "changes when the container next starts".

- [ ] **Step 1: Add the failing section.** It uses the harness's fakes. Fake `mysql` checks that `MYSQL_PWD` equals the test password and that it isn't in argv. Fake `df` answers from `$FAKE_DF_<n>`, and fake `valkey-cli` from `$FAKE_VALKEY`. The fake `occ` answers `status`, `config:app:get`, `setupchecks` and `config:system:get`. Cases:
  - **Healthy.** Everything fine gives `Overall: GREEN`, exit 0, and every label printed once.
  - **Cron.** Age 1200 gives `cron_last_run WARN`, AMBER, exit 2. An empty `lastcron` gives FAIL, RED, exit 3.
  - **Maintenance.** `maintenance:true` gives `maintenance WARN` and `setup_checks WARN skipped`.
  - **Upgrade pending.** `needsDbUpgrade:true` gives `needs_db_upgrade FAIL` and RED.
  - **Untrusted host.** `curl` answering 400 for `status.php` gives `http_status FAIL trusted domain error`.
  - **Setup checks.** One `warning` named `PHP memory limit` and three `info` give `setup_checks WARN PHP memory limit`.
  - **Restore marker** present: FAIL.
  - **Disk.** `df` at 91% for `/var/www/html` gives WARN; at 97% gives FAIL.
  - **Unreachable.** `sshpass` failing for `NEXTCLOUD_HOST` gives `ssh_nextcloud FAIL`, RED, and the HTTP and DB checks still run.
  - **No secret leaks.** The database password appears in no argv, stdout or stderr.
  - **Environment.** No `NEXTCLOUD_URL` gives exit 1.

- [ ] **Step 2: Run.** Expected: the new cases FAIL.

- [ ] **Step 3: Implement** to the interface.

- [ ] **Step 4: Run** the test, `shellcheck` and the env test. Expected: all pass.

- [ ] **Step 5: Stage**

```bash
git add plugins/nextcloud/skills/nextcloud/scripts/verify-health.sh tests/nextcloud-scripts.test.sh
```

---

### Task 6: Backups, restores, and running them in the container

**Files:**
- Create: `plugins/nextcloud/skills/nextcloud/scripts/backup.sh`, `…/scripts/restore.sh`, `…/scripts/run-in-nextcloud.sh` (all mode 755)
- Test: `tests/nextcloud-scripts.test.sh` (new sections)

**Interfaces:**
- Consumes: Plan 1's container (`/var/www/html`; `mariadb-dump` and `mariadb` 11.8; `tar`, `gzip`, `sha256sum`; `occ` as www-data). Not Task 2's `occ.sh`: these scripts run inside the container.
- Produces `run-in-nextcloud.sh` (agent side; loader line for `CLOUVE_OPS_PASSWORD`):

```
Usage: run-in-nextcloud.sh [--detach] <backup.sh|restore.sh> [args...]
       run-in-nextcloud.sh --status <job>
```

  - **Plain run.** `SSHPASS=… sshpass -e ssh <opts> clouve-ops@${NEXTCLOUD_HOST} "sudo bash -s --<args quoted with %q>" < <scripts dir>/<script>`. Output streams through, and the exit code is the script's. Only `backup.sh` and `restore.sh` are accepted (exit 64 otherwise).
  - **`--detach`.** The job is `<backup|restore>-<UTC YYYYmmdd-HHMMSS>`.
    - The first SSH call installs the script as `/run/clouve/jobs/<job>.sh` (`sudo install -d -m 700 /run/clouve/jobs`, then `sudo tee` with the script on stdin, then `chmod 700`).
    - The second starts it with `sudo setsid nohup bash -c 'bash "$0.sh" "$@" > "$0.log" 2>&1; echo $? > "$0.rc"' /run/clouve/jobs/<job> <args> < /dev/null > /dev/null 2>&1 &`.
    - It prints `job: <job>`, then the `--status` command to run.
    - Detached jobs outlive the assistant's 10-minute command limit and a dropped SSH session.
  - **`--status <job>`.** The job name must match `^(backup|restore)-[0-9]{8}-[0-9]{6}$`. It prints the last 40 log lines, then `status: running` or `status: finished, exit <rc>`. Exit 0 when it finished with 0, 1 when it finished with anything else, 3 while it runs, and 64 for an unknown job.
- Produces `backup.sh` (runs as root in the container; overrides `NC_ROOT`, default `/var/www/html`, and `NC_OCC`, default `sudo -u www-data php ${NC_ROOT}/occ --no-interaction --no-warnings`):

```
Usage: backup.sh [--with-data] [--no-maintenance]
       backup.sh --list
```

  1. **Pre-checks.** Root (`id -u` is 0), a readable `config/config.php`, and `occ status` saying installed. Exit 1 otherwise.
  2. **Read the config.** `dbhost`, `dbname`, `dbuser`, `dbpassword`, `datadirectory`, `version` and `instanceid`, with `php -r` reading `config.php` (the file path and key come in as argv). `dbhost` may be `host:port`.
  3. **Space.** The estimate is the database size (`SUM(data_length+index_length)` from `information_schema.tables` for the schema), plus `du -sb` of `config`, `custom_apps` and `themes`, plus with `--with-data` `du -sb` of the data folder, minus `clouve-backups` and `appdata_*/preview`. Free space is `df -PB1` of the data folder. If free is less than 1.2 times the estimate, exit 3 before writing anything, printing both numbers in MB.
  4. **The folder.** `<datadirectory>/clouve-backups/<UTC YYYYmmdd-HHMMSS>/`, root-owned, mode 700, files mode 600. `clouve-backups` itself is root-owned, mode 700.
  5. **Maintenance.** Unless `--no-maintenance`, turn it on (`maintenance:mode --on`) when it was off. The trap (EXIT, INT, TERM, HUP) puts it back off only if this run turned it on.
  6. **The parts.**
     - `database.sql.gz`: `mariadb-dump --defaults-extra-file=<600 temp file holding [client] host, port, user and password> --skip-ssl --single-transaction --quick --hex-blob --default-character-set=utf8mb4 --routines --triggers <dbname> | gzip`. No `--databases`, so the dump restores into any schema name.
     - `config.tar.gz`: the `config/` folder.
     - `apps.tar.gz`: `custom_apps/` and `themes/`.
     - With `--with-data`, `data.tar.gz`: the data folder, excluding `./clouve-backups` and `./appdata_*/preview`, with `.ncdata` and `.htaccess` kept.
  7. **The manifest.** `manifest.json` holds `created` (UTC ISO 8601), `version`, `versionstring`, `instanceid`, `dbname`, `with_data`, the file list with byte sizes, and `"made_by": "nextcloud skill backup.sh 0.1.0"`. Then `SHA256SUMS`.
  8. **Verify.** `sha256sum -c` and `gzip -t` on each archive. On failure, delete the folder and exit 4.
  9. **Last line.** `[nextcloud/backup] done: <folder> (<size>). It is on Nextcloud's data volume next to the data it protects; it is never deleted automatically.`
  - **`--list`.** One line per backup: name, size, `with_data`, `versionstring`, and `INCOMPLETE` when the checksum file is missing. Read-only.
  - **Exit codes.** 0 ok; 1 usage or environment; 2 a step failed (folder removed); 3 not enough space; 4 the check failed (folder removed). The database password never reaches argv.
- Produces `restore.sh` (same runtime and overrides):

```
Usage: restore.sh --backup <name> --yes-replace-current-data [--skip-data]
```

  1. **Checks, before touching anything.**
     - Root, and `<datadirectory>/clouve-backups/<name>` with `manifest.json` and a passing `sha256sum -c`; else exit 2.
     - Without `--yes-replace-current-data`, print what would be replaced and exit 1.
     - Versions from the manifest against `occ status`: refuse (exit 3) when the backup is newer than the code, or more than one major older.
     - A backup without `data.tar.gz` and no `--skip-data` is exit 2, "this backup has no users' files; add --skip-data to restore the rest".
  2. **Remember the current settings.** Read the keys the image manages from the current `config.php` into a mode-600 temp file: `dbhost`, `dbname`, `dbuser`, `dbpassword`, `overwrite.cli.url`, `overwriteprotocol`, `trusted_domains`, `trusted_proxies`, `memcache.distributed`, `memcache.locking`, `redis`, `preview_concurrency_new`, `preview_concurrency_all` and `datadirectory`.
  3. **Start.** Turn maintenance on, and write the marker `<datadirectory>/clouve-backups/RESTORE-IN-PROGRESS` (holding the backup's name).
  4. **Database.** Drop every table in the current schema (`SET FOREIGN_KEY_CHECKS=0`, then `DROP TABLE` for each `information_schema.tables` row), then `gunzip -c database.sql.gz | mariadb … <current dbname>`.
  5. **`config.php`.** The backup's `config.php` with the remembered keys put back. `trusted_domains` is the union of both lists, current entries first. Set `'maintenance' => true`. A `php -r` program writes it with `var_export`, keeping the current file's owner and mode. Every other `config/` file comes from the backup.
  6. **Apps and themes.** Empty `custom_apps/` and `themes/`, then extract `apps.tar.gz`.
  7. **Users' files** (unless `--skip-data`). Remove everything in the data folder except `clouve-backups`, then extract `data.tar.gz`.
  8. **Ownership.** `chown -R www-data:www-data` on `config`, `custom_apps`, `themes` and the data folder, except `clouve-backups`.
  9. **Finish.**
     - When the backup's version is older than the code: `occ upgrade`.
     - Then `occ maintenance:data-fingerprint`.
     - Then `occ files:scan --all`, only when the users' files were restored whole.
     - Then `occ maintenance:mode --off`, remove the marker, and print `[nextcloud/restore] done: <name>`.
  10. **On failure after step 3.** Leave maintenance on and the marker in place. Print the failed step, and that `restore.sh --backup <the pre-restore backup> --yes-replace-current-data` puts the previous state back. Exit 4.
  - **Exit codes.** 0 ok; 1 not confirmed; 2 the backup is unusable; 3 the versions don't fit; 4 a step failed after changes began.

- [ ] **Step 1: Add the failing sections.** Each script runs two ways, as a file and through `bash -s` with the script on stdin, under `env -i` with `NC_ROOT` and `NC_OCC` pointing into a temp tree.
  - **The temp tree.** `config/config.php`, `custom_apps/calendar/appinfo/info.xml`, `themes/`, and `data/` with `.ncdata`, `alice/files/a.txt`, `appdata_oc123/preview/1/x.png` and `nextcloud.log`.
  - **The fakes.**
    - `id -u` prints 0.
    - `php` answers config reads from `$FAKE_CFG/<key>`. For the merge program it copies the backup's `config.php` to the target and appends `// merged` (the real merge is exercised in Plan 3).
    - `mariadb-dump` checks that its `--defaults-extra-file` is mode 600 and holds the password, and that the password isn't in argv. It prints `-- dump of <db>`.
    - `mariadb` records each SQL statement and answers the size and table queries.
    - `df` answers from `$FAKE_DF_AVAIL`, and `chown` records its calls.
    - The `occ` fake records calls and answers `status`.
  - **Backup cases:**
    - **Default.** A config-only backup has `database.sql.gz`, `config.tar.gz`, `apps.tar.gz`, `manifest.json` and `SHA256SUMS`, and no `data.tar.gz`. The folder is mode 700, the files 600, and `sha256sum -c` passes. The `occ` log shows `maintenance:mode --on`, then `--off`. The last line is `[nextcloud/backup] done: …`.
    - **`--with-data`.** `data.tar.gz` lists `./alice/files/a.txt`, `./.ncdata` and `./nextcloud.log`, but not `./clouve-backups` or `./appdata_oc123/preview/1/x.png`.
    - **Maintenance already on** before the run: the script never turns it off.
    - **`--no-maintenance`:** no `maintenance:mode` call at all.
    - **Low space.** `$FAKE_DF_AVAIL` below 1.2 times the estimate gives exit 3, with no new folder and no maintenance call.
    - **Dump fails.** A fake `mariadb-dump` exiting 2 gives exit 2, no backup folder left, and maintenance back off.
    - **`--list`** shows the backups made above, and `INCOMPLETE` for a folder without `SHA256SUMS`.
  - **Restore cases:**
    - **Not confirmed.** Without `--yes-replace-current-data`: exit 1 and nothing changed (the tree's checksum is the same before and after).
    - **Corrupted.** A backup whose checksum fails gives exit 2.
    - **Version from the future.** A manifest version of `36.0.0.1` against code `35.0.2.2` gives exit 3, and so does `33.0.0.1`. A `35.0.1.1` backup gives exit 0 and `occ upgrade` in the log.
    - **Full restore.**
      - The SQL log shows `DROP TABLE` for each table the fake lists, then the import.
      - `config/config.php` ends with `// merged`.
      - `data/alice/files/a.txt` is back, a file created after the backup is gone, and `clouve-backups` is untouched.
      - The `occ` log shows `maintenance:mode --on`, `maintenance:data-fingerprint`, `files:scan --all`, `maintenance:mode --off`, in that order.
      - The marker is gone.
    - **`--skip-data`.** User files untouched, and no `files:scan`.
    - **Import fails.** A failing fake `mariadb` import gives exit 4. The marker exists, maintenance was never turned off, and the message names the step.
  - **`run-in-nextcloud.sh` cases:**
    - A plain run streams the script's output and exits with its code.
    - `--detach backup.sh --with-data` prints `job: backup-<timestamp>`.
    - `--status` of that job: exit 3 while a fake slow script runs, then exit 0 with `status: finished, exit 0`.
    - `--status ../../etc` gives exit 64, and `run-in-nextcloud.sh other.sh` gives exit 64.
    - `SSHPASS` never appears in argv.

- [ ] **Step 2: Run.** Expected: the new cases FAIL.

- [ ] **Step 3: Implement the three scripts** to the interfaces. Each in-container script starts with a header saying it runs inside the Nextcloud container as root, sent by `run-in-nextcloud.sh`, and that `sudo` drops the container's env, so credentials come from `config.php`.

- [ ] **Step 4: Run** the test, `shellcheck` on the three scripts and the env test. Expected: all pass.

- [ ] **Step 5: Stage**

```bash
git add plugins/nextcloud/skills/nextcloud/scripts/{backup.sh,restore.sh,run-in-nextcloud.sh} tests/nextcloud-scripts.test.sh
```

---

### Task 7: The static command test

**Files:**
- Test: `tests/nextcloud-skill-commands.test.sh`

**Interfaces:**
- Consumes: the plugin's files. It reads only, and has no Docker or network.
- Produces: the rules every Markdown and script file of the plugin must pass. Tasks 8 to 10 write against them.

The test builds a command corpus: the fenced code blocks of every `.md` file, plus every non-comment line of every `.sh` file. It reports `file:line` for each hit. Rules on the corpus:
1. **`occ` form.** Any `occ` call is `occ.sh` by its absolute path, or `sudo` (with `-n`, `-E` or `--preserve-env=NC_PASS`) `-u www-data` (optionally `flock /var/www/html/nextcloud-init-sync.lock`) `php /var/www/html/occ`, or a script's `${NC_OCC}`/`"${occ[@]}"`. Fail on `php occ`, `./occ`, `sudo php`, a bare `php /var/www/html/occ`, `docker exec` and `kubectl`.
2. **Secret reads.** Fail on `config:list --private` and `config:list … --private`. Fail on `config:system:get` of `dbpassword`, `secret`, `passwordsalt`, `mail_smtppassword`, or `redis` followed by `password`. Fail on `config:app:get` of a key containing `password`, `secret`, `token` or `private`.
3. **Unscoped cleanups.** `versions:cleanup` and `trashbin:cleanup` without a user argument, or with `--all-users`, fail.
4. **Passwords on a command line.**
   - `--value=` on a key containing `pass` or `secret`;
   - `user:resetpassword` without `--password-from-env`;
   - `user:add` without `--password-from-env` or `--generate-password`;
   - `mysql`, `mariadb` or `mariadb-dump` with `-p<something>` or `--password=`;
   - `sshpass -p`.
5. **Prompts that `-n` declines.** `groupfolders:delete` without `--force` or `-f`, and `files:delete` without `--force` or `-f`.
6. **Never run.** `encryption:enable`, `encryption:encrypt-all`, `encryption:enable-master-key`, `encryption:disable-master-key`, `encryption:decrypt-all`, `maintenance:install`, and the experimental share-store commands: `sharing:create-share`, `sharing:delete-share`, `sharing:get-share`, `sharing:get-shares`, `sharing:add-share-*`, `sharing:remove-share-*`, `sharing:update-share-*` and `sharing:select-share-permission-preset`. The `files_sharing` repair commands (`sharing:delete-orphan-shares`, `sharing:fix-share-owners` and the rest) stay allowed.
7. **No SQL writes.** `INSERT`, `UPDATE`, `DELETE`, `ALTER`, `DROP`, `TRUNCATE`, `CREATE` or `REPLACE` in a `mysql`/`mariadb -e` or heredoc, except in `scripts/restore.sh`.
8. **No feeding redacted config back.** `config:list` piped or redirected into `config:import`.
9. **Quotas.** Values use `GB` or `MB` with a space (`"5 GB"`). `GiB` or `MiB` in a line that sets a quota fails. Prose may still explain the `GiB` trap.

Rules on every line of every file, prose included:

10. **No undefined `$SKILL_DIR`.** `$SKILL_DIR` or `${SKILL_DIR}` fails.
11. **Named files exist.** Every `/clouve/skills/nextcloud/plugin/<path>` named exists as `plugins/nextcloud/<path>`.

- [ ] **Step 1: Write the test, with a self-check.** It runs every rule against a built-in fixture folder (in a temp dir) holding one bad line per rule, and expects each rule to fire. Then it checks that the fixture's good lines don't fire:

```bash
ok_line 'printf "%s\n" "${NEXTCLOUD_ADMIN_PASSWORD:-$(clv-secret NEXTCLOUD_ADMIN_PASSWORD)}" | /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh --password-stdin user:resetpassword --password-from-env -- "${NEXTCLOUD_ADMIN_USER}"'
ok_line 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "sudo -u www-data php /var/www/html/occ status --output=json -n"'
ok_line '/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh groupfolders:delete 3 --force'
ok_line '/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh versions:cleanup alice'
ok_line '/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh user:setting alice files quota "5 GB"'
```

Then it runs the rules on `plugins/nextcloud`.

- [ ] **Step 2: Run** `bash tests/nextcloud-skill-commands.test.sh`. Expected: the self-check passes, and the plugin passes, since so far it holds only Task 1's files and the scripts. Fix any hit in the file that has it.

- [ ] **Step 3: Stage**

```bash
git add tests/nextcloud-skill-commands.test.sh
```

---

### Task 8: `SKILL.md`

**Files:**
- Modify: `plugins/nextcloud/skills/nextcloud/SKILL.md` (the body under Task 1's frontmatter)

**Interfaces:**
- Consumes: the scripts' usage lines (Tasks 2 to 6) and the reference and playbook file names in Tasks 9 and 10. Link those by their final names now. Task 11 checks that every link resolves.

The sections, in order, with what each must say:
1. **Intro.** You run a live Nextcloud holding a small business's files, calendars and contacts. The people asking are owners and office managers, so don't lose their files or lock them out.
2. **When to use / When not to use.** As the description says, plus: not for the Magneto Agent itself, and not for other apps in the pod.
3. **What you can and can't do here.** The spec's three-row capability table, verbatim in substance.
4. **Operating principles,** numbered:
   1. users' files are private;
   2. the image re-asserts its settings at every start: list them, and say a hand change reverts at the next start;
   3. Nextcloud's version comes from the image: no web updater, and `occ upgrade` only in the recovery playbook;
   4. always go through `occ.sh`: `-n` takes each prompt's default, exit codes can lie, so read the state back after every write;
   5. destructive commands go through the gates;
   6. no SQL writes;
   7. passwords never pass through the chat (the five rules from "Passwords and the chat");
   8. shares only of an admin's own files, through `share-as-admin.sh`, and everyone else shares their own;
   9. no server-side encryption;
   10. capacity is paid;
   11. never expose the AI Assistant's key (`MAGNETO_AGENT_LLM_KEY`, `ANTHROPIC_AUTH_TOKEN`);
   12. clouve-ops is root-equivalent;
   13. Clouve can't see inside the container, so give the user enough detail for a support ticket.
5. **Environment you are running in.**
   - The variables from Global Constraints. Discover them with `compgen -e | grep -i nextcloud`, and the passwords' names with `clv-secret --list | grep -i -e nextcloud -e clouve_ops`. Passwords aren't in the environment: use `${NAME:-$(clv-secret NAME)}`.
   - The channels.
   - The SSH line with the two-part `SSHPASS` form, and the `occ.sh` line.
   - `NEXTCLOUD_ADMIN_USER` is the cleaned login, and `occ.sh user:list` confirms it.
6. **What the Clouve image does at every start, and the limits.**
   - The do-not-fight list.
   - Cron every 5 minutes, with heavy jobs between 01:00 and 06:00 UTC.
   - Valkey for cache and locks.
   - 50 MB per request and 60 s, with browser uploads chunked at 40 MiB.
   - The first install adds Calendar, Contacts and Team folders.
7. **Scripts.** One line each for the seven, with its absolute path.
8. **Pointers into the deeper docs.** One line per reference and playbook.
9. **Maintaining this skill.** WordPress's section, adapted, including the runtime caveat with `/clouve/skills/nextcloud/plugin/skills/nextcloud/` and the `Captured to skill learnings:` echo.
10. **Safety gates.** The spec's gate table, verbatim in substance, then the WordPress definition of "user ack".

- [ ] **Step 1: Write the body.**
- [ ] **Step 2: Humanize** it with the hash check, keeping the frontmatter byte-identical.
- [ ] **Step 3: Run** `bash tests/nextcloud-skill-commands.test.sh && bash tests/skills-env-values.test.sh && claude plugin validate . && python3 -I /tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/check-occ-usage.py plugins/nextcloud`. Expected: all pass; the env test finds `clv-secret --list` in `SKILL.md`.
- [ ] **Step 4: Stage** `git add plugins/nextcloud/skills/nextcloud/SKILL.md`

---

### Task 9: References

**Files:**
- Create: `plugins/nextcloud/skills/nextcloud/reference/README.md` (index: one line per file) and the 13 files below.

**Interfaces:**
- Consumes: the research notes and source clones listed in Global Constraints, and the spec's appendix. Every fact carries a source link. Write facts only, no procedures (those are playbooks). Where a fact was verified on the spike rather than read in code, say "verified on 35.0.2".

What each file must cover (the topics are the spec's reference table; the "Must include" column lists the facts that must not be missed):

| File | Must include |
|---|---|
| `shell-access.md` | The three channels, and which script uses which. The SSH line and `occ.sh` with every option. Why `sudo` loses the container env, and what the image does about it. `-n` takes each prompt's default; the list of commands whose prompt defaults to no and which still exit 0. Exit codes that lie (`user:delete` of an unknown user, `setupchecks` exiting 1 on info). Only core commands load in maintenance mode or with an upgrade pending. Long runs go through `run-in-nextcloud.sh --detach`. |
| `stack-and-runtime.md` | Containers, volumes (20 GB and 10 GB at x-small), paths, processes (Apache prefork, Valkey, crond, sshd). The boot sequence and the hooks in plain words. The do-not-fight list. The worker and preview sizing. The 50 MB and 60 s limits and the 40 MiB chunks. What `413` means for desktop and WebDAV clients. |
| `configuration.md` | `config.php` against `config/*.config.php` fragments (fragments win; any write bakes them in). The managed keys. Reading config without printing secrets (`config:list system` is redacted; never feed it to `config:import`). `config:system:set` types (`--type=integer`/`boolean`). Mail keys, retention, previews, `maintenance_window_start`, `default_phone_region`. |
| `users-and-groups.md` | The uid rules. `user:add` options and their traps: `-g` creates missing groups; `--email` mails a reset link; an invalid email returns 1 after creating. Disable against delete (what `user:delete` removes, permanently). Quotas: the exact `"5 GB"` form, and a quota below usage blocking downloads and purging trash and versions. Passwords and policy. 2FA state and reset. App passwords: users make their own. `files:transfer-ownership`. Groups, and `group:list --output=json` for members. |
| `files-and-sharing.md` | The data layout. `files:scan` and its traps (an incomplete volume loses shares). Trash and versions retention and the scoped cleanups. Share types and permission bits. Sharing policy keys. `share:list`. Owner-only share creation over OCS (no admin override; rate limit 20 per 10 minutes; `sendMail` defaults to mailing user-share recipients). The experimental `sharing:*` store isn't Files' shares. Team folders: `groupfolders:*` commands, permissions, quota, ACL (`--enable`, manage rules), and `delete --force`. |
| `apps.md` | Shipped against store apps. `app:list --output=json`, `app:install`, `app:enable`, `app:disable`, `app:update`, `app:remove`. Compatibility with 35. App store reachability. What can't run on Clouve: ExApps (AppAPI off), office servers, Talk HPB, notify_push, antivirus, full-text search. |
| `backup-restore.md` | What a complete backup is (database, config, apps and themes, users' files). The two scripts, their options and exit codes, and where backups live. The restore order. Why `secret`, `passwordsalt` and `instanceid` come from the backup. The version rule. `files:scan` only when the data is whole. The data fingerprint and clients resyncing. Copying a backup off the deployment. |
| `upgrade.md` | Upgrades come from the image, one major at a time. The start-time recovery. What to check after (`db:add-missing-*`, `setupchecks`, apps disabled for incompatibility). Why not to run the web updater. |
| `security.md` | Brute force (429 after more than 10 failures in 30 minutes per IP; `security:bruteforce:attempts` and `security:bruteforce:reset`). Rate limits, password policy, 2FA enforcement. The log file and `loglevel`. `config:list` against `config:system:get`. Why encryption is declined (the data-loss modes). Trusted domains and proxies as set by the image. HSTS. |
| `cron-and-background-jobs.md` | How cron runs here (busybox crond, every 5 minutes, as www-data). `lastcron`. The maintenance window. `background-job:list`, `background-job:execute`. Stuck jobs. Why AJAX/webcron mode is wrong here. |
| `http-api.md` | OCS and WebDAV from the agent: the Host header, `OCS-APIRequest`, `format=json`, app passwords. Password confirmation (app passwords fail admin writes, so `occ` is the admin channel). The strict-cookie rule (send no cookies). Status codes. Chunked upload through `remote.php/dav/uploads/` (on local disk Nextcloud assembles the chunks itself; the native v2 path needs object storage). |
| `data-model.md` | The key tables (`oc_filecache`, `oc_storages`, `oc_mounts`, `oc_share`, `oc_users`, `oc_accounts`, `oc_group_user`, `oc_preferences`, `oc_appconfig`, `oc_jobs`, `oc_group_folders*`). Read-only diagnostic queries over TCP with the `MYSQL_PWD` form. The never-write rule. |
| `troubleshooting.md` | Symptom, cause, first check, fix (or playbook) for at least: trusted domain error, maintenance page, "update needed" page, 413 on upload, slow pages, cron not running, login throttled (429), files missing in the web UI but present on disk, shares gone after a scan, mail not arriving, the app store unreachable, and calendar sync redirecting to http. |

- [ ] **Step 1: Write the 14 files.**
- [ ] **Step 2: Humanize** each, with the hash check.
- [ ] **Step 3: Check the commands and links.** Every link is to the `v35.0.2` tag (or the Team folders tag), and every relative link resolves. Then run:

```bash
python3 -I /tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/check-occ-usage.py plugins/nextcloud
```

Expected: `occ usage: 0 problem(s)`. It checks every `occ` call (command and options) in code blocks, inline code and scripts.

- [ ] **Step 4: Run** `bash tests/nextcloud-skill-commands.test.sh && bash tests/skills-env-values.test.sh`. Expected: pass.
- [ ] **Step 5: Stage** `git add plugins/nextcloud/skills/nextcloud/reference`

---

### Task 10: Playbooks

**Files:**
- Create in `plugins/nextcloud/skills/nextcloud/playbooks/`: `onboard-users-and-groups.md`, `offboard-user.md`, `set-up-team-folders.md`, `share-files-and-links.md`, `install-or-update-app.md`, `configure-email.md`, `harden-fresh-install.md`, `diagnose-problems.md`, `recover-stuck-upgrade-or-maintenance.md`, `back-up.md`, `restore-from-backup.md`, `fix-files-out-of-sync.md`, `regain-admin-access.md`, `free-up-space.md`.

**Interfaces:**
- Consumes: the scripts (Tasks 2 to 6) and references (Task 9). Each playbook has:
  - **When to use** and **Before you start** (checks, with commands);
  - numbered **Steps**, each with its exact command and the read-back that proves it worked;
  - the **gate** each destructive step needs, from the `SKILL.md` table;
  - **If it goes wrong**;
  - **Tell the user**: what to say in plain words, including the steps only they can do.

The decisions each playbook must carry:
- **`onboard-users-and-groups`.**
  - Ask the admin: email invite, or a temporary password in a private file. Recommend email once a test message has arrived (`occ.sh config:app:get core emailTestSuccessful` is `1`, or the admin confirms one).
  - Email path: `user:add --generate-password --email=… --display-name=… -g …`, then read the log for `Sending mail to … failed`.
  - File path: `temp-password.sh --create …`, tell the admin which file to hand over, then `--remove` after.
  - Groups first, created with `group:add`. Quotas in the `"5 GB"` form.
- **`offboard-user`.** Disable first (`user:disable`), then `files:transfer-ownership <from> <to>` (with `--path` when asked). Delete only with ack, never in maintenance mode, and after a backup when the user had files. List what goes first: shares, calendars, contacts. Read back with `user:info` (exit 1 means it's gone).
- **`set-up-team-folders`.**
  - Check the app is enabled (`app:list`), and install it if missing.
  - `groupfolders:create`, `groupfolders:group <id> <group> read write share delete` (narrower when asked), `groupfolders:quota`, ACL with `groupfolders:permissions <id> --enable` and the manage commands.
  - Read back with `groupfolders:list --output=json`.
  - Tell the user that members may see the folder after their next page load.
- **`share-files-and-links`.**
  - The admin's own files only, with `share-as-admin.sh`: offer an expiry and a link password for links, and send no mail unless asked.
  - For anyone else's files, walk the user through the Share button.
  - List all shares with `share:list`, and revoke the admin's own with `share-as-admin.sh … delete`. Someone else's share can be removed only by the person who made it (or the file's owner), from the Share tab in Files; a recipient can also leave a share made with them. The assistant can't remove it for them.
- **`install-or-update-app`.**
  - Store apps: check compatibility, back up, then install and read back with `app:list`.
  - A third-party app (not from the store): read its `info.xml` and source, back up, ack.
  - Updates: `app:update --showonly`, then per app.
  - Disabling an app that breaks the UI.
- **`configure-email`.**
  - The admin fills in Administration > Basic settings > Email server, password included, and presses "Send email".
  - The assistant checks `config:list system` (redacted), `emailTestSuccessful`, and the log.
  - Common SMTP errors, and port and encryption pairs.
  - Never ask for the SMTP password.
- **`harden-fresh-install`.** Read the setup checks. Phone region (`default_phone_region`). 2FA apps and enforcement for admins (ack). The password policy. Sharing defaults (link expiry and password). Brute-force settings. Check that the admin's email is set. Skip what the image already sets.
- **`diagnose-problems`.** `verify-health.sh` first, then follow `troubleshooting.md` by symptom. Logs: the last 200 lines of `data/nextcloud.log` with `jq` over SSH (`sudo tail`), never the whole file into the chat. Apache's logs go to the container's stdout, which the assistant can't read.
- **`recover-stuck-upgrade-or-maintenance`.**
  - `occ status`.
  - When `needsDbUpgrade` is true: take a config-only backup (`run-in-nextcloud.sh backup.sh`, which works in maintenance mode). Then turn maintenance off (`maintenance:mode --off`) and set `loglevel` back to 2 if it was left at 0, and only then run `occ.sh --init-lock upgrade`. The order matters: `occ upgrade` never turns off a maintenance mode it found on, so the other order leaves the site in maintenance if the upgrade succeeds. Tell the user it can take a few minutes, and that the lock keeps the health check from restarting the container meanwhile.
  - When only maintenance is on: find out why before turning it off. A backup or restore may be running (`run-in-nextcloud.sh --status <job>`, the restore marker).
- **`back-up`.** Config-only against `--with-data` (space: the data doubles on the volume). Always `--detach` for `--with-data`. Check with `--status`, then `backup.sh --list`. Copying a backup off the deployment. Cleanup is the admin's call.
- **`restore-from-backup`.**
  - Pick the backup (`--list`).
  - A fresh backup of the current state first (ack), then the restore with `--detach`, then `--status`, then `verify-health.sh`.
  - What users notice: clients resync, and sessions may end.
  - Recovering from an interrupted restore: the marker, and restoring the pre-restore backup.
- **`fix-files-out-of-sync`.**
  - When it applies: files changed on disk, a restore, or a folder that won't show.
  - Scan the narrowest path first: `files:scan --path="/<uid>/files/<folder>"`, then `files:scan <uid>`, and `--all` only with the gate.
  - `groupfolders:scan` for Team folders, `files:repair-tree`, and the data fingerprint.
- **`regain-admin-access`.**
  - Reset to the dashboard password over stdin: the `printf … | occ.sh --password-stdin user:resetpassword --password-from-env -- "${NEXTCLOUD_ADMIN_USER}"` form, with ack.
  - Brute-force reset for the user's IP (ask for it, or read it from the log).
  - 2FA reset (`twofactorauth:state`, `twofactorauth:disable <uid> <provider>`), with ack.
  - Re-enable a disabled admin.
  - Tell the user the dashboard password works again, and to change it after.
- **`free-up-space`.**
  - Measure first: `df`, `user:report`, the biggest users, trash and versions per user, previews, old backups in `clouve-backups`, and the log size.
  - Then scoped cleanups, each with ack: `trashbin:cleanup <uid>`, `versions:cleanup <uid>`, `preview:cleanup` (previews come back on demand), and deleting a named old backup folder.
  - Quotas to stop it recurring.
  - A bigger plan through the Clouve dashboard: never resize anything.

- [ ] **Step 1: Write the 14 playbooks.**
- [ ] **Step 2: Humanize** each, with the hash check.
- [ ] **Step 3: Run** `bash tests/nextcloud-skill-commands.test.sh && bash tests/skills-env-values.test.sh && python3 -I /tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/check-occ-usage.py plugins/nextcloud`. Expected: pass, with `occ usage: 0 problem(s)`.
- [ ] **Step 4: Stage** `git add plugins/nextcloud/skills/nextcloud/playbooks`

---

### Task 11: Validate the plugin and audit its claims

**Files:** none new (fixes go back into the files of Tasks 1 to 10).

- [ ] **Step 1: Run every check**

```bash
cd /home/aj/Projects/magneto-skills
claude plugin validate .
for t in tests/*.test.sh; do bash "$t" >/dev/null 2>&1 && echo "ok   $t" || echo "FAIL $t"; done
bash plugins/gibbon/skills/gibbon/scripts/tests/mysql-tls.test.sh >/dev/null && echo "ok   gibbon mysql-tls"
shellcheck plugins/nextcloud/install.sh plugins/nextcloud/skills/nextcloud/scripts/*.sh tests/nextcloud-*.test.sh
python3 -I /tmp/claude-1000/-home-aj-Projects/041b1a98-9912-43db-8289-b9553208207d/scratchpad/check-occ-usage.py plugins/nextcloud
```

Expected: validation passes, every test `ok` (the existing ones too), no shellcheck output, and `occ usage: 0 problem(s)`.

- [ ] **Step 2: Check the links.** Every relative Markdown link in `plugins/nextcloud` resolves to a file. Every external link uses a pinned tag (`v35.0.2`, the Team folders tag, or a docker commit). `SKILL.md` links every reference and playbook.

- [ ] **Step 3: Audit the claims.** For each "works out of the box" item in `SKILL.md`, name the playbook step or script that does it, and the Plan 3 step that exercises it. Add anything with no such step to Plan 3's checks, or word it down in `SKILL.md`. Each "needs the customer" and "not available" item must say so wherever it comes up in the playbooks. Every file that tells the assistant about uploads (the references, `troubleshooting.md`, and any playbook that moves files) mentions the 50 MB per-request cap and the 40 MiB browser chunks.

- [ ] **Step 4: Sweep for secrets and stray text.**

```bash
grep -rnE '(password|passwd|secret|token)[^ ]*[=:] *[A-Za-z0-9+/]{12,}' plugins/nextcloud || echo clean
grep -rnP '[\x{2013}\x{2014}]' plugins/nextcloud || echo 'no dashes in the plugin'
grep -nP '[\x{2013}\x{2014}]' CHANGELOG.md | grep -i nextcloud || echo 'no dashes in the nextcloud entry'
```

Expected: `clean` (or only test-fixture text, which belongs in `tests/`, never in the plugin), and both `no dashes` lines.

- [ ] **Step 5: Final staging check.**

Run: `git status --short`
Expected: only the files named in this plan, all staged (`A` or `M` in the first column, nothing in the second), and nothing untracked.
