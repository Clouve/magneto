# Modules

## Core vs. Additional

Gibbon has two classes of module.

**Core modules** (27 in v30.0.01) ship with the release and live at `/var/www/html/modules/<Name>/`. They have no `manifest.php` — their metadata is populated into `gibbonModule` / `gibbonAction` / `gibbonPermission` directly by the installer and maintained by `CHANGEDB.php` migrations. You cannot uninstall them; the UI will refuse.

```
Activities                Finance            Reports
Admissions                Form Groups        Rubrics
Attendance                Formal Assessment  School Admin
Behaviour                 Individual Needs   Staff
Calendar                  Library            Student Alerts
Crowd Assessment          Markbook           Students
Data Updater              Messenger          System Admin
Departments               Planner            Timetable
                                             Timetable Admin
                                             Tracking
                                             User Admin
```

**Additional modules** are third-party. They are installed by dropping a folder at `/var/www/html/modules/<Name>/` containing a `manifest.php` and registering the module through **System Admin → Manage Modules → Install Module**.

## `manifest.php` required fields

From `modules/System Admin/module_manage_installProcess.php`, the installer reads `manifest.php` and validates:

```php
// Required
$name        // unique across modules
$description // one-liner
$type        // MUST be 'Additional' — Core modules are not installable via this path
$version     // semver-ish

// Expected (used if present)
$entryURL    // main page users land on
$category    // bucket for the nav menu
$author
$url         // upstream repo / homepage
```

If `$name`, `$description`, `$type`, or `$version` is empty, or `$type != 'Additional'`, installation fails with `&return=error1`. The installer also refuses if a module with the same name already exists in `gibbonModule` (`&return=error6`).

During install the installer:

1. `LOCK TABLES gibbonModule WRITE` (concurrency guard).
2. `INSERT` a row into `gibbonModule` with name/description/entryURL/type/category/version/author/url.
3. `UNLOCK TABLES`.
4. (the installer also walks the module's `permissions/` and `actions/` if present to seed `gibbonAction` and `gibbonPermission` — see the full script).

## Where modules register themselves

Core modules don't have a manifest; their rows are seeded by `gibbon.sql` and kept up-to-date by `CHANGEDB.php` migrations every release.

Additional modules register via the install flow above. They can ship their own `actions.php` / `permissions.php` / `settings.php` to register permissions, and their own `install.sql` / `uninstall.sql` scripts if they need schema.

## Install / uninstall / update semantics

| Action | What it does | Reversible? |
|---|---|---|
| **Install** (Manage Modules → Install) | Creates `gibbonModule` row, creates any actions/permissions, optionally runs the module's `install.sql` | Via Uninstall, usually |
| **Uninstall** (Manage Modules → Uninstall) | Deletes the `gibbonModule` row; the cascade removes `gibbonAction` and `gibbonPermission` rows; runs `uninstall.sql` if the module ships one | Data stays if the module didn't drop its own tables. Module folder on disk is NOT deleted — safe to reinstall. |
| **Update** (Manage Modules → Update) | Re-reads `manifest.php` and applies the module's own incremental migrations if it provides any | Usually module-specific; check the module's docs |
| **Enable / Disable** | Flag only — toggles whether menu entries show | Trivial |

**Critical:** uninstall only guarantees removal of the things **Gibbon** wrote to the DB. A badly-written module may have created its own tables and NOT provided an `uninstall.sql`. Always check a tenant's module's uninstall script before running it.

## Auditing an untrusted module before installing

Required reading before the first install from an unfamiliar source:

1. `manifest.php` — make sure `$type == 'Additional'` and `$name` is unique. Look at `$url` — if it's not a GitHub repo you can inspect, raise a red flag with the user.
2. `install.sql` (if present) — read every SQL statement. Specifically look for:
   - `DROP TABLE` or `TRUNCATE` targeting any `gibbon*` table → **refuse**.
   - `INSERT INTO gibbonPerson` or `UPDATE gibbonPerson` → highly suspicious; refuse unless the user understands.
   - `INSERT INTO gibbonRole` or `gibbonPermission` with `defaultPermissionAdmin='Y'` on broad actions → the module is granting itself admin access beyond what it needs.
3. Any PHP files under `modules/<Name>/`. Specifically:
   - `include` / `require` of files outside the module's own directory (other than `/var/www/html/gibbon.php`, `moduleFunctions.php`, the `src/` classes).
   - `system()`, `exec()`, `passthru()`, `shell_exec()`, `eval()`, backticks — unusual and warrants scrutiny.
   - Writes to `/var/www/html/config.php` or any file outside `uploads/`.
   - `curl_exec` / `file_get_contents` calls that hit external domains — document what the module phones home about.
4. `README`, `LICENSE`, anything in the repo that explains what the module does and who maintains it.

If all four look clean, proceed. If anything looks off, the user picks whether to continue knowing the risk — it is their call, not yours.

## Where modules live in the schema

Every module (core or additional) gets a row in `gibbonModule`:

```
gibbonModuleID  | name (unique)   | description | entryURL    | type       | category | version | active
```

Each page / capability of a module is a row in `gibbonAction`:

```
gibbonActionID  | gibbonModuleID  | name (unique per module)    | URLList  | entryURL | ...
                                  | defaultPermissionAdmin/Teacher/Student/Parent/Support enum('Y','N')
                                  | categoryPermissionStaff/Student/Parent/Other enum('Y','N')
```

And role-to-action wiring lives in `gibbonPermission`:

```
gibbonRoleID (FK gibbonRole)  |  gibbonActionID (FK gibbonAction)
```

To see what a role can actually do: `SELECT a.name, m.name AS module FROM gibbonPermission p JOIN gibbonAction a USING(gibbonActionID) JOIN gibbonModule m ON a.gibbonModuleID=m.gibbonModuleID WHERE p.gibbonRoleID=<id>`.

To see what a user can do: user → `gibbonPerson.gibbonRoleIDPrimary` → `gibbonPermission` → `gibbonAction`.

## Common module-related failure modes

- **Module shown in nav but pages 403** — user's role lacks the `gibbonPermission` row. Fix in System Admin → Manage Permissions.
- **Module installed but not in nav** — `gibbonModule.active='N'`. Fix in Manage Modules → Enable.
- **Module install wedged the DB** — a bad `install.sql`. Restore from the pre-install DB dump. Refuse reinstallation until the module's author ships a fix.
- **Uninstalled core module (!)** — technically not possible via the UI, but someone may have `DELETE`d the `gibbonModule` row directly. Restore from backup; do not try to recreate the row by hand (the `gibbonAction` / `gibbonPermission` rows that reference it will have been cascade-deleted, and re-seeding them is a release-by-release endeavour).
