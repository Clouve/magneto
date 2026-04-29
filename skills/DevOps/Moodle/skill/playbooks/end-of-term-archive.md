# Playbook: End-of-term archive (or rollover)

Use this playbook when the school is at the end of an academic term/year and wants to:

- **Archive** a set of finished courses (preserve as read-only / hide from students).
- **Roll over** courses to next term (clone into next-term shells with starter content).
- **Reset** courses to remove last term's data (not recommended; archive is cleaner).

Moodle does not have a single "rollover" workflow the way some LMSs do. You compose it from course-backup, course-restore, course visibility, and category management.

## Preconditions

- [ ] **Backup taken.** This is a long, cross-cutting operation; restore-from-backup is your safety net. See [scripts/backup.sh](../scripts/backup.sh).
- [ ] User has a written **list of source courses** and a written **target plan** (archive vs. rollover vs. reset). Don't guess at scope.
- [ ] User has confirmed the **timing**. End-of-term operations on a busy site can take hours. Schedule for a weekend or after-hours.
- [ ] If rollover: the target category for next-term shells is created (or you have a naming convention).

## Concept map

| Action | Effect | Reversible? |
|---|---|---|
| Hide a course (`mdl_course.visible = 0`) | Students no longer see it; teachers and admins still do | Yes — set visible back to 1 |
| Move a course to an "Archive" category | Same visibility, organisational only | Yes |
| **Course backup → Restore as new course** | Creates a clone (with or without user data) in another category. The original is untouched. | The clone exists separately; can be deleted. |
| **Course reset** (`reset` admin action on a course) | Removes user data (enrolments, submissions, attempts, posts) but keeps the structure (activities, content, settings). | **Irreversible** — restore the course backup if you need user data back. |
| Delete a course | Permanently removes the course and all its data. | **Irreversible** without backup. |

The right pattern for end-of-term in most schools is **archive + rollover**:

1. **Archive** the past term's courses by hiding them and moving to an "Archive YYYY-Q" category. Read-only history; teachers can review previous content.
2. **Roll over** content (no user data) into a new shell in the next-term category.
3. New term starts; teachers start with a clean copy of the structure they had.

## Steps — archive

### 1. Hide the source courses

UI bulk path: Site administration → Courses → Manage courses and categories → select category → bulk select → "Hide".

