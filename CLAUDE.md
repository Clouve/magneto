# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Magneto** is a Docker Compose-based system for packaging containerized applications (WordPress, Moodle, Gibbon, LimeSurvey, Odoo, OwnCloud, Nextcloud, SuiteCRM, AI Studio) for deployment in Kubernetes-based marketplace environments. It provides standardized structures for single applications and multi-application bundles.

## Common Commands

### Build Images
```bash
# Build a specific app (multi-platform: amd64 + arm64)
./build.sh wordpress
./build.sh apps/wordpress

# Build all apps
./build.sh --all

# Build and push to registry
./build.sh wordpress --push

# Rebuild from scratch, uploading every layer fresh (prunes the builder's cache first)
./build.sh wordpress --push --prune

# Environment-specific builds
./build-e2e.sh wordpress     # r.clv.zone/e2eorg (the local kind cluster's Harbor)
./build-dev.sh wordpress
./build-prod.sh wordpress
./build-uat.sh wordpress

# UAT and prod pushes are gated: build-uat.sh/build-prod.sh --push refuse an app until
# `bash tests/new-disk-start.test.sh <app>` has passed on its current source (see "Testing on new cluster disks").
# --skip-new-disk-check pushes anyway, for emergencies only.
# A rebuilt image with openssh-server goes to an environment only after that environment's AI Assistant image is
# magneto-agent 4.5.3 or later (it saves no sibling host keys) and its AI Assistants have restarted onto it. Where such
# an image runs, the AI Assistant image never goes back below 4.5.3 (README.md, "The clouve-ops SSH channel").
./build-uat.sh wordpress --push
```

### Switch Registry Users
Docker stores one credential per registry, and the Docker Desktop credential
helper silently ignores overwrites — `docker login` as a new user "succeeds"
but pushes keep using the old (project-scoped) robot. Always logout first:
```bash
./logout.sh                  # remove stored credential for r.clv.zone (default)
./logout.sh my.registry.io   # ...or for another registry
docker login r.clv.zone -u 'robot$<project>+<name>' -p '<secret>'
```

### Push Failures on r.clv.zone
- **`unexpected status from HEAD request ... 401 Unauthorized`**: the robot belongs to
  another Harbor project. Robots are project-scoped and `build-e2e.sh` pushes to
  `e2eorg`, so use a `robot$e2eorg+...` login (issued on app.clouve.dev to ca@clouve.com).
- **`unknown: blob sha256:... not found`**, with only never-pushed images succeeding:
  Harbor's database was recreated but its storage kept older repositories (a rebuilt
  kind cluster that reused the shared e2e bucket). BuildKit remembers which repositories
  already hold each layer and asks Harbor to mount it from there instead of uploading;
  the new database has never seen the layer, so Harbor rejects the mount. Fix: add
  `--prune` (full rebuild, then every layer is uploaded). strato's `setup-harbor` now
  gives each new kind cluster its own storage folder, so this shouldn't recur there.

### Start / Stop Applications
```bash
# Start an app
./start.sh wordpress
./start.sh apps/wordpress

# Start fresh (remove volumes)
./start.sh wordpress --cleanup

# New volumes start like new cluster disks: root's top folder, lost+found, none of the image's files (see
# "Volumes on a cluster" below). --docker-volumes gives Docker's copy of the image instead, for debugging only.
./start.sh wordpress --docker-volumes

# Stop an app
./stop.sh wordpress

# Stop and remove persistent data
./stop.sh wordpress --cleanup

# Agent-enabled apps: give the local AI Assistant model access from your shell.
# Local runs only; Clouve deployments use a managed key and never read these.
export MAGNETO_AGENT_LLM_BASE_URL=https://llm.example.com MAGNETO_AGENT_LLM_KEY=<litellm-key>
# ...or: export ANTHROPIC_API_KEY=<your-anthropic-key>
./start.sh wordpress
```

### Monitoring & Debugging
```bash
# View logs (follow mode)
./logs.sh wordpress -f

# View last N lines for a specific service
./logs.sh wordpress wordpress -n 50

# Check health and resource usage
./status.sh wordpress
```

