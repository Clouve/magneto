# Playbook: Year-End Rollover

Gibbon's highest-risk routine operation. Read [reference/academic-year-rollover.md](../reference/academic-year-rollover.md) first. This playbook covers pre-flight, the three UI steps, and post-flight verification.

## Preconditions (hard gates — refuse to proceed if any are missing)

- [ ] **A current, verified backup** (not older than 1 hour). Run [scripts/backup.sh](../scripts/backup.sh).
- [ ] **Next `gibbonSchoolYear` row exists** with `status='Upcoming'` and `firstDay` / `lastDay` set.
- [ ] **`max_input_vars` >= (3 × number of current students)**. The rollover form posts ~3 fields per student. Default is 8000 → safe up to ~2500 students.
- [ ] **Tenant has a maintenance window agreed.** Rollover should not happen during an active school day.
- [ ] **No active imports / writes** in progress. Ask the user to stop any batch imports they kicked off.

## Pre-flight (safe read-only queries)

```bash
# The current school year
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
  SELECT gibbonSchoolYearID, name, status, firstDay, lastDay, sequenceNumber
  FROM gibbonSchoolYear
  ORDER BY sequenceNumber;"
# There should be exactly one row with status='Current'.
# There should be exactly one row with status='Upcoming', and its sequenceNumber should be current+1.
# If not, fix in School Admin → Manage School Years BEFORE rollover.

# Current student count (will drive max_input_vars need)
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
  SELECT COUNT(*) AS active_students
  FROM gibbonStudentEnrolment e
  JOIN gibbonSchoolYear y ON e.gibbonSchoolYearID = y.gibbonSchoolYearID
  JOIN gibbonPerson p ON e.gibbonPersonID = p.gibbonPersonID
  WHERE y.status='Current' AND p.status='Full';"

# Current value of max_input_vars, from PHP
curl -sf http://gibbon/installer/install.php 2>/dev/null | grep -oP 'max_input_vars[^<]*' | head -1
# OR ask the user to run a phpinfo page (safer):
#   <?php echo ini_get('max_input_vars'); ?>
```

If the student count × 3 > max_input_vars, bump `max_input_vars` before rollover:

```
# /var/www/html/.htaccess already has: php_value max_input_vars 8000
# Bump to a safe ceiling. The image's default is 8000; schools with 3000+ students need more.
# Tell the user to edit .htaccess via the File Browser or ask Clouve ops to inject a new env.
# Per-tenant: 20000 is safe for nearly any single school.
```

## Capture the pre-rollover snapshot

```bash
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
  SELECT 'active_persons' AS metric, COUNT(*) AS val FROM gibbonPerson WHERE status='Full'
  UNION ALL SELECT 'current_enrolments',
    (SELECT COUNT(*) FROM gibbonStudentEnrolment e
     JOIN gibbonSchoolYear y ON e.gibbonSchoolYearID=y.gibbonSchoolYearID
     WHERE y.status='Current')
  UNION ALL SELECT 'next_year_enrolments (should be 0 pre-rollover)',
    (SELECT COUNT(*) FROM gibbonStudentEnrolment e
     JOIN gibbonSchoolYear y ON e.gibbonSchoolYearID=y.gibbonSchoolYearID
     WHERE y.status='Upcoming');"
```

Print these numbers in chat. You will compare after.

## Run the rollover — tenant walks through the UI, you coach

### Step 1 — the tenant navigates to User Admin → Rollover

They see the pre-flight screen. Gibbon re-checks `max_input_vars` and whether a next year exists. If either is missing, they see a red error and cannot proceed — fix it and return.

### Step 2 — the tenant reviews each student

Gibbon generates the big form: for each current student, a row with target year-group, target form-group, and a status dropdown (Promoted / Repeating / Graduating / Left). Defaults are sensible (next year-group + same form-group).

