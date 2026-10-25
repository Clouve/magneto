#!/bin/bash
# Runs at every start, as the official entrypoint's before-starting hook: as www-data, with the container's
# environment, after the entrypoint has installed or upgraded Nextcloud and let go of its init lock, and before Apache
# starts. A hook that exits with a failure stops the start, and the container restarts.
#
#   1. Refuses to start when Nextcloud is not installed. That is what an install that was cut off leaves behind, and
#      Apache would serve the web installer.
#   2. Finishes an upgrade that was cut off. A killed `occ upgrade` leaves maintenance mode on, the old version in
#      config.php and log level 0, and the entrypoint never tries it again, because it copied version.php before it
#      began. So the hook turns maintenance mode off, puts the log level back, runs `occ upgrade` once more and then
#      the post-upgrade steps the entrypoint would have run (db:add-missing-* and the expensive repair).
#   3. Runs nextcloud-config.sh. When that fails, the hook exits with its status.
#   While a restore is cut off (nc_restore_cut_off), the hook stops nothing: when occ can't report the status, or
#   nextcloud-config.sh fails, it warns and exits 0, so Apache starts and the pod gets Ready, and the AI Assistant can
#   reach it to finish or undo the restore. A half-imported database or an emptied data folder makes occ fail then.
#   4. Finishes a first install whose own settings were cut off. The post-installation hook runs them once, and its last
#      step writes a marker (the app config value clouve first_install_done). A container killed before then never
#      runs that hook again, because the next start finds Nextcloud installed. So when the marker is missing, this hook
#      runs the same steps (nc_first_install_steps in lib.sh), which write the marker at the end.
#   5. Runs the post-upgrade steps (nc_post_upgrade_steps in lib.sh) when they have not run to the end for this version.
#      Their marker, clouve post_upgrade_done, holds the version they last ran for. They delete it first and write it
#      last, so a start cut off during them leaves it missing. A marker that names another version means that they
#      never began for this one: the AI Assistant can finish an upgrade at runtime (occ.sh --init-lock upgrade), and
#      that runs none of them.
#
# Steps 4 and 5 both run occ maintenance:repair, which turns maintenance mode on while it runs and puts back the value it
# found only at its end, so a kill during the repair leaves maintenance mode on with nothing pending. A missing marker
# therefore means a cut-off run: when step 4 or 5 finds its marker missing and maintenance mode on, it turns maintenance
# mode off before it runs its steps, and says why. With the first-install marker missing, Apache has not served since
# the install (the hooks run before it), so nobody can have turned maintenance mode on on purpose. A post-upgrade marker
# for another version leaves maintenance mode as it is: the steps never began, so it was turned on some other way,
# maybe on purpose. Both steps wait for a later start while an upgrade is pending or a restore was cut off.
#
# The entrypoint has let go of its init lock by the time this hook runs, so the upgrade takes that lock itself, on the
# same file, and the post-upgrade steps run under the same hold. Steps 4 and 5 take it the same way. The health check
# counts a start as healthy while the lock is held. Without it, the check would kill a container that spends minutes in
# an upgrade, or in the first install's app downloads, with Apache not yet running.

set -u

installer=/clouve/nextcloud/installer
config_script=$installer/nextcloud-config.sh
lock=/var/www/html/nextcloud-init-sync.lock
# shellcheck source=/dev/null
. "$installer/lib.sh" || { printf '[nextcloud] ERROR: cannot read lib.sh\n' >&2; exit 1; }
# The AI Assistant's restore.sh keeps this marker while it replaces the database, config.php and the files, and it
# leaves maintenance mode on. Finishing an upgrade or turning maintenance off in the middle of that would let people into
# a half-restored instance. nc_restore_cut_off (lib.sh) also reads the note the root entrypoint leaves, since www-data
# can't see into the folder the marker is in.
restore_marker=$(nc_marker_path restore)

# www-data's home. su -p keeps root's HOME, which www-data cannot write to, and PHP then logs "Fontconfig error: No
# writable cache directories". The locked bash below inherits it.
export HOME=/var/www

# read_status: runs `occ status`. $status_text is what occ printed on stdout and $status_json its JSON line (nc_json_line
# in lib.sh: php notices can come before it and after it). Succeeds when occ exited 0 and printed that line.
read_status() {
    local rc=0
    status_text=$(nc_occ status --output=json --no-warnings) || rc=$?
    status_json=$(nc_json_line "$status_text")
    [ "$rc" -eq 0 ] && [ -n "$status_json" ]
}

# reset_log_level: puts the log level back to 2 when it reads 0. The Updater sets 0 (debug) while it runs and puts back the
# level it found when it ends, so a killed run leaves 0 behind. finish_upgrade calls this before occ upgrade, so that the
# upgrade finds 2 and puts 2 back, and again after an upgrade that failed, for an occ that died before it could.
reset_log_level() {
    local level
    level=$(nc_occ config:system:get loglevel 2>/dev/null) || level=''
    if [ "$level" = 0 ]; then
        nc_occ config:system:set loglevel --type=integer --value=2 >/dev/null || nc_warn 'could not set the log level back to 2'
    fi
}

