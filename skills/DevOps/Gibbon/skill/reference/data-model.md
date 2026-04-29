# Data Model

208 tables in v30.0.01, all prefixed `gibbon*`. Full list is in `/var/www/html/gibbon.sql` (the shipped reference schema) and in `CHANGEDB.php` (for any additions since the last full-schema snapshot).

This file is the authoritative **"never touch" / "safe to touch"** split for a DevOps agent operating without human review of each SQL statement.

## NEVER TOUCH — student, academic, and finance data

These contain real school records. A lost row is a lost grade, a lost attendance mark, a lost tuition invoice. Never `TRUNCATE`, never `DELETE` without an explicit user ack, never run a `DELETE` you didn't `SELECT COUNT(*)` first.

### People / identity
- `gibbonPerson` — all users. Never. Ever. This is the root of every FK in the system.
- `gibbonPersonMedical`, `gibbonPersonMedicalCondition`, `gibbonPersonMedicalUpdate`
- `gibbonFamily`, `gibbonFamilyAdult`, `gibbonFamilyChild`, `gibbonFamilyRelationship`
- `gibbonUserStatusLog` — audit log of role/status changes; required for rollover to work
- `gibbonCustomField`, `gibbonCustomFieldData` — arbitrary per-person attributes

### Academic records
- `gibbonSchoolYear` — the one row per year that scopes everything else
- `gibbonYearGroup`, `gibbonYearGroupClass`
- `gibbonFormGroup`, `gibbonStudentEnrolment`
- `gibbonCourse`, `gibbonCourseClass`, `gibbonCourseClassPerson`, `gibbonCourseClassMap`
- `gibbonMarkbookColumn`, `gibbonMarkbookEntry`, `gibbonMarkbookTarget`, `gibbonMarkbookWeight`
- `gibbonPlannerEntry`, `gibbonPlannerEntryDiscuss`, `gibbonPlannerEntryGuest`, `gibbonPlannerEntryHomework`, `gibbonPlannerEntryStudentHomework`, `gibbonPlannerEntryStudentTracker`
- `gibbonUnit`, `gibbonUnitBlock`, `gibbonUnitClass`

### Attendance
- `gibbonAttendanceCode`, `gibbonAttendanceLogPerson`, `gibbonAttendanceLogCourseClass`, `gibbonAttendanceLogFormGroup`

### Behaviour
- `gibbonBehaviour`, `gibbonBehaviourFollowUp`, `gibbonBehaviourLetter`, `gibbonBehaviourLevel`

### Admissions
- `gibbonAdmissionsAccount`, `gibbonAdmissionsApplication`
- `gibbonApplicationForm`, `gibbonApplicationFormFile`, `gibbonApplicationFormLink`, `gibbonApplicationFormRelationship`

### Finance — **highest-sensitivity**
- `gibbonFinanceBillingSchedule`, `gibbonFinanceBudget`, `gibbonFinanceBudgetCycle`, `gibbonFinanceBudgetCycleAllocation`, `gibbonFinanceBudgetPerson`
- `gibbonFinanceExpense`, `gibbonFinanceExpenseApprover`, `gibbonFinanceExpenseLog`
- `gibbonFinanceFee`, `gibbonFinanceFeeCategory`
- `gibbonFinanceInvoice`, `gibbonFinanceInvoiceFee`, `gibbonFinanceInvoicee`, `gibbonFinanceInvoiceeUpdate`
- `gibbonFinancePettyCash`

### Assessments / Reports
- `gibbonExternalAssessment`, `gibbonExternalAssessmentField`, `gibbonExternalAssessmentStudent`, `gibbonExternalAssessmentStudentEntry`
- `gibbonFormalAssessmentColumn`, `gibbonFormalAssessmentEntry`, `gibbonFormalAssessmentTerm`
- `gibbonRubric`, `gibbonRubricCell`, `gibbonRubricColumn`, `gibbonRubricRow`, `gibbonRubricEntry`
- `gibbonReport`, `gibbonReportArchive`, `gibbonReportingCriteria`, `gibbonReportingCriteriaType`, `gibbonReportingScope`, `gibbonReportingValue`
- `gibbonReportTemplate`, `gibbonReportTemplateAsset`, `gibbonReportTemplateFont`, `gibbonReportTemplateSection`

