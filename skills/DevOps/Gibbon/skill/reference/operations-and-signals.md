# Operations & Signals

## What "healthy" looks like

A healthy Gibbon container in this app satisfies all of the below. Run these checks whenever the user asks "is this working?"

1. **HTTP**. `curl -sI http://gibbon/index.php` from inside the AI Studio container returns `200 OK`. Login page renders (html contains `Gibbon`).
2. **DB reachability**. `mysqladmin -h gibbon-mysql -u gibbon -p"$GIBBON_DB_PASSWORD" ping` returns `mysqld is alive`.
3. **`gibbonSetting(version) == /var/www/html/version.php $version`**. If they drift, an upgrade is pending.
4. **Cron running**. Inside the `gibbon` container: `service cron status` → `cron is running`. From AI Studio you can't check this directly — you'd infer from whether `/var/log/gibbon-cron.log` is progressing, but you also can't read that file from AI Studio. See "Limits" below.
5. **Uploads writable**. `uploads/cache/` owned by `www-data`, mode 755. Gibbon writes compiled templates here on every request.
6. **No PHP fatal in Apache log**. `docker logs gibbon | tail -n 200` — no `PHP Fatal error`, no `mysqli_sql_exception`.

The Clouve healthcheck configured in [apps/gibbon/clv-docker-compose.yml](../../clv-docker-compose.yml) is an HTTP GET against `/index.php`, port 80, initial delay 60s, interval 30s, timeout 15s, failure threshold 15. A container that fails this for 7.5 minutes is restarted by Clouve's orchestrator.

## Where logs live

### In the `gibbon` container (reachable only via `kubectl exec` — not from AI Studio)

| Path | What's in it | Rotation |
|---|---|---|
| `/var/log/apache2/access.log` | Apache access log | Docker-managed (stdout) |
| `/var/log/apache2/error.log` | Apache errors + PHP errors | Same |
| `/var/log/gibbon-cron.log` | Our cron wrapper's output (one banner per task start/finish) | Not rotated — grows unbounded |
| `/var/log/gibbon-cron.state/<script>.lastrun` | Per-CLI-task unix timestamp of last run | Overwritten each run |
| `/var/www/html/var/log/` | Gibbon's own Monolog output (depending on settings) | Gibbon-managed |
| stdout / stderr (via `docker logs <container>`) | Apache access + error | Docker-managed |

### Accessible to the tenant

- **Gibbon UI: System Admin → View Logs** — reads `gibbonLog`, the in-DB event log (logins, setting changes, module installs, rollover runs). Not the Apache log.
- **Clouve platform logs** — whatever view Clouve surfaces for the tenant's pod.

### Accessible from AI Studio

From inside this container, you can:
- `curl` Gibbon's HTTP endpoint for page responses.
- Query the DB (read-only with gibbon user, write with the same).
- Read `gibbonLog` via SQL.
- NOT directly read files inside the `gibbon` container. Not `/var/log/gibbon-cron.log`, not `/var/www/html/config.php`.

If the tenant needs to see Apache logs, tell them: (a) use `./logs.sh gibbon` from the host, (b) use the Clouve platform's pod-log view, or (c) escalate to Clouve ops.

## The in-container cron daemon

