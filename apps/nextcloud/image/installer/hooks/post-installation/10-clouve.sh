#!/bin/bash
# Runs once, after the first install, as the official entrypoint's post-installation hook (as www-data, with the
# container's environment, inside the entrypoint's init lock, which this script must not take again).
#
# Sets what a fresh install needs. First the settings that follow the environment (nextcloud-config.sh), then the first
# install's own settings: the admin's email, background jobs by cron, the nightly window, retention for the trash and
# for old versions, a few settings Clouve decides for every instance, and the apps a small team starts with. Those are
# nc_first_install_steps in lib.sh, which ends with two markers: clouve post_upgrade_done (a fresh install needs none of
# the post-upgrade steps) and clouve first_install_done. A container killed before the markers are written never runs
# this hook again, so the before-starting hook runs the same function at a later start when the marker is missing. It
# turns maintenance mode off first, since a kill during the steps' repair leaves it on.
#
# It always exits 0, because a first install that worked must not become a failed start over one setting or an
# unreachable app store. Each failure is a warning, and the next step runs. The AI Assistant can install the apps later.
#
# The admin password is not used here, and no step puts a password on a command line.

set -u

installer=/clouve/nextcloud/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || { printf '[nextcloud] ERROR: cannot read lib.sh\n' >&2; exit 1; }

# www-data's home. su -p keeps root's HOME, which www-data cannot write to, and PHP then logs "Fontconfig error: No
# writable cache directories".
export HOME=/var/www

rc=0
"$installer/nextcloud-config.sh" || rc=$?
if [ "$rc" -ne 0 ]; then
    nc_warn "nextcloud-config.sh failed (exit status $rc), so its settings are missing until the next start"
fi

nc_first_install_steps
exit 0
