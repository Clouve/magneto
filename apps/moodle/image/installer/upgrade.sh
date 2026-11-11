#!/bin/bash
set -euo pipefail

# ============================================================================
# Moodle in-place upgrade
# ============================================================================
# Invoked by entrypoint.sh ONLY when the Moodle $version baked into this image
# is newer than the version recorded on the data volume (see entrypoint.sh's
# version-stamp gate), and by install.sh to lay down the code of a new site.
# It performs Moodle's *supported* upgrade procedure.
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
# The plugins that the site's admin added (Install plugins in Moodle's UI) live
# in that tree too. So the old tree is moved aside, not deleted, and the added
# plugins are copied back into the new tree (added-plugins.php says which ones,
# and holds back those that the new Moodle ships or that won't work with it).
# The old tree stays in clouve/upgrade-previous until Moodle's upgrade succeeds,
# so a start that is cut off runs the whole upgrade again. If Moodle's upgrade
# fails twice with the added plugins in place, the one Moodle failed on is held
# back (all of them when Moodle doesn't name one) and it runs once more.
# Held-back plugins are saved in clouve/upgrade-stash/<UTC time>/, and the log
# says why. Nothing prunes the stash; the log gives its size at each upgrade.
#
# It exits with status 3, before it changes anything, when the site can't move to
# the new Moodle as it is (added-plugins.php's "stop": an added plugin that the new
# Moodle ships in an older version). The entrypoint then keeps the old code
# running and records no new version, so the next start checks again.
#
# NOTE: take a database + volume backup/snapshot BEFORE rolling out an image
# that bumps the Moodle version — this script intentionally surfaces a failed
# `upgrade.php` (non-zero exit) instead of starting a half-upgraded site.
#
# Env provided by entrypoint.sh:
#   MOODLE_PACKAGE_PATH   pristine Moodle code baked into the image
#   MOODLE_INSTALL_PATH   the persisted code dir on the volume (dirroot)
#   MOODLEDATA_PATH       the persisted moodledata dir (dataroot)
#   MOODLE_PACKAGE_INSTALLER  this folder (added-plugins.php lives here)
# ============================================================================

echo "Upgrading Moodle code: $MOODLE_PACKAGE_PATH -> $MOODLE_INSTALL_PATH"

CLOUVE_DIR="$MOODLE_INSTALL_PATH/clouve"
PREV="$CLOUVE_DIR/upgrade-previous"           # the old code, until Moodle's upgrade succeeds
PARTIAL="$CLOUVE_DIR/upgrade-previous.partial"
STASH_ROOT="$CLOUVE_DIR/upgrade-stash"
STASH=""                                      # this run's folder in the stash, made when needed
PICKED_UP=0                                   # 1 when this start picks up an upgrade that was cut off

# Runs a command as www-data, the owner of the code tree, so that this script
# never runs a plugin file as root.
as_www_data() {
  su -s /bin/bash -p www-data -c "$(printf '%q ' "$@")"
}

# A plain relative folder path, as Moodle's plugin folders are.
plain_path() {
  [[ "$1" =~ ^[a-z0-9_]+(/[a-z0-9_]+)*$ ]]
}

# The table prefix in config.php ($CFG->prefix), mdl_ when it has none.
site_prefix() {
  local prefix
  prefix="$(sed -nE "s/^[[:space:]]*\\\$CFG->prefix[[:space:]]*=[[:space:]]*'([a-z0-9_]*)'.*/\\1/p" \
    "$MOODLE_INSTALL_PATH/config.php" 2>/dev/null | head -n 1)"
  printf '%s' "${prefix:-mdl_}"
}

# site_sql <query>: a query on the site's database, rows tab-separated; the password goes in MYSQL_PWD, never on the
# command line.
site_sql() {
  MYSQL_PWD="${DB_PASSWORD:-}" mysql --skip-ssl -h "${DB_HOST:-}" -u "${DB_USER:-}" "${DB_NAME:-}" -N -B -e "$1"
}

