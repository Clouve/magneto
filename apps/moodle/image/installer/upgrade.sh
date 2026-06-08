#!/bin/bash
set -euo pipefail

# ============================================================================
# Moodle in-place upgrade
# ============================================================================
# Invoked by entrypoint.sh ONLY when the Moodle $version baked into this image
# is newer than the version recorded on the data volume (see entrypoint.sh's
# version-stamp gate). It performs Moodle's *supported* upgrade procedure.
#
# Why this is not a plain `cp` overlay (the previous implementation):
#   - Merging new code over old leaves orphaned files for plugins/classes that
#     were removed upstream. After a core-version bump those orphans break the
#     component scanner during bootstrap (e.g. "Call to undefined function
#     core\debugging()"), 500ing every request.
#   - Copying code without running the database upgrade leaves the schema behind
#     the code, which Moodle refuses to serve.
# So we (1) REPLACE the code tree cleanly, then (2) run the real DB upgrade.
#
# NOTE: take a database + volume backup/snapshot BEFORE rolling out an image
# that bumps the Moodle version — this script intentionally surfaces a failed
# `upgrade.php` (non-zero exit) instead of starting a half-upgraded site.
#
# Env provided by entrypoint.sh:
#   MOODLE_PACKAGE_PATH   pristine Moodle code baked into the image
#   MOODLE_INSTALL_PATH   the persisted code dir on the volume (dirroot)
#   MOODLEDATA_PATH       the persisted moodledata dir (dataroot)
# ============================================================================

echo "Upgrading Moodle code: $MOODLE_PACKAGE_PATH -> $MOODLE_INSTALL_PATH"

# --- 1. Clean code replacement -------------------------------------------------
# Replace dirroot with the image's pristine tree, preserving only the runtime
# config and Clouve bookkeeping. moodledata lives on a separate mount and is
# untouched here. This guarantees zero orphaned files from the previous release.
echo "  Removing previous code (preserving config.php, clouve/, lost+found) ..."
find "$MOODLE_INSTALL_PATH" -mindepth 1 -maxdepth 1 \
  ! -name config.php ! -name clouve ! -name 'lost+found' \
  -exec rm -rf {} +

echo "  Copying pristine code into place ..."
cp -prf "$MOODLE_PACKAGE_PATH"/. "$MOODLE_INSTALL_PATH"/
chown -R www-data:www-data "$MOODLE_INSTALL_PATH"/

# Locate Moodle's CLI dir (5.1+ may nest the codebase under public/).
CLI=""
for cand in "$MOODLE_INSTALL_PATH/admin/cli" "$MOODLE_INSTALL_PATH/public/admin/cli"; do
  if [[ -f "$cand/upgrade.php" ]]; then
    CLI="$cand"
    break
  fi
done

# If Moodle has never been installed (no config.php) or the CLI is missing,
# there is no database to upgrade — the fresh-install path handles that case.
if [[ -z "$CLI" || ! -f "$MOODLE_INSTALL_PATH/config.php" ]]; then
  echo "  Moodle not fully installed (no config.php / CLI); code copied, skipping DB upgrade."
  exit 0
fi

# Run Moodle CLI as www-data so generated cache/lock files are owned correctly.
run_cli() {
  su -s /bin/bash -p www-data -c "php -d memory_limit=1024M $1"
}

# --- 2. Stale-cache purge + maintenance mode ----------------------------------
echo "  Purging stale moodledata caches ..."
rm -rf "${MOODLEDATA_PATH:?}"/cache/* "${MOODLEDATA_PATH:?}"/localcache/* "${MOODLEDATA_PATH:?}"/temp/* 2>/dev/null || true

echo "  Enabling maintenance mode ..."
run_cli "$CLI/maintenance.php --enable" || true

# --- 3. Database upgrade (mandatory; failure aborts startup) -------------------
echo "  Running database upgrade ..."
run_cli "$CLI/upgrade.php --non-interactive"

# --- 4. Purge caches post-upgrade ---------------------------------------------
echo "  Purging caches ..."
run_cli "$CLI/purge_caches.php" || true

# --- 5. Disable maintenance mode ----------------------------------------------
echo "  Disabling maintenance mode ..."
run_cli "$CLI/maintenance.php --disable" || true

echo "Moodle upgrade completed successfully."