### Testing URL Change Detection
```bash
# Test dynamic URL substitution without modifying files
./test.sh apps/wordpress
./test.sh apps/wordpress custom.domain.com custom2.domain.com 8090
./test.sh apps/limesurvey
```

### Testing build.sh
```bash
# --prune flag: stubbed docker, builds and pushes nothing, no daemon needed
bash tests/build-prune.test.sh
# Every build pulls its base image (--pull), a --tag push names that one tag and no :latest, and a push refuses an
# app whose Dockerfiles name a base with no tag. Stubbed docker
bash tests/build-pull.test.sh
# Every FROM and COPY --from names a tag, so --pull never moves a base to a new major version. No Docker needed
bash tests/dockerfile-base-tags.test.sh
```

### Checking manifests
```bash
# Every apps/*/ and bundles/*/ marketplace manifest against the publish wizard's limits (every container's admin path
# and version), the container name rule and the host alias rules (README.md, "Host aliases"). Needs python3 with PyYAML
./check-manifests.sh
# The checks themselves, on manifests written for each case (good ones and one per rule)
bash tests/check-manifests.test.sh
# The AI Assistant's listing copy: each agent-enabled container's title is the app's own name. A sentence that offers
# more usage, names an allowance, says what the price includes or says no API key is needed says it of a paid plan,
# and a description that mentions any of these also says that a free trial or free services use the customer's own
# Claude subscription. Needs python3 with PyYAML
bash tests/listing-ai-copy.test.sh
# The same rules on one text, such as a listing's own description from the publish wizard (the SEO page's About
# text, which no manifest holds). It prints which rules pass, never the text. Save the text in a file first, so that
# quotes and $ in it reach the test unchanged
bash tests/listing-ai-copy.test.sh --text "$(cat description.txt)"
# The rules themselves, on texts written to break each one and on texts that keep them all
bash tests/listing-ai-copy-rules.test.sh
```

### Testing on new cluster disks
```bash
# Every app and bundle must start the way a cluster starts a new install: each volume a new disk, each container
# judged by its own x-clouve-healthcheck probe within Kubernetes' deadline, then a 90 s settle period. Builds the app
# first (host platform) and records a pass for that exact source on this machine, which build-uat.sh and build-prod.sh
# require before they push (a run with a shorter --settle doesn't count). Run it after every change to an app's image,
# entrypoint or compose files, on the machine that will push. Needs Docker, python3 with PyYAML
bash tests/new-disk-start.test.sh <app-or-bundle>      # or --all
# After a fix to an app that already has installs: the previous build installs, the fix restarts on the same volumes,
# and each volume's top folder must keep its owner and mode. This run records no pass, so a push needs the plain run
# above as well
bash tests/new-disk-start.test.sh <app> --upgrade-from <previous dated tag>
# Starting from what an environment's tenants run: pull each container's image the listing pins, by digest (a listing
# that pins :latest: read the digest :latest has now, before any push), tag every one of them with one name of its own
# (r.clv.zone/e2eorg/<repo>:envpin), then run --no-build --upgrade-from envpin and check the log names that tag for
# every service. The runner refuses --upgrade-from latest and a tag only some of the target's images have
# (tests/new-disk-upgrade-tags.test.sh)
docker pull <registry>/<org>/<repo>@sha256:<digest> && docker tag <registry>/<org>/<repo>@sha256:<digest> r.clv.zone/e2eorg/<repo>:envpin
bash tests/new-disk-start.test.sh --no-build --upgrade-from envpin <app>
# A pass counts only for a git work tree (its source hash comes from git ls-files), so a UAT or prod build runs from a
# work tree at the release's commit, never from a git archive copy, and never with --skip-new-disk-check:
git -C <magneto checkout> worktree add --detach <folder> <tag or commit> && cd <folder>   # then the two runs above
# The volume helper, start.sh, the runner and the push gate themselves, on fake apps (about 10 minutes)
bash tests/new-disk-volumes.test.sh
# --upgrade-from's image lookup on a fake docker: no latest, no target with the tag on only some images
bash tests/new-disk-upgrade-tags.test.sh
```

