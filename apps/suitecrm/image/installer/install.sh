#!/bin/bash
# install.sh [--clear-first]
#
# A new SuiteCRM install on an empty volume. entrypoint.sh calls it when the volume holds no SuiteCRM and the
# database holds no table. The stand-in for the health check answers meanwhile. In order:
#
#   1. The install-in-progress stamp (root's, at the top of the volume). It stays until the last step, so a
#      start that finds it knows the install never finished. With --clear-first, which the entrypoint passes
#      when it found the stamp, what the unfinished install left on the volume is removed first.
#   2. The package is copied from the image as www-data, and the folders get the set-group-ID bit: on the
#      volume everything is www-data's, folders 2755 and files 0644, as SuiteCRM's install guide asks. In the
#      image the package is root's, so that www-data can't change what root reads there.
#   3. SuiteCRM's own installer, bin/console suitecrm:app:install, runs as www-data. It takes its passwords as
#      options, so install-args.php builds its argument list from the environment inside the PHP process, and
#      no password is on a command line. The installer makes the database again from nothing: it DROPS a
#      database of that name first. That is why the entrypoint never calls this script for a database that
#      holds tables, unless the stamp says this install made them.
#   4. config_si.php goes: the installer leaves it behind with the admin's and the database's passwords in
#      clear text. The settings files with the database password are closed to others.
#   5. The OAuth2 key pair for the API, mode 600, the markers the earlier image wrote, and the scheduler's
#      setting: a new install runs its scheduled jobs from the first start (scheduler-setting.php).
#   6. The stamp goes, and the script checks that it is gone: a stamp that stayed would make the next start
#      clear the volume and let SuiteCRM's installer drop the database.
#
# Exit status: 0 when SuiteCRM is installed, 1 when not, 143 when the container was asked to stop. A failed or
# stopped install keeps its stamp, so the next start clears it and installs again.

set -u

# shellcheck source=lib.sh
. /clouve/suitecrm/installer/lib.sh

# A stop request ends the install where it is. entrypoint.sh sends it to this script and to everything it
# started, so the command that was running has ended by the time the trap runs.
trap 'sc_log "the install was stopped on request. The next start clears it and installs again."; exit 143' TERM INT WINCH

version=$(sc_image_version)
if [ -z "$version" ]; then
    sc_err "the image has no SuiteCRM package in $SC_PACKAGE"
    exit 1
fi
for name in SUITECRM_ADMIN_USER SUITECRM_ADMIN_PASSWORD SUITECRM_URL; do
    if [ -z "${!name-}" ]; then
        sc_err "$name is not set, so SuiteCRM cannot be installed"
        exit 1
    fi
done

case "${SUITECRM_INSTALL_DEMO_DATA:-no}" in
    [Yy][Ee][Ss] | [Tt][Rr][Uu][Ee] | 1) demo=yes ;;
    *) demo=no ;;
esac

# --- 1. the stamp ---------------------------------------------------------------------------------------------------
if [ "${1:-}" = --clear-first ] && [ "$demo" = no ]; then
    # The stamp says that the tables in this database are a cut-off install's. Such an install has made one
    # user, the admin. More users mean that people have worked here, and their database is never dropped on a
    # stamp's word alone. (An install with demo records makes users of its own.)
    users=$(sc_sql "SELECT COUNT(*) FROM \`$DATABASE_NAME\`.users" 2> /dev/null) || users=''
    case $users in '' | *[!0-9]*) users=0 ;; esac
    if [ "$users" -gt 1 ]; then
        sc_err "$SC_INSTALL_STAMP says that an install was cut off here, but the database $DATABASE_NAME holds $users users, and a cut-off install has one. Installing again would drop that database, so nothing was changed. If this is a working site, remove the stamp. If the database really is to be made again, empty it first."
        exit 1
    fi
fi
if ! sc_install_stamp_write; then
    sc_err "could not write $SC_INSTALL_STAMP"
    exit 1
fi
if [ "${1:-}" = --clear-first ]; then
    sc_log "an install was cut off before it finished: clearing what it left on the volume and installing again"
    # Everything but the stamp and lost+found, as www-data, which owns all of it.
    if ! sc_as_www find "$SC_ROOT" -mindepth 1 -maxdepth 1 ! -name lost+found ! -name "${SC_INSTALL_STAMP##*/}" \
        -exec rm -rf -- {} +; then
        sc_err "could not clear the unfinished install from $SC_ROOT"
        exit 1
    fi