# Makes this run's folder in the stash, the first time something goes there.
make_stash() {
  if [[ -z "$STASH" ]]; then
    mkdir -p "$STASH_ROOT"
    STASH="$STASH_ROOT/$(date -u +%Y%m%d-%H%M%S)-$$"
    mkdir "$STASH"
  fi
}

# Everything in the code tree except what stays in place across upgrades.
code_entries() {
  find "$MOODLE_INSTALL_PATH" -mindepth 1 -maxdepth 1 \
    ! -name config.php ! -name clouve ! -name 'lost+found' -print0
}

# These must be real folders, so that nothing is ever moved through a link.
if [[ -L "$CLOUVE_DIR" ]]; then
  echo "  WARNING: $CLOUVE_DIR is a symbolic link; replacing the link with a folder."
  link_target="$(readlink -f "$CLOUVE_DIR" || true)"
  rm -f "$CLOUVE_DIR"
  mkdir "$CLOUVE_DIR"
  # Keep the version stamp and install markers, which entrypoint.sh reads and writes.
  if [[ -n "$link_target" && -d "$link_target/installed" && ! -L "$link_target/installed" ]]; then
    cp -a "$link_target/installed" "$CLOUVE_DIR/installed"
  fi
fi
for path in "$PREV" "$PARTIAL" "$STASH_ROOT" "$PREV.done"; do
  if [[ -L "$path" ]]; then
    echo "  WARNING: $path is a symbolic link; removing the link."
    rm -f "$path"
  fi
done
# What is left of a finished upgrade whose clean-up was cut off.
rm -rf "$PREV.done"

# --- 1. Move the old code aside ------------------------------------------------
if [[ -d "$PARTIAL" ]]; then
  # A move aside that was cut off left the old code split between the tree and
  # $PARTIAL. Put it back together and start over.
  echo "  Putting back the code from a move aside that was cut off ..."
  find "$PARTIAL" -mindepth 1 -maxdepth 1 -exec mv -t "$MOODLE_INSTALL_PATH" {} +
  rmdir "$PARTIAL"
fi

# A site that can't move to the new Moodle as it is: stop before anything changes, and say why. The check reads the
# plugin versions the site's database records too, because Moodle compares with those: a newer copy whose folder an
# admin deleted still blocks the upgrade. If the database can't be read, the check uses the code alone.
if [[ ! -d "$PREV" && -f "$MOODLE_INSTALL_PATH/config.php" ]]; then
  RECORDED="$(mktemp)"
  site_sql "SELECT plugin, value FROM $(site_prefix)config_plugins WHERE name = 'version'" > "$RECORDED" 2>/dev/null \
    || : > "$RECORDED"
  chmod 644 "$RECORDED"
  CHECK="$(as_www_data php "$MOODLE_PACKAGE_INSTALLER/added-plugins.php" "$MOODLE_INSTALL_PATH" "$MOODLE_PACKAGE_PATH" \
    "$RECORDED")" || CHECK=""
  rm -f "$RECORDED"
  if [[ "$(tail -n 1 <<< "$CHECK")" == end ]] && grep -q $'^stop\t' <<< "$CHECK"; then
    echo "  NOT UPGRADED: this site can't move to the new Moodle as it is, so it keeps running its current code."
    while IFS=$'\t' read -r action component old new reason; do
      if [[ "$action" == stop ]]; then
        folder=""
        [[ "$old" != - ]] && folder=", $old"
        echo "  $component: $reason. Uninstall it in Moodle while the site still runs this code (Site administration >" \
          "Plugins > Plugins overview, or php admin/cli/uninstall_plugins.php --plugins=$component --run; that deletes" \
          "its data and the version Moodle recorded), then delete its folder$folder. Deleting only the folder isn't" \
          "enough. Or wait for an image whose Moodle has a newer copy of it."
      fi
    done <<< "$CHECK"
    exit 3
  fi
fi

if [[ -d "$PREV" ]]; then
  echo "  Picking up an upgrade that was cut off: the previous code is still in $PREV"
  PICKED_UP=1
  echo "  Removing the half-copied code ..."
  code_entries | xargs -0 -r rm -rf