# finish_upgrade: step 2. It does nothing while a restore was cut off.
#
# It first puts back what the killed run changed: maintenance mode goes off, and log level 0 goes back to 2. occ upgrade
# then runs as it does from the official entrypoint: it turns maintenance mode on itself, turns it off again once the
# upgrade has worked, and puts back the log level it found. An occ upgrade that finds maintenance mode on leaves it on, so
# this order matters. Otherwise maintenance mode would stay on through the post-upgrade steps, which can take minutes,
# and a start cut off during them would leave Nextcloud in maintenance mode, with no upgrade pending for the next start
# to finish. Nobody can use Nextcloud while maintenance mode is off and the upgrade is pending: Apache isn't running yet,
# cron.php does nothing, and occ loads no app's commands, as in maintenance mode.
#
# If maintenance mode can't be turned off before the upgrade, occ upgrade finds it on and leaves it on, so the hook tries
# once more after an upgrade that worked.
#
# When the upgrade fails, it stays pending, and maintenance mode is on when the Updater itself failed. (When occ never
# got that far, because flock could not open the lock file or PHP died as occ started, maintenance mode stays off.) The
# hook warns, puts the log level back if a crash left it at 0, and the start goes on.
finish_upgrade() {
    local rc=0 off_again=no
    if nc_restore_cut_off; then
        nc_warn "A restore was cut off ($restore_marker exists), so the pending upgrade and maintenance mode are left as they are. The AI Assistant can finish or undo the restore."
        return 0
    fi
    nc_log 'An upgrade is pending: a start was cut off during one, or the data is older than the code. Running occ upgrade.'
    case $status_json in
        *'"maintenance":true'*)
            if ! nc_occ maintenance:mode --off; then
                off_again=yes
                nc_warn 'could not turn maintenance mode off before the upgrade, so it is tried again after it'
            fi
            ;;
    esac
    reset_log_level
    # flock can only run a program, so the upgrade and the steps after it run in a bash that loads lib.sh. They share one
    # hold of the lock, and the steps only run when the upgrade worked.
    # shellcheck disable=SC2016  # $1 is for the inner bash, which gets the path of lib.sh as its first argument.
    flock "$lock" bash -c '. "$1" && nc_occ upgrade --no-interaction && nc_post_upgrade_steps' _ "$installer/lib.sh" || rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 66 ]; then
            # flock's own status for a lock file it cannot open. A root-owned file in /var/www/html (sticky and
            # world-writable in the official image) is refused to www-data under fs.protected_regular.
            nc_warn "The upgrade did not run: flock could not open $lock. www-data has to be able to open that file, so the root entrypoint makes it www-data's."
        else
            nc_warn "occ upgrade failed (exit status $rc)."
        fi
        nc_warn 'Nextcloud starts with the upgrade unfinished, and nobody can use it until the upgrade is done. The AI Assistant can still reach it, find out why and run the upgrade again.'
        reset_log_level
    elif [ "$off_again" = yes ]; then
        nc_occ maintenance:mode --off || nc_warn 'could not turn maintenance mode off after the upgrade either, so Nextcloud starts in maintenance mode'
    fi
}

# may_resume WHAT MODE: whether steps 4 and 5 may run the steps they finish (WHAT names them, for the log). Not while a
# restore was cut off, and not while an upgrade is pending. It asks occ for the status again, since the steps before may
# have changed it. MODE is off when the steps' marker is missing: a maintenance mode that is on was then left by their
# own repair when a start was cut off, so it goes off first, and the log says so. MODE is keep when the marker names
# another version: the steps never began, and maintenance mode stays as it is. Fails, and the steps wait for a later
# start, when any of that stands in the way.
may_resume() {
    if nc_restore_cut_off; then
        nc_warn "The $1 were never finished, and a restore was cut off ($restore_marker exists), so they wait for a later start."
        return 1
    fi
    if ! read_status; then
        nc_warn "occ did not report the status, so the $1, which were never finished, wait for a later start"
        return 1
    fi
    case $status_json in
        *'"needsDbUpgrade":true'*)
            nc_log "The $1 were never finished, but an upgrade is pending, so they wait for a later start."
            return 1
            ;;
    esac
    if [ "${2-}" != off ]; then
        return 0
    fi
    case $status_json in
        *'"maintenance":true'*)
            nc_log "Maintenance mode is on, left by a start that was cut off during the $1 (their occ maintenance:repair turns it on while it runs). Turning it off before they run again."
            if ! nc_occ maintenance:mode --off; then
                nc_warn "could not turn maintenance mode off, so the $1 wait for a later start"
                return 1
            fi
            ;;
    esac
    return 0
}

