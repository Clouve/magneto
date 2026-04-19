# Security Posture

## File permissions

After the Clouve image's `upgrade.sh` runs (which happens on every install and every version bump):

```
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html
```

Every file is `0755`. Apache runs as `www-data`. This is the broadest-read + narrowest-write the standard `php:8.3-apache` base image produces. `config.php` inherits the same `0755` — readable by anyone who can read the volume, which in-container is only `root` and `www-data`.

**What to watch for:**
- A tenant uploading a PHP shell into `uploads/`. Apache serves `/uploads/` by default; Gibbon's `.htaccess` in `uploads/` SHOULD prevent PHP execution — verify on any 500 diagnosis that the `.htaccess` is intact. Look for `php_flag engine off` or `RemoveHandler .php` inside `uploads/.htaccess`.
- Anything writing outside `/var/www/html/uploads/`. The app itself shouldn't need to; a module that does is suspicious.

## Installer lockdown

Gibbon does not ship a "rename `/installer` after install" story. The `installer/` directory stays at `/var/www/html/installer/` forever. It is **protected by the presence of `config.php`**: the installer code itself early-returns if `config.php` already exists and has a valid `$version`. That is the lockdown.

Implications:
- Do not delete `/var/www/html/config.php` without a backup; doing so "unlocks" the installer and anyone hitting `/installer/install.php` can re-initialize the DB.
- If a tenant has a stale `config.php` from a prior instance and it points at a real DB, the installer refuses to run — good. But if `config.php` is empty or syntactically broken, the installer re-opens — bad. A corrupt `config.php` is an installer-re-exposure risk, not just a 500.

## Authentication & sessions

- Native auth: `gibbonPerson.username` + hashed password in `gibbonPerson.password`. Strong-password policy controlled by `gibbonSetting(scope='User Admin', name='passwordPolicy*')`.
- Password-reset flow writes to `gibbonLog` and emails the user.
- Session store: `gibbonSession` table.
- CSRF: **all POST forms** now carry nonce + CSRF token handling — added in v29.0.00. A module that circumvents this (e.g. ships its own forms without the helpers) is a red flag.
- SSO: Google OAuth and Microsoft Graph supported via `config.php` settings. Credentials for those live in `config.php` NOT the DB.

## 2FA

- Package: [`robthree/twofactorauth`](https://github.com/RobThree/TwoFactorAuth) — TOTP.
- Per-user enable in preferences; admin can enforce for role categories.
- Secrets stored in `gibbonPerson.` fields. Backup-restore round-trips them correctly.
- **Recovery for a locked-out user:** an admin resets 2FA via User Admin → Manage Users → Reset Two Factor Auth. No CLI shortcut — do not help the user bypass 2FA by SQL-zeroing the secret unless they prove they are the tenant admin and understand they're disabling their own protection.

## Impersonate User

**New in v30.0.00.** The "admin can log in as another user" capability is gated behind a `config.php` flag — see the v30 release note: `The Impersonate User action must be manually enabled in the config.php file`. The precise flag name is `$enableImpersonation = true;` (verify in the `config.twig.html` template / the module code before editing).

If a tenant asks to turn impersonation on:
1. Explain: this allows any admin with the `Impersonate User` action to become any user, including students and parents, without their password. It is a high-privilege capability.
2. Show them the `config.php` change (a single line).
3. Confirm they understand, then add the line. Restart is NOT required (PHP reads `config.php` on every request), but advise them to verify in an incognito window.

## Known CVEs (from the v30 release notes)

- **CVE-2025-56573** — Library module: SQL injection via unsanitised user input. Fixed in v30.0.00. Any tenant on ≤29.x is vulnerable; this alone is sufficient justification to upgrade.
- Earlier CVEs exist in the upstream changelog but are fixed in versions this app doesn't ship.
- For new CVEs: check `github.com/GibbonEdu/core/security/advisories` for current advisories before confidently claiming "you're on a safe version."

## Hardening checklist for a fresh install

Each of these can be verified/adjusted from Gibbon's admin UI or from `config.php`. Playbook: [playbooks/harden-fresh-install.md](../playbooks/harden-fresh-install.md).

1. **Change the `GIBBON_PASSWORD` bootstrap** (if the tenant used the default). Clouve's `applicationPassword` type auto-generates one, so if they did a default install this is already safe.
2. **Set a strong password policy** via `gibbonSetting(scope='User Admin', name='passwordPolicy*')`. Minimum length 12 is a reasonable target.
3. **Enable HTTPS-only**. Our image exposes port 80 and relies on Clouve's ingress to terminate TLS. Verify the tenant's `$GIBBON_URL` is `https://` and their ingress is issuing a real (non-self-signed) cert.
4. **Disable self-registration** (System Admin → Public Registration settings) unless the school specifically wants applicants to create accounts without staff review.
5. **Set `cuttingEdgeCode = 'No'`** in `gibbonSetting` unless the tenant explicitly wants beta features. Auto-install already sets this.
6. **Set `statsCollection = 'N'`** (no phone-home telemetry to the Gibbon project). Auto-install already does this.
7. **Review the Admin role's permissions** — Gibbon's shipped `Admin` role is broad. If the tenant has multiple admins, consider a narrower role for day-to-day.
8. **Lock down the `installer/` directory** — not needed at the apache level; Gibbon's own gate on `config.php` covers it. Verify `config.php` is non-empty and syntactically valid.
9. **2FA for all admin accounts.** The `passwordPolicyTwoFactor` settings control enforcement scope.
10. **Cron daemon is running.** `service cron status` in the container. Without it, password-reset emails, behaviour letters, and overdue library notices never fire.

## What this skill should and should not do regarding security

**Do:**
- Advise on hardening.
- Run diagnostics that don't change state.
- Patch a known CVE by upgrading (following the upgrade playbook).
- Rotate credentials (DB: via env vars + pod restart; admin user: via Gibbon UI).

**Don't:**
- Disable 2FA for an account the user hasn't proven ownership of.
- Reset an admin password via SQL when the user could do it via the Forgot Password flow.
- Edit file permissions to "fix" a 500 without diagnosing why Apache is getting a permission-denied.
- Enable impersonation silently.
- Store or log tenant API keys or DB passwords.