### Testing the AI Assistant personas
```bash
# Renders every apps/<app>/image/context/<app>/CONTEXT.md.tpl with envsubst, as the Magneto Agent does, using
# Kubernetes-style hosts (tkt-7-<app>): each persona must give the SSH command for ${<APP>_HOST}, never write a
# password into the text (clouve-ops, database or Odoo master: name the variable and fetch it with
# ${NAME:-$(clv-secret NAME)}, which works on an agent with clv-secret and on one without, never
# ${THE_VARIABLE} or printenv), leave no {user.*}/{org.*} placeholder, and AI Studio's must say the user's work
# is on the workspace. Needs envsubst.
bash tests/persona-hosts.test.sh
# The gibbon, moodle and wordpress personas' commands run as written: every ssh command passes
# StrictHostKeyChecking=accept-new and UserKnownHostsFile=/dev/null (checked with ssh -G, which connects to nothing),
# SSHPASS is set on each command, no tail of Apache's error log, no password rotation through the environment, and
# wordpress runs wp through the skill's wp.sh. ai-studio's sshpass commands and nextcloud's SSH options too. Needs
# ssh and python3
bash tests/persona-ssh-commands.test.sh
```

### Testing the Gibbon image
```bash
# school-year.sh: the Current school year comes from the install date, not the seed data (no MySQL or Docker needed)
bash tests/gibbon-school-year.test.sh
```

### Testing the Moodle image
```bash
# upgrade.sh keeps the plugins that admins added through Moodle's UI when a newer Moodle replaces the code tree. It
# holds back, in clouve/upgrade-stash/, the ones the new Moodle ships itself or whose version.php says they won't work
# with it (incompatible, a supported range that covered the old branch but not the new, a missing dependency). When
# Moodle's upgrade fails twice, it holds back the added plugin Moodle failed on, or all of them when Moodle names none.
# A site with an added plugin newer than the new Moodle's own copy isn't touched (status 3; the entrypoint keeps the old
# code running). A start that is cut off runs the upgrade again, after clearing the upgrade lock that Moodle leaves
# when its upgrade is cut off. The old Moodle's Classic theme is never copied back, and after the upgrade a config.php
# line that only forces Classic becomes a comment (php -l checked). The last run uses the real metadata of the previous
# pinned Moodle and the Dockerfile's, downloaded once (about 190 MB, checksums checked) into
# ~/.cache/magneto/moodle-tarballs. Needs Docker: it runs in php:8.3-apache, the image's base
bash tests/moodle-upgrade-plugins.test.sh
# The same, with real plugins as the added ones: a folder of plugin ZIPs as Install plugins takes them
MOODLE_PLUGIN_ZIPS=<folder> bash tests/moodle-upgrade-plugins.test.sh
# A real site through a real upgrade: the image at --from installs a site with made-up data, the added plugins (ZIPs
# or stand-ins) and the Classic theme everywhere, then the image at --to (default latest) starts on the same volumes.
# Checks that the upgrade runs once in maintenance mode, the plugins and data are there, everything is on Boost, GET /
# answers 200, cron runs and a restart doesn't upgrade again. --cut-off kills the container during Moodle's database
# upgrade and starts it again; --newer-core-plugin checks that a site with an added plugin newer than the new Moodle's
# own copy stays on its old code and says why. About 5 minutes. Needs Docker and python3
bash tests/moodle-site-upgrade.test.sh --from <previous dated tag> [--plugin-zips <folder>] [--cut-off]
bash tests/moodle-site-upgrade.test.sh --from <previous dated tag> --newer-core-plugin
# The Moodle and Moodle MySQL images ship no SSH host keys, and each container makes its own (./build.sh moodle first).
# Needs Docker
bash tests/moodle-ssh-host-keys.test.sh [--tag <tag>]
```

### Testing the WordPress image
```bash
# A real install with no network: WORDPRESS_DEBUG='false' (or off, no, in any case) leaves WP_DEBUG off as Apache and
# wp.sh see it, 1 keeps it on, and the admin password is set byte for byte with nothing in the log. Needs Docker
bash tests/wordpress-debug.test.sh [--image wordpress=<ref> --image wordpress-mariadb=<ref>]
```

