#!/bin/bash
# A new LimeSurvey site. site.sh sources this file and calls its functions as root, from inside the state folder.
# What touches the web root or runs PHP runs as www-data (ls_www).
#
# An install keeps a stamp, clouve/install-in-progress, from before its first change until after its last check.
# The stamp holds a random token, and the same token goes into a small table in the database. A start that finds
# the stamp clears what the install had made and installs again. It drops tables only when the database holds that
# token: a database that some other install filled is never emptied. The stamp also says what was being installed:
# mode=full is the code and the database, mode=database is the database only, on a volume that already had the
# package's code and its security.php.

# ls_install_stamp MODE: writes the stamp and marks the database with its token. Status 1 when either fails.
ls_install_stamp() {
    local token
    token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    if ! printf 'token=%s\nmode=%s\nstarted=%s\nversion=%s\n' "$token" "$1" "$(ls_now)" "$pkg_ver" |
        ls_write_file install-in-progress; then
        ls_error "cannot write $LS_CLOUVE/install-in-progress"
        return 1
    fi
    if ! ls_sql "CREATE TABLE clouve_install_in_progress (token CHAR(32) NOT NULL PRIMARY KEY) ENGINE=InnoDB;
        INSERT INTO clouve_install_in_progress (token) VALUES ('$token')"; then
        ls_error "cannot mark the database $DB_NAME as being installed"
        return 1
    fi
}

# ls_install_done HOW: the version stamp, then the install stamp goes, then the marker table. If the start is
# killed between the last two, site.sh drops the table at the next start.
ls_install_done() {
    printf '%s+%s %s %s\n' "$pkg_ver" "$pkg_build" "$1" "$(ls_now)" | ls_write_file version 2>/dev/null || :
    rm -f -- install-in-progress
    ls_sql "DROP TABLE IF EXISTS clouve_install_in_progress" || :
    ls_log "the install is done"
}

# ls_install: a new site on a volume with no code and a database with no tables. Status 1 when it fails.
ls_install() {
    read -r pkg_ver pkg_db pkg_build <<< "$(ls_version "$LS_PACKAGE")"
    ls_install_stamp full || return 1
    ls_log "new install: copying LimeSurvey $pkg_ver (build $pkg_build) onto the volume"
    if ! ls_copy_package; then
        ls_error "the copy of LimeSurvey onto the volume failed"
        return 1
    fi
    ls_upload_skeleton || { ls_error "the upload volume could not be given the package's skeleton"; return 1; }
    ls_install_database || return 1
    ls_test_pause install-done
    ls_install_done installed
}

# ls_install_into_database: the volume has the package's code and the database is empty. The tables and the admin
# account are made, under the same stamp as a full install, and the code and its security.php stay.
ls_install_into_database() {
    read -r pkg_ver pkg_db pkg_build <<< "$(ls_version "$LS_PACKAGE")"
    ls_install_stamp database || return 1
    ls_install_database || return 1
    ls_test_pause install-done
    ls_install_done "installed into an empty database"
}

# ls_install_database: writes config.php when it is missing and runs LimeSurvey's own console installer, which
# makes the tables and the admin account. The admin's password reaches it in-process (console-install.php), never
# on a command line. Status 1 when the installer fails or the database isn't at the package's version afterwards.
ls_install_database() {
    local out rc=0 db_ver
    if ! ls_www php -d display_errors=0 "$LS_INSTALLER/tool.php" write-config; then
        ls_error "config.php could not be written"
        return 1
    fi
    ls_log "installing LimeSurvey's tables and the admin account"
    out="$(ls_www php "$LS_INSTALLER/console-install.php" 2>&1)" || rc=$?
    db_ver="$(ls_db_version)"
    if [ "$rc" -ne 0 ] || [ "$db_ver" != "$pkg_db" ]; then
        # The installer's output can quote its arguments, so only its first line is logged, without quoted text.
        ls_error "LimeSurvey's installer failed (status $rc, database version '${db_ver:-none}'):" \
            "$(printf '%s' "$out" | head -n 1 | cut -c1-200 | sed "s/'[^']*'/'...'/g")"
        return 1
    fi
    ls_log "LimeSurvey $pkg_ver is installed (database version $db_ver)"
}

# ls_redo_install: a start found clouve/install-in-progress. It clears what that install had made (its tables, when
# the database holds the stamp's token, and the code it copied) and installs again. Status 20 when the stamp is
# not a file of root's or the database holds tables that are not that install's (a person has to look), 1 when the
# new install fails.
ls_redo_install() {
    local token mode db_token tables
    if ! ls_trusted install-in-progress || [ ! -f install-in-progress ]; then
        ls_attention "no code" "$pkg_ver" "$LS_CLOUVE/install-in-progress is not a file of root's, so it is not acted on." \
            "Remove it, then restart the container."
        return 20
    fi
    token="$(sed -n 's/^token=\([0-9a-f]\{32\}\)$/\1/p' install-in-progress | head -n 1)"
    mode="$(sed -n 's/^mode=//p' install-in-progress | head -n 1)"
    tables="$(ls_db_tables)" || { ls_error "the database $DB_NAME can't be read"; return 1; }
    ls_log "an install was cut off (clouve/install-in-progress is there): clearing it and installing again"
    if [ "$tables" != 0 ]; then
        db_token="$(ls_sql "SELECT token FROM clouve_install_in_progress" 2>/dev/null | head -n 1)"
        if [ -z "$token" ] || [ "$db_token" != "$token" ]; then
            ls_attention "no code" "$pkg_ver" "an install was cut off on this volume, but the $tables tables in the database" \
                "$DB_NAME are not that install's, so they are left alone and nothing is installed. Empty the database, or" \
                "remove $LS_CLOUVE/install-in-progress if this volume belongs to that database. Then restart the container."
            return 20
        fi
        ls_drop_all_tables || { ls_error "the cut-off install's tables could not be dropped"; return 1; }
    fi
    if [ "$mode" = database ]; then
        # Only the database was being installed. The code and its security.php were there before and stay.
        rm -f -- install-in-progress
        ls_install_into_database
        return
    fi
    # The code the cut-off install copied. Nothing else is on the volume yet: Apache never started on it.
    ls_remove_package_names || { ls_error "cannot remove the cut-off install's code from $LS_ROOT"; return 1; }
    rm -f -- install-in-progress
    ls_install
}
