#!/bin/bash
# release-scheduler.sh
#
# Releases the held scheduler. An install that existed before this image never ran a scheduled job, so the
# image holds its scheduler until someone has looked at what is queued (README.md, "Staff runbook"). The AI
# Assistant's restore holds it too, with the file tmp/clouve-backup/scheduler-held.
#
# This script removes that file and switches the scheduler on in SuiteCRM's own settings
# ($sugar_config['clouve']['scheduler'] = 'on' in public/legacy/config_override.php, written through SuiteCRM's
# Configurator as www-data). The scheduler loop then runs SuiteCRM's scheduled jobs from its next minute on. No
# restart is needed.
#
# Run it as root in the app container, with SuiteCRM running. Exit status: 0 when the scheduler is released, 1
# when not, and it says why.

set -u

# shellcheck source=lib.sh
. /clouve/suitecrm/installer/lib.sh

if [ "$(id -u)" != 0 ]; then
    sc_err "release-scheduler.sh has to run as root (it removes a file in root's state folder)"
    exit 1
fi
cd "$SC_ROOT" || exit 1
if [ "$(sc_state_dir_status)" = untrusted ] || [ -n "$(sc_untrusted_dirs)" ]; then
    sc_err "a state folder that is not root's is on the volume (tmp/clouve-backup, or one that was moved aside to tmp/clouve-backup.untrusted-<time>). It may hold a hold file that could not be read, so the scheduler is not released. Put the folder back first (README.md, \"Staff runbook\")."
    exit 1
fi
if sc_state_has restore-in-progress; then
    sc_err "a restore is under way ($SC_RESTORE_MARKER), so the scheduler is not released now"
    exit 1
fi
if [ -e "$SC_SCHEDULER_HELD" ] || [ -L "$SC_SCHEDULER_HELD" ]; then
    rm -f -- "$SC_SCHEDULER_HELD" || { sc_err "could not remove $SC_SCHEDULER_HELD"; exit 1; }
fi
if ! sc_as_www php "$SC_INSTALLER/scheduler-setting.php" on "$SC_ROOT"; then
    sc_err "the scheduler setting could not be written to SuiteCRM's settings, so the scheduler is not released"
    exit 1
fi
if [ "$(sc_as_www php "$SC_INSTALLER/settings.php" scheduler "$SC_ROOT" 2> /dev/null)" != on ]; then
    sc_err "SuiteCRM's settings don't say that the scheduler is on, so the scheduler is not released"
    exit 1
fi
sc_log "the scheduler is released: SuiteCRM's scheduled jobs run from the next minute on"
exit 0
