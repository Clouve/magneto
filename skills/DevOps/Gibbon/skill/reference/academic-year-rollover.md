# Academic Year Rollover

This is the single riskiest routine operation in Gibbon. Naive automation here is how real schools lose data. Read this page fully before touching anything related to rollover.

## What rollover is

Gibbon scopes almost every academic record (attendance, markbook, enrolment, finance, planner, etc.) by `gibbonSchoolYearID`. At the end of an academic year, students need to be promoted into the next year's enrolment records. That operation is called **rollover**.

The rollover process:
1. Marks the current school year as `Past`.
2. Marks the next school year as `Current`.
3. Creates new `gibbonStudentEnrolment` rows (one per current student) assigning them to the next year's form group and year group.
4. Optionally: rolls over other artefacts (classes, timetables) — separately, via the `modules/Timetable Admin/course_rollover.php` flow.

## Where it lives

- Entry point: **User Admin → Rollover**. UI file: [modules/User Admin/rollover.php](../../../.research/gibbon-core/modules/User Admin/rollover.php).
- Three steps: (1) pre-flight checks, (2) form to map each student to their next year-group/form-group, (3) execute.
- Related: **Timetable Admin → Roll Over Classes** for carrying course/class structure across.

## Preconditions — before you touch the rollover UI

1. **Next `gibbonSchoolYear` row must exist** and have `status='Upcoming'`, with `firstDay` / `lastDay` set. Created via **School Admin → Manage School Years → Add**. Rollover will refuse without this.
2. **`max_input_vars` must be larger than the total enrolment.** The rollover form has one POST field per student. If PHP caps the input at 8000 (our default) and the school has 8001+ currently-enrolled students, every request past the cap is silently dropped. The UI checks this in Step 1 and shows an error, but only if `max_input_vars` is under the configured `$systemRequirements.settings.max_input_vars[2]` (5000 by default). **For any school with more than ~4000 enrolled students, bump `max_input_vars` via PHP ini before running rollover.**
3. **A current, verified backup.** Not "we took one last month." Right now. See [backup-restore.md](backup-restore.md).
4. **The school's actual calendar says it's time.** Rollover is one-way (there is no "un-rollover" button). Do not run it mid-year "to see what happens."
5. **No active classes mid-session.** If timetable/classes are still in active use on the old year, rollover will still run, but teachers will lose write access to this year's markbook entries that haven't been finalized. Confirm with the user.

## The 3 steps (what each actually does)

### Step 1 — pre-flight

- Verifies `max_input_vars >= requiredInputVars` (default 5000 — schools rolling 5000+ students at once need higher).
- Calls `$schoolYearGateway->getNextSchoolYearByID($currentYear)`. If it returns false or empty → fatal error, stop.
- Shows the set of students to be rolled and their default target year group (current year group + 1).
- No DB mutation yet.

### Step 2 — form

- Renders a giant form with one `<select>` per student: target year group, target form group, status (promoted / repeating / left).
- Admin can bulk-override year groups, mark students as graduating / repeating.
- Submission is one big POST with N×3 fields.
- **If the POST exceeds `max_input_vars`, PHP drops the excess fields silently, and the submitted values for those students fall back to defaults.** This is the single most damaging failure mode.

### Step 3 — execute

- For each submitted student:
  - INSERT a new `gibbonStudentEnrolment` row for the next year.
  - Update `gibbonPerson.status` if they've been marked 'Left'.
  - Log to `gibbonUserStatusLog`.
- Flip `gibbonSchoolYear.status`: the `Current` year becomes `Past`, the `Upcoming` year becomes `Current`.
- No transaction spans the whole operation — individual INSERTs commit as they go. **A failure partway through leaves the DB half-rolled-over.**

## If rollover fails partway

1. Stop immediately — do not re-run rollover.
2. Compare `gibbonStudentEnrolment` counts for the new year with the current student body. A partial rollover has fewer rows than expected.
3. Check `gibbonSchoolYear.status` — has the year already flipped? If so you're in a weird state where the new year is active but some students have no enrolment.
4. **Restore from the backup taken pre-rollover.** Do not try to "patch forward" by inserting missing rows by hand — the form-group assignments, role transitions, and log entries are too interdependent.

## Timetable / course rollover

Separate from student rollover. `modules/Timetable Admin/course_rollover.php`. This clones courses/classes from the old year into the new year. Run AFTER student rollover so the new enrolment rows already exist to enrol into the new classes.

## What the skill should do in practice

- **Refuse to run rollover via SQL.** No exceptions. It must go through the UI.
- **Offer to run the pre-flight checks for the user** — `max_input_vars`, next school year existence, student count, backup timestamp. Those are all safe reads.
- **Offer to take the backup** before they click through the UI.
- **Help them set `max_input_vars`** by showing how to set it in `.htaccess` (`php_value max_input_vars 20000`), NOT by shelling into the container to edit `php.ini` (we can't from AI Studio, and it'd get clobbered on rebuild anyway).
- **Stay with them during the run** — ask them to tell you when Step 2 is submitted and Step 3 completed, and run verification queries in between.
- **Run the post-check** — `SELECT COUNT(*) FROM gibbonStudentEnrolment WHERE gibbonSchoolYearID=<new year ID>` and compare to the previously-active student count.

## Post-rollover cleanup

- Teachers who left need their `gibbonPerson.status='Left'` manually if not done during rollover.
- Markbook columns need rolling into the new year's courses (separate workflow).
- Last year's attendance/markbook data stays in place, scoped to the old year — it's read-only going forward but never deleted.
- Fees / invoices for the old year stay on the old year; new billing schedules for the new year need to be set up in Finance.