Tell the tenant:
- "Skim through the list. Flag any student who should be marked 'Graduating' or 'Left' instead of 'Promoted'."
- "If the form looks truncated (fewer rows than you expect), STOP — `max_input_vars` is too low. Do not submit."

### Step 3 — the tenant submits

The submission is a single big POST. Gibbon iterates each student, INSERTs the new `gibbonStudentEnrolment` row, updates `gibbonPerson.status` if 'Left' / 'Graduating', and logs to `gibbonUserStatusLog`. At the end it flips the year: `Current → Past`, `Upcoming → Current`.

**No transaction spans the whole submission.** Each student is committed as it's processed. A PHP timeout or MySQL hiccup mid-way leaves you half-rolled-over. If the user sees a blank page or the submit hangs past a minute, STOP and read the next section.

## Post-rollover verification (immediately after)

```bash
MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
  -- Years flipped correctly:
  SELECT name, status, firstDay, lastDay FROM gibbonSchoolYear ORDER BY sequenceNumber;
  -- New year's enrolments roughly match pre-rollover active student count:
  SELECT COUNT(*) AS new_year_enrolments
  FROM gibbonStudentEnrolment e
  JOIN gibbonSchoolYear y ON e.gibbonSchoolYearID=y.gibbonSchoolYearID
  WHERE y.status='Current';
  -- Old year's enrolments unchanged (historical):
  SELECT COUNT(*) AS past_year_enrolments
  FROM gibbonStudentEnrolment e
  JOIN gibbonSchoolYear y ON e.gibbonSchoolYearID=y.gibbonSchoolYearID
  WHERE y.status='Past'
  ORDER BY y.sequenceNumber DESC LIMIT 1;
  -- Graduating / Left students have matching gibbonPerson.status:
  SELECT status, COUNT(*) FROM gibbonPerson WHERE status IN ('Left', 'Full', 'Expected') GROUP BY status;"
```

Compare `new_year_enrolments` to the pre-rollover `current_enrolments` minus Graduating/Left. Should match within the tenant's manual adjustments.

## If rollover partially completed

Symptoms: new year enrolments < expected, year already flipped, students without enrolment rows.

1. **Stop.** Do not re-run rollover.
2. **Capture state:**
   ```bash
   MYSQL_PWD="$GIBBON_DB_PASSWORD" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
     SELECT status, COUNT(*) FROM gibbonSchoolYear GROUP BY status;
     SELECT gibbonSchoolYearID, COUNT(*) FROM gibbonStudentEnrolment GROUP BY gibbonSchoolYearID;"
   ```
3. **Restore from pre-rollover backup.** Follow [rollback-from-backup.md](rollback-from-backup.md). A full restore is the only safe path — the partial rollover state is too tangled to patch by hand.
4. **Address the root cause before retrying:**
   - PHP timeout → bump `max_execution_time`.
   - `max_input_vars` too low → bump it.
   - MySQL connection dropped → investigate mysql server health, then retry with a maintenance window.

## Follow-up operations (after a successful rollover)

These are NOT automatic — the tenant needs to do each deliberately:

- **Timetable rollover** — `modules/Timetable Admin/course_rollover.php` clones courses/classes from the old year into the new year.
- **Markbook rollover** — each department's markbook columns need to be cloned into new classes. Separate workflow per course.
- **Finance setup** — new year's billing schedule is a fresh entity; invoices don't roll forward.
- **Messenger templates** — any year-specific templates need reviewing.
- **Activities** — new year's activity catalog is a fresh entity; old activities close automatically.

## Do NOT

- Do NOT simulate rollover with SQL. There is too much implicit logic in the UI flow (role transitions, log entries, per-student status updates, year flip) to replicate by hand.
- Do NOT skip the backup. There is no un-rollover.
- Do NOT run rollover "to see what the form looks like" — Step 3 is the dangerous one; Steps 1 and 2 are safe reads, but clicking through Step 3 on a whim is how schools lose a year.
- Do NOT run rollover with `max_input_vars` untested. The silent-truncation failure mode is the worst one in this skill.
