#!/usr/bin/env bash
# Clouve's copy of ownCloud's /etc/owncloud.d/45-php.sh (owncloud/server 10.16.6), which `owncloud server` sources as
# root at every start. The Dockerfile checks upstream's file against its checksum before it puts this one in its
# place, and keeps upstream's at /clouve/app/upstream/45-php.sh (never run).
#
# What upstream's does, and this one too: it renders three templates with gomplate, objectstore.config.php into the
# volume's config folder, and PHP's owncloud.ini and owncloud-apache.ini into /etc. The messages are upstream's.
#
# The one change, as in Clouve's 20-config.sh: objectstore.config.php goes through safe_put (root-paths.sh) instead of
# `gomplate -o` into the config folder, so a link or a pipe there is replaced and never followed. This step runs
# after ownCloud's own occ steps, which run the site's PHP as www-data, so a process of www-data's may still be running
# here; safe_put works from inside the checked folder, by plain names, so it can't send the write anywhere else. The
# two files in /etc are the image's, and their lines are upstream's.
# shellcheck source-path=SCRIPTDIR source=root-paths.sh
. /clouve/app/installer/root-paths.sh

echo "Writing objectstore config..."
gomplate \
  -f /etc/templates/objectstore.php.tmpl |
  safe_put "${OWNCLOUD_VOLUME_CONFIG}/objectstore.config.php"

echo "Writing php config..."
gomplate \
  -f /etc/templates/owncloud.ini.tmpl \
  -o /etc/php/7.4/mods-available/owncloud.ini
gomplate \
  -f /etc/templates/owncloud-apache.ini.tmpl \
  -o /etc/php/7.4/mods-available/owncloud-apache.ini

true
