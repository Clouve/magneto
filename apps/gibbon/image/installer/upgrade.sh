#!/bin/bash
set -e

echo "Copying Gibbon package from $GIBBON_PACKAGE_PATH to $GIBBON_INSTALL_PATH ..."
cp -prf "$GIBBON_PACKAGE_PATH"/* "$GIBBON_INSTALL_PATH"/
cp -prf "$GIBBON_PACKAGE_PATH"/.[a-zA-Z0-9]* "$GIBBON_INSTALL_PATH"/

echo "Setting ownership of all Gibbon files ..."
chown -R www-data:www-data "$GIBBON_INSTALL_PATH"/

echo "Setting permissions of all Gibbon files ..."
chmod -R 755 "$GIBBON_INSTALL_PATH"/
