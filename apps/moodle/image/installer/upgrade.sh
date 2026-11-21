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

# reap_www_data: ends every process that the site's PHP left running.
. "$(dirname -- "${BASH_SOURCE[0]}")/www-data.sh"
# in_folder and stamp_folders: root's work inside a folder of the volume, and clouve/ and clouve/installed/ as real
# folders.
. "$(dirname -- "${BASH_SOURCE[0]}")/stamp.sh"

# Runs a command as www-data, the owner of the code tree, so that this script
# never runs a plugin file as root. su -p keeps the environment, but never
# CLOUVE_OPS_PASSWORD: the entrypoint unsets it only after this script, and it
# signs in as clouve-ops, who has passwordless sudo, so plugin code that this
# runs (version.php, upgrade code) must not see it. It goes before su, so no
# process of www-data's ever holds it.
# Every caller then ends what the command left behind with
# `reap_www_data STEP || exit 1`, a statement of its own right after it, before
# this script moves, copies or removes anything in clouve/ again: such a process
# could swap a folder there for a link at that moment, and a reap that can't
# make sure ends this script. as_www_data itself doesn't reap: it runs inside
# $( ), where the reap's exit would end only that subshell
# (tests/moodle-root-paths.test.sh).
as_www_data() {
  env -u CLOUVE_OPS_PASSWORD su -s /bin/bash -p www-data -c "$(printf '%q ' "$@")"
}

# config.php is www-data's: it is read and changed only through update-config.sh, which never follows a link there
# and changes it by renaming a new file over it.
CONFIG_TOOL="$MOODLE_PACKAGE_INSTALLER/update-config.sh"

# A plain relative folder path, as Moodle's plugin folders are.
plain_path() {
  [[ "$1" =~ ^[a-z0-9_]+(/[a-z0-9_]+)*$ ]]
}

# The plan (added-plugins.php's output) is the site's to decide: added-plugins.php loads the previous code's core
# version.php in its own process, and the previous code's lib/components.json and lib/plugins.json name the plugin
# folders. So root uses a path from the plan only after it has checked every folder on the way to it, on the volume,
# and a component only when it looks like a plugin's name. Each check runs after reap_www_data has ended every
# process of www-data's that the last step of the site's PHP left, and no PHP of the site runs again before root has
# used the path, so nothing can swap a folder for a link between the check and the use: a check of what is there is
# enough (tests/moodle-root-paths.test.sh).

