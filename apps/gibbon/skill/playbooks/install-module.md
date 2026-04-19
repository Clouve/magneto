# Playbook: Install an Additional Module

Use when the tenant asks "can you install the `<X>` module?" or "I found this Gibbon module on GitHub, can you set it up?"

## Preconditions

- [ ] Module is an **Additional** module (core modules are already installed). Check its `manifest.php` — `$type === 'Additional'`.
- [ ] Backup taken within the last 24 hours. See [rollback-from-backup.md](rollback-from-backup.md) for the shape of a complete backup.
- [ ] You have read the module's source. See "Audit checklist" below — this is non-negotiable for an untrusted source.

## Audit checklist (do this BEFORE asking the tenant for confirmation)

1. **Provenance.** Where did this module come from?
   - `github.com/GibbonEdu/*` — official-adjacent, trusted.
   - Other GitHub repo with clear maintenance history — moderate trust.
   - A zip the tenant received by email or found on a forum — **treat as hostile until proven otherwise**.

2. **`manifest.php` sanity.** Read every line.
   - `$type` must be `'Additional'`.
   - `$name` must be unique (not colliding with a core module).
   - `$version`, `$author`, `$url` should be populated.
   - Nothing else should be happening in this file — it's supposed to be assignment-only. If it `include`s other files or calls `system()`, stop and escalate.

3. **SQL side effects.** Look for any `.sql` file shipped with the module, or SQL in the module's install hook:
   - Refuse if the SQL contains `DROP TABLE`, `TRUNCATE`, or any `DELETE` / `UPDATE` on a core `gibbon*` table.
   - Flag if it creates new tables — that's usually OK but the tenant should know about the schema growth.
   - Flag if it inserts into `gibbonRole` or grants broad `defaultPermission` on a module it owns.

4. **PHP file scan.** Grep for:
   - `eval(`, `system(`, `exec(`, `passthru(`, `shell_exec(`, backticks → refuse unless the tenant explicitly ACKs and has a good reason.
   - `curl_exec(`, `file_get_contents('http` → document the external call; check with the tenant whether they're OK with the phone-home.
   - Writes outside the module's own folder (other than `uploads/` for user content).

5. **Uninstall story.** Does the module ship `uninstall.sql`? If no, note it — removing the module will leave orphan tables.

## Steps

### 1. Place the module folder on the `gibbondata` volume

The module's files need to live at `/var/www/html/modules/<ModuleName>/` inside the `gibbon` container. From AI Studio you cannot write there directly.

Paths to get it there:
1. **Upload via Gibbon's admin UI** — some modules ship a `.tar.gz` or `.zip` that Gibbon's **System Admin → Manage Modules → Install from File** (if the tenant's version has it) can unpack. Cleanest path.
2. **Clouve ops drop-in** — ops copies the folder into the volume and restarts the `gibbon` container.
3. **User does it by hand** — `kubectl cp` or equivalent. The user is doing it, not you.

Pick based on what the tenant has access to. Do NOT attempt to shell into the `gibbon` container from AI Studio.

### 2. Register the module in Gibbon

The tenant clicks through: **System Admin → Manage Modules → Install → `<ModuleName>`**. This:
- Reads `modules/<ModuleName>/manifest.php`.
- `LOCK TABLES gibbonModule WRITE`.
- INSERTs a `gibbonModule` row.
- Seeds `gibbonAction` and `gibbonPermission` rows from the module's `actions.php` / `permissions.php` if present.
- Runs `install.sql` if present.
- `UNLOCK TABLES`.

Do NOT perform the registration via direct SQL. The UI flow is idempotent, permission-aware, and matches what the tenant would get on any vanilla Gibbon install.

### 3. Enable and permission it

After install, the module's actions are in `gibbonAction` but roles may not have permission yet. The tenant assigns permissions at **System Admin → Manage Permissions → `<ModuleName>`**. Offer to help them reason about which roles should get which actions.

### 4. Verify

```bash
# Module row exists.
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e \
  "SELECT gibbonModuleID, name, version, type, active FROM gibbonModule WHERE name='<ModuleName>';"

# Actions were seeded.
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e \
  "SELECT name, category, entryURL FROM gibbonAction WHERE gibbonModuleID=(SELECT gibbonModuleID FROM gibbonModule WHERE name='<ModuleName>');"

# Tenant can see the module in the nav and click through its entry page.
```

### 5. If it's broken

- Module in `gibbonModule` but not in nav → `active='N'`, or no `gibbonPermission` row for the logged-in user's role.
- Module in nav but pages 403 → `gibbonPermission` missing for the role.
- Module page 500s → PHP error. Check Apache log (requires the tenant or ops to surface it from the `gibbon` container).
- Module install failed → check the SQL in `install.sql` for charset/collation issues (utf8mb3 required) and missing FKs.

If the install left the DB in a half-installed state: restore from the pre-install backup. Do NOT try to "finish" the install by hand unless the user explicitly accepts the risk AND you can show them exactly what rows need adding.

## Do NOT

- Install a module whose source you haven't read.
- Run `INSERT INTO gibbonModule` directly — always use the UI.
- Skip the backup because "it's just a module install." Modules can run SQL in `install.sql` that touches the rest of the DB.
- Install a module that fails the audit checklist, even if the tenant says "I trust them." It's still their call, but your job is to make them know what they're accepting.
