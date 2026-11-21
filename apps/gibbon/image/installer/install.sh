#!/bin/bash
set -e

# reap_www_data: ends every process that auto.php left running (www-data.sh, beside this script).
# shellcheck source-path=SCRIPTDIR source=www-data.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/www-data.sh"

"$GIBBON_PACKAGE_INSTALLER"/upgrade.sh

echo "Executing auto.php installer at $GIBBON_INSTALL_PATH/installer/auto.php ..."
# As www-data, as Apache and cron run Gibbon's PHP, and without CLOUVE_OPS_PASSWORD: auto.php loads the site's own
# files, config.php among them, and a site installed again (its clouve/installed/ removed) still has the tenant's.
# Run as root, a line of PHP that www-data put in config.php would run as root.
(
  cd "$GIBBON_INSTALL_PATH/installer" || exit
  if [ "$(id -u)" = 0 ]; then
    env -u CLOUVE_OPS_PASSWORD runuser -u www-data -- php auto.php
  else
    env -u CLOUVE_OPS_PASSWORD php auto.php
  fi
)
reap_www_data "auto.php" || exit 1
echo "Executed auto.php Successfully!"

# gibbon.sql ships the school years with the statuses they had at release.
# Set them from the install date (see school-year.sh). If that fails, Gibbon
# keeps the years as shipped; it must not stop the install.
echo "Setting the school year from the install date ..."
if ! "$GIBBON_PACKAGE_INSTALLER"/school-year.sh; then
  echo "⚠ Warning: could not set the school year. Gibbon keeps the years it ships with; set the current one in School Admin > Manage School Years."
fi