### Testing the AI Studio image
```bash
# The deployment's address shows the fixed page on port 80 (busybox httpd as nobody, link from AI_STUDIO_APP_HOST),
# never the Vite dev server; 5173 still serves Vite for previews. --static needs no Docker
bash tests/ai-studio-page.test.sh [--static | --image <ref>]
```

### Testing the Nextcloud image
```bash
# Installer scripts (lib.sh, the probe, the settings script, the hooks, the build's edits to the official entrypoint), run inside nextcloud:35.0.2-apache with no network. Needs Docker
bash tests/nextcloud-image.test.sh
# The root entrypoint in the built image (./build.sh nextcloud first): cleaned login and email in PID 1's environment, MYSQL_* only before the first install, CLOUVE_OPS_PASSWORD kept from Valkey and later processes, a missing admin password, a new disk's root-owned top folder given to www-data, the official entrypoint's lock opened read-only and version.php read as www-data. Needs Docker
bash tests/nextcloud-entrypoint.test.sh
# The database image: Nextcloud's settings, the buffer pool sized from the memory limit, the clouve-ops sshd. Needs Docker
bash tests/nextcloud-mariadb.test.sh
# Both compose files against the platform's rules (variables, probe, listing text). Needs only python3 with PyYAML, like check-manifests.sh
bash tests/nextcloud-manifest.test.sh
```

### Testing the Odoo image
```bash
# addons_path names /mnt/extra-addons as a pattern, so an empty folder logs no warning
bash tests/odoo-addons-path.test.sh
# Without Docker: odoo.conf locks the database manager (list_db = False, and a dbfilter, never db_name, for the
# deployment's database); lib.sh's secret-name rule is magneto-agent's, and odoo_unset_secrets takes every secret and
# PGPASSWORD out of Odoo's environment; the markers are written under env -i; the Dockerfile copies lib.sh
bash tests/odoo-entrypoint.test.sh
# The Odoo persona's commands run as written: the config on every odoo command, backup.sh piped into
# the Odoo container, restarts by SIGHUP to PID 1, nothing that prints odoo.conf's passwords, both host-key options
# and SSHPASS on every clouve-ops@ command, and what the image does to the database manager
bash tests/odoo-persona-commands.test.sh
# tini is PID 1: no zombies after clouve-ops SSH sessions, the SIGHUP restart still works, and docker stop ends Odoo
# and then PostgreSQL in time (PostgreSQL with a clean shutdown). Builds both Odoo images and runs them with no network.
# Needs Docker
bash tests/odoo-init.test.sh
# No image with the clouve-ops sshd ships SSH host keys (Odoo, WordPress, Gibbon, Nextcloud, AI Studio and their
# database images), and each container makes its own. Naming images limits the run. Needs Docker
bash tests/ssh-host-keys.test.sh [--image <name>=<ref>]... [<name>...]
# odoo-postgres's gosu is built from upstream's source with the Dockerfile's Go (past CVE-2025-68121): root's,
# mode 755, static, and it still drops to postgres. Needs Docker
bash tests/odoo-postgres-gosu.test.sh
# Odoo runs as the odoo user and no password is on a command line or in the log: through the first start and a
# SIGHUP restart, for odoo commands root runs with sudo, and on a new and an upgraded disk; odoo.conf is odoo's,
# mode 600; the clouve-ops SSH check passes before and after the restart. No drop to odoo gets a secret or
# PGPASSWORD (a stand-in setpriv logs names). The database manager is locked from the first install on (a backup
# POST with the right master password gets no ZIP), backups and odoo db load still work, /web/login serves with a
# second database, and the AI Assistant's one-task open step opens and closes it. Modules of root's in
# /mnt/extra-addons go to odoo at every start, and the pass over /var/lib/odoo runs once per volume. Links and files
# that code running as odoo could leave in /var/lib/odoo (the install marker as a link, backups as a file or a link)
# never make root write to or change anything outside it, and the database container keeps CLOUVE_OPS_PASSWORD out
# of PostgreSQL's environment while tini keeps it for the AI Assistant. Needs Docker
bash tests/odoo-non-root.test.sh
# The checks of ssh-host-keys.test.sh, with a fake docker: no daemon needed
bash tests/ssh-host-keys-checks.test.sh
```

