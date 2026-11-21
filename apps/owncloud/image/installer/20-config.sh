#!/usr/bin/env bash
# Clouve's copy of ownCloud's /etc/owncloud.d/20-config.sh (owncloud/server 10.16.6), which `owncloud server` sources
# as root at every start. The Dockerfile checks upstream's file against its checksum before it puts this one in its
# place, and keeps upstream's at /clouve/app/upstream/20-config.sh (never run).
#
# What upstream's does, and this one too: it links /var/www/owncloud/custom and /var/www/owncloud/config (the image's
# code tree) to the volume's apps and config folders, then renders /etc/templates/config.php with gomplate into
# overwrite.config.php in the config folder. The messages are upstream's.
#
# The one change: upstream ran `gomplate -o "${OWNCLOUD_VOLUME_CONFIG}/overwrite.config.php"`, which writes through a
# link at that name (or opens a pipe there and waits), and the config folder is on the volume, which belongs to
# www-data. Here gomplate writes to stdout, and safe_put (root-paths.sh) puts the result into a new file it makes in
# the config folder, from inside that folder once the kernel has shown it to be the folder named, and renames it over
# the old name. A link or a pipe there is replaced and never followed; a regular file keeps its owner, group and read
# and write bits, as gomplate's write in place kept them. When the config folder is a link, or has one on the way,
# nothing is written and the start stops with a line that names the file (tests/owncloud-domain-marker.test.sh).
# shellcheck source-path=SCRIPTDIR source=root-paths.sh
. /clouve/app/installer/root-paths.sh

if [[ ! -L /var/www/owncloud/custom ]]; then
  echo "Removing custom folder..."
  rm -rf /var/www/owncloud/custom

  echo "Linking custom folder..."
  ln -sf "${OWNCLOUD_VOLUME_APPS}" /var/www/owncloud/custom
fi

if [[ ! -L /var/www/owncloud/config ]]; then
  echo "Removing config folder..."
  rm -rf /var/www/owncloud/config

  echo "Linking config folder..."
  ln -sf "${OWNCLOUD_VOLUME_CONFIG}" /var/www/owncloud/config
fi

# What a start cut off between making a new file and renaming it left in the config folder (Clouve's).
clear_temp_files "${OWNCLOUD_VOLUME_CONFIG}" overwrite.config.php objectstore.config.php

# objectstore.config.php is written later (45-php.sh), after ownCloud's own occ steps, which read every file of the
# config folder as www-data: a pipe there would hold them forever, and a link or a folder would make them fail. So
# anything there that isn't a regular file is removed now, from inside the folder and without being followed
# (Clouve's). A regular file stays until 45-php.sh replaces it.
clouve_objectstore="${OWNCLOUD_VOLUME_CONFIG}/objectstore.config.php"
if [[ -L "${clouve_objectstore}" || ( -e "${clouve_objectstore}" && ! -f "${clouve_objectstore}" ) ]]; then
  remove_entry "${clouve_objectstore}" || :
fi
unset clouve_objectstore

echo "Writing config file..."
gomplate \
  -f /etc/templates/config.php |
  safe_put "${OWNCLOUD_VOLUME_CONFIG}/overwrite.config.php"

true
