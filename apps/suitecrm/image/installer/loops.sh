#!/bin/bash
# loops.sh scheduler|worker
#
# SuiteCRM's two background jobs. The entrypoint starts each as a background process just before it becomes
# Apache, so Apache (PID 1) is their parent. Neither is ever PID 1, and when one fails it logs a line and tries
# again later: it never stops the container.
#
# Each loop is a small shell of root's, because it reads root's state folder. What it starts is SuiteCRM's own
# command, as www-data. Root runs no file that www-data can write.
#
#   scheduler  runs bin/console schedulers:run once a minute, which is SuiteCRM's replacement for its cron line.
#              It runs only while SuiteCRM's own settings switch it on ($sugar_config['clouve']['scheduler'] =
#              'on' in config_override.php). A new install sets that, and so does a release
#              (release-scheduler.sh). An install made by the earlier image has no such setting: no scheduled
#              job ever ran on it, and starting them all at once could send queued campaign email and run
#              workflows over old records without anyone's yes. The file tmp/clouve-backup/scheduler-held holds
#              the scheduler too, whatever the setting says: the AI Assistant's restore writes it. And while a
#              state folder that is not root's is on the volume, the scheduler is held as well, because a hold
#              file in it can't be read.
#   worker     runs bin/console messenger:consume internal-async, the worker SuiteCRM 8.10 needs for its
#              asynchronous tasks, capped at 256 MB and restarted every hour, as upstream's own line has it.
#
# Neither runs while the AI Assistant's restore is under way (tmp/clouve-backup/restore-in-progress) or while
# staff's pause file is there (tmp/clouve-backup/loops-paused): a command that is running then is ended, and
# the loop goes on when the file is gone.
#
# A run that fails makes the loop wait longer before the next one, up to 15 minutes for the scheduler and 5
# minutes for the worker. SIGHUP is ignored: Apache, as PID 1, passes a restart's SIGHUP on to every process in
# the container, and these would end for good.

set -u
trap '' HUP

# shellcheck source=lib.sh
. /clouve/suitecrm/installer/lib.sh
cd "$SC_ROOT" || exit 1

# last_line TEXT: its last line that isn't empty, cut to 200 characters.
last_line() {
    local line
    line=$(printf '%s\n' "$1" | awk 'NF { last = $0 } END { print last }')
    printf '%s' "${line:0:200}"
}

# paused: prints why both loops stand still, or nothing.
paused() {
    if sc_state_has restore-in-progress; then
        echo "a restore is under way ($SC_RESTORE_MARKER is there)"
    elif sc_state_has loops-paused; then
        echo "$SC_LOOPS_PAUSED is there"
    fi
}

# held: prints why the scheduler runs no job, or nothing.
held() {
    local untrusted
    untrusted=$(sc_untrusted_dirs | head -n 1)
    if sc_state_has scheduler-held; then
        echo "no scheduled job runs while $SC_SCHEDULER_HELD exists"
    elif [ "$(sc_state_dir_status)" = untrusted ] || [ -n "$untrusted" ]; then
        echo "a state folder that is not root's is on the volume (${untrusted:-$SC_STATE_DIR}), and a hold file in it can't be read"
    elif [ "$(sc_as_www php "$SC_INSTALLER/settings.php" scheduler "$SC_ROOT" 2> /dev/null)" != on ]; then
        echo "SuiteCRM's settings don't switch it on, because no scheduled job ever ran on this install"
    fi
}

# run_as_www LOG COMMAND...: runs the command as www-data and waits for it, looking every two seconds whether
# the loops are paused. A command that is still running then is ended. Its output goes to the file LOG, or
# nowhere when LOG is empty. Status: the command's own, or 200 when it was ended for a pause.
run_as_www() {
    local log=$1 pid status waited=0
    shift
    if [ -n "$log" ]; then
        setpriv --reuid=www-data --regid=www-data --init-groups -- "$@" > "$log" 2>&1 &
    else
        setpriv --reuid=www-data --regid=www-data --init-groups -- "$@" > /dev/null 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2> /dev/null; do
        if [ -n "$(paused)" ]; then
            kill -TERM "$pid" 2> /dev/null
            while kill -0 "$pid" 2> /dev/null && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
            kill -KILL "$pid" 2> /dev/null
            wait "$pid" 2> /dev/null
            return 200
        fi
        sleep 2
    done
    wait "$pid" 2> /dev/null
    status=$?
    return "$status"
}

case "${1:-}" in
    scheduler)
        wait_for=60
        fails=0
        said=''
        out=$(mktemp /tmp/clouve-scheduler.XXXXXX) || exit 1
        while :; do
            why=$(paused)
            if [ -n "$why" ]; then
                why="the scheduler stands still: $why"
            else
                why=$(held)
                if [ -n "$why" ]; then
                    why="the scheduler is held: $why (README.md, \"Staff runbook\", says how to look at what is queued and release it)"
                fi
            fi
            if [ -n "$why" ]; then
                if [ "$why" != "$said" ]; then
                    sc_log "$why"
                    said=$why
                fi
                sleep 15
                continue
            fi
            if [ -n "$said" ]; then
                sc_log "the scheduler runs: scheduled jobs run from now on"
                said=''
            fi
            began=$SECONDS
            run_as_www "$out" php bin/console schedulers:run
            status=$?
            if [ "$status" -eq 0 ]; then
                fails=0
                wait_for=60
            elif [ "$status" -eq 200 ]; then
                continue
            else
                fails=$((fails + 1))
                wait_for=$((60 * (1 << (fails < 4 ? fails : 4))))
                [ "$wait_for" -le 900 ] || wait_for=900
                sc_warn "the scheduler run failed (exit status $status), next try in $wait_for s: $(last_line "$(cat "$out" 2> /dev/null)")"
            fi
            rest=$((wait_for - (SECONDS - began)))
            [ "$rest" -ge 1 ] || rest=1
            # In slices, so that a hold or a pause is seen within seconds.
            while [ "$rest" -gt 0 ] && [ -z "$(paused)" ]; do
                slice=$((rest < 5 ? rest : 5))
                sleep "$slice"
                rest=$((rest - slice))
            done
        done
        ;;
    worker)
        wait_for=5
        said=''
        while :; do
            why=$(paused)
            if [ -n "$why" ]; then
                if [ "$why" != "$said" ]; then
                    sc_log "the Messenger worker stands still: $why"
                    said=$why
                fi
                sleep 5
                continue
            fi
            if [ -n "$said" ]; then
                sc_log "the Messenger worker runs again"
                said=''
            fi
            began=$SECONDS
            run_as_www '' php bin/console messenger:consume internal-async --time-limit=3600 --memory-limit=256M --quiet
            status=$?
            ran=$((SECONDS - began))
            if [ "$status" -eq 200 ]; then
                continue
            elif [ "$status" -eq 0 ] || [ "$ran" -ge 300 ]; then
                wait_for=5
            else
                wait_for=$((wait_for * 2))
                [ "$wait_for" -le 300 ] || wait_for=300
                sc_warn "the Messenger worker stopped after $ran s (exit status $status), starting it again in $wait_for s"
            fi
            sleep "$wait_for"
        done
        ;;
    *)
        echo "Usage: loops.sh scheduler|worker" >&2
        exit 2
        ;;
esac
