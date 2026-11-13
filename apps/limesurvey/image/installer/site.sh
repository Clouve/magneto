#!/bin/bash
# What a start does with the volume and the database. entrypoint.sh runs it as root, once the database answers and
# before Apache starts. Status 0 means Apache can start. Any other status means it must not, and the lines this
# script printed say why. 20: a person has to repair the site, and the container stays up for that. 143: the
# container was asked to stop.
#
# It runs as root because the image's state folder, /var/www/html/clouve, is root's (lib.sh says why). Everything
# that reads, writes or runs a file of the web root runs as www-data, through ls_www.
#
# It decides from three things: the version file of the code on the volume, the version file of the package in the
# image, and DBVersion in the database.
#
#   an upgrade's state file says backup, upgrade or restore   the upgrade was cut off: upgrade.sh picks it up
#   clouve/install-in-progress                                an install was cut off: clear it and install again
#   no code, no tables                                        a new install (install.sh)
#   no code, tables in the database                           waits for repair: a volume was lost or swapped
#   code, an empty database                                   the package's version: install into the database;
#                                                             another version: waits for repair
#   code, tables, but no LimeSurvey settings table            waits for repair: nothing is installed over them
#   code and database at the package's version                nothing to do
#   the package's code, an older database                     waits for repair: there is no backup of ours to go back to
#   older code                                                upgrade (upgrade.sh), unless clouve/upgrade-failed
#                                                             says this build already failed
#   newer code than the package                               refused: this needs a newer image
#   a database newer than the code                            waits for repair
#   a DBUpdateIncomplete row with no upgrade of ours          waits for repair: there is no backup to go back to
#   code and a LimeSurvey database, but no security.php       waits for repair: new keys could not read what is stored
#
# "Refused" ends the container with status 1. "Waits for repair" ends this script with status 20: Apache doesn't
# start, and entrypoint.sh keeps the container up with the stand-in page and the sshd, so that staff or the AI
# Assistant can get in. A container that stops and starts in a loop would leave nobody a way in.
#
# Then, at every start: config.php and security.php are www-data's with mode 600, config.php's database settings and
# publicurl match the environment, allowed_hosts.php names localhost and PUBLIC_URL's host, the upload volume has
# the package's skeleton, and the SuiteCRM plugin and the demo survey are set up when their variables ask for them.

set -u

installer=/clouve/limesurvey/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || exit 1
# shellcheck source=/dev/null
. "$installer/install.sh" || exit 1

# A stop request: entrypoint.sh sends SIGTERM to every process of the start. What runs ends, and so does this.
trap 'ls_log "stopped: the container was asked to stop before LimeSurvey was started"; exit 143' TERM INT WINCH

# From here the working directory is the state folder, and its files are named by relative paths (lib.sh).
if ! ls_enter_clouve || [ "$(stat -c %a . 2>/dev/null)" != 700 ]; then
    ls_error "$LS_CLOUVE is not a folder of root's with mode 700, so the image can't keep its state there"
    exit 1
fi

read -r pkg_ver pkg_db pkg_build <<< "$(ls_version "$LS_PACKAGE")"
if [ -z "${pkg_ver:-}" ] || [ -z "${pkg_db:-}" ]; then
    ls_error "the image's package has no version file"
    exit 1
fi
build="$(ls_image_build)"

# refuse MSG...: the start stops here, with the reason, and the container ends. For what nobody can repair from
# inside the container.
refuse() {
    ls_error "$@"
    exit 1
}

# hold MSG...: the volume and the database don't fit together, and a person has to repair the site. Apache must not
# start, but the container stays up for the repair (status 20, see ls_attention in lib.sh). The site's own facts
# decide this, never the lack of a state file: a state folder can be lost, or moved aside as not root's.
hold() {
    ls_attention "${vol_ver:-no code}" "$pkg_ver" "$@"
    exit 20
}

# active_upgrade: the folder of an upgrade that was cut off (its state says backup, upgrade or restore), if any.
# Only a folder and a state file that are root's and no link count.
active_upgrade() {
    local state
    for state in upgrade-*-to-*/state; do
        ls_trusted "$state" && [ -f "$state" ] || continue
        case "$(sed -n 's/^phase=//p' "$state" | head -n 1)" in
            backup | upgrade | restore) dirname "$state"; return 0 ;;
        esac
    done
}

# run_upgrade: upgrade.sh, and what its status means here. 0: the site is on the package's version. 10: the old
# version is in place and stays. 11: an upgrade that an earlier image began is closed, and the caller looks at the
# site again. Anything else stops the start.
run_upgrade() {
    local rc=0
    bash "$installer/upgrade.sh" || rc=$?
    case "$rc" in
        0 | 10) return 0 ;;
        11) return 11 ;;
        *) exit "$rc" ;;
    esac
}

