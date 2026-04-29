# Playbook: Harden a fresh install

Use this playbook on a brand-new Moodle install (or any time the tenant asks "is this safe to expose?"). It walks through the checks and settings to apply before letting users in.

This is a checklist, not a step-by-step recipe — many of these are quick UI clicks. The order is roughly importance: the first 5 are non-negotiable; the rest are defense-in-depth.

## 1. Confirm HTTPS + cookie security

```sql
SELECT name, value FROM mdl_config
WHERE name IN ('wwwroot', 'cookiesecure', 'cookiehttponly');
```

Required state for production:

- `wwwroot` starts with `https://`
- `cookiesecure = 1`
- `cookiehttponly = 1`

If `wwwroot` is `http://`, the browser refuses to send the secure cookie and the site appears logged-out. **Match the env to reality**: if TLS is terminated upstream (LB / ingress), also set `$CFG->sslproxy = true` in `config.php` (see [reference/security.md](../reference/security.md)).

## 2. Lock down `config.php` permissions

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo ls -la /var/www/html/config.php'
```

Should be `-rw-r----- 1 root www-data ...` (mode `0640`). Fix:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo chown root:www-data /var/www/html/config.php && sudo chmod 0640 /var/www/html/config.php'
```

`<dirroot>` itself should NOT be writable by `www-data`:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'find /var/www/html -writable -user www-data 2>/dev/null | head'
```

Should return at most a tiny number of files (often empty). Anything unexpected, investigate before continuing.

## 3. Disable self-registration unless explicitly wanted

Site administration → Plugins → Authentication → Manage authentication.

For most schools, only the auth methods they actually use should be **enabled** (eye icon visible). Disable:

- `Email-based self-registration` (`auth_email`) — unless the school wants self-signup.
- Any auth plugin that's not in active use.

The "Self registration" dropdown at the bottom of the page should be set to "Disable" unless `auth_email` is intentional.

## 4. Set `$CFG->preventexecpath = true`

Add to `<dirroot>/config.php`:

```php
$CFG->preventexecpath = true;
$CFG->pathtoclam      = '/usr/bin/clamscan';   // if antivirus_clamav is enabled
$CFG->aspellpath      = '/usr/bin/aspell';     // if spell-check is enabled
$CFG->pathtodot       = '/usr/bin/dot';        // if Graphviz is used
```

Why: blocks an admin (or anyone who can post as admin via XSS) from setting `pathtoclam = /tmp/evil.sh` and triggering arbitrary code execution. See [reference/security.md](../reference/security.md).

After editing `config.php`, restart Apache to pick up the change:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'sudo apachectl graceful'
```

## 5. Run the security check report

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/checks.php --filter=security'
```

Or browse to Site administration → Reports → Security checks.

**Every red item must be resolved before opening the site.** Common items:

- "No login attempt limit" — set a brute-force lockout under Site administration → Security → Site security settings.
- "No password policy" — set a password policy.
- "Frame embedding allowed" — `$CFG->allowframembedding = 0` unless you have a documented LTI use case.
- "Default user role has too many capabilities" — review the default role.

## 6. Set a password policy

Site administration → Security → Site security settings → Password policy.

Recommended baseline:

| Setting | Value |
|---|---|
| Password policy | Enabled |
| Minimum length | 12 |
| Minimum digits | 1 |
| Minimum lowercase | 1 |
| Minimum uppercase | 1 |
| Minimum non-alphanumeric | 1 |
| Password rotation | per institution policy |
| Password reuse limit | 5 |

For staff/admin accounts, also enable two-factor auth: Site administration → Plugins → Admin tools → Multi-factor authentication.

## 7. Disable update notifications and auto-deploy

In a containerized deploy where you upgrade by deploying a new image:

```php
// in config.php
$CFG->disableupdatenotifications = true;
$CFG->disableupdateautodeploy    = true;
```

This prevents the in-product UI from urging admins to update (which would conflict with image-driven upgrades) and from triggering plugin installs from the UI.

## 8. Lock cron to CLI only

```php
// in config.php
$CFG->cronclionly = true;
```

Disallows triggering cron via HTTP. The CLI cron (`admin/cli/cron.php`) is the only path. Verify:

```bash
curl -sI "http://${MOODLE_HOST}/admin/cron.php"
# Expected: 403 Forbidden or similar — anything but 200.
```

## 9. Enable antivirus on uploads (optional but recommended for schools)

If the moodle container has ClamAV available:

Site administration → Plugins → Antivirus → ClamAV plugin → Enable.

Set:
- Scanner: `clamscan` (CLI) or `clamdscan` (faster, daemon)
- Path: `/usr/bin/clamscan` (or wherever — `which clamscan` over SSH)
- Action on positive: "Treat files as broken" (default — quarantines and notifies)

Without this, malicious uploads can sit in `<dataroot>/filedir/` until someone downloads them. The cost is per-upload latency (~1–2 s).

## 10. Review the default role's capabilities

Site administration → Users → Permissions → Define roles.

The "Authenticated user" role applies site-wide to every logged-in user. Default capabilities are mostly harmless, but:

- `moodle/site:senddefaultmessage` — can the role message anyone? Restrict if not desired.
- `moodle/user:viewdetails` — can they look up other users' profiles? Restrict for student-heavy sites.
- `moodle/grade:edit` — should NEVER be on the authenticated-user role (it isn't, by default; if it is, your role config is broken).

## 11. Add minimal headers via `$CFG->additionalhtmlhead`

```php
// in config.php
$CFG->additionalhtmlhead = '<meta http-equiv="X-Content-Type-Options" content="nosniff">'
                         . '<meta http-equiv="Referrer-Policy" content="same-origin">';
```

Real CSP requires per-site tuning — start with `Content-Security-Policy-Report-Only` for at least a week before enforcing. See [reference/security.md](../reference/security.md).

## 12. Configure outgoing email properly

Site administration → Server → Email → Outgoing mail configuration.

Required:
- SMTP hosts: `<your smtp host>:587` or `:465`
- SMTP secure: `tls` (587) or `ssl` (465)
- SMTP auth type: `LOGIN` (most common)
- SMTP user / pass
- "No-reply address": a real mailbox at the SMTP host's allowed-sender list

Send a test email (Site administration → Server → Email → Test outgoing mail configuration). If the test email arrives, you're good. If not, see [reference/troubleshooting.md → Email isn't sending](../reference/troubleshooting.md).

## 13. Confirm cron is firing

```sql
SELECT FROM_UNIXTIME(MAX(timestart)) AS last_cron FROM mdl_task_log;
```

If this is more than a couple minutes ago, cron is broken. See [reference/cron-and-tasks.md](../reference/cron-and-tasks.md).

## 14. Confirm backups are configured

Site administration → Courses → Backups → Automated backup setup.

Set:
- Active: Yes
- Schedule: a quiet time (typically 02:00 local)
- Save to: a path with sufficient space (or to object storage via `tool_objectfs` if installed)
- Maximum backup retention: per institution policy (default 1 = keeps last week of dailies)

This is course-level backup. The DB + dataroot snapshot is a separate, operator-driven backup — see [scripts/backup.sh](../scripts/backup.sh).

## 15. Final verification

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/checks.php'
```

All checks pass. If anything is red, address it before this checklist is "done".

## Tell the user

Report:

- What you set / changed.
- What's still red on the checks dashboard, and why.
- Anything that requires their action (out-of-band password setting, choosing whether to enable self-registration, etc.).
- Any item from the list above that you skipped, and why.

This list is conservative. For low-stakes internal sandboxes you can skip several items; for any site that will hold student data, the list should be applied as written.
