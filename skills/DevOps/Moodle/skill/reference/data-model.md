# Data Model — what to touch, what NEVER to touch

Moodle's DB has hundreds of tables. As an operator, you almost never need to write SQL — go through Moodle's UI or CLI. When you DO need to read a table, this is the orientation map.

The default prefix is `mdl_`. References below use that; substitute your site's prefix if it differs.

## NEVER touch (no `UPDATE` / `DELETE` / `INSERT` directly)

These tables hold student/instructor work that, if mutated outside Moodle's APIs, leaves the file API and gradebook silently inconsistent. **Refuse** to write to these. If the user has a clear use case, escalate to using Moodle's tooling.

| Table | What it holds |
|---|---|
| `mdl_user` | User accounts. Bulk modify ONLY through Site administration → Users → Bulk user actions, or `admin/cli/`. |
| `mdl_user_password_history`, `mdl_user_password_resets` | Password lifecycle records. |
| `mdl_grade_*` (grade_items, grade_grades, grade_categories, grade_letters, grade_outcomes_*, grade_settings) | Gradebook. The single most fragile thing in Moodle. Use the gradebook UI. |
| `mdl_quiz_attempts`, `mdl_quiz_grades`, `mdl_quiz_overrides`, `mdl_question_attempts`, `mdl_question_attempt_steps`, `mdl_question_attempt_step_data` | Quiz attempts and the question engine state. The question engine reconstructs answers from a chain of step rows; gaps are unrecoverable. |
| `mdl_assign_submission`, `mdl_assign_grades`, `mdl_assign_user_flags`, `mdl_assign_overrides`, `mdl_assign_user_mapping` | Assignment submissions. Bytes are in `mdl_files`; rows here index them. |
| `mdl_forum_posts`, `mdl_forum_discussions`, `mdl_forum_read`, `mdl_forum_track_prefs`, `mdl_forum_subscriptions` | Forum content + read tracking. |
| `mdl_logstore_standard_log`, `mdl_log_queries` | Audit log. Editing is forensic-evidence destruction. |
| `mdl_files` | File metadata. Files on disk are addressed by hash; corrupting this table breaks downloads silently. |
| `mdl_files_reference` | Aliases / external references (e.g. one course imports a file from another via reference). |
| `mdl_backup_courses`, `mdl_backup_logs` | Course backup state machine. |
| `mdl_lesson_attempts`, `mdl_lesson_grades`, `mdl_lesson_branch`, `mdl_lesson_timer` | Lesson activity progress. |
| `mdl_scorm_scoes_track`, `mdl_scorm_attempt`, `mdl_scorm_aicc_session` | SCORM tracking. |
| `mdl_h5pactivity_attempts`, `mdl_h5p_*` | H5P activity attempts and content packages. |
| `mdl_competency_*` | Competency framework (used in production by some institutions; data is high-stakes). |
| `mdl_badge_issued`, `mdl_badge_*_log` | Badges actually awarded. |
| `mdl_certif_*`, `mdl_completion_*` | Course completion records. |

The general rule: if it has the word `submission`, `attempt`, `grade`, `log`, or `complet` in the table name, **don't touch it**.

## Safer to read (and sometimes update via Moodle's UI/CLI)

These hold configuration, structure, or relationships that are routinely modified by admins through the UI. You can `SELECT` freely; for any `UPDATE`, prefer the UI / CLI.