# sync_settings: config.php and security.php are www-data's with mode 600 (config.php holds the database password
# and security.php the encryption keys), and config.php's database settings and publicurl match the environment. A
# copied or restored deployment, or a rotated database password, comes up with new values, and every console.php
# command of this start reads config.php, so this comes first.
sync_settings() {
    local file rc=0 changed old_url
    for file in config.php security.php allowed_hosts.php; do
        ls_www_fn ls_own_private "$LS_ROOT/application/config/$file" ||
            ls_warn "could not make application/config/$file a file of www-data's with mode 600"
    done
    [ -f "$LS_ROOT/application/config/config.php" ] || return 0
    old_url="$(ls_www php -d display_errors=0 "$installer/tool.php" publicurl 2>/dev/null)"
    changed="$(ls_www php -d display_errors=0 "$installer/tool.php" sync-config)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        ls_warn "config.php's database settings and publicurl could not be brought in step with the environment"
    elif [ -n "$changed" ]; then
        ls_log "config.php now follows the environment: $changed"
        case " $changed " in
            *' publicurl '*)
                # ./test.sh looks for these lines.
                ls_log "PUBLIC_URL has changed"
                ls_log "  old URL: $old_url"
                ls_log "  new URL: ${PUBLIC_URL:-}"
                ;;
        esac
    fi
}

# LimeSurvey makes new encryption keys when security.php is missing, even from the command line, and they can't read
# what the old ones wrote. So an install without the file stops, before any LimeSurvey code runs. An upgrade that
# was cut off is different: the file is safe in its backup folder.
missing_keys() {
    hold "application/config/security.php is missing, and the database holds a LimeSurvey install. LimeSurvey would" \
        "make new encryption keys, which can't read the encrypted answers, participants and passwords that are" \
        "stored. Put the file back from a backup, then start again."
}

# decide: looks at the volume and the database and installs, upgrades or refuses. Status 11 when upgrade.sh closed
# an upgrade that an earlier image had begun and the site has to be looked at again.
decide() {
    local tables vol_db db_ver incomplete cmp
    tables="$(ls_db_tables)" || refuse "the database $DB_NAME can't be read as $DB_USERNAME"
    read -r vol_ver vol_db _ <<< "$(ls_version "$LS_ROOT")"
    db_ver="$(ls_db_version)"
    incomplete="$(ls_db_setting DBUpdateIncomplete)"

    if [ -z "$(active_upgrade)" ] && [ ! -e install-in-progress ] && [ -n "${vol_ver:-}" ] && [ -n "$db_ver" ] &&
        [ ! -f "$LS_ROOT/application/config/security.php" ]; then
        missing_keys
    fi

    if [ -n "$(active_upgrade)" ]; then
        run_upgrade
        return
    elif [ -e install-in-progress ] || [ -L install-in-progress ]; then
        ls_redo_install || exit "$?"
    elif [ -z "${vol_ver:-}" ]; then
        if [ "$tables" != 0 ]; then
            hold "the volume holds no LimeSurvey code, but the database $DB_NAME has $tables tables. A volume was lost or" \
                "swapped. Installing over that database would also make new encryption keys, which can't read the old" \
                "answers, so nothing is installed. Put the code volume back with its application/config/security.php, or" \
                "empty the database if a new site is what you want."
        fi
        ls_install || exit 1
    elif [ -z "$db_ver" ]; then
        if [ "$tables" != 0 ]; then
            hold "the volume holds LimeSurvey $vol_ver, but the database $DB_NAME has $tables tables and none of them is" \
                "LimeSurvey's settings table ($(ls_table settings_global)). Nothing is installed over them."
        fi
        if [ "$vol_ver" != "$pkg_ver" ] || [ "$vol_db" != "$pkg_db" ]; then
            hold "the volume holds LimeSurvey $vol_ver and the database $DB_NAME is empty. This image installs" \
                "LimeSurvey $pkg_ver. If the database was lost, restore it. If a new site is what you want, empty the code" \
                "volume as well."
        fi
        ls_warn "the volume holds LimeSurvey $vol_ver and the database $DB_NAME is empty, so LimeSurvey is installed into it. The volume's security.php is kept."
        ls_install_into_database || exit 1
    elif [ -n "$incomplete" ]; then
        hold "the database says an update from version $incomplete failed or was cut off (DBUpdateIncomplete), and no" \
            "upgrade of this image is under way, so there is no backup of ours to go back to. Restore the database from a" \
            "backup taken before that update, then start again."
    else
        cmp="$(ls_vercmp "$vol_ver" "$pkg_ver")"
        if [ "$cmp" = 0 ] && [ "$vol_db" != "$pkg_db" ]; then
            if [ "$vol_db" -gt "$pkg_db" ] 2>/dev/null; then cmp=1; else cmp=-1; fi
        fi
        if [ "$cmp" = 1 ]; then
            refuse "the volume holds LimeSurvey $vol_ver (database version $vol_db), which is newer than this image's" \
                "LimeSurvey $pkg_ver (database version $pkg_db). An image never puts older code over newer code. Start" \
                "this deployment with an image of LimeSurvey $vol_ver or later."
        fi
        if [ "$db_ver" -gt "$vol_db" ] 2>/dev/null; then
            hold "the database is at version $db_ver, which is newer than the code on the volume (LimeSurvey $vol_ver," \
                "database version $vol_db). LimeSurvey doesn't notice that, and would write to tables that are gone." \
                "Restore the database that belongs to this code, or the code that belongs to this database."
        fi
        if [ "$cmp" = 0 ]; then
            if [ "$db_ver" != "$pkg_db" ]; then
                hold "the volume holds LimeSurvey $vol_ver, but the database is at version $db_ver, not $pkg_db, and no" \
                    "upgrade of this image is under way. With Apache up, anyone could start the database update from the" \
                    "browser. Take a database backup, run 'php application/commands/console.php updatedb' as www-data in" \
                    "$LS_ROOT, then start again."
            fi
            ls_log "LimeSurvey $vol_ver is installed (database version $db_ver): nothing to install or upgrade"
        elif ls_trusted upgrade-failed &&
            [ "$(sed -n 's/^build=//p' upgrade-failed | head -n 1)" = "$build" ]; then
            ls_up_log "not upgrading: the upgrade from LimeSurvey $vol_ver to $pkg_ver failed with this image" \
                "(build $build) on $(sed -n 's/^when=//p' upgrade-failed | head -n 1)." \
                "LimeSurvey $vol_ver keeps running. Remove $LS_CLOUVE/upgrade-failed to try again."
        else
            run_upgrade
            return
        fi
    fi
    return 0
}

