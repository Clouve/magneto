#!/usr/bin/env bash
# Clouve's copy of ownCloud's /etc/owncloud.d/25-chown.sh (owncloud/server 10.16.6), which `owncloud server` sources
# as root at every start. The Dockerfile checks upstream's file against its checksum before it puts this one in its
# place, and keeps upstream's at /clouve/app/upstream/25-chown.sh (never run).
#
# What upstream's does, and this one too: unless OWNCLOUD_SKIP_CHOWN is true, it gives every file and folder of the
# code tree (/var/www/owncloud) and of the volume folders (OWNCLOUD_VOLUME_ROOT, and CONFIG, FILES, APPS and
# SESSIONS when one isn't inside the root) to www-data:root when it isn't www-data:root already. Unless
# OWNCLOUD_SKIP_CHMOD is true, it makes the *.sh hook scripts in the six hook folders executable. The messages are
# upstream's.
#
# The one change: upstream ran `find ... -print0 | xargs -r -0 chown www-data:root`. chown without -h follows a link,
# and the volume belongs to www-data, so a link that www-data put there gave its target, any file of root's in the
# container (/etc/passwd, say), to www-data at the next start. Here find walks without following links (-P) and runs
# `chown -h` from inside each folder (-execdir), on plain names: a link gets the new owner itself, its target never
# does, and a folder swapped for a link while find works can't send chown anywhere else. Real files and folders end
# with the owner, group and mode upstream's gives them (tests/owncloud-domain-marker.test.sh compares the two).

# chown_tree DIR: gives what isn't www-data:root in DIR (DIR included) to www-data:root, never through a link.
chown_tree() {
  find -P "$1" \( \! -user www-data -o \! -group root \) -execdir chown -h www-data:root {} +
}

if [[ ${OWNCLOUD_SKIP_CHOWN} == "true" ]]; then
  echo "Skipping chown as requested..."
else
  echo "Fixing base perms..."
  chown_tree /var/www/owncloud

  echo "Fixing data perms..."
  chown_tree "${OWNCLOUD_VOLUME_ROOT}"

  if [[ ! ${OWNCLOUD_VOLUME_CONFIG} =~ ^${OWNCLOUD_VOLUME_ROOT} ]]; then
    echo "Fixing config perms..."
    chown_tree "${OWNCLOUD_VOLUME_CONFIG}"
  fi

  if [[ ! ${OWNCLOUD_VOLUME_FILES} =~ ^${OWNCLOUD_VOLUME_ROOT} ]]; then
    echo "Fixing file perms..."
    chown_tree "${OWNCLOUD_VOLUME_FILES}"
  fi

  if [[ ! ${OWNCLOUD_VOLUME_APPS} =~ ^${OWNCLOUD_VOLUME_ROOT} ]]; then
    echo "Fixing app perms..."
    chown_tree "${OWNCLOUD_VOLUME_APPS}"
  fi

  if [[ ! ${OWNCLOUD_VOLUME_SESSIONS} =~ ^${OWNCLOUD_VOLUME_ROOT} ]]; then
    echo "Fixing session perms..."
    chown_tree "${OWNCLOUD_VOLUME_SESSIONS}"
  fi
fi

# Upstream's lines, unchanged: the hook folders are the image's (under /etc), not the volume.
if [[ ${OWNCLOUD_SKIP_CHMOD} == "true" ]]; then
  echo "Skipping chmod as requested..."
else
  echo "Fixing hook perms..."
  find "${OWNCLOUD_PRE_INSTALL_PATH}" -iname "*.sh" -print0 | xargs -r -0 chmod +x
  find "${OWNCLOUD_POST_INSTALL_PATH}" -iname "*.sh" -print0 | xargs -r -0 chmod +x
  find "${OWNCLOUD_PRE_SERVER_PATH}" -iname "*.sh" -print0 | xargs -r -0 chmod +x
  find "${OWNCLOUD_POST_SERVER_PATH}" -iname "*.sh" -print0 | xargs -r -0 chmod +x
  find "${OWNCLOUD_PRE_CRONJOB_PATH}" -iname "*.sh" -print0 | xargs -r -0 chmod +x
  find "${OWNCLOUD_POST_CRONJOB_PATH}" -iname "*.sh" -print0 | xargs -r -0 chmod +x
fi

true
