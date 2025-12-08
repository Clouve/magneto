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
# The cron.php script should be run as the web server user (www-data)
if [ -f "$MOODLE_PATH/admin/cli/cron.php" ]; then
    /usr/local/bin/php "$MOODLE_PATH/admin/cli/cron.php" >> "$LOG_FILE" 2>&1
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