# PUBLIC_URL goes into config.php as it is given. LimeSurvey builds its links from it, so a value that is no web
# address is worth a line.
case "${PUBLIC_URL:-}" in
    '' | http://?* | https://?*) ;;
    *) ls_warn "PUBLIC_URL does not begin with http:// or https://. It is written to config.php as it is, and" \
        "LimeSurvey builds its links from it." ;;
esac

sync_settings

# What an earlier start of this container said about a site that needed repair no longer holds.
rm -f -- needs-attention

vol_ver=""
rc=0
decide || rc=$?
if [ "$rc" -eq 11 ]; then
    rc=0
    decide || rc=$?
fi
if [ "$rc" -ne 0 ]; then
    ls_error "the start could not decide what to do with the volume (status $rc)"
    exit 1
fi

# A marker table that an install left behind when it was killed between its last two steps.
if [ ! -e install-in-progress ]; then
    ls_sql "DROP TABLE IF EXISTS clouve_install_in_progress" 2>/dev/null || :
fi

# --- at every start ---------------------------------------------------------------------------------------------------

read -r vol_ver _ <<< "$(ls_version "$LS_ROOT")"

[ -f "$LS_ROOT/application/config/security.php" ] || missing_keys

sync_settings

# LimeSurvey 7 answers its admin pages only for the hosts in allowed_hosts.php, and writes that file itself at the
# first admin sign-in, with whatever host that request used. So the file is here before anyone signs in.
if [ "${vol_ver%%.*}" -ge 7 ] 2>/dev/null; then
    rc=0
    added="$(ls_www php -d display_errors=0 "$installer/tool.php" allowed-hosts)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        ls_warn "allowed_hosts.php could not be written"
    elif [ -n "$added" ]; then
        ls_log "allowed_hosts.php gained: $added"
    fi
fi

ls_upload_skeleton || ls_warn "the upload volume could not be given the package's skeleton"

# Clouve's SuiteCRM plugin, in the Customer Kit. The plugin's files come from the package at every start, so a new
# image brings its fixes, and its settings follow the environment.
if [ "${ENABLE_SUITECRM_INTEGRATION:-}" = true ]; then
    if [ -d "$LS_PACKAGE/plugins/SuiteCRMIntegration" ]; then
        # shellcheck disable=SC2016  # the script is for the bash that ls_www starts
        if ls_www bash -c '
            rm -rf -- "$2/plugins/.SuiteCRMIntegration.clv-new" &&
                cp -a -- "$1/plugins/SuiteCRMIntegration" "$2/plugins/.SuiteCRMIntegration.clv-new" &&
                rm -rf -- "$2/plugins/SuiteCRMIntegration" &&
                mv -- "$2/plugins/.SuiteCRMIntegration.clv-new" "$2/plugins/SuiteCRMIntegration"' _ "$LS_PACKAGE" "$LS_ROOT"; then
            ls_www bash "$installer/configure-suitecrm-plugin.sh" ||
                ls_warn "the SuiteCRM plugin could not be set up. LimeSurvey starts without it."
        else
            ls_warn "the SuiteCRM plugin's files could not be copied from the package"
        fi
    fi
fi

if [ "${INSTALL_DEMO_DATA:-}" = true ]; then
    ls_www bash "$installer/import-demo-data.sh" || ls_warn "the demo survey could not be imported. LimeSurvey starts without it."
fi

exit 0