| Table | What it holds | Right way to modify |
|---|---|---|
| `mdl_config` | Site-wide settings | `admin/cli/cfg.php`, or the admin UI |
| `mdl_config_plugins` | Per-plugin settings | Same |
| `mdl_config_log` | Audit log of config changes | Read-only |
| `mdl_course` | Course definitions (name, format, dates, category) | Course settings UI |
| `mdl_course_categories` | Category tree | Site admin → Courses → Manage categories |
| `mdl_course_modules` | Activity instances inside courses (the link between mod_assign instance #X and course Y) | Course editing UI |
| `mdl_course_sections` | Sections inside courses | Course editing UI |
| `mdl_modules` | Map of module name (`mod_quiz`) to its install ID | DON'T touch |
| `mdl_role`, `mdl_role_capabilities`, `mdl_role_assignments`, `mdl_role_context_levels` | Role and capability system | Site admin → Users → Permissions |
| `mdl_capabilities` | List of all defined capabilities (registered by core + plugins on install) | DON'T touch |
| `mdl_context` | Context tree (system → category → course → module → block) | DON'T touch — derived from the structure tables |
| `mdl_enrol` | Enrolment instance (one row per enabled enrolment method per course) | Enrolment UI |
| `mdl_user_enrolments` | Who's enrolled in what | Enrolment UI; bulk via `enrol/manual/cli/` |
| `mdl_groups`, `mdl_groups_members`, `mdl_groupings` | Course-level grouping | Course UI |
| `mdl_cohort`, `mdl_cohort_members` | Site-wide cohorts (often used for SSO group mappings) | Site admin → Users → Cohorts; CLI bulk via `cohort/cli/` |
| `mdl_tag`, `mdl_tag_instance` | Tags | Tag UI |
| `mdl_filter_active`, `mdl_filter_config` | Filter activation per context | Filter management UI |
| `mdl_block_instances`, `mdl_block_positions` | Block placements | Block configuration UI |
| `mdl_message_*` | Messages between users and notification preferences | Messaging UI |

## The install/upgrade sentinel rows in `mdl_config`

`mdl_config` is the single most useful diagnostic table. Some rows that matter:

```sql
SELECT name, value FROM mdl_config WHERE name IN (
    'version',                     -- installed Moodle DB version, compare to public/version.php
    'release',                     -- human-readable release ('5.2 (Build: 20260420)')
    'siteidentifier',              -- random; identifies this installation
    'maintenance_enabled',         -- 1 if maintenance mode is on
    'cron_enabled',                -- 1 if cron is on
    'allowemailaddresses',         -- domain restrictions for self-registration
    'theme'                        -- active theme
);
```

`mdl_config_plugins` is per-plugin:

```sql
SELECT name, value FROM mdl_config_plugins
WHERE plugin = 'mod_quiz'
ORDER BY name;
```

Plugin-installed sentinel: every plugin has a `version` row in `mdl_config_plugins`:

```sql
SELECT plugin, value AS installed_version FROM mdl_config_plugins
WHERE name = 'version'
ORDER BY plugin;
```

If a plugin's `version` row is missing, it's not installed (regardless of whether the code is present on disk). If the code is missing but the row exists, the next `admin/cli/upgrade.php` or page load will report it as orphaned.

## The user identity rows

| User ID | What it is |
|---|---|
| `0` | "nobody" — anonymous / system; do not log in as |
| `1` | `guest` — pre-seeded guest user account |
| `2` | The first admin created at install (default username `admin`) |

Bulk user operations (delete, suspend, change auth method) MUST go through `mdl_user`'s flags, not raw `DELETE FROM mdl_user`. Setting `mdl_user.deleted = 1` is Moodle's "soft delete"; the row stays for audit but the user can't log in. Hard deletion is rarely correct.

## File storage rows

`mdl_files` is the index, `<dataroot>/filedir/<2>/<2>/<sha1>` is the bytes. See [file-storage.md](file-storage.md). Never UPDATE this table — the file API is the right way.

## "Stuck" task rows

Two tables drive the task scheduler:

| Table | Holds |
|---|---|
| `mdl_task_scheduled` | One row per scheduled task (defined in plugin's `db/tasks.php`); admin overrides live here |
| `mdl_task_adhoc` | One row per queued one-shot task; consumed by the runner |
| `mdl_task_log` | History of task runs (timestart, timeend, result, output) |
| `mdl_task_log_running` | (5.x) Currently-executing task tracking |

If a task seems "stuck" (won't fire), check `mdl_task_scheduled` for a non-zero `disabled` flag, an unreasonable `nextruntime`, or `faildelay` set very high. The right tool to reset is `admin/cli/scheduled_task.php --execute='\namespace\task'` (immediate run) or admin UI Site administration → Server → Tasks → Scheduled tasks → "Reset task to defaults".

## Inspecting what changed recently

The audit log:

```sql
SELECT FROM_UNIXTIME(timecreated) AS at, userid, action, target, objectid, contextid
FROM mdl_logstore_standard_log
ORDER BY timecreated DESC
LIMIT 50;
```

Filtered to a user:

```sql
SELECT FROM_UNIXTIME(timecreated), action, target, objectid, ip
FROM mdl_logstore_standard_log
WHERE userid = (SELECT id FROM mdl_user WHERE username = 'jane.doe')
ORDER BY timecreated DESC
LIMIT 100;
```

This is the right table to consult when "something changed in this course yesterday" but no one knows what.
