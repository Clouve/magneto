# Cron & Scheduled Tasks

Modern Moodle is **cron-driven** — almost every asynchronous behaviour (email digests, scheduled reports, file thumbnail generation, completion recalc, course backups, log rotation, message processing, search index updates) runs through the task scheduler. Cron must fire **every minute**, every minute, on at least one node.

## The minute cron

The recommended frequency since Moodle 3.0 is **every 60 seconds**. The script is [admin/cli/cron.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/cron.php).

```cron
# /etc/cron.d/moodle
* * * * * www-data /usr/bin/php /var/www/html/admin/cli/cron.php > /dev/null 2>&1
```

In Kubernetes, run this as a `CronJob` with `schedule: "* * * * *"` and `concurrencyPolicy: Forbid` so a slow run doesn't double up.

In the Magneto Moodle pod, cron is launched by the entrypoint of the moodle container (or a sidecar), not by an external scheduler — confirm with `ps aux | grep cron.php` over SSH.

## CLI flags

From [admin/cli/cron.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/cron.php) `cli_get_params(...)`:

| Flag | Default | Purpose |
|---|---|---|
| `--keep-alive=N` | `null` | **Daemon mode.** Keep running for `N` seconds, executing tasks as they appear, instead of returning after one pass. Useful when you want a long-lived runner instead of a per-minute spawn. |
| `--list` / `-l` | `false` | List currently-running tasks (queries `mdl_task_log_running`) and exit. |
| `--stop` / `-s` | `false` | Politely ask all running cron processes to stop after their current task. |
| `--force` / `-f` | `false` | Skip the throttle that prevents concurrent runs. **Dangerous** — only use when you've manually verified no other cron is active. |
| `--enable` / `--disable` | `false` | Toggle `$CFG->cron_enabled`. |
| `--disable-wait=SEC` | `false` | Disable cron after waiting up to `SEC` seconds for current tasks to finish. |
| `-h`, `--help` | | |

## Task taxonomy

Two kinds of tasks live in the scheduler:

| Kind | Where defined | When it runs | Example |
|---|---|---|---|
| **Scheduled** | `db/tasks.php` of any plugin | On a cron-like schedule (minute/hour/day/dayofweek/month) | `core\task\file_temp_cleanup_task` runs daily |
| **Adhoc** | Queued in code via `\core\task\manager::queue_adhoc_task(...)` | Once, ASAP, then dropped from queue | Course backup queued by user action |

The framework lives in [public/lib/classes/task/](https://github.com/moodle/moodle/tree/v5.2.0/public/lib/classes/task). Key entry points:

| Class / file | Role |
|---|---|
| `\core\task\manager` | Schedules, dequeues, and dispatches tasks. |
| `\core\task\scheduled_task` | Base class for periodic tasks. |
| `\core\task\adhoc_task` | Base class for one-shot tasks. |
| `\core\task\task_executor` | Runs a single task with locking + error capture. |
| `\core\lock\lock_factory` | Provides cluster-safe locks. Cron uses this to avoid double-execution across nodes. |

## Inspecting tasks

```bash
# Show currently-running tasks:
sudo -u www-data php admin/cli/cron.php --list

# Show scheduled tasks (admin/cli/scheduled_task.php):
sudo -u www-data php admin/cli/scheduled_task.php --list

# Run a single named scheduled task immediately (ignoring schedule):
sudo -u www-data php admin/cli/scheduled_task.php --execute='\core\task\file_temp_cleanup_task'

# Show queued adhoc tasks:
sudo -u www-data php admin/cli/adhoc_task.php --showsql --execute   # runs them all
```

[admin/cli/scheduled_task.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/scheduled_task.php) and [admin/cli/adhoc_task.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/adhoc_task.php) are the surgical tools. `admin/cli/cron.php` is the dispatcher.

## Per-task config in `mdl_task_scheduled` and `mdl_task_adhoc`

Scheduled-task definitions live in code (`db/tasks.php`) AND in the DB (`mdl_task_scheduled`). The DB row holds the **runtime overrides** — admin can pause a task, change its schedule, or reset it to defaults via Site administration → Server → Tasks → Scheduled tasks.

Adhoc tasks live entirely in `mdl_task_adhoc` until executed; one row per pending invocation, with the serialised task class and arguments.

## Locking

Cron's safety story rests on locks. By default Moodle uses [public/lib/classes/lock/file_lock_factory.php](https://github.com/moodle/moodle/blob/v5.2.0/public/lib/classes/lock/file_lock_factory.php) which writes lockfiles under `<dataroot>/lock/`. On a single node this is fine; **on a cluster, the lock dir MUST be a shared volume** (NFS, RWX PVC) — otherwise two nodes both grab the same lock and run the same task.

Alternatives selected via `$CFG->lock_factory`:

| Class | Backing |
|---|---|
| `\core\lock\file_lock_factory` (default) | Filesystem; needs shared mount on a cluster |
| `\core\lock\db_record_lock_factory` | A row in `mdl_lock_db`; works on any DB |
| `\core\lock\mysql_lock_factory` | MySQL/MariaDB `GET_LOCK()` — fast, but per-connection scoping has subtleties |
| `\core\lock\postgres_lock_factory` | Postgres advisory locks |

For a cluster on RDS Postgres, `postgres_lock_factory` is the right choice. For a cluster on MariaDB, `mysql_lock_factory`. For a single-node Magneto Moodle pod, the file factory is fine — the moodledata volume is the natural shared backing.

## Long-running tasks

Some tasks (course backup, log archive, search index rebuild) take minutes to hours. The runner re-checks the lock TTL periodically and extends it. If the cron process is killed mid-task, the task ends up "stuck" until the lock TTL expires, after which another runner picks it up.

When a task hangs:

```bash
# 1) Identify the runner.
sudo -u www-data php admin/cli/cron.php --list

# 2) If it's actually wedged, stop it gently.
sudo -u www-data php admin/cli/cron.php --stop

# 3) If --stop doesn't work in a reasonable time, look at mdl_task_log for the failed run.
SELECT * FROM mdl_task_log WHERE result = 1 ORDER BY timestart DESC LIMIT 5;
```

Never `kill -9` a cron process unless the task is provably hung — the lock won't be released until the TTL.

## What runs in cron

A short non-exhaustive list, so you know what breaks if cron stops:

- Scheduled email digests
- Forum post emails
- Quiz attempt close-on-deadline
- Course completion recomputation
- Recycle-bin purge (`tool_recyclebin`)
- File temp cleanup
- Log archival
- Search index updates
- Backup automation (`automated_backups.php`)
- Adhoc tasks queued by user actions: course backup, course restore, big imports, send-message-to-large-group

If the user reports "no emails are being sent" or "course completion isn't updating" or "scheduled backups aren't running", **the first thing to check is whether cron has fired in the last 60 seconds.**

```sql
SELECT MAX(timestart) AS last_cron FROM mdl_task_log;
```

If that's more than a few minutes ago, cron is broken — go to [troubleshooting.md](troubleshooting.md).

## Web cron (legacy)

Pre-3.0 sites triggered cron via HTTP at `/admin/cron.php`. This still exists but is **off by default** in 5.x via `$CFG->cronclionly = true`. Leave it that way; HTTP cron is a security and performance footgun (it can be DoS'd, and PHP request timeouts cap how long a task can run).

If `cronclionly = false`, the operator must also set `$CFG->cronremotepassword` and trigger via `/admin/cron.php?password=<token>`. There is essentially no reason to do this on a modern install.