fi

# --- 2. the package -------------------------------------------------------------------------------------------------
sc_log "new install: SuiteCRM $version"
began=$SECONDS
# www-data copies the package, so every file on the volume is www-data's, with the package's modes (files 0644,
# bin/console 0755). cp can't keep a set-group-ID bit across owners, so the folders get it afterwards: 2755, as
# SuiteCRM's install guide asks. lost+found is root's and stays as it is.
if ! sc_as_www cp -a --no-preserve=ownership "$SC_PACKAGE/." "$SC_ROOT/" ||
    ! sc_as_www find "$SC_ROOT" -path "$SC_ROOT/lost+found" -prune -o -type d ! -perm 2755 -exec chmod 2755 {} +; then
    sc_err "could not copy SuiteCRM $version to $SC_ROOT"
    exit 1
fi
sc_log "the package is on the volume ($((SECONDS - began)) s)"
sc_pause install

# --- 3. the installer -----------------------------------------------------------------------------------------------
if [ "$demo" = yes ]; then sc_log "demo data will be installed"; fi
cd "$SC_ROOT" || exit 1
status=0
# umask 027: what the installer writes (config_si.php, .env.local, config.php) is never open to others.
CLV_SC_DEMO_DATA=$demo DATABASE_PORT=${DATABASE_PORT:-3306} sc_as_www bash -c \
    'umask 027; exec php -d auto_prepend_file=/clouve/suitecrm/installer/install-args.php bin/console' || status=$?

# --- 4. config_si.php and the settings files ---------------------------------------------------------------------
sc_as_www rm -f "$SC_ROOT/public/legacy/config_si.php"
if [ "$status" -ne 0 ]; then
    sc_err "SuiteCRM's installer failed (exit status $status)"
    exit 1
fi
recorded=$(sc_db_version) || recorded=''
if [ "$recorded" != "$version" ]; then
    sc_err "SuiteCRM's installer ended without recording version $version in the database"
    exit 1
fi
for file in .env.local public/legacy/config.php public/legacy/config_override.php; do
    if [ -f "$SC_ROOT/$file" ] && [ ! -L "$SC_ROOT/$file" ]; then sc_as_www chmod o-rwx "$SC_ROOT/$file"; fi
done
sc_pause install-end

# --- 5. the OAuth2 keys and the markers ----------------------------------------------------------------------------
keys=$SC_ROOT/public/legacy/Api/V8/OAuth2
if [ ! -f "$keys/private.key" ] || [ ! -f "$keys/public.key" ]; then
    if sc_as_www bash -c 'umask 077; cd "$1" && openssl genrsa -out private.key 2048 2>/dev/null &&
        openssl rsa -in private.key -pubout -out public.key 2>/dev/null' _ "$keys"; then
        sc_log "OAuth2 keys made for the API"
    else
        sc_warn "could not make the OAuth2 keys, so the API gives no tokens until they exist"
    fi
fi
# The earlier image's entrypoint looked for these two files. They are kept so that a volume this image
# installed still reads as installed to it.
sc_as_www bash -c 'date -u > "$1/.suitecrm_initialized" && printf "%s\n" "$2" > "$1/.suitecrm_url"' _ "$SC_ROOT" "$SUITECRM_URL"
# A new install has nothing queued, so its scheduler runs from the first start.
if ! sc_as_www php "$SC_INSTALLER/cron-user.php" "$SC_ROOT" || ! sc_as_www php "$SC_INSTALLER/scheduler-setting.php" on "$SC_ROOT"; then
    sc_warn "could not switch the scheduler on in SuiteCRM's settings, so no scheduled job runs until it is released (README.md, \"Staff runbook\")"
fi

# --- 6. done ---------------------------------------------------------------------------------------------------------
rm -f -- "$SC_INSTALL_STAMP"
if [ -e "$SC_INSTALL_STAMP" ] || [ -L "$SC_INSTALL_STAMP" ]; then
    sc_err "the install finished, but its stamp $SC_INSTALL_STAMP could not be removed. With the stamp there, the next start would clear this install. Remove it by hand."
    exit 1
fi
sc_log "install finished: SuiteCRM $version ($((SECONDS - began)) s)"
exit 0