### Library
- `gibbonLibraryItem`, `gibbonLibraryItemEvent`, `gibbonLibraryType`, `gibbonLibraryShelf`

### Individual Needs
- `gibbonIN`, `gibbonINArchive`, `gibbonINDescriptor`, `gibbonINInvestigation`, `gibbonINPersonDescriptor`, `gibbonINStatus`

### Activities
- `gibbonActivity`, `gibbonActivityAttendance`, `gibbonActivityCategory`, `gibbonActivityChoice`, `gibbonActivityPhoto`, `gibbonActivitySlot`, `gibbonActivityStaff`, `gibbonActivityStudent`, `gibbonActivityType`

### Calendar / communication
- `gibbonCalendarEvent`, `gibbonCalendarEventPerson` (participants)
- `gibbonMessenger`, `gibbonMessengerReceipt`, `gibbonMessengerTag`, `gibbonMessengerTarget`
- `gibbonEmailTemplate`

## SAFE TO TOUCH — but know what you're doing

These tables can be inspected, pruned, or even rebuilt in recovery scenarios. Still: no freehand destructive ops. The gates in [SKILL.md](../SKILL.md) still apply.

### Caches / transient
- **`gibbonSession`** — PHP session store. `DELETE FROM gibbonSession` logs everybody out. Usually fine; you're doing it to kick stuck sessions or to force a re-auth after a CVE patch.
- `/var/www/html/uploads/cache/*` — compiled templates; our entrypoint already wipes this on every restart.

### Logs (auditable; prune with care)
- **`gibbonLog`** — system event log (logins, setting changes, etc.). Growing unbounded? Prune by date with user ack: `DELETE FROM gibbonLog WHERE timestamp < NOW() - INTERVAL 1 YEAR` — **show row count first**.
- `gibbonUserStatusLog` — DO NOT prune; rollover and re-enrolment logic depend on historical rows.

### Settings
- **`gibbonSetting`** — `(scope, name)` unique key. Hundreds of rows. Safe to `UPDATE` a single setting if you know what it does. `absoluteURL` is updated automatically by `update-config.sh` on every container start, so editing it by hand gets reverted. Common settings worth knowing:
  - `scope='System', name='version'` — authoritative schema version
  - `scope='System', name='absoluteURL'` — public URL (auto-synced)
  - `scope='System', name='systemName'` / `name='organisationName'` — display names
  - `scope='System', name='timezone'`
  - `scope='User Admin', name='passwordPolicy*'` — strength requirements
  - `scope='System', name='cuttingEdgeCode'` — beta features toggle
  - `scope='System', name='enableImpersonation'` — added in v30.0.00, gated in `config.php`

### Notifications (transient)
- `gibbonNotification` — in-app notifications; pruned automatically by the `userAdmin_removeStaleNotifications` cron task

### Modules / RBAC (careful)
- **`gibbonModule`** — inserting/deleting rows is how modules are installed/uninstalled. Use the UI, not SQL.
- `gibbonAction` / `gibbonPermission` — RBAC wiring. UI-first. If you must SQL, wrap it in a transaction and `SELECT` before.

### i18n
- `gibboni18n` — installed languages. Editing `active` / `installed` flags is safe.

### Hooks / extensions
- `gibbonHook` — lets modules register themselves as dashboard widgets or report extensions. Inspected-only unless you're installing a new module.

## Key schema facts that come up in practice