# run_locked FUNCTION WHAT: runs the lib.sh step function FUNCTION under the init lock, in a bash that loads lib.sh (flock
# can only run a program). A failure gives a warning that names WHAT, and the next start tries again.
run_locked() {
    local rc=0
    # shellcheck disable=SC2016  # $1 is for the inner bash, which gets the path of lib.sh as its first argument.
    flock "$lock" bash -c '. "$1" && "$2"' _ "$installer/lib.sh" "$1" || rc=$?
    if [ "$rc" -eq 66 ]; then
        nc_warn "The $2 did not run: flock could not open $lock. The next start tries again."
    elif [ "$rc" -ne 0 ]; then
        nc_warn "The $2 stopped with exit status $rc. The next start tries again."
    fi
}

# finish_first_install: step 4. nc_clouve_marker gives status 1 only when occ answered that the marker is not set; a read
# that failed is status 2, and then nothing runs.
finish_first_install() {
    local st=0
    nc_clouve_marker first_install_done >/dev/null || st=$?
    case $st in
        0) return 0 ;;
        1) ;;
        *)
            nc_warn 'could not read the marker clouve first_install_done, so this start does not check whether the first-install settings are done'
            return 0
            ;;
    esac
    may_resume 'first-install settings' off || return 0
    nc_log 'A first start was cut off before its first-install settings were all in place. Running them now, under the init lock.'
    run_locked nc_first_install_steps 'first-install settings'
}

# finish_post_upgrade: step 5. The version comes from the status, which is the code's: nothing in a start changes it once
# the official entrypoint has copied the code. A missing marker is a cut-off run (maintenance mode goes off first), and
# one for another version means the steps never began (maintenance mode stays as it is).
finish_post_upgrade() {
    local st=0 done_for version
    done_for=$(nc_clouve_marker post_upgrade_done) || st=$?
    case $st in
        0 | 1) ;;
        *)
            nc_warn 'could not read the marker clouve post_upgrade_done, so this start does not check whether the post-upgrade steps were finished'
            return 0
            ;;
    esac
    if ! version=$(nc_status_version "$status_json"); then
        nc_warn 'occ status gave no version, so this start does not check whether the post-upgrade steps were finished'
        return 0
    fi
    if [ "$st" -eq 0 ] && [ "$done_for" = "$version" ]; then
        return 0
    fi
    if [ "$st" -eq 1 ]; then
        may_resume "post-upgrade steps for $version" off || return 0
        nc_log "The post-upgrade steps for $version were cut off at an earlier start (the marker clouve post_upgrade_done is missing). Running them again, under the init lock."
    else
        may_resume "post-upgrade steps for $version" keep || return 0
        nc_log "The post-upgrade steps have not run for $version yet (the marker clouve post_upgrade_done says $done_for). Running them now, under the init lock, with maintenance mode left as it is."
    fi
    run_locked nc_post_upgrade_steps "post-upgrade steps for $version"
}

# 1. Is Nextcloud installed?
if ! read_status; then
    # occ cannot start without a working database. A clone's config.php still names the database of the deployment it
    # was copied from, and nextcloud-config.sh repairs that as its first step, so let it try before giving up.
    nc_warn 'occ did not report the status. Database settings in config.php can be out of date (a cloned deployment has them), so nextcloud-config.sh tries to repair them first. Then occ is asked again.'
    "$config_script" || :
    if ! read_status; then
        # A restore that was cut off can leave occ unable to start: its tables dropped and half imported, or the data
        # folder emptied with .ncdata not back yet. Stopping here would stop the container at every start, and a pod
        # that never gets Ready has no address, so the AI Assistant could not reach it to finish or undo the restore.
        if nc_restore_cut_off; then
            nc_warn "occ does not report the status, and a restore was cut off ($restore_marker exists), so the start goes on without the steps that need occ: Apache answers with Nextcloud's error or maintenance page, and the AI Assistant can finish or undo the restore. occ said: $(nc_first_lines "$status_text")"
            exit 0
        fi
        printf '[nextcloud] ERROR: occ does not report the status, so Nextcloud is not started. occ said: %s\n' "$(nc_first_lines "$status_text")" >&2
        exit 1
    fi
fi
case $status_json in
    *'"installed":true'*) ;;
    *)
        nc_log 'Nextcloud is not installed; refusing to start. See apps/nextcloud/README.md, "A half-finished first install".'
        exit 1
        ;;
esac

# 2. Is an upgrade waiting?
case $status_json in
    *'"needsDbUpgrade":true'*) finish_upgrade ;;
esac

# 3. The settings.
rc=0
"$config_script" || rc=$?
if [ "$rc" -ne 0 ]; then
    if nc_restore_cut_off; then
        nc_warn "nextcloud-config.sh failed (exit $rc), and a restore was cut off ($restore_marker exists), so the start goes on: the AI Assistant can finish or undo the restore, and the next start applies the settings again"
        exit 0
    fi
    exit "$rc"
fi

# 4. The first install's own settings, when a first start was cut off before they were done.
finish_first_install

# 5. The post-upgrade steps, when a start was cut off before they were done.
finish_post_upgrade
exit 0