elif [[ -f "$MOODLE_INSTALL_PATH/config.php" ]]; then
  echo "  Moving the previous code aside to $PREV ..."
  mkdir -p "$CLOUVE_DIR"
  mkdir "$PARTIAL"
  code_entries | xargs -0 -r mv -t "$PARTIAL"
  mv "$PARTIAL" "$PREV"
else
  # A new site: no code to keep.
  echo "  Removing previous code (preserving config.php, clouve/, lost+found) ..."
  code_entries | xargs -0 -r rm -rf
fi

# --- 2. Copy the pristine code ---------------------------------------------------
# While the previous code is kept aside, the copy needs room for a second tree.
if [[ -d "$PREV" ]]; then
  need_kb="$(du -sk "$MOODLE_PACKAGE_PATH" | cut -f1)" || true
  free_kb="$(df -Pk "$MOODLE_INSTALL_PATH" | awk 'NR == 2 {print $4}')" || true
  if [[ "$need_kb" =~ ^[0-9]+$ && "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb < need_kb + need_kb / 10 )); then
    echo "  WARNING: the code volume has $((free_kb / 1024)) MB free, and the new code needs about $((need_kb / 1024)) MB while the previous code is kept aside. If the copy fails, free some space on the volume."
  fi
fi
echo "  Copying pristine code into place ..."
cp -prf "$MOODLE_PACKAGE_PATH"/. "$MOODLE_INSTALL_PATH"/

# --- 3. Copy back the plugins that the site's admin added -----------------------
KEPT=()            # component<TAB>new path<TAB>old path
HELD=()            # component<TAB>old path<TAB>reason
KEEP_PREVIOUS=0    # 1 when the plan can't be trusted: the whole old tree is saved
if [[ -d "$PREV" ]]; then
  echo "  Looking for plugins that the site's admin added ..."
  if PLAN="$(as_www_data php "$MOODLE_PACKAGE_INSTALLER/added-plugins.php" "$PREV" "$MOODLE_PACKAGE_PATH")" \
      && [[ "$(tail -n 1 <<< "$PLAN")" == end ]]; then
    while IFS=$'\t' read -r action component old new reason; do
      [[ "$action" == keep || "$action" == skip || "$action" == stop ]] || continue
      if ! plain_path "$old" || { [[ "$action" == keep ]] && ! plain_path "$new"; }; then
        echo "  WARNING: $component has an unexpected path in the plan."
        KEEP_PREVIOUS=1
        continue
      fi
      if [[ "$action" != keep ]]; then
        HELD+=("$component"$'\t'"$old"$'\t'"$reason")
        echo "  Holding back $component ($reason)"
      elif [[ -e "$MOODLE_INSTALL_PATH/$new" ]]; then
        HELD+=("$component"$'\t'"$old"$'\t'"the new Moodle has its own copy")
        echo "  Holding back $component (the new Moodle has its own copy)"
      else
        mkdir -p "$(dirname "$MOODLE_INSTALL_PATH/$new")"
        cp -a "$PREV/$old" "$MOODLE_INSTALL_PATH/$new"
        KEPT+=("$component"$'\t'"$new"$'\t'"$old")
        if [[ "$reason" != - ]]; then
          echo "  WARNING: Kept $component ($new): $reason"
        else
          echo "  Kept $component ($new)"
        fi
        # A theme based on Classic can't load where Classic is gone: Moodle shows its default theme instead.
        if [[ "$component" == theme_* && ! -e "$MOODLE_INSTALL_PATH/public/theme/classic/version.php" ]] \
            && grep -qE $'parents.*[\'"]classic[\'"]' "$MOODLE_INSTALL_PATH/$new/config.php" 2>/dev/null; then
          echo "  WARNING: $component is based on the Classic theme, which this Moodle doesn't have: Moodle shows its default theme instead of it until it has a release for this Moodle."
        fi
      fi
    done <<< "$PLAN"
  else
    KEEP_PREVIOUS=1
    echo "  WARNING: could not list the plugins that the site's admin added."
  fi
fi

chown -R www-data:www-data "$MOODLE_INSTALL_PATH"/

# Saves the held-back plugins and drops the old code, once Moodle's upgrade is done.
finish_previous() {
  [[ -d "$PREV" ]] || return 0
  if (( KEEP_PREVIOUS )); then
    make_stash
    mv "$PREV" "$STASH/previous"
    echo "  WARNING: the previous code, with every plugin the site's admin added, is saved in $STASH/previous"
    return 0
  fi
  local entry component old reason
  for entry in ${HELD[@]+"${HELD[@]}"}; do
    IFS=$'\t' read -r component old reason <<< "$entry"
    make_stash
    mkdir -p "$(dirname "$STASH/$old")"
    mv "$PREV/$old" "$STASH/$old"
    echo "  WARNING: $component held back ($reason): saved in $STASH/$old"
  done
  mv "$PREV" "$PREV.done"
  rm -rf "$PREV.done"
}

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

# --- 4. Stale-cache purge + maintenance mode ------------------------------------
echo "  Purging stale moodledata caches ..."
rm -rf "${MOODLEDATA_PATH:?}"/cache/* "${MOODLEDATA_PATH:?}"/localcache/* "${MOODLEDATA_PATH:?}"/temp/* 2>/dev/null || true

# A start cut off during Moodle's upgrade leaves Moodle's upgrade lock (upgraderunning in its config table) set for up
# to 5 minutes, and until then every upgrade.php stops with "Site is being upgraded, please retry later". Nothing else
# upgrades this site (Apache and the clouve-ops sshd start only after this script), so when this start picks up a
# cut-off upgrade, the lock is the cut-off start's own and is cleared. The password goes in MYSQL_PWD, never on the
# command line.
if (( PICKED_UP )); then
  if site_sql "DELETE FROM $(site_prefix)config WHERE name = 'upgraderunning'"; then
    echo "  Cleared Moodle's upgrade lock, if the start that was cut off left one."
  else
    echo "  WARNING: could not clear Moodle's upgrade lock; if the upgrade stops on it, the next start after it expires (5 minutes) succeeds."
  fi
fi

echo "  Enabling maintenance mode ..."
run_cli "$CLI/maintenance.php --enable" || true

# --- 5. Database upgrade (mandatory; failure aborts startup) ---------------------
# An added plugin can break under the new Moodle in ways its version.php doesn't
# declare. If the upgrade fails with added plugins in place, run it again, since
# the failure may have had another cause (a dropped database connection). If it
# fails twice, hold the added plugins back and run it once more, so that the site
# comes up without them, as it did before.
# Moodle prints "-->component" for each plugin it installs or upgrades, so the last such line before a failure names
# the plugin it failed on.
UPGRADE_OUT="$(mktemp)"
run_upgrade() {
  run_cli "$CLI/upgrade.php --non-interactive" 2>&1 | tee "$UPGRADE_OUT"
}
# hold_back <component> <reason>: takes one carried plugin out of the new tree.
hold_back() {
  local entry component new old rest=()
  for entry in "${KEPT[@]}"; do
    IFS=$'\t' read -r component new old <<< "$entry"
    if [[ "$component" == "$1" ]]; then
      rm -rf "${MOODLE_INSTALL_PATH:?}/$new"
      HELD+=("$component"$'\t'"$old"$'\t'"$2")
      echo "  Holding back $component ($2)"
    else
      rest+=("$entry")
    fi
  done
  KEPT=(${rest[@]+"${rest[@]}"})
}
echo "  Running database upgrade ..."
if ! run_upgrade; then
  if (( ${#KEPT[@]} == 0 )); then
    exit 1
  fi
  echo "  Moodle's upgrade failed. Running it again with the added plugins in place ..."
  if ! run_upgrade; then
    culprit="$({ grep -E '^-->[a-z][a-z0-9_]*$' "$UPGRADE_OUT" || true; } | tail -n 1 | sed 's/^-->//')"
    upgraded=0
    if [[ -n "$culprit" ]] && printf '%s\n' "${KEPT[@]}" | grep -q "^$culprit"$'\t'; then
      echo "  WARNING: Moodle's upgrade failed twice while upgrading $culprit, a plugin the site's admin added. Holding it back and running it once more."
      hold_back "$culprit" "Moodle's upgrade failed twice while upgrading it"
      run_upgrade && upgraded=1
    fi
    if (( ! upgraded )); then
      echo "  WARNING: Moodle's upgrade failed twice with the added plugins in place. Holding them back and running it once more."
      for entry in ${KEPT[@]+"${KEPT[@]}"}; do
        IFS=$'\t' read -r component new old <<< "$entry"
        rm -rf "${MOODLE_INSTALL_PATH:?}/$new"
        HELD+=("$component"$'\t'"$old"$'\t'"Moodle's upgrade failed twice with the added plugins in place")
      done
      KEPT=()
      run_upgrade
    fi
  fi
fi
rm -f "$UPGRADE_OUT"

# --- 5b. A config.php that forces the Classic theme ------------------------------
# Moodle 5.3 removed the Classic theme. Its upgrade moves the site's Classic settings to Boost when the site theme is
# Classic (a theme forced in config.php counts, so this runs after it), uninstalls Classic, and resets every category,
# course, cohort and user theme that was Classic. It can't change config.php: a forced Classic would make Moodle ask
# for the missing theme on every page and fall back with a warning. So, unless the new code has Classic (an admin
# installed it again), a line that only sets Classic becomes an empty statement and a comment saying why (an if
# without braces keeps its body), and config.php must still pass php -l, or it is put back as it was. Any other line
# that sets Classic is left alone and named in the log.
CONFIG="$MOODLE_INSTALL_PATH/config.php"
CLASSIC_SET=$'\\$CFG->theme[[:space:]]*=[[:space:]]*[\'"]classic[\'"]'
CLASSIC_LINE=$'^([[:space:]]*)(\\$CFG->theme[[:space:]]*=[[:space:]]*[\'"]classic[\'"][[:space:]]*;[[:space:]]*((//|#).*)?)$'
if [[ -f "$CONFIG" && ! -L "$CONFIG" && ! -e "$MOODLE_INSTALL_PATH/public/theme/classic/version.php" ]] \
    && grep -qE "$CLASSIC_SET" "$CONFIG"; then
  if grep -qE "$CLASSIC_LINE" "$CONFIG"; then
    cp -p "$CONFIG" "$CONFIG.clouve-new"
    sed -i -E "s~$CLASSIC_LINE~\\1; // Moodle 5.3 removed the Classic theme, so Clouve's upgrade turned this line off: \\2~" \
      "$CONFIG.clouve-new"
    if php -l "$CONFIG.clouve-new" >/dev/null 2>&1; then
      mv "$CONFIG.clouve-new" "$CONFIG"
      echo "  config.php forced the Classic theme, which this Moodle doesn't have: that line is now a comment."
    else
      rm -f "$CONFIG.clouve-new"
      echo "  WARNING: config.php fails php -l after the change, so it is left as it was; take out its Classic theme line by hand."
    fi
  fi
  { grep -nE "$CLASSIC_SET" "$CONFIG" || true; } |
    { grep -vE '^[0-9]+:[[:space:]]*; // Moodle 5.3 removed the Classic theme' || true; } | cut -d: -f1 |
    while read -r line; do
      echo "  WARNING: config.php sets the Classic theme on line $line, which this upgrade doesn't change: change it by hand."
    done
fi

# --- 6. Purge caches post-upgrade -----------------------------------------------
echo "  Purging caches ..."
run_cli "$CLI/purge_caches.php" || true

# --- 7. Disable maintenance mode ------------------------------------------------
echo "  Disabling maintenance mode ..."
run_cli "$CLI/maintenance.php --disable" || true

# --- 8. Save the held-back plugins and drop the old code ------------------------
finish_previous
if [[ -d "$STASH_ROOT" ]]; then
  echo "  The stash $STASH_ROOT holds $(du -sh "$STASH_ROOT" | cut -f1) of held-back code from this and earlier upgrades."
fi

echo "Moodle upgrade completed successfully."
