# Security

A working hardening posture for a Moodle 5.2 site. Treat this as a pre-flight checklist before letting users in, and as the diagnosis ladder when something's reported as a security concern.

## TLS and the `wwwroot`/sslproxy contract

The single most common misconfiguration. The rules:

| Topology | `wwwroot` | `sslproxy` |
|---|---|---|
| Direct HTTPS to Apache (no LB, certs on the web server) | `https://...` | unset (default `false`) |
| TLS terminated upstream (LB / nginx / ingress-nginx), HTTP between LB and app | **`https://...`** | **`true`** |
| Pure HTTP (dev only) | `http://...` | unset |
| Mixed (HTTP and HTTPS both work) | pick one | as above |

If you set `wwwroot` to `https://...` but Moodle thinks the request came in over HTTP (because it's terminated upstream and `sslproxy` is unset), every redirect / form / OAuth callback will mis-construct the URL and the site half-works.

Diagnostic:

```php
// Add to a temporary debug page; never leave on:
echo "isHTTPS: ", is_https() ? "yes" : "no", "\n";
echo "wwwroot: $CFG->wwwroot\n";
echo "sslproxy: ", $CFG->sslproxy ?? 'unset', "\n";
echo "REQUEST_SCHEME: ", $_SERVER['REQUEST_SCHEME'] ?? '?', "\n";
echo "HTTP_X_FORWARDED_PROTO: ", $_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '?', "\n";
```

`sslproxy = true` makes Moodle treat any request as HTTPS regardless of what the local PHP SAPI sees. Without it, Moodle generates `http://` URLs and the browser silently drops them as mixed content. **Always pair `sslproxy` with `reverseproxy = true` if you also want correct client-IP logging.**

## Cookies

| Setting | Production value |
|---|---|
| `$CFG->cookiesecure` | `true` (when `wwwroot` is https) |
| `$CFG->cookiehttponly` | `true` (always) |
| `session.cookie_samesite` (php.ini) | `Lax` minimum; `Strict` if no SSO redirect inbound |

`cookiesecure = true` without HTTPS makes all logins fail silently — the browser refuses to send the cookie, every page acts logged-out. Operators sometimes set it pre-emptively before flipping `wwwroot` to HTTPS; **set them in lockstep.**

## File and directory permissions

Recap from [stack-and-runtime.md](stack-and-runtime.md):

```
<dirroot>                    0755 root:www-data       (web reads, deploy user writes)
<dirroot>/config.php         0640 root:www-data
<dataroot>                   0770 www-data:www-data   (web user reads + writes)
<dataroot>/filedir           0770 www-data:www-data
```

`<dirroot>` MUST NOT be writable by `www-data`. If it is, an RCE in any plugin (a malicious image upload mishandled, a CVE in tinymce) becomes a full server takeover — the attacker can drop a webshell anywhere in `public/`. The deploy user (`root` or a dedicated user) writes the codebase; runtime PHP only writes to `<dataroot>`.

Auditing:

```bash
find /var/www/html -type d ! -perm 0755 2>/dev/null | head
find /var/www/html -writable -user www-data 2>/dev/null | head   # should be empty
ls -la /var/www/html/config.php   # should be 0640 root:www-data
```

## `$CFG->preventexecpath`

Set `$CFG->preventexecpath = true` to **block admins from configuring filesystem paths via the web UI** — paths to `clamscan`, `aspell`, `unoconv`, `gs` (ghostscript), `dot` (graphviz), etc.

Why this matters: an admin-level XSS or compromised admin account can otherwise set, e.g., `pathtoclam = /tmp/evil.sh`, then trigger an antivirus scan and execute arbitrary code. With `preventexecpath = true`, those paths are read-only and must be set in `config.php` — outside the attacker's reach.

```php
$CFG->preventexecpath = true;
$CFG->pathtoclam      = '/usr/bin/clamscan';   // if antivirus_clamav enabled
$CFG->aspellpath      = '/usr/bin/aspell';     // if spell-check enabled
$CFG->pathtodot       = '/usr/bin/dot';        // if Graphviz used
```

Reference: [config-dist.php line ~609](https://github.com/moodle/moodle/blob/v5.2.0/config-dist.php).

## Antivirus on user uploads

`antivirus_clamav` (shipped in core under `public/lib/antivirus/`) scans every file on upload. To enable:

1. Install ClamAV in the moodle container: `apt-get install clamav clamav-daemon`.
2. Site administration → Plugins → Antivirus → ClamAV → Enable.
3. Set scan target to `clamscan` or `clamdscan`.
4. Decide what to do on positive: **quarantine** (default — file is moved aside and the user gets a notice) or **error out**.

For a school environment, antivirus on uploads is usually appropriate. The cost is per-upload latency (~1–2 seconds) and the daemon's RAM footprint (~500MB–2GB).

## Headers / CSP

Moodle does not ship a default Content-Security-Policy. The recommended minimal set, injected via `$CFG->additionalhtmlhead`:

```html
<meta http-equiv="X-Content-Type-Options" content="nosniff">
<meta http-equiv="Referrer-Policy" content="same-origin">
```

Real CSP requires per-site tuning — Moodle uses inline scripts and styles in many places, and a strict CSP will break the editor, the calendar, and several plugins. Enable CSP **after** auditing with `Content-Security-Policy-Report-Only` for at least a week.

`X-Frame-Options` is set by Moodle automatically based on `$CFG->allowframembedding` — leave that off unless you have a documented reason to allow framing (LMS-in-LTI scenarios).

## CSRF and `sesskey`

Every state-changing form in Moodle includes a hidden `sesskey` field. The framework rejects POSTs whose `sesskey` doesn't match the user's session. The CLI does not have sesskeys; CLI scripts are gated by `define('CLI_SCRIPT', true)` plus the OS-level user check.

If you ever see "Invalid sesskey submitted, form not accepted" errors:

- The user's session expired between page load and form submit.
- The user has multiple tabs open and one had a stale sesskey.
- A reverse proxy is stripping cookies (rare).

Refresh the page; never disable sesskey checks.

## Authentication

Moodle ships with multiple auth plugins under [public/auth/](https://github.com/moodle/moodle/tree/v5.2.0/public/auth). The defaults relevant for school deployments:

| Plugin | When to enable |
|---|---|
| `manual` | Admin creates accounts. Default. |
| `email` | Self-registration via email confirmation. **Disable** unless you have a reason. |
| `oauth2` | Generic OAuth2 — Google, Microsoft, GitHub, ... Site admin → Server → OAuth 2 services. |
| `oidc` | OpenID Connect (incl. Azure AD / Entra). |
| `shibboleth` | SAML via Shibboleth SP. Common at universities. |
| `saml2` (contrib) | SAML2 IdP integration. |
| `db` | External database authentication. |
| `ldap` | LDAP / Active Directory. |
| `cas` | CAS SSO. |

The "Authentication" page lists all plugins; **only enabled plugins can authenticate**. A common audit issue is leaving `auth_email` enabled unintentionally — let any random visitor self-register. Disable everything except the auth methods the school actually uses.

## Password policy

`mdl_config` keys for the password policy:

```sql
SELECT name, value FROM mdl_config WHERE name LIKE '%password%' ORDER BY name;
```

Settings under Site administration → Security → Site security settings → Password policy:

- `passwordpolicy = 1` (enforce)
- `minpasswordlength = 12` (or per institutional policy)
- `minpassworddigits`, `minpasswordlower`, `minpasswordupper`, `minpasswordnonalphanum`
- `passwordreuselimit` (number of past passwords to disallow)
- `pwresettime` (minutes a reset link stays valid)

For school admin accounts, additionally enable two-factor auth via `tool_mfa` (shipped in core).

## Security report

Moodle has a built-in security audit at Site administration → Reports → Security checks. Equivalently from CLI:

```bash
sudo -u www-data php admin/cli/checks.php --filter=security
```

This runs the `\core\check\security\*` checks. The output is a list of pass/warn/fail items; **fix every fail before opening the site.**

## Update notifications

`$CFG->disableupdatenotifications`: in a containerized deploy where you upgrade by deploying a new image, set this to `true` so admins don't see the "an update is available" banner urging them to upgrade in-product (which would conflict with your image-driven upgrade flow).

`$CFG->disableupdateautodeploy = true`: prevents the in-product UI from triggering plugin installs. Recommended on locked-down deployments.

## Known CVEs and the moodle.org security advisory feed

The Moodle Security Advisory feed: [https://moodle.org/security/](https://moodle.org/security/). Patches land in minor releases (5.2.1, 5.2.2, ...) — keeping current with the minor releases is the primary defence. The Magneto Moodle image rebuild cadence is the operator's responsibility; flag any CVE that Moodle marks as "Serious" so the user can plan a re-image.

## What to do if you suspect a compromise

1. Maintenance mode on (`admin/cli/maintenance.php --enable`).
2. **Take a forensic backup** — DB dump and full `<dataroot>` and `<dirroot>` snapshot. Don't `rm` anything.
3. Check `mdl_user` for unexpected admin / manager role assignments:
   ```sql
   SELECT u.id, u.username, u.email, ra.contextid, r.shortname
   FROM mdl_role_assignments ra
   JOIN mdl_role r ON r.id = ra.roleid
   JOIN mdl_user u ON u.id = ra.userid
   WHERE r.shortname IN ('manager', 'admin', 'siteadmin')
   ORDER BY ra.timemodified DESC;
   ```
4. Check `mdl_logstore_standard_log` for `webservice/login` and `auth_login` from unexpected IPs.
5. Check `mdl_files` for recently-uploaded `.php`, `.phtml`, `.phar`, or `.pl` files:
   ```sql
   SELECT id, filename, mimetype, FROM_UNIXTIME(timecreated)
   FROM mdl_files
   WHERE filename ~* '\.ph(p|tml|ar)$|\.pl$'
   ORDER BY timecreated DESC LIMIT 50;
   ```
6. `find <dataroot>/filedir -name '*.php'` — should be empty.
7. Compare the codebase against the upstream tag with `git diff` if it's a git deploy, or `find <dirroot> -newer /tmp/install_marker -type f`.

This is enough to triage. Anything beyond is a forensic engagement; surface it to Clouve ops and the school's IT contact.