# parent_of REL: the folder that holds REL, relative to the same folder; empty for a name with no slash.
parent_of() {
  if [[ "$1" == */* ]]; then printf '%s' "${1%/*}"; fi
}

# real_folders BASE REL: status 0 when BASE/REL and every folder on the way to it below BASE are real folders, none
# of them a link. An empty REL is BASE itself, whose path the caller trusts.
real_folders() {
  local path="$1" part parts=()
  IFS=/ read -r -a parts <<< "$2"
  for part in ${parts[@]+"${parts[@]}"}; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
    path+="/$part"
    [[ -d "$path" && ! -L "$path" ]] || return 1
  done
}

# folders_on_way BASE REL: status 0 when each part of BASE/REL that is there is a real folder, not a link. The parts
# that aren't there yet are made by mkdir -p, below real folders.
folders_on_way() {
  local path="$1" part parts=()
  IFS=/ read -r -a parts <<< "$2"
  for part in ${parts[@]+"${parts[@]}"}; do
    [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
    path+="/$part"
    [[ -e "$path" || -L "$path" ]] || return 0
    [[ -d "$path" && ! -L "$path" ]] || return 1
  done
}

# The table prefix in config.php ($CFG->prefix), mdl_ when it has none.
site_prefix() {
  local prefix
  prefix="$(bash "$CONFIG_TOOL" --read "$MOODLE_INSTALL_PATH/config.php" 2>/dev/null |
    sed -nE "s/^[[:space:]]*\\\$CFG->prefix[[:space:]]*=[[:space:]]*'([a-z0-9_]*)'.*/\\1/p" | head -n 1)" || :
  printf '%s' "${prefix:-mdl_}"
}

# site_sql <query>: a query on the site's database, rows tab-separated; the password goes in MYSQL_PWD, never on the
# command line.
site_sql() {
  MYSQL_PWD="${DB_PASSWORD:-}" mysql --skip-ssl -h "${DB_HOST:-}" -u "${DB_USER:-}" "${DB_NAME:-}" -N -B -e "$1"
}

# Makes this run's folder in the stash, the first time something goes there. own_folders has run: clouve/ is a real
# folder, and nothing but a real folder is at upgrade-stash.
make_stash() {
  if [[ -z "$STASH" ]]; then
    mkdir -p -- "$STASH_ROOT"
    STASH="$STASH_ROOT/$(date -u +%Y%m%d-%H%M%S)-$$"
    mkdir -- "$STASH"
  fi
}

# Everything in the code tree except what stays in place across upgrades.
code_entries() {
  find "$MOODLE_INSTALL_PATH" -mindepth 1 -maxdepth 1 \
    ! -name config.php ! -name clouve ! -name 'lost+found' -print0
}

# own_folders: clouve/ and the folders this script keeps there must be real folders, so that nothing is ever moved
# through a link. stamp_folders removes a link (or anything that isn't a folder) at clouve/ or clouve/installed/
# without following it, and an installed site gets both back, empty: the entrypoint then records the stamp. A link or
# a file where the previous code, the half-moved code or the stash goes is removed, never followed. It runs here and
# again after each step of the site's PHP, before root moves anything in clouve/.
own_folders() {
  local path
  stamp_folders "$MOODLE_INSTALL_PATH" || exit 1
  for path in "$PREV" "$PARTIAL" "$STASH_ROOT" "$PREV.done"; do
    if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
      echo "  WARNING: $path is a symbolic link or not a folder; removing it without following it."
      rm -f -- "$path"
    fi
  done
}
own_folders
# What is left of a finished upgrade whose clean-up was cut off.
rm -rf -- "$PREV.done"

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
  reap_www_data "added-plugins.php" || exit 1
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

# added-plugins.php just ran the site's code: what it left at clouve/ is checked again before the move aside.
own_folders
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
  PLAN="$(as_www_data php "$MOODLE_PACKAGE_INSTALLER/added-plugins.php" "$PREV" "$MOODLE_PACKAGE_PATH")" || PLAN=""
  reap_www_data "added-plugins.php" || exit 1
  if [[ "$(tail -n 1 <<< "$PLAN")" == end ]]; then
    while IFS=$'\t' read -r action component old new reason; do
      [[ "$action" == keep || "$action" == skip || "$action" == stop ]] || continue
      if ! [[ "$component" =~ ^[a-z][a-z0-9]*_[a-z0-9_]+$ ]]; then
        echo "  WARNING: the plan has a line whose component isn't a plugin's name."
        KEEP_PREVIOUS=1
        continue
      fi
      if ! plain_path "$old" ||
          { [[ "$action" == keep ]] && { ! plain_path "$new" || [[ "$new" == clouve || "$new" == clouve/* ]]; }; }; then
        echo "  WARNING: $component has an unexpected path in the plan."
        KEEP_PREVIOUS=1
        continue
      fi
      # A plugin is a real folder in the previous code, with no link on the way to it.
      if ! real_folders "$MOODLE_INSTALL_PATH" "clouve/upgrade-previous/$old"; then
        echo "[clouve-upgrade] WARNING: $component is held back: $PREV/$old is a link or not a folder, or a" \
          "folder on the way to it is a link"
        HELD+=("$component"$'\t'"$old"$'\t'"its folder in the previous code is a link or not a folder")
        continue
      fi
      if [[ "$action" != keep ]]; then
        HELD+=("$component"$'\t'"$old"$'\t'"$reason")
        echo "  Holding back $component ($reason)"
      elif ! folders_on_way "$MOODLE_INSTALL_PATH" "$(parent_of "$new")"; then
        echo "[clouve-upgrade] WARNING: $component is held back: a folder on the way to $MOODLE_INSTALL_PATH/$new" \
          "is a link or not a folder"
        HELD+=("$component"$'\t'"$old"$'\t'"a folder on the way to its place in the new code is a link or not a folder")
      elif [[ -e "$MOODLE_INSTALL_PATH/$new" || -L "$MOODLE_INSTALL_PATH/$new" ]]; then
        HELD+=("$component"$'\t'"$old"$'\t'"the new Moodle has its own copy")
        echo "  Holding back $component (the new Moodle has its own copy)"
      else
        # Its files go into a folder made here; cp -a copies a link inside the plugin as a link.
        [[ -z "$(parent_of "$new")" ]] || mkdir -p -- "$MOODLE_INSTALL_PATH/$(parent_of "$new")"
        mkdir -- "$MOODLE_INSTALL_PATH/$new"
        cp -a -- "$PREV/$old/." "$MOODLE_INSTALL_PATH/$new/"
        KEPT+=("$component"$'\t'"$new"$'\t'"$old")
        if [[ "$reason" != - ]]; then
          echo "  WARNING: Kept $component ($new): $reason"
        else
          echo "  Kept $component ($new)"
        fi
        # A theme based on Classic can't load where Classic is gone: Moodle shows its default theme instead. Its
        # config.php is the site's: dd reads at most 1 MiB of it, only a regular file and never through a link or
        # from a pipe (which could hold the start up), and only a yes or a no comes out.
        theme_config="$MOODLE_INSTALL_PATH/$new/config.php"
        if [[ "$component" == theme_* && ! -e "$MOODLE_INSTALL_PATH/public/theme/classic/version.php" ]] \
            && [[ -f "$theme_config" && ! -L "$theme_config" ]] \
            && dd if="$theme_config" iflag=nofollow,nonblock bs=1M count=1 status=none 2>/dev/null |
               grep -E $'parents.*[\'"]classic[\'"]' > /dev/null; then
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

# Saves the held-back plugins and drops the old code, once Moodle's upgrade is done. Moodle's CLI ran as www-data
# since the plan was checked, so own_folders and the checks run again first.
finish_previous() {
  local entry component old reason
  own_folders
  [[ -d "$PREV" ]] || return 0
  if (( KEEP_PREVIOUS )); then
    make_stash
    mv -T -- "$PREV" "$STASH/previous"
    echo "  WARNING: the previous code, with every plugin the site's admin added, is saved in $STASH/previous"
    return 0
  fi
  for entry in ${HELD[@]+"${HELD[@]}"}; do
    IFS=$'\t' read -r component old reason <<< "$entry"
    if ! real_folders "$MOODLE_INSTALL_PATH" "clouve/upgrade-previous/$old"; then
      echo "[clouve-upgrade] WARNING: $component isn't saved: $PREV/$old is a link or not a folder, or a folder on" \
        "the way to it is a link"
      continue
    fi
    make_stash
    if ! folders_on_way "$STASH" "$(parent_of "$old")" || [[ -e "$STASH/$old" || -L "$STASH/$old" ]]; then
      echo "[clouve-upgrade] WARNING: $component isn't saved: something is already at its place in $STASH"
      continue
    fi
    [[ -z "$(parent_of "$old")" ]] || mkdir -p -- "$STASH/$(parent_of "$old")"
    mv -T -- "$PREV/$old" "$STASH/$old"
    echo "  WARNING: $component held back ($reason): saved in $STASH/$old"
  done
  mv -T -- "$PREV" "$PREV.done"
  rm -rf -- "$PREV.done"
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

# www_cli: Moodle's CLI as www-data so generated cache/lock files are owned correctly, without CLOUVE_OPS_PASSWORD (as
# as_www_data): Moodle's upgrade runs the plugins' upgrade code. It doesn't reap, so it can run in a pipeline.
www_cli() {
  env -u CLOUVE_OPS_PASSWORD su -s /bin/bash -p www-data -c "php -d memory_limit=1024M $1"
}
# run_cli: www_cli, then the end of what it left running; a reap that can't make sure ends this script. Never in a
# pipeline or a $( ), where that exit would end only a subshell.
run_cli() {
  local rc=0 script="${1%% *}"
  www_cli "$1" || rc=$?
  reap_www_data "${script##*/}" || exit 1
  return "$rc"
}

# --- 4. Stale-cache purge + maintenance mode ------------------------------------
# moodledata is www-data's: each cache folder is emptied from inside it (in_folder), by plain names, so a link at the
# folder or on the way to it is never followed. Such a folder is left as it is, with a warning.
echo "  Purging stale moodledata caches ..."
_purge_here() { rm -rf -- ./* 2>/dev/null || true; }
for cache in cache localcache temp; do
  if [[ -e "${MOODLEDATA_PATH:?}/$cache" || -L "$MOODLEDATA_PATH/$cache" ]] &&
      ! in_folder "$MOODLEDATA_PATH/$cache" _purge_here; then
    echo "[clouve-upgrade] WARNING: $MOODLEDATA_PATH/$cache is a link or not a folder, so it is not emptied"
  fi
done

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
# Its reap comes after the pipeline, in this shell, so a reap that can't make sure ends this script.
run_upgrade() {
  local rc=0
  www_cli "$CLI/upgrade.php --non-interactive" 2>&1 | tee "$UPGRADE_OUT" || rc=$?
  reap_www_data "upgrade.php" || exit 1
  return "$rc"
}
# take_out <component> <new path>: removes a carried plugin's folder from the new tree. Moodle's upgrade ran as
# www-data since the copy, so every folder on the way to it is checked first (the folder itself may be a link, which
# rm removes as a link). Status 1, with a warning, when that check fails: the plugin stays in place.
take_out() {
  if ! real_folders "$MOODLE_INSTALL_PATH" "$(parent_of "$2")"; then
    echo "[clouve-upgrade] WARNING: $1 can't be held back: a folder on the way to $MOODLE_INSTALL_PATH/$2 is a link" \
      "or not a folder, so it stays in place"
    return 1
  fi
  rm -rf -- "${MOODLE_INSTALL_PATH:?}/$2"
}
# hold_back <component> <reason>: takes one carried plugin out of the new tree.
hold_back() {
  local entry component new old rest=()
  for entry in ${KEPT[@]+"${KEPT[@]}"}; do
    IFS=$'\t' read -r component new old <<< "$entry"
    if [[ "$component" == "$1" ]] && take_out "$component" "$new"; then
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
      still_kept=()
      for entry in ${KEPT[@]+"${KEPT[@]}"}; do
        IFS=$'\t' read -r component new old <<< "$entry"
        if take_out "$component" "$new"; then
          HELD+=("$component"$'\t'"$old"$'\t'"Moodle's upgrade failed twice with the added plugins in place")
        else
          still_kept+=("$entry")
        fi
      done
      KEPT=(${still_kept[@]+"${still_kept[@]}"})
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
# that sets Classic is left alone and named in the log. config.php is read and changed through update-config.sh (a link
# or anything but a regular file there is left alone), and the change takes config.php's place only if php -l passes
# the new text.
CONFIG="$MOODLE_INSTALL_PATH/config.php"
CLASSIC_SET=$'\\$CFG->theme[[:space:]]*=[[:space:]]*[\'"]classic[\'"]'
CLASSIC_LINE=$'^([[:space:]]*)(\\$CFG->theme[[:space:]]*=[[:space:]]*[\'"]classic[\'"][[:space:]]*;[[:space:]]*((//|#).*)?)$'
if [[ ! -e "$MOODLE_INSTALL_PATH/public/theme/classic/version.php" ]] \
    && CONFIG_TEXT="$(bash "$CONFIG_TOOL" --read "$CONFIG" 2>/dev/null)" && grep -qE "$CLASSIC_SET" <<< "$CONFIG_TEXT"; then
  if grep -qE "$CLASSIC_LINE" <<< "$CONFIG_TEXT"; then
    classic_rc=0
    bash "$CONFIG_TOOL" --edit --php-lint "$CONFIG" sed -E \
      "s~$CLASSIC_LINE~\\1; // Moodle 5.3 removed the Classic theme, so Clouve's upgrade turned this line off: \\2~" \
      || classic_rc=$?
    if (( classic_rc == 0 )); then
      echo "  config.php forced the Classic theme, which this Moodle doesn't have: that line is now a comment."
      CONFIG_TEXT="$(bash "$CONFIG_TOOL" --read "$CONFIG" 2>/dev/null)" || CONFIG_TEXT=""
    elif (( classic_rc == 3 )); then
      echo "  WARNING: config.php fails php -l after the change, so it is left as it was; take out its Classic theme line by hand."
    else
      echo "  WARNING: config.php couldn't be changed, so it is left as it was; take out its Classic theme line by hand."
    fi
  fi
  { grep -nE "$CLASSIC_SET" <<< "$CONFIG_TEXT" || true; } |
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
if [[ -d "$STASH_ROOT" && ! -L "$STASH_ROOT" ]]; then
  echo "  The stash $STASH_ROOT holds $(du -sh "$STASH_ROOT" | cut -f1) of held-back code from this and earlier upgrades."
fi

echo "Moodle upgrade completed successfully."
