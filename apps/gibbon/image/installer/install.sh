#!/bin/bash
set -e

"$GIBBON_PACKAGE_INSTALLER"/upgrade.sh

echo "Executing auto.php installer at $GIBBON_INSTALL_PATH/installer/auto.php ..."
(
  cd "$GIBBON_INSTALL_PATH/installer" || exit
  php auto.php
)
echo "Executed auto.php Successfully!"