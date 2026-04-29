# Playbook: Rotate the admin password (or any user's password)

Use this playbook when the tenant has lost or wants to rotate the primary admin password, or when forcing a password reset for a specific user account.

## Preconditions

- [ ] User has acknowledged that the rotation will log the affected user(s) out of any active sessions.
- [ ] You have a way to communicate the new password back to the user **out-of-band** (not in chat). The user should set the password themselves on the next login. The right pattern is "set a temporary password and force a password change on first login."
- [ ] If rotating the primary admin (uid=2): user has confirmed there's no other admin available, OR they've already proven their identity to you in a way that justifies it.

## Steps

### 1. Confirm the target user

```sql
SELECT id, username, email, deleted, suspended, FROM_UNIXTIME(lastlogin) AS last
FROM mdl_user
WHERE username = '<the username>'
   OR email = '<the email>';
```

There should be exactly one row, `deleted = 0`, `suspended = 0`. If there are two users with the same email, surface to the user — Moodle allows non-unique emails by default but the password reset flow is ambiguous.

### 2. Use Moodle's CLI tool

[admin/cli/reset_password.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/reset_password.php) is the right path — it hashes the password, updates `mdl_user.password`, invalidates the user's existing sessions, and logs the change.

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    "sudo -u www-data php /var/www/html/admin/cli/reset_password.php --username='<the username>' --password='<temporary-strong-random>'"
```

Notes:

- `--password` accepts the new password directly. Generate a strong random one (`openssl rand -base64 24` is fine).
- The script does NOT print the password back, but **the password is in your shell history and the SSH process tree for the duration of the call**. To avoid this:
  ```bash
  read -s -p "New password: " NEWPASS && echo
  sshpass -e ssh clouve-ops@${MOODLE_HOST} \
      "sudo -u www-data php /var/www/html/admin/cli/reset_password.php --username='<user>' --password=\"$NEWPASS\""
  unset NEWPASS
  ```

### 3. Force a password change on next login

Set the user's `mdl_user.password_change_required` flag so Moodle redirects them to the change-password page on first login:

```sql
UPDATE mdl_user
SET preference_auth_forcepasswordchange = 1
WHERE username = '<the username>';
```

Wait — that's actually a user *preference*, not a column. The right way is via `mdl_user_preferences`:

```sql
INSERT INTO mdl_user_preferences (userid, name, value)
VALUES (
  (SELECT id FROM mdl_user WHERE username='<the username>'),
  'auth_forcepasswordchange',
  '1'
)
ON DUPLICATE KEY UPDATE value = '1';
```

For PostgreSQL, replace `ON DUPLICATE KEY UPDATE` with:

```sql
INSERT INTO mdl_user_preferences (userid, name, value)
VALUES ((SELECT id FROM mdl_user WHERE username='<the username>'), 'auth_forcepasswordchange', '1')
ON CONFLICT (userid, name) DO UPDATE SET value = excluded.value;
```

Or, more cleanly, use the admin UI: Site administration → Users → Accounts → Browse list of users → click the user → Edit → "Force password change".

### 4. Verify

The user can now log in with the temporary password and is immediately redirected to the password-change page.

```sql
SELECT u.username, p.name, p.value
FROM mdl_user u
JOIN mdl_user_preferences p ON p.userid = u.id
WHERE u.username = '<the username>'
  AND p.name = 'auth_forcepasswordchange';
```

Should show `value = '1'`.

### 5. Communicate the temp password

Out-of-band — call, secure messaging, password manager, NOT chat or email. Tell the user:

- The temporary password.
- That they must change it on first login.
- That their existing sessions are invalidated.

### 6. Audit log

The reset is recorded in `mdl_logstore_standard_log`:

```sql
SELECT FROM_UNIXTIME(timecreated), action, target, userid, ip
FROM mdl_logstore_standard_log
WHERE eventname = '\core\event\user_password_updated'
  AND objectid = (SELECT id FROM mdl_user WHERE username='<the username>')
ORDER BY timecreated DESC LIMIT 5;
```

This is your evidence the rotation happened.

## Special case: the primary admin (uid=2) is the only admin

If the tenant has lost the only admin credential, you can also create a NEW admin via direct SQL (last resort) — but the cleaner path is to use `admin/cli/reset_password.php` for the existing primary admin.

If for some reason the primary admin user is broken (e.g. `deleted = 1` somehow):

1. Surface to the user — this is unusual and worth understanding why.
2. Take a backup before doing anything.
3. To un-delete: `UPDATE mdl_user SET deleted = 0 WHERE id = 2;` — but Moodle's "soft delete" sets `username` to a placeholder; you may also need to reset `username` and `email`. Use Moodle UI's bulk-actions "Restore deleted user" if available.

This is not a fast workflow — accept the time cost and stay cautious.

## Special case: SSO-managed accounts

If the user is authenticated via SSO (`auth_oauth2`, `auth_shibboleth`, etc.), `mdl_user.password` is not used. Resetting it does nothing — the user authenticates against the IdP, not Moodle's local DB.

```sql
SELECT username, auth FROM mdl_user WHERE username = '<the username>';
```

If `auth` is anything other than `manual` or `email`, the password reset has to happen at the IdP, not in Moodle. Surface this to the user.

## What NOT to do

- Don't `UPDATE mdl_user SET password = MD5('newpass')` or any direct hash. Moodle uses bcrypt with a salt; raw MD5 / SHA writes will be rejected at login.
- Don't reuse the same temp password across multiple users.
- Don't write the new password to chat. Even ephemeral chat content can be screenshotted and shared.
- Don't bypass the `auth_forcepasswordchange` preference — making the user change immediately is a hard requirement for "you reset their password" flows.