Source: [apps/gibbon/image/installer/gibbon-cron.sh](../../image/installer/gibbon-cron.sh). Details in [apps/gibbon/README.md](../../README.md#scheduled-tasks).

The container runs Debian `cron` as a service. `/etc/cron.d/gibbon-cron` is rendered from `$GIBBON_CRON_INTERVAL` at container start and invokes `gibbon-cron.sh` on that interval (default `* * * * *`). The wrapper:

1. Bails early if `/var/www/html/config.php` is missing or empty (install sentinel).
2. Iterates a hard-coded map of Gibbon CLI scripts → per-task interval in minutes.
3. For each, checks `/var/log/gibbon-cron.state/<script>.lastrun`; if enough time has passed, runs `/usr/local/bin/php /var/www/html/cli/<script>.php`.
4. Logs `Started` / `Completed` / `Failed` banners with timestamps to `/var/log/gibbon-cron.log`.

### Task schedule (intervals in minutes)

| Script | Interval | Purpose |
|---|---|---|
| `userAdmin_statusCheckAndFix` | 1440 | Daily: verify and fix user statuses |
| `userAdmin_removeStaleNotifications` | 1440 | Daily: prune `gibbonNotification` |
| `attendance_dailyIncompleteEmail` | 1440 | Daily: email teachers who haven't taken attendance |
| `attendance_dailyIncompleteEmail_byClass` | 1440 | Daily: same, class-level breakdown |
| `attendance_weeklySummaryEmail` | 10080 | Weekly: attendance summary |
| `behaviour_dailySummaryEmail` | 1440 | Daily: behaviour events digest |
| `behaviour_lettersNegative` | 1440 | Daily: auto-generate negative-behaviour letters |
| `behaviour_lettersPositive` | 1440 | Daily: auto-generate positive-behaviour letters |
| `schoolAdmin_parentDailyEmailSummary` | 1440 | Daily: parent digest |
| `schoolAdmin_parentWeeklyEmailSummary` | 10080 | Weekly: parent digest |
| `schoolAdmin_tutorDailyEmailSummary` | 1440 | Daily: tutor digest |
| `library_overdueNotification` | 1440 | Daily: library overdue-item emails |
| `finance_staffPettyCashNotification` | 1440 | Daily: petty cash reminders (staff) |
| `finance_studentPettyCashNotification` | 1440 | Daily: petty cash reminders (students) |
| `staff_FirstAidExpiryNotification` | 1440 | Daily: first-aid cert expiry alerts |

### Not scheduled (deliberately)

- `system_backgroundProcessor.php` — a worker invoked programmatically by Gibbon with `processID` / `processKey` arguments (e.g. async report generation). **Do not add it to the schedule.** The wrapper omits it by design.

### Diagnosing "are my scheduled tasks running?"

The canonical diagnostic surface lives in the `gibbon` container. Because you can't `kubectl exec` from AI Studio, walk the user through it:

```
# Inside the gibbon container (the user or Clouve ops runs this):
service cron status                            # Is cron alive?
cat /etc/cron.d/gibbon-cron                    # Rendered crontab
tail -F /var/log/gibbon-cron.log               # Follow the scheduler log
ls -la /var/log/gibbon-cron.state/             # Per-task lastrun timestamps
```

From the AI Studio side, you can still check indirect signals:
- `SELECT * FROM gibbonLog WHERE title LIKE '%cron%' OR title LIKE '%notification%' ORDER BY timestamp DESC LIMIT 20;` — some scripts write to the event log.
- `SELECT * FROM gibbonNotification WHERE timestamp > NOW() - INTERVAL 2 DAY ORDER BY timestamp DESC LIMIT 20;` — if notifications are being created, something is running.
- Ask the user to try to trigger a behaviour-letter manually and check if it arrives on the expected cadence.

## Clearing the upload cache

`/var/www/html/uploads/cache/` holds compiled twig templates and cached rendered pages. It's wiped on every `entrypoint.sh` run. If you see stale rendering (e.g. a CSS change didn't take effect after an upgrade), a pod restart is the fix.

The only way to clear it without a restart: ask the tenant to use **System Admin → Cache Manager → Clear Cache** from the Gibbon UI. Do not try to clear it from the AI Studio side — you can't write to that volume.

## Metrics / observability the tenant sees

- Clouve platform dashboards: pod uptime, memory/CPU, bandwidth.
- Gibbon admin UI: **System Admin → System Overview** shows version, last login, basic counts.
- Gibbon admin UI: **System Admin → View Logs** (the `gibbonLog` event log).

Claude Code should not intermediate any of this — surface it as "your platform dashboard has this" or "run this query to see."

## Limits of what this skill can observe

Every skill user should know, and you should say so when relevant:
- We cannot see Apache logs from AI Studio.
- We cannot see `/var/log/gibbon-cron.log` from AI Studio.
- We cannot run `service cron status` from AI Studio.
- We cannot read or write files inside the `gibbon` container's volume from AI Studio.
- We CAN: query Gibbon's DB over the pod network, HTTP-fetch Gibbon's public pages, and read anything in the AI Studio container's own filesystem.

When a user asks a diagnostic question whose answer lives inside the `gibbon` container, be explicit about that boundary. Ask them to run the command or escalate, rather than inventing output.