- **Primary keys are zero-filled INTs.** `gibbonPersonID INT(10) UNSIGNED ZEROFILL`. `0000000042`, not `42`. Your `WHERE` clauses can pass either — MySQL coerces — but `SELECT` output looks unfamiliar.
- **Soft deletes via status enums, not a `deleted_at` column.** `gibbonPerson.status` is `Full | Expected | Pending Approval | Left`. Users who "leave" stay in the DB for historical attendance / grades. **Do not** `DELETE FROM gibbonPerson` to "remove a former student" — set `status='Left'`.
- **Charset:** `utf8mb3`. Legacy but stable. New schema additions follow the same charset for consistency.
- **FK enforcement is lax.** Many logical FKs are not declared with `FOREIGN KEY` constraints — inserting an orphan row won't raise an error. Cascade-delete behavior is inconsistent. Treat the schema as if all FKs were `ON DELETE RESTRICT` (i.e. don't delete parents).
- **Academic-year scoping:** almost every "academic" table has a `gibbonSchoolYearID` column. When a query "misses" data, the first thing to check is the year scope. `gibbonSchoolYear.status` is `Upcoming | Current | Past`; exactly one row should be `Current`.
- **Multi-tenant-per-schema is NOT supported.** One Gibbon schema = one school. This app is single-tenant-per-instance by design.

## Gotchas when inserting rows manually

### gibbonPerson

`gibbonPerson` has ~50 columns declared `NOT NULL` with no `DEFAULT` value. MySQL strict mode will reject any `INSERT` that omits them. You must pass explicit empty strings for every text/varchar field you don't have a real value for. Key ones that catch people:

- `nameInCharacters`, `officialName` — must be `''` if unknown
- `passwordStrongSalt` — **must not be empty**; see [security.md](security.md) for the correct SHA-256 scheme
- `address1`, `address1District`, `address1Country`, `address2`, `address2District`, `address2Country`
- `phone1CountryCode`, `phone1`, `phone2CountryCode`, `phone2`, `phone3CountryCode`, `phone3`, `phone4CountryCode`, `phone4`
- `website`, `languageFirst`, `languageSecond`, `languageThird`, `countryOfBirth`
- `birthCertificateScan`, `ethnicity`, `religion`, `profession`, `employer`, `jobTitle`
- Emergency contact fields: `emergency1Name`, `emergency1Number1`, `emergency1Number2`, `emergency1Relationship`, (same for emergency2)
- `studentID`, `lastSchool`, `nextSchool`, `departureReason`, `transport`, `transportNotes`
- `calendarFeedPersonal`, `lockerNumber`, `vehicleRegistration`, `personalBackground`
- `googleAPIRefreshToken`, `microsoftAPIRefreshToken`, `genericAPIRefreshToken`, `fields`

Use a PHP PDO script (piped via SSH) rather than a raw SQL heredoc — it's easier to supply named parameters cleanly without shell quoting issues.

### gibbonFormGroup

`gibbonFormGroup.website` has no default; always supply `''`.

## How to safely explore the DB

From the AI Studio container, against the app's pod-internal MySQL:

```bash
# Read-only probe, safe to run
mysql -h "$GIBBON_DB_HOST" -u gibbon -p"$GIBBON_DB_PASSWORD" gibbon -e \
  "SELECT COUNT(*) FROM gibbonPerson WHERE status='Full';"

# Inspect the currently-active school year
mysql -h "$GIBBON_DB_HOST" -u gibbon -p"$GIBBON_DB_PASSWORD" gibbon -e \
  "SELECT gibbonSchoolYearID, name, status, firstDay, lastDay FROM gibbonSchoolYear ORDER BY sequenceNumber;"

# See what a given setting is
mysql -h "$GIBBON_DB_HOST" -u gibbon -p"$GIBBON_DB_PASSWORD" gibbon -e \
  "SELECT scope,name,value FROM gibbonSetting WHERE scope='System' ORDER BY name;"
```

Never paste `$GIBBON_DB_PASSWORD` into chat. Pass it via env or `MYSQL_PWD` (preferred), and redact it in any diagnostics output you surface to the user.
