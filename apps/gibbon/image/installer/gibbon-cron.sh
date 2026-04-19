#!/bin/bash
# Gibbon scheduled-tasks runner.
#
# Invoked by /etc/cron.d/gibbon-cron (every minute by default). Unlike Moodle,
# Gibbon v30 has no central dispatcher — its cli/ directory holds one PHP
# script per task, and upstream docs prescribe a separate crontab entry per
# script. This wrapper iterates that set, runs each script when its per-task
# interval has elapsed, and writes timestamped banners to /var/log/gibbon-cron.log
# so the Gibbon DevOps Skill can `tail` it by a known path.
#
# Install sentinel: Gibbon's own Core::isInstalled() treats a non-empty
# /var/www/html/config.php as "installed", so the wrapper bails early when it
# is absent to avoid invoking the CLI against an uninitialised schema.

set -u

GIBBON_PATH="/var/www/html"
LOG_FILE="/var/log/gibbon-cron.log"
STATE_DIR="/var/log/gibbon-cron.state"

touch "$LOG_FILE"
mkdir -p "$STATE_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

if [ ! -s "$GIBBON_PATH/config.php" ]; then
  log "Gibbon not yet installed ($GIBBON_PATH/config.php missing or empty). Skipping tick."
  exit 0
fi

# Per-task interval in minutes. Scripts omitted from this map are never run
# (e.g. system_backgroundProcessor.php, which is a worker invoked
# programmatically by Gibbon with processID/processKey arguments).
declare -A SCHEDULE_MIN=(
  [userAdmin_statusCheckAndFix]=1440
  [userAdmin_removeStaleNotifications]=1440
  [attendance_dailyIncompleteEmail]=1440
  [attendance_dailyIncompleteEmail_byClass]=1440
  [attendance_weeklySummaryEmail]=10080
  [behaviour_dailySummaryEmail]=1440
  [behaviour_lettersNegative]=1440
  [behaviour_lettersPositive]=1440
  [schoolAdmin_parentDailyEmailSummary]=1440
  [schoolAdmin_parentWeeklyEmailSummary]=10080
  [schoolAdmin_tutorDailyEmailSummary]=1440
  [library_overdueNotification]=1440
  [finance_staffPettyCashNotification]=1440
  [finance_studentPettyCashNotification]=1440
  [staff_FirstAidExpiryNotification]=1440
)

now=$(date +%s)
ran_any=0

for script in "${!SCHEDULE_MIN[@]}"; do
  script_file="$GIBBON_PATH/cli/${script}.php"
  if [ ! -f "$script_file" ]; then
    continue
  fi

  last_file="$STATE_DIR/${script}.lastrun"
  interval_sec=$(( SCHEDULE_MIN[$script] * 60 ))

  if [ -f "$last_file" ]; then
    last=$(cat "$last_file" 2>/dev/null || echo 0)
    if [ "$(( now - last ))" -lt "$interval_sec" ]; then
      continue
    fi
  fi

  ran_any=1
  log "========================================"
  log "Gibbon Cron Started: $script"
  if /usr/local/bin/php "$script_file" >> "$LOG_FILE" 2>&1; then
    log "Gibbon Cron Completed: $script"
  else
    log "Gibbon Cron Failed: $script (exit $?)"
  fi
  echo "$now" > "$last_file"
done

if [ "$ran_any" -eq 0 ]; then
  # Keep the log quiet on idle ticks — uncomment for debugging.
  : # log "Idle tick: no scheduled tasks due."
fi
