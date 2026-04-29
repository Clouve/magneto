# Shell Access (`clouve-ops` SSH)

You have an interactive shell into both side containers via SSH as the `clouve-ops` operator account. The account is dedicated to this app's DevOps agent (you), pre-created in both images, and has **passwordless sudo for everything** — treat it as effective root inside those containers, gated only by the safety rules in [SKILL.md](../SKILL.md).

This file describes when SSH is the right tool vs. the TCP `mysql`/`curl` channels, and the safety gates that apply over the SSH hop.

## Authenticating

The per-pod password lives in the env var `CLOUVE_OPS_PASSWORD` — already in your shell env. Use `sshpass -e`, which reads from `SSHPASS` rather than the command line, so it never lands in shell history or `ps`:

```bash
# Make the per-pod password available to sshpass (do this once per shell):
export SSHPASS=$(printenv CLOUVE_OPS_PASSWORD)

# Open an interactive shell in the moodle container:
sshpass -e ssh clouve-ops@${MOODLE_HOST}

# Open an interactive shell in the moodle-mysql container:
sshpass -e ssh clouve-ops@${MOODLE_DB_HOST}

# Run a one-shot command (preferred for scripted operations):
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    "sudo tail -50 /var/log/apache2/error.log"
```

The first connection prints a host-key fingerprint warning — accept it once (`StrictHostKeyChecking` interactively, or pass `-o StrictHostKeyChecking=accept-new` on the first run; the host key is captured to `~/.ssh/known_hosts` for subsequent connections).

## When SSH is the right tool

The SSH hop is unambiguously needed for any of:

- **Tailing PHP / Apache logs.** `/var/log/apache2/error.log` and `/var/log/apache2/access.log` are inside the moodle container — not reachable any other way.
- **Running Moodle CLI scripts.** `admin/cli/*.php` lives at `/var/www/html/admin/cli/` inside the moodle container. Use `sudo -u www-data php /var/www/html/admin/cli/<script>.php` so the script runs as the web user with the right `$CFG->dataroot` permissions.
- **Inspecting `/var/www/html` filesystem.** Listing plugin directories, checking `<dataroot>` permissions, locating a config file.
- **Restarting Apache or PHP-FPM.** `sudo systemctl reload apache2` or `sudo apachectl graceful`. Required after a `config.php` edit (the change isn't picked up until the worker recycles).
- **Inspecting MariaDB / Postgres internals on the DB host.** `/etc/mysql/`, `/var/lib/mysql/`, slow query log files, `mysqltuner`, `pg_stat_*` views via the on-host socket.
- **Writing to `<dataroot>` for diagnostics.** E.g. `chown -R www-data:www-data <dataroot>` after a volume remount.

## When NOT to use SSH

The SSH hop is overkill (and slower) for:

- **Routine SQL.** From the AI Studio container you can `mysql -h ${MOODLE_DB_HOST} ...` or `psql -h ${MOODLE_DB_HOST} ...` over TCP — no SSH hop needed.
- **HTTP probes.** `curl -sI http://${MOODLE_HOST}/login/index.php` works directly.
- **Reading files that the script wrapper already exposes.** [scripts/php-info.sh](../scripts/php-info.sh) and [scripts/verify-health.sh](../scripts/verify-health.sh) are designed to give you the data you need without SSH.

The TCP channels (mysql, curl) are faster and produce more reliable transcripts. Reach for SSH only when you need filesystem access or a process inside the target container.

## Safety gates apply over SSH too

Having a `sudo` prompt does not change the safety story. Every gate from [SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow) applies whether the command runs locally in AI Studio or via SSH:

- `sudo apachectl stop` is destructive — gate it.
- `sudo systemctl stop mariadb` (on the DB host) is destructive — gate it.
- `sudo rm -rf /var/www/html/...` is destructive — gate it.
- `sudo mysqldump --all-databases > /tmp/dump.sql` is fine (read-only) but **its output may contain secrets** — be careful where you put the file and what you do with it next.
- `sudo php /var/www/html/admin/cli/upgrade.php` IS the upgrade — gate it via [playbooks/upgrade-moodle.md](../playbooks/upgrade-moodle.md).
- `sudo -u www-data php /var/www/html/admin/cli/maintenance.php --enable` is fine (idempotent state change) and you should announce it before running.

The general rule: if the same command would require user ack when run from AI Studio, it requires user ack when run via SSH.

## Common one-shot commands

```bash
# Tail Apache error log (most useful one-shot — diagnoses 500s)
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo tail -100 /var/log/apache2/error.log'

# Tail Moodle's own error log (Moodle writes some warnings via PHP error_log)
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo tail -100 /var/log/apache2/error.log | grep -i moodle'

# Check the running Moodle code version
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo \$CFG->version, PHP_EOL;"'

# List currently running scheduled tasks
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --list'

# Check whether an upgrade is pending
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --is-pending; echo "exit: $?"'

# Read the effective config value for a setting
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cfg.php --name=lang'

# Check disk usage on the dataroot volume
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'df -h /var/moodledata'

# Check directory permissions on dataroot
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'ls -la /var/moodledata | head'

# Reload Apache after a config.php change
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo apachectl graceful'

# On the DB host: show MariaDB / Postgres version
sshpass -e ssh clouve-ops@${MOODLE_DB_HOST} 'sudo mariadb --version'
sshpass -e ssh clouve-ops@${MOODLE_DB_HOST} 'sudo -u postgres psql -c "SELECT version();"'
```

## What you do NOT do over SSH

- Edit `<dirroot>/config.php` by hand. Use the env-var-driven path: change the env in the pod definition, restart the pod. The image's entrypoint regenerates `config.php` from env on boot. (See [reference/configuration.md](configuration.md).)
- Install plugins by `git clone`-ing into `<dirroot>/local/`. Plugins are part of the *image*. Hand-installed plugins disappear on the next pod restart. Surface this as a feature request to Clouve ops.
- Modify the Moodle codebase under `<dirroot>` for any reason. Same rule.
- Stop or restart MariaDB / Postgres. Even with sudo, this is a tenant-impacting action — gate it and prefer to escalate to Clouve ops.