CLI path (uses [admin/cli/maintenance.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/maintenance.php) is NOT what you want; there's no shipped bulk-visibility CLI):

```sql
-- DRY RUN: count first
SELECT COUNT(*) FROM mdl_course
WHERE category = (SELECT id FROM mdl_course_categories WHERE name = '<source category>');
```

Show this count to the user, get ack, then:

```sql
UPDATE mdl_course
SET visible = 0
WHERE category = (SELECT id FROM mdl_course_categories WHERE name = '<source category>');
```

After the SQL, purge caches — course visibility is cached.

### 2. Create the archive category

Site administration → Courses → Manage courses and categories → "Create new category". Name it consistently, e.g. `Archive 2025-26 Q3`.

### 3. Move the courses to the archive category

UI bulk: select category → bulk select courses → "Move".

The DB-level path is in `mdl_course.category`, but **don't update this directly** — Moodle has cached `path` and `depth` columns that need recalculation, plus events that fire on category change. Use the UI or `local_*` plugins designed for bulk operations.

### 4. Verify

```sql
SELECT id, fullname, shortname, visible
FROM mdl_course
WHERE category = (SELECT id FROM mdl_course_categories WHERE name = 'Archive 2025-26 Q3');
```

All `visible = 0`. Done with the archive step.

## Steps — rollover (clone for next term)

This is per-course. For dozens of courses, plan a maintenance window of an evening (or run via cron in batches).

### 5. Decide what to copy

Default: **course content without user data.** That means activities, resources, settings, but NOT enrolments, submissions, posts, grades, attempts.

The course backup wizard's "Include users" toggle controls this. From CLI, [admin/cli/backup.php](https://github.com/moodle/moodle/blob/v5.2.0/admin/cli/backup.php) — read its `--help` to see the user-inclusion flags.

### 6. Back up each source course

```bash
mkdir -p /tmp/rollover-mbz
for course_id in 101 102 103 104 105; do
  sshpass -e ssh clouve-ops@${MOODLE_HOST} \
      "sudo -u www-data php /var/www/html/admin/cli/backup.php \
         --courseid=$course_id \
         --destination=/tmp/rollover-mbz/"
done
```

Each course produces an `.mbz` file in `/tmp/rollover-mbz/`. For a school with 200 courses, this is hours.

Verify:

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} 'ls -la /tmp/rollover-mbz/ | wc -l'
```

### 7. Restore each into the new category as a new course

```bash
NEXT_CAT_ID=$(mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" -p"$MOODLE_DB_PASSWORD" "$MOODLE_DB_NAME" -sN \
    -e "SELECT id FROM mdl_course_categories WHERE name = 'Term 2026-Q1';")

for mbz in /tmp/rollover-mbz/*.mbz; do
  sshpass -e ssh clouve-ops@${MOODLE_HOST} \
      "sudo -u www-data php /var/www/html/admin/cli/restore_backup.php \
         --file=$mbz --categoryid=$NEXT_CAT_ID"
done
```

The restored courses get fresh IDs, fresh `mdl_course.startdate` / `enddate` (you'll want to update these), and no enrolled users. Teachers are NOT auto-enrolled into the new shells — handle that in the next step.

### 8. Auto-enrol the teachers into the new shells

This part depends on how the school manages enrolments:

- **Manual enrolment (small school):** Use the UI per-course or via [enrol/manual/cli/](https://github.com/moodle/moodle/tree/v5.2.0/public/enrol/manual/cli).
- **Cohort sync:** Update the cohort definition for the new term; cohort sync (cron task) populates the courses automatically.
- **External SSO with role-mapping:** The next IdP login provisions the teacher with the right role; nothing to do.

Discuss with the user which path applies.

### 9. Set new course start/end dates and visibility

The cloned courses inherit dates from the source. For the new term:

```sql
-- Show the dates first
SELECT id, fullname, FROM_UNIXTIME(startdate), FROM_UNIXTIME(enddate)
FROM mdl_course WHERE category = $NEXT_CAT_ID;
```

Update via the UI per-course, or in bulk via a custom script (no shipped bulk-CLI). For a one-off term boundary you can `UPDATE mdl_course SET startdate = UNIX_TIMESTAMP('2026-09-01'), enddate = UNIX_TIMESTAMP('2026-12-15') WHERE category = $NEXT_CAT_ID` — but **only after a count + ack** per the safety gates.

Set `visible = 1` once teachers have prepped the shells and it's time to open them to students.

## Steps — course reset (rare, irreversible)

If the user explicitly wants to **reset** a course rather than archive + rollover (common with persistent course shells — the same Moodle course is reused term over term, with last term's data wiped):

### 10. Confirm scope

The course reset removes:
- All enrolled users (according to the reset options chosen)
- Submissions, attempts, posts, grades
- Activity completion records
- Subscription / read tracking

It KEEPS:
- The course structure: sections, activities, content
- Settings, role assignments at course level
- Files referenced by activity content

### 11. Take a backup OF THIS COURSE specifically

```bash
sshpass -e ssh clouve-ops@${MOODLE_HOST} \
    "sudo -u www-data php /var/www/html/admin/cli/backup.php --courseid=$COURSE_ID --destination=/tmp/pre-reset/"
```

Save that `.mbz` somewhere durable. The reset is irreversible; the backup is the only undo path.

### 12. Run the reset

There's no shipped CLI for course reset. UI: navigate to the course → Course administration → Reset → check the categories of data to clear → "Reset course".

For a bulk reset, you'd write a `local_*` plugin that calls the reset functions. Out of scope for ad-hoc operations.

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| Course backup runs forever / OOMs | One activity (often a forum or H5P) has too much content | Backup courses individually; bump cron memory; profile the slow activity |
| Restore fails with "category not found" | Wrong `--categoryid` | Re-check category id |
| Restored course has no users | Expected — backup was without user data | Step 8: enrol teachers |
| Restored course has DUPLICATE activities | Restore-as-new ran twice on the same target | Delete the duplicate course; re-do |
| `mdl_files` doubles in size | Each restore-as-new duplicates file metadata; bytes are deduped on disk via content hash | Expected; the bytes-on-disk don't double |
| Auto-enrolment failed for teachers | Cohort sync hadn't run yet | Run `admin/cli/scheduled_task.php --execute='\enrol_cohort\task\enrol_cohort_sync'` |

## After-action

End-of-term events tend to surface site-wide issues that don't show in normal operation. Capture in [learnings.md](../learnings.md):

- Courses with enormous backups → flag for content cleanup.
- Plugins that misbehaved during backup/restore.
- Time taken (helpful for planning the next term boundary).
- Specific cohort / enrolment gotchas for this institution.
