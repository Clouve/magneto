#!/bin/sh
# Runs before the first install, as the official entrypoint's pre-installation hook (as www-data).
#
# Removes config/CAN_INSTALL. While that file exists and config.php does not say Nextcloud is installed, Nextcloud
# shows its web installer to any host name, with the database password in the page source. An install that is cut
# off after the admin user exists never recovers on its own, so the file has to be gone before any start. The
# install itself does not need it: `occ maintenance:install` works without it.
rm -f /var/www/html/config/CAN_INSTALL
