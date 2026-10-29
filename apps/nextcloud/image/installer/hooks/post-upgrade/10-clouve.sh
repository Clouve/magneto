#!/bin/bash
# Runs after the official entrypoint has upgraded Nextcloud, as its post-upgrade hook (as www-data, with the
# container's environment, inside the entrypoint's init lock, which this script must not take again).
#
# Adds the indexes, columns and primary keys that a new version expects and `occ upgrade` leaves for later, then runs
# the repairs that are too slow for `occ upgrade` itself (nc_post_upgrade_steps in lib.sh, which the before-starting
# hook runs too, after an upgrade it finishes and after a start that was cut off during them). The last step writes the
# marker clouve post_upgrade_done, the version they ran for. It always exits 0, because an upgrade that worked must not
# become a failed start when one of these steps fails. Each failure is a warning, and the next step runs.
#
# occ upgrade keeps a maintenance mode that it finds on. When the start before was cut off during these steps' repair,
# which leaves maintenance mode on, the marker is missing, and nc_post_upgrade_steps turns maintenance mode off first.

set -u

# shellcheck source=/dev/null
. /clouve/nextcloud/installer/lib.sh || { printf '[nextcloud] ERROR: cannot read lib.sh\n' >&2; exit 1; }

# www-data's home. su -p keeps root's HOME, which www-data cannot write to, and PHP then logs "Fontconfig error: No
# writable cache directories".
export HOME=/var/www

nc_post_upgrade_steps
exit 0
