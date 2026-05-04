#!/bin/bash
set -e

echo "Copying Moodle package from $MOODLE_PACKAGE_PATH to $MOODLE_INSTALL_PATH ..."
cp -prf "$MOODLE_PACKAGE_PATH"/* "$MOODLE_INSTALL_PATH"/
cp -prf "$MOODLE_PACKAGE_PATH"/.[a-zA-Z0-9]* "$MOODLE_INSTALL_PATH"/ 2>/dev/null || true

echo "Setting ownership of all Moodle files ..."
chown -R www-data:www-data "$MOODLE_INSTALL_PATH"/

echo "Setting permissions of all Moodle files ..."
chmod -R 755 "$MOODLE_INSTALL_PATH"/

echo "Moodle files copied successfully!"

