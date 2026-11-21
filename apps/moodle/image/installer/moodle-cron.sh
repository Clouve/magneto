#!/bin/bash
# Moodle Cron Job Script
# This script runs Moodle's scheduled tasks via cron.php
# It logs output to both stdout and a log file for debugging

# Set the Moodle installation path
MOODLE_PATH="/var/www/html"
LOG_FILE="/var/log/moodle-cron.log"

# Create log file if it doesn't exist
touch "$LOG_FILE"

# Log the start time
echo "========================================" >> "$LOG_FILE"
echo "Moodle Cron Started: $(date)" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"

# Run Moodle cron and capture output
# cron.php runs as www-data, as Apache does, never as root: it loads config.php and the plugins' code, which www-data
# can change, so as root it would run whatever www-data put there with root's rights. This script stays root's (the
# cron line's user), so it can write the log in root's /var/log. runuser by its full path: cron's PATH has no
# /usr/sbin. cron gives its jobs a small environment of their own, without CLOUVE_OPS_PASSWORD; env -u makes sure
# (tests/moodle-root-paths.test.sh).
if [ -f "$MOODLE_PATH/admin/cli/cron.php" ]; then
    env -u CLOUVE_OPS_PASSWORD /usr/sbin/runuser -u www-data -- /usr/local/bin/php "$MOODLE_PATH/admin/cli/cron.php" >> "$LOG_FILE" 2>&1
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        echo "Moodle Cron Completed Successfully: $(date)" >> "$LOG_FILE"
    else
        echo "Moodle Cron Failed with exit code $EXIT_CODE: $(date)" >> "$LOG_FILE"
    fi
else
    echo "ERROR: Moodle cron.php not found at $MOODLE_PATH/admin/cli/cron.php" >> "$LOG_FILE"
    echo "Moodle may not be installed yet." >> "$LOG_FILE"
fi

echo "" >> "$LOG_FILE"

