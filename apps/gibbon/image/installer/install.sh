#!/bin/bash
set -e

"$GIBBON_PACKAGE_INSTALLER"/upgrade.sh

echo "Executing auto.php installer at $GIBBON_INSTALL_PATH/installer/auto.php ..."
(
  cd "$GIBBON_INSTALL_PATH/installer" || exit
  php auto.php
)
echo "Executed auto.php Successfully!"

# gibbon.sql ships the school years with the statuses they had at release.
# Set them from the install date (see school-year.sh). If that fails, Gibbon
# keeps the years as shipped; it must not stop the install.
echo "Setting the school year from the install date ..."
if ! "$GIBBON_PACKAGE_INSTALLER"/school-year.sh; then
  echo "⚠ Warning: could not set the school year. Gibbon keeps the years it ships with; set the current one in School Admin > Manage School Years."
fi