### Checking the database images
```bash
# Each database image: zombies after 40 clouve-ops SSH sessions, and what happens when a background job left by a
# session is killed (PostgreSQL can end its connections and restart). Under tini, sshd's parent has to be PID 1.
# Also: no CLOUVE_OPS_PASSWORD in the database server's own environment, a clean docker stop, and a clouve-ops sign-in
# after a restart. Needs Docker
bash tests/db-image-zombies.test.sh
# gosu in the MySQL and MariaDB images is 1.20 built with a current Go (the bases' 1.19 was built with Go 1.24.6,
# CVE-2025-68121), with the base's path, owner and mode, and still starts the server as mysql. Needs Docker
bash tests/db-image-gosu.test.sh [--image <name>=<ref>]... [<name>...]
# Passwords stay off command lines in the Gibbon, Moodle and WordPress images: update-config.sh logs none and gives
# mysql, sed and awk none (config.php gets it as a PHP string), Moodle's install gives php none, and no image script
# passes one as an option or expands one into an outside command's arguments, double-quoted text included (the scan
# reads quotes as the shell does, and checks itself on a probe first). Fake mysql, sed, awk and php; no Docker
bash tests/installer-db-password.test.sh
# CLOUVE_OPS_PASSWORD stays out of Apache in the three app containers (a PHP probe as www-data finds none, PID 1 holds
# none), clouve-ops still signs in, no password reaches the log, and Moodle's admin signs in with the password given
# at install. Installs each app for real with no network. Needs Docker
bash tests/app-ops-password.test.sh [--image <name>=<ref>]... [wordpress|gibbon|moodle]
```

## Architecture

### Project Layout
```
apps/<app-name>/           # Individual application packages
bundles/<bundle-name>/     # Multi-app combinations
build.sh                   # Multi-platform image builder
start.sh / stop.sh         # Orchestration scripts
logs.sh / status.sh        # Monitoring utilities
test.sh                    # URL substitution testing
```

### Application Package Structure
Each app in `apps/` contains:
- `docker-compose.yml` — Local development/testing configuration
- `clv-docker-compose.yml` — Marketplace manifest with Clouve metadata extensions
- `image/Dockerfile` — Custom application container
- `image/build.config` — Image name and registry configuration
- `image/installer/entrypoint.sh` — Container initialization logic
- Optional: `image/<db>/Dockerfile` for custom database containers

### Compose Files Per App
The key distinction between the compose files:
- **`docker-compose.yml`**: Uses `.data/` volume mounts for local persistence, supports `TEST_DOMAIN`/`TEST_PORT` env var substitution for URL testing
- **`clv-docker-compose.yml`**: Marketplace manifest — no host volume mounts, uses Clouve-specific YAML extensions for orchestration metadata
- **`clv-docker-compose-basic.yml`** (retired on 2026-10-18): the AI-disabled twin of the marketplace manifest. No app has one now. Each app has one manifest, and the AI Assistant is chosen at install. An agent-capable app (wordpress, moodle, gibbon, odoo, nextcloud; also `bundles/education-kit/`) carries `x-clouve-agent: enabled: true` in that manifest, and its appTitle is the app's own name ("Moodle", never "Moodle with AI Assistant"), because the deployment page shows the title whether or not the customer added the AI Assistant. The images also run without the AI Assistant: the `clouve-ops` sshd in them starts only when the platform injects `CLOUVE_OPS_PASSWORD`.

### Clouve Metadata Extensions
The `clv-docker-compose.yml` files use custom YAML extensions to describe how the marketplace orchestrates the app:

- **`x-clouve-metadata`**: Per-container purpose (`app`, `database`), resource limits, protocol
- **`x-clouve-environment-types`**: Declares how each env var is handled:
  - `static`: fixed value
  - `secret`: auto-generated secure password
  - `containerReference`: reference to another container's name/IP
  - `applicationUrl` / `applicationHost`: replaced with the container's own URL (`https://<host>`) or host
  - `applicationAliasUrl` / `applicationAliasHost`: the same for one of the container's host aliases; the value is the alias's name, which must be an alias of that container
  - `applicationUsername` / `applicationPassword`: user credentials
  - `userConfigurable`: user can modify at deploy time
- **`x-clouve-healthcheck`**: HTTP/TCP/command-based health checks for the marketplace
- **`x-clouve-bundle-metadata`**: App title, version, icon (only the path the publish wizard's upload wrote for the listing's own organization; leave it out of a manifest you write), description, admin path (`adminPath`)
- **`x-clouve-host-aliases`** (release 4.5.2): up to 3 more hosts for a public Frontend or Backend container. Alias `studio` on a deployment at `acme-12.clouve.app` answers at `studio-acme-12.clouve.app`, a sibling host under the environment's wildcard certificate (never `studio.acme-12.clouve.app`), on the same container and port; the app tells its hosts apart by `Host`. Each entry has `name` (required) and the text fields of `x-clouve-bundle-metadata`: `appTitle` (the wizard asks for it, and for the owning container's; without one, the name with a capital first letter), `appDescription` (empty: "<title> application"), `appVersion` (the owner's when empty) and `adminPath` (a container's rules, which the owner's own `adminPath` then has to keep too). The icon is a PNG uploaded in the wizard, with no manifest field; a manifest downloaded from the wizard leaves alias icons out, so they are uploaded again after a re-upload. The customer sees each alias as its own app with its own custom-domain field, and a domain saved on an alias goes into the owning container's environment. Rules, checked at upload, save and publish: a name matches `^[a-z][a-z0-9]{1,14}$`; it isn't `default`, `ai`, `icon`, `gcp`, `aws`, `azure`, `clv`, `magneto-agent` or `oauth2-proxy`; it isn't a container's name (lower-cased, public or not) or another alias's; never on the AI Assistant; no `{{` or `}}` in an alias's title or description, or in the owning container's title, description or version. Every save after the first publish also keeps the first published version's aliases (adding, removing or moving one means a new listing), and installs and copies keep every host of the deployment within 63 characters. `./check-manifests.sh` checks magneto's manifests against the rules a file can show, and needs a container with aliases to state `isPublic` and `purpose` in its `x-clouve-metadata` (an upload would guess them). Spec: README.md, "Host aliases".
- **`x-clouve-volumes`**: Volume sizing and human-readable descriptions
- **`x-clouve-agent`**: AI Assistant opt-in for agent-capable apps: `enabled`, `skills.url` (plus optional `skills.git`), and optional `advanced.sidecarPullTimeout` / `advanced.passthroughEnv`. There is no `advanced.client` (one built-in client; uploads reject any value other than `null` or `claude-code`) and no API key: Clouve manages model access, with one key per paid deployment (a free trial or free services use the customer's own Claude subscription). `quota` is retired (Clouve sets the usage allowance; uploads ignore it); the publisher's AI Assistant fee is a pricing setting in the publish wizard, not a manifest field. Spec: README.md, "AI Assistant (`x-clouve-agent`)".

Rules thermo checks at upload, every save, a reviewer's download and publish (release 4.5.3; spec: README.md, "Values Clouve refuses"):
- No `{{` or `}}` in variables, `image`, the health check path, volumes, chart fields, global secret names or the AI Assistant's `skills.url` and `skills.git.username`, and no placeholder: Clouve writes its own expressions, such as `tkt-{{ticket.id}}-<name>`, after the check (single braces such as `{user.userEmail}` are fine). Variable and global secret names keep Kubernetes' env-name rule: letters, digits, `.`, `-` and `_`, no digit first, not `.`, `..` or a `..` start. No line breaks or other control characters in `image`, the health check path, volume names, mount paths or chart fields.
- Every container's `adminPath`, with host aliases or without: `/` first, then letters, digits and `- _ . ~ % /`, no `//`, at most 256 characters.
- A container's name (`x-clouve-metadata.containerName`) is a DNS-1123 label: 1 to 63 lower-case letters, digits and hyphens, starting and ending with a letter or a digit.
- Icons (`appIcon`, alias icons, the listing's logo) come only from the listing's own organization's uploads.

Template variables available in manifest values: `{user.userEmail}`, `{user.firstName}`, `{org.name}`

### Bundles
Bundles in `bundles/` combine multiple apps with integration:
- Each service's environment variables can cross-reference other services via `containerReference` type
- Used for SSO, enrollment sync, shared databases between apps
- Example: `bundles/education-kit/` integrates Gibbon + Moodle

### Build System
`build.sh` reads `image/build.config` from each app directory to determine image names and registry paths. It uses Docker Buildx for multi-platform builds (`linux/amd64` + `linux/arm64`).

### Volumes on a cluster
A new volume on a cluster is an empty disk: a top folder of root's (mode 755), `lost+found`, and none of the files the image keeps at that path. Docker named volumes copy the image's folder in instead, which is how Nextcloud's first GKE install broke on 2026-10-26 while every local test passed. So an image's entrypoint starts as root and, before the app's user runs anything, makes each volume's top folder usable when it is root's; it keeps the files it needs outside volume paths and copies them in when they're missing; it treats `lost+found` as empty; and it switches to the app's user only after that. A fix for an app with installs changes only what a working install never has, and passes `--upgrade-from`. `./start.sh` and `tests/new-disk-start.test.sh` reproduce the cluster's volumes locally. The full rules are in README.md, "Volumes on a cluster".

### The clouve-ops SSH channel
An image the AI Assistant works in runs an sshd for `clouve-ops`. It ships no SSH host keys (`rm -f /etc/ssh/ssh_host_*` in the `RUN` that installs openssh-server), so each container makes its own at start; every image does this since 4.5.5. AI Assistants older than magneto-agent 4.5.3 save each sibling's key and refuse a changed one, so a rebuilt image with openssh-server goes to an environment only after its AI Assistant image is 4.5.3 or later and its AI Assistants have restarted onto it, and the AI Assistant image never goes back below 4.5.3 where such an image runs. PID 1 has to reap what SSH sessions leave behind: tini is PID 1 when the server doesn't reap them (Odoo, MySQL, MariaDB) or takes one for a crashed process of its own (PostgreSQL then ends every connection and restarts). A database image also starts its sshd detached, `( start-clouve-ops-sshd.sh & )`, so that sshd's parent is tini. Every image unsets `CLOUVE_OPS_PASSWORD` once its sshd start has its own copy, before it execs a server that runs code a tenant controls or reaches: the database server, or Apache and the app (PHP reads Apache's environment); `tests/app-ops-password.test.sh` and `tests/db-image-zombies.test.sh` check it. Both Odoo images and the four MySQL and MariaDB images do all of this. The full rules are in README.md, "The clouve-ops SSH channel".

### AI Studio (`apps/ai-studio/`)
The AI Studio app is an Ubuntu 26.04 LTS workspace **pre-seeded with a running MERN starter project** (Node.js 22 LTS, MongoDB 7.0, Express API on `:4000`, Vite React frontend on `:5173`, mongo-express on `:8081` — all supervised by `supervisord` as PID 1; there is no systemd in the container). It is **not** a UI host — it is a sibling workspace operated by the Magneto Agent. The user talks to the agent in the chat UI (provided automatically because `x-clouve-agent: enabled: true` is always set in [apps/ai-studio/clv-docker-compose.yml](apps/ai-studio/clv-docker-compose.yml)), and the agent SSHes in as `clouve-ops` (passwordless sudo) to iterate on the seeded project at `/home/clouve-ops/projects/starter/`, install software, run services, and verify deploys. In a cluster deploy the dev servers are reached through the fleet clv-proxy at `https://<port>-<workspace-id>.<base>/`, which signs the user in first. The deployment's own address goes to port 80, where an image-owned supervisor program (`page`, busybox httpd as nobody) serves a fixed page that points to the AI Assistant at `ai-<AI_STUDIO_APP_HOST>` (an `applicationHost` variable); before 4.5.5 it showed the Vite dev server to anyone. Four volumes (`/home`, `/usr`, `/opt`, `/var`) persist across pod restarts, so apt-installed packages, user files and Mongo data survive. The agent's behavioral contract lives in the `ai-studio` skill at [magneto-skills/plugins/ai-studio/](../magneto-skills/plugins/ai-studio/); the per-tenant persona is templated from [apps/ai-studio/image/context/ai-studio/CONTEXT.md.tpl](apps/ai-studio/image/context/ai-studio/CONTEXT.md.tpl); the seed app sources live in [apps/ai-studio/image/seed/](apps/ai-studio/image/seed/). Local dev: `./build.sh ai-studio && ./start.sh ai-studio`, then browse the seeded app at `http://localhost:5173` (API `:4000`, mongo-express `:8082`) or `ssh -p 2222 clouve-ops@localhost` (password `clouve_ops_dev_password`, set in [apps/ai-studio/docker-compose.yml](apps/ai-studio/docker-compose.yml)).

## Known Issues

### Untrusted TLS certificates break WebSocket (ttyd terminal) on Kubernetes
The Magneto Agent's web terminal (ttyd) relies on WebSocket (`wss://`). Browsers silently reject WebSocket connections when the TLS certificate is not trusted — the page and HTTP requests work (user accepted the cert warning), but `new WebSocket("wss://...")` fails before the request ever leaves the browser. Symptoms: the terminal iframe loads but stays blank; the AI client never spawns (or appears to spawn-and-exit); server logs show repeated `/_clv/chat/token` fetches with zero `/_clv/chat/*/ws` entries. This bites any deployment that includes `x-clouve-agent: enabled: true` — including AI Studio.

**Root cause on the kind / clv local cluster:** The `selfsigned` cert-issuer strategy installs the `gcp-prod` ClusterIssuer with `spec.selfSigned: {}` — each tenant ingress gets a unique self-signed leaf with no shared CA, so no amount of OS-keychain trust fixes them. Accepting the browser cert warning lets HTTP requests through but `new WebSocket("wss://...")` still rejects the connection.

**Diagnosis:**
```bash
# Check if the cert chain has no real issuer (empty issuer = self-signed leaf, no CA)
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -subject

# Confirm the ClusterIssuer is selfSigned and not CA-backed
kubectl get clusterissuer gcp-prod -o yaml | grep -A1 'spec:'
```

**Fix (kind / clv local clusters):** Pick the `dev` cert-issuer strategy — not `selfsigned` — when bringing up the local cluster. The `cluster/action` dispatcher only prompts for the strategy during `setup*` actions (see [strato/cluster/action](../../strato/cluster/action) lines 64–74, where `CERT_ISSUER_STRATEGY_ARR=("selfsigned" "dev")` is gated to actions `setup`, `setup-load-balancer`, and `setup-cert-issuers`):
```bash
./strato/cluster/action clv create                 # create the kind cluster
./strato/cluster/action clv setup                # pick "dev" at the strategy prompt
# (or, to re-issue on an existing cluster:)
./strato/cluster/action clv setup-cert-issuers   # pick "dev"
```
The `dev` strategy replaces the `selfSigned` `gcp-prod` ClusterIssuer with a **real public ACME issuer** — Google Trust Services (Google Public CA) — that solves DNS-01 against the `clouve.app` Cloud DNS zone (so the kind cluster needs valid GCP credentials for project `clouve-develop`). The resulting leaf certs chain to a publicly-trusted root already in every browser's trust store, so `wss://` upgrades validate without any local CA-trust step. See [strato/cluster/k8s/manifests/clouve-e2e/cert-issuers/dev/](../../strato/cluster/k8s/manifests/clouve-e2e/cert-issuers/dev/) for the issuer manifest that gets copied into place by `cluster/action` (lines 122–127).

**Fix (real prod clusters):** Same `dev`-style ACME ClusterIssuers — see the manifests linked above for working HTTP-01 / DNS-01 examples.

Docker deployments are unaffected (HTTP only, no TLS).
