#!/bin/bash
# Puts the old LimeSurvey version back after an upgrade that finished, from the backup that the upgrade kept. Staff
# run it as root in the LimeSurvey container, with --yes-lose-what-was-written-since. It changes nothing in the
# site itself. It asks the next start to do the work, with the checks that every restore has:
#
#   1. It checks that the upgrade's folder says phase=done, that its dump still matches its stamp, that the old code
#      is in it, and that the upgrade went to the version this image holds.
#   2. It sets the state to phase=restore and writes the marker db-touched, so the next start empties the database,
#      loads the dump, removes the new code and moves the old code back (upgrade.sh).
#   3. It fills clouve/upgrade-attempts for this image's build, so that start then gives up, writes
#      clouve/upgrade-failed and runs the old version. No start upgrades again until that file is removed or the
#      image's build differs.
#
# Everything written to the site since the upgrade is lost: the dump is the database from before it. The upload
# volume is not changed.
#
# Usage: go-back.sh --yes-lose-what-was-written-since
# Exit status: 0 when the next start will put the old version back, 1 when nothing was changed.

set -u

installer=/clouve/limesurvey/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || exit 1

say() { printf '[go-back] %s\n' "$*"; }

if [ "${1:-}" != --yes-lose-what-was-written-since ] || [ "$#" -ne 1 ]; then
    sed -n 's/^# \{0,1\}//; 2,/^Exit status/p' "$0" >&2
    exit 1
fi
if [ "$(id -u)" != 0 ]; then
    say "run this as root"
    exit 1
fi
if ! ls_enter_clouve; then
    say "$LS_CLOUVE is not a folder of root's, so nothing in it is used"
    exit 1
fi

dir=""
for state in upgrade-*-to-*/state; do
    ls_trusted "$state" && [ -f "$state" ] || continue
    case "$(sed -n 's/^phase=//p' "$state" | head -n 1)" in
        done) dir="$(dirname "$state")" ;;
        backup | upgrade | restore)
            say "an upgrade is under way or waits for repair ($LS_CLOUVE/$(dirname "$state")). Nothing was changed."
            exit 1
            ;;
    esac
done
if [ -z "$dir" ]; then
    say "no upgrade folder in $LS_CLOUVE says phase=done, so there is no finished upgrade to go back from"
    exit 1
fi
from="$(sed -n 's/^from=//p' "$dir/state" | head -n 1)"
to="$(sed -n 's/^to=//p' "$dir/state" | head -n 1)"
read -r pkg_ver _ <<< "$(ls_version "$LS_PACKAGE")"
read -r vol_ver _ <<< "$(ls_version "$LS_ROOT")"
if [ "$to" != "$pkg_ver" ] || [ "$vol_ver" != "$to" ]; then
    say "the folder $LS_CLOUVE/$dir is from an upgrade to LimeSurvey $to. The volume holds ${vol_ver:-no code} and this" \
        "image $pkg_ver, so this is not the upgrade to go back from. Nothing was changed."
    exit 1
fi
want="$(sed -n 's/^sha256=//p' "$dir/backup-complete" 2>/dev/null | head -n 1)"
if ! ls_trusted "$dir/db.sql.gz" || ! ls_trusted "$dir/backup-complete" || [ -z "$want" ] ||
    [ "$(sha256sum "$dir/db.sql.gz" | cut -d' ' -f1)" != "$want" ] || ! gzip -t "$dir/db.sql.gz" 2>/dev/null; then
    say "the dump $LS_CLOUVE/$dir/db.sql.gz is not the one that was stamped complete. Nothing was changed."
    exit 1
fi
if ! ls_trusted "$dir/code" || [ ! -f "$dir/code/application/config/version.php" ]; then
    say "the old code is not in $LS_CLOUVE/$dir/code. Nothing was changed."
    exit 1
fi

# The counter first: if this script is cut off after it, nothing has changed for the site, which is at the
# package's version and never reads the counter. The marker next, and the state last: only the state makes the next
# start act.
if ! printf 'build=%s\ncount=2\nreason=the old version was put back by hand (go-back.sh)\n' "$(ls_image_build)" |
    ls_write_file upgrade-attempts ||
    ! printf 'since=%s (go-back.sh)\n' "$(ls_now)" | ls_write_file "$dir/db-touched" ||
    ! { printf 'phase=restore\nrstep=removing-new\n'; grep -v -e '^phase=' -e '^rstep=' -e '^step=' "$dir/state"; } |
        ls_write_file "$dir/state.go-back" || ! mv -f -- "$dir/state.go-back" "$dir/state"; then
    rm -f -- upgrade-attempts "$dir/db-touched" "$dir/state.go-back"
    say "the state could not be written (is the code volume full?). Nothing was changed."
    exit 1
fi
say "the next start puts LimeSurvey $from back from $LS_CLOUVE/$dir: it empties the database, loads the dump from before" \
    "the upgrade, removes the LimeSurvey $to code and moves the old code back. Everything written since the upgrade is" \
    "lost. Restart the container now. LimeSurvey $from then stays until $LS_CLOUVE/upgrade-failed is removed."
exit 0
