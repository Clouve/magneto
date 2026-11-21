#!/bin/bash
# SC2016: many values here hold a $ on purpose (PHP code, bash -c scripts). SC2329: check and the traps run helpers.
# shellcheck disable=SC2016,SC2329

# ============================================================================
# The Gibbon image's start never reads or writes through www-data's links
# ============================================================================
# The entrypoint runs as root on the site's volume (/var/www/html), which
# belongs to www-data. Before this test's fix it wrote the install markers
# (clouve/installed/<version> and .moodle-integration-setup) with touch and
# echo >, which follow a link as root; update-config.sh edited config.php with
# sed -i and cat >, which read through a link; and install.sh ran Gibbon's installer
# (auto.php) as root, which loads config.php, so www-data could get its own PHP
# run as root by removing clouve/installed/. Its cleanup of uploads/cache
# (rm -rf .../uploads/cache/*, chmod -R) followed a link at uploads or
# uploads/cache, and upgrade.sh's cp -prf of the package over the site wrote
# through a link at any file or folder of the package.
#
# Unit cases, no Docker: installer/root-paths.sh (in_folder, plain_file,
# safe_read, safe_write, remove_entry, make_folder) takes only regular files
# that aren't links, in folders reached through no link, writes only into a
# file it has just made, and never changes anything a link points to; links
# put where a write is about to go (shims, and a flipper that exchanges a
# folder with an outside link in a tight loop, which needs python3) change
# nothing outside. ownCloud's copy of the helper is the same file.
# copy_tree (upgrade.sh's copy of the package): the package's tree, dot files
# included; the site's own files kept; links at a file, a folder and a dot
# file replaced by the package's, with nothing outside changed; a file where
# the package has a folder fails, as cp -r did; links put at each name just
# before cp writes it, and a folder exchanged with an outside link in a tight
# loop, change nothing outside. clear_temp_files removes only regular files
# named .NAME.<16 hex> (what a start cut off between dd and mv leaves), never a
# link or a folder, and nothing in a folder reached through a link.
# update-config.sh, on a made-up site with a fake mysql: config.php keeps its
# mode and gets the settings; a link, a folder or a pipe at config.php is left
# as it is with a warning that names it, nothing behind a link is read or
# changed, and the start goes on to the URL update.
# Static cases: the entrypoint writes the markers only with safe_write, tests
# them with plain_file, repairs clouve/ and clouve/installed/ before it uses
# them, and runs update-config.sh without CLOUVE_OPS_PASSWORD; update-config.sh
# has no sed -i and no write through config.php's name; install.sh runs
# auto.php as www-data without CLOUVE_OPS_PASSWORD; refresh-vendor.sh makes no
# file by a full path in the state folder and copies vendor/ only into a
# folder it has just made; root-paths.sh, update-config.sh and
# refresh-vendor.sh check a folder with /bin/pwd -P (the kernel's answer),
# never bash's builtin pwd; upgrade.sh has no cp -r over the site, copies with
# copy_tree and runs chmod -R as www-data from inside the site's folder; no
# script removes, chowns or chmods the uploads cache by its path; no runuser
# or setpriv runs with CLOUVE_OPS_PASSWORD in reach; the entrypoint clears
# cut-off leftovers in clouve/installed and beside config.php.
# Docker, before the image: refresh-vendor.sh as root in php:8.3-apache
# (pulled when missing), with shims for a www-data process that swaps clouve/
# for an outside link just before the state file is made, or puts a link at
# vendor.clouve-new just before the copy: nothing outside changes;
# reap_www_data (installer/www-data.sh, whose functions are the Moodle
# image's word for word) stops two detached processes of www-data's (setsid, a
# double fork), says how many in one line, and leaves a process of root's.
#
# Docker cases: the Gibbon image installs a site with no network (the app in
# the database's network namespace, nothing published, CLOUVE_OPS_PASSWORD
# set), then the container restarts after each of these:
#   - nothing planted, config.php given to root:www-data mode 640: no warning,
#     no upgrade, the marker unchanged, config.php keeps its owner and mode;
#   - leftovers of a cut-off write (.<marker>.<hex> and .config.php.<hex>, and
#     a link at such a name): the regular ones are removed, the link is left;
#   - the version marker a link to a missing file outside the volume: root
#     makes nothing there, the marker is a regular file again, the log names
#     the marker, and GET /index.php answers 200;
#   - clouve/installed, and then clouve, a link to a folder outside the volume:
#     nothing in it changes, both are real folders again, the log names the
#     folder, GET /index.php answers 200 (and config.php keeps its owner and
#     mode through the upgrade's restart);
#   - uploads/cache, and then uploads, a link to a folder of root's outside the
#     volume: nothing in it changes (content, owner, modes); uploads/cache is a
#     real folder of www-data's again (mode 755), a linked uploads is left with
#     a warning;
#   - links at index.php and lib/, a file of the site's own, and the version
#     marker taken away: the start copies the package again, nothing outside
#     the volume changes, index.php and lib/ are the package's again, the
#     site's file stays, and the site is www-data's with mode 755 as before;
#   - config.php a link to the process's environment: no regular config.php holds the
#     clouve-ops password, the log names config.php and holds no password; then
#     the version marker is taken away and the container restarts once more
#     (the upgrade gives the site to www-data): no file www-data can read holds
#     the password;
#   - a stand-in php whose installer step leaves a detached process of
#     www-data's that exchanges clouve/installed with an outside link in a
#     loop, and clouve/installed taken away so the installer runs: the start
#     finishes, says how many processes of www-data's it stopped, the process
#     is gone, nothing outside changes, and the marker is a regular file in a
#     real folder;
#   - clouve/installed removed and a line of PHP put in config.php, so the
#     start installs Gibbon again: the line never runs as root.
#
# --image NAME=REF (gibbon, gibbon-mysql) picks the images; the default is
# r.clv.zone/e2eorg/<name>:latest, as ./build.sh gibbon tags them. --no-docker
# runs only the unit and static cases. Every container, volume and file it
# makes is removed at the end. Needs bash, coreutils and python3 (the races);
# Docker for the last part.
#
# Usage: bash tests/gibbon-root-paths.test.sh [--image NAME=REF]... [--no-docker]
#   Exit status: 0 when every check passes, 1 when one fails, 2 when the test
#   can't run (no image, Docker missing).
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO/apps/gibbon/image/installer"
ENTRYPOINT="$INSTALLER/entrypoint.sh"
LIB="$INSTALLER/root-paths.sh"
OWNCLOUD_LIB="$REPO/apps/owncloud/image/installer/root-paths.sh"

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^ *can.t run/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

declare -A IMAGE=([gibbon]=r.clv.zone/e2eorg/gibbon:latest [gibbon-mysql]=r.clv.zone/e2eorg/gibbon-mysql:latest)
DOCKER=true
while [ $# -gt 0 ]; do
  case "$1" in
    --image)
      [[ "${2:-}" == ?*=?* ]] || usage
      name="${2%%=*}"
      [ -n "${IMAGE[$name]+set}" ] || usage
      IMAGE[$name]="${2#*=}"
      shift
      ;;
    --no-docker) DOCKER=false ;;
    *) usage ;;
  esac
  shift
done

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
PASSES=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=$((FAILED + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
# check LABEL COMMAND...: passes when the command succeeds.
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

if [ "$DOCKER" = true ] && { ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; }; then
  echo "This test needs Docker (or --no-docker)." >&2
  exit 2
fi

WORK="$(mktemp -d)"
WORK="$(cd -P "$WORK" && pwd)"   # the helper refuses a folder reached through a link
RUN="grp-t-$$"
cleanup() {
  [ -n "${FLIP_PID:-}" ] && { touch "$WORK/flip.stop"; wait "$FLIP_PID" 2>/dev/null; }
  if [ "$DOCKER" = true ]; then
    docker rm -f -v "$RUN-app" "$RUN-db" >/dev/null 2>&1
    docker volume rm -f "$RUN-site" "$RUN-dbdata" >/dev/null 2>&1
  fi
  chmod -R u+rwx "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# regular PATH: a regular file, not a link. real_dir PATH: a folder, not a link.
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
# listing DIR: every entry under DIR with its type, mode and content, to compare before and after.
listing() { (cd "$1" && find . -printf '%p %y %m\n' | sort && find . -type f -exec md5sum {} + | sort); }
# no_temp_left DIR: no temporary file of safe_write's or update-config.sh's (a name that starts with a dot) is in DIR.
no_temp_left() { [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -name '.*' -print -quit)" ]; }
fresh() { chmod -R u+rwx "$WORK/u" "$WORK/target" 2>/dev/null; rm -rf "$WORK/u" "$WORK/real" "$WORK/target" &&
  mkdir "$WORK/u"; }
# run_lib FUNCTION ARGS...: a function of root-paths.sh in a shell of its own; prints what it said, then its status.
run_lib() {
  timeout 20 bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@" 2>&1
  echo "status=$?"
}
last() { printf '%s' "${1##*$'\n'}"; }

# ----------------------------------------------------------------------------
echo "Unit cases (installer/root-paths.sh)"
# ----------------------------------------------------------------------------
if [ ! -f "$LIB" ]; then
  fail "apps/gibbon/image/installer/root-paths.sh exists"
else
  if [ -f "$OWNCLOUD_LIB" ] && cmp -s "$LIB" "$OWNCLOUD_LIB"; then
    pass "ownCloud's copy is the same file"
  else
    fail "ownCloud's copy is the same file"
  fi

  echo " in_folder and plain_file"
  fresh; mkdir "$WORK/real"; ln -s "$WORK/real" "$WORK/u/linked"; mkdir "$WORK/u/sub"
  assert_eq "a real folder: the command runs there" "$WORK/u/sub" \
    "$(bash -c '. "$1"; in_folder "$2" /bin/pwd -P' _ "$LIB" "$WORK/u/sub" 2>&1)"
  assert_eq "a folder that is a link: status 125, the command doesn't run" "status=125" \
    "$(run_lib in_folder "$WORK/u/linked" touch ran)"
  check "a folder that is a link: nothing is made in its target" test ! -e "$WORK/real/ran"
  mkdir "$WORK/real/deeper"
  assert_eq "a folder with a link on the way: status 125" "status=125" "$(run_lib in_folder "$WORK/u/linked/deeper" true)"
  assert_eq "a missing folder: status 125" "status=125" "$(run_lib in_folder "$WORK/u/missing" true)"
  printf 'x\n' > "$WORK/u/file"; ln -s file "$WORK/u/link"; mkfifo "$WORK/u/pipe"; printf 'x\n' > "$WORK/real/f"
  assert_eq "plain_file: a regular file" "status=0" "$(run_lib plain_file "$WORK/u/file")"
  assert_eq "plain_file: a link to a regular file" "status=1" "$(run_lib plain_file "$WORK/u/link")"
  assert_eq "plain_file: a folder" "status=1" "$(run_lib plain_file "$WORK/u/sub")"
  assert_eq "plain_file: a pipe" "status=1" "$(run_lib plain_file "$WORK/u/pipe")"
  assert_eq "plain_file: a missing file" "status=1" "$(run_lib plain_file "$WORK/u/missing")"
  assert_eq "plain_file: a regular file in a folder reached through a link" "status=125" \
    "$(run_lib plain_file "$WORK/u/linked/f")"

  echo " safe_read"
  fresh; printf 'example.test\n' > "$WORK/u/m"
  assert_eq "a regular file: its text, status 0" "$(printf 'example.test\nstatus=0')" "$(run_lib safe_read "$WORK/u/m" 300)"
  fresh; printf '0123456789' > "$WORK/u/m"
  assert_eq "at most MAX bytes" "$(printf '0123status=0')" "$(run_lib safe_read "$WORK/u/m" 4)"
  fresh; printf 'a\0b' > "$WORK/u/m"
  assert_eq "a NUL byte comes out as ?" "$(printf 'a?bstatus=0')" "$(run_lib safe_read "$WORK/u/m" 300)"
  fresh; printf 'secret\n' > "$WORK/target"; chmod 600 "$WORK/target"; ln -s "$WORK/target" "$WORK/u/m"
  assert_eq "a link to a file: nothing, status 1" "status=1" "$(run_lib safe_read "$WORK/u/m" 300)"
  fresh; mkfifo "$WORK/u/m"
  assert_eq "a pipe: nothing, status 1, no wait" "status=1" "$(run_lib safe_read "$WORK/u/m" 300)"
  fresh; mkdir "$WORK/u/m"
  assert_eq "a folder: nothing, status 1" "status=1" "$(run_lib safe_read "$WORK/u/m" 300)"
  fresh
  assert_eq "a missing file: nothing, status 1" "status=1" "$(run_lib safe_read "$WORK/u/m" 300)"
  fresh; mkdir "$WORK/real"; printf 'example.test\n' > "$WORK/real/m"; ln -s "$WORK/real" "$WORK/u/linked"
  assert_eq "a file in a folder reached through a link: nothing, status 125" "status=125" \
    "$(run_lib safe_read "$WORK/u/linked/m" 300)"
  # A shim dd that swaps the file for a link to the secret just before it opens it: nofollow must refuse.
  mkdir -p "$WORK/shim-read"
  cat > "$WORK/shim-read/dd" <<'SH'
#!/bin/bash
PATH="${PATH#*:}"
for a in "$@"; do case $a in if=*) rm -f -- "${a#if=}"; ln -s -- "$SHIM_TARGET" "${a#if=}" ;; esac; done
exec dd "$@"
SH
  chmod 755 "$WORK/shim-read/dd"
  fresh; printf 'secret\n' > "$WORK/target"; chmod 600 "$WORK/target"; printf 'example.test\n' > "$WORK/u/m"
  out="$(SHIM_TARGET="$WORK/target" PATH="$WORK/shim-read:$PATH" run_lib safe_read "$WORK/u/m" 300)"
  assert_eq "the file swapped for a link just before the read: nothing of the link's target is read" "status=1" "$out"

  echo " safe_write"
  fresh
  assert_eq "a new file: status 0 and nothing said" "status=0" "$(run_lib safe_write "$WORK/u/version" 2026-11-20-12-00-00)"
  assert_eq "a new file: it holds the text and a newline" "$(printf '2026-11-20-12-00-00\nx')" \
    "$(cat "$WORK/u/version"; echo x)"
  assert_eq "a new file: mode 644" "644" "$(stat -c %a "$WORK/u/version")"
  check "a new file: no temporary file is left" no_temp_left "$WORK/u"

  fresh; printf 'outside\n' > "$WORK/target"; chmod 600 "$WORK/target"; ln -s "$WORK/target" "$WORK/u/version"
  assert_eq "over a link: status 0" "status=0" "$(run_lib safe_write "$WORK/u/version" stamp)"
  assert_eq "over a link: the link's target is unchanged" "outside 600" \
    "$(cat "$WORK/target") $(stat -c %a "$WORK/target")"
  check "over a link: a regular file is left" regular "$WORK/u/version"

  fresh; ln -s "$WORK/target" "$WORK/u/version"
  assert_eq "over a link to a missing file: status 0" "status=0" "$(run_lib safe_write "$WORK/u/version" stamp)"
  check "over a link to a missing file: nothing is made where it pointed" test ! -e "$WORK/target"
  check "over a link to a missing file: a regular file is left" regular "$WORK/u/version"

  fresh; mkdir "$WORK/real"; ln -s "$WORK/real" "$WORK/u/version"
  assert_eq "over a link to a folder: status 0" "status=0" "$(run_lib safe_write "$WORK/u/version" stamp)"
  check "over a link to a folder: a regular file replaces the link (mv -T)" regular "$WORK/u/version"
  assert_eq "over a link to a folder: nothing is moved into the folder" "" "$(ls -A "$WORK/real")"

  fresh; mkdir -p "$WORK/u/version/sub"; printf 'keep\n' > "$WORK/target"; ln -s "$WORK/target" "$WORK/u/version/sub/link"
  assert_eq "over a planted folder: status 0" "status=0" "$(run_lib safe_write "$WORK/u/version" stamp)"
  check "over a planted folder: a regular file is left" regular "$WORK/u/version"
  assert_eq "over a planted folder: a link inside it was never followed" "keep" "$(cat "$WORK/target" 2>&1)"

  fresh; mkfifo "$WORK/u/version"
  assert_eq "over a pipe: status 0 (it doesn't wait on it)" "status=0" "$(run_lib safe_write "$WORK/u/version" stamp)"
  check "over a pipe: a regular file is left" regular "$WORK/u/version"

  fresh; mkdir "$WORK/real"; ln -s "$WORK/real" "$WORK/u/linked"
  out="$(run_lib safe_write "$WORK/u/linked/version" stamp)"
  assert_eq "in a folder reached through a link: status 1" "status=1" "$(last "$out")"
  check "in a folder reached through a link: the ✗ Error line names the file" \
    grep -qF "✗ Error: can't write $WORK/u/linked/version" <<< "$out"
  assert_eq "in a folder reached through a link: nothing is written there" "" "$(ls -A "$WORK/real")"

  if [ "$(id -u)" -eq 0 ]; then
    echo "  (skipped) into a read-only folder: root can write there anyway"
  else
    fresh; chmod 555 "$WORK/u"
    out="$(run_lib safe_write "$WORK/u/version" stamp)"
    assert_eq "into a read-only folder: status 1" "status=1" "$(last "$out")"
    check "into a read-only folder: nothing is left there" test -z "$(ls -A "$WORK/u")"
    chmod 755 "$WORK/u"
  fi

  # Shims that do what a www-data process watching the folder could: put a link to $SHIM_TARGET where safe_write is
  # about to write. shim-open acts on dd's of= before the real dd runs; shim-rename on the new file just before mv.
  mkdir -p "$WORK/shim-open" "$WORK/shim-rename"
  cat > "$WORK/shim-open/dd" <<'SH'
#!/bin/bash
PATH="${PATH#*:}"
for a in "$@"; do case $a in of=*) ln -s -- "$SHIM_TARGET" "${a#of=}" ;; esac; done
exec dd "$@"
SH
  cat > "$WORK/shim-rename/mv" <<'SH'
#!/bin/bash
PATH="${PATH#*:}"
src="${*: -2:1}"
rm -f -- "$src" && ln -s -- "$SHIM_TARGET" "$src"
exec mv "$@"
SH
  chmod 755 "$WORK"/shim-open/* "$WORK"/shim-rename/*
  swap_case() {
    local out
    fresh; printf 'secret\n' > "$WORK/target"; chmod 600 "$WORK/target"
    out="$(SHIM_TARGET="$WORK/target" PATH="$WORK/$1:$PATH" run_lib safe_write "$WORK/u/version" stamp)"
    if [[ "$(last "$out")" == status=1 ]] || { [[ "$(last "$out")" == status=0 ]] && regular "$WORK/u/version" &&
        [[ "$(cat "$WORK/u/version")" == stamp ]]; }; then
      pass "$2: the write fails, or a new regular file holds the text"
    else
      fail "$2: the write fails, or a new regular file holds the text"; printf '       got: %q\n' "$out"
    fi
    assert_eq "$2: the link's target keeps its content and mode" "secret 600" \
      "$(cat "$WORK/target") $(stat -c %a "$WORK/target")"
    check "$2: nothing of the write is left in the folder" no_temp_left "$WORK/u"
  }
  swap_case shim-open "a link put at the new file's name as soon as it is known"
  swap_case shim-rename "the new file swapped for a link just before the rename"

  echo " remove_entry and make_folder"
  fresh; mkdir -p "$WORK/target/installed"; printf 'keep\n' > "$WORK/target/installed/keep"
  ln -s "$WORK/target/installed" "$WORK/u/installed"; before="$(listing "$WORK/target")"
  assert_eq "remove_entry on a link to a folder: status 0" "status=0" "$(run_lib remove_entry "$WORK/u/installed")"
  check "remove_entry on a link to a folder: the link is gone" eval '[ ! -e "$WORK/u/installed" ] && [ ! -L "$WORK/u/installed" ]'
  assert_eq "remove_entry on a link to a folder: the target is unchanged" "$before" "$(listing "$WORK/target")"
  assert_eq "make_folder: status 0" "status=0" "$(run_lib make_folder "$WORK/u/installed")"
  check "make_folder: a real folder" real_dir "$WORK/u/installed"
  fresh; mkdir "$WORK/real"; ln -s "$WORK/real" "$WORK/u/linked"
  assert_eq "make_folder under a link: status 125" "status=125" "$(run_lib make_folder "$WORK/u/linked/made")"
  check "make_folder under a link: nothing is made in the target" test ! -e "$WORK/real/made"

  # A folder exchanged with a link to an outside folder (renameat2 RENAME_EXCHANGE) in a tight loop, so the path is a
  # link only for moments: what a check that reads the path twice (bash's builtin pwd -P after cd -P) can miss. Every
  # write, removal and mkdir must stay in the folder that was checked. Needs python3 and a filesystem that can exchange
  # two names; otherwise skipped.
  cat > "$WORK/flip.py" <<'FLIP'
import ctypes, os, sys
a, b, stop, ready = (arg.encode() for arg in sys.argv[1:5])
exchange = ctypes.CDLL(None, use_errno=True).renameat2
exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
AT_FDCWD, RENAME_EXCHANGE = -100, 2
if exchange(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE) != 0:
    sys.exit(3)
open(ready, "w").close()
n = 0
while n % 1024 or not os.path.exists(stop):
    exchange(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)
    n += 1
if os.path.islink(a):
    exchange(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)
FLIP
  start_flip() {
    rm -f "$WORK/flip.stop" "$WORK/flip.ready"
    python3 -I "$WORK/flip.py" "$1" "$2" "$WORK/flip.stop" "$WORK/flip.ready" &
    FLIP_PID=$!
    until [ -e "$WORK/flip.ready" ]; do
      kill -0 "$FLIP_PID" 2>/dev/null || { wait "$FLIP_PID"; FLIP_PID=""; return 1; }
      sleep 0.01
    done
  }
  stop_flip() { touch "$WORK/flip.stop"; wait "$FLIP_PID"; FLIP_PID=""; }
  race_call() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@" >/dev/null 2>&1; echo "$?"; }
  # race_loop N OUTSIDE FUNCTION ARGS...: N calls while the flipper runs; prints "<calls that changed OUTSIDE> <calls
  # that returned neither 0, 1 nor 125>". OUTSIDE is put back as it was after each call that changed it.
  race_loop() {
    local n="$1" outside="$2" before hits=0 odd=0 saved="$WORK/race.saved"
    shift 2
    rm -rf "$saved"; cp -a "$outside" "$saved"; before="$(listing "$outside")"
    for _ in $(seq "$n"); do
      case "$(race_call "$@")" in 0 | 1 | 125) ;; *) odd=$((odd + 1)) ;; esac
      if [ "$(listing "$outside")" != "$before" ]; then
        hits=$((hits + 1))
        find "$outside" -mindepth 1 -delete; cp -a "$saved/." "$outside/"
      fi
    done
    echo "$hits $odd"
  }
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  (skipped) the exchange races: they need python3"
  else
    rm -rf "$WORK/rx"; mkdir -p "$WORK/rx/S/clouve/installed" "$WORK/rx/X/installed"
    ln -s "$WORK/rx/X" "$WORK/rx/S/clink"
    printf 'secret\n' > "$WORK/rx/X/installed/30.0.01"; chmod 600 "$WORK/rx/X/installed/30.0.01"
    printf 'keep\n' > "$WORK/rx/X/installed/keep"
    if ! start_flip "$WORK/rx/S/clouve" "$WORK/rx/S/clink"; then
      echo "  (skipped) the exchange races: this filesystem can't exchange two names (renameat2)"
    else
      read -r hits odd <<< "$(race_loop 300 "$WORK/rx/X" safe_write "$WORK/rx/S/clouve/installed/30.0.01" stamp)"
      assert_eq "clouve exchanged with an outside link in a tight loop: none of 300 writes changes anything outside" \
        "0" "$hits"
      assert_eq "clouve exchanged with an outside link: every write returns 0 or 1" "0" "$odd"
      read -r hits odd <<< "$(race_loop 300 "$WORK/rx/X" remove_entry "$WORK/rx/S/clouve/installed/keep")"
      assert_eq "clouve exchanged with an outside link: none of 300 removals removes anything outside" "0" "$hits"
      read -r hits odd <<< "$(race_loop 300 "$WORK/rx/X" make_folder "$WORK/rx/S/clouve/installed/made")"
      assert_eq "clouve exchanged with an outside link: none of 300 make_folder calls makes anything outside" "0" "$hits"
      stop_flip
    fi
  fi

  echo " copy_tree (upgrade.sh's copy of the package over the site)"
  # ct_setup: a package P (a/, a/b/, top.txt, .htaccess, a/f.txt, a/b/g.txt), an empty site S, and an outside folder X
  # (a file of mode 600, a folder with a file) that links in S point to.
  ct_setup() {
    chmod -R u+rwx "$WORK/ct" 2>/dev/null; rm -rf "$WORK/ct"
    mkdir -p "$WORK/ct/P/a/b" "$WORK/ct/S" "$WORK/ct/X/dir"
    printf 'top\n' > "$WORK/ct/P/top.txt"; printf 'deny\n' > "$WORK/ct/P/.htaccess"
    printf 'f\n' > "$WORK/ct/P/a/f.txt"; printf 'g\n' > "$WORK/ct/P/a/b/g.txt"
    printf 'secret\n' > "$WORK/ct/X/secret"; chmod 600 "$WORK/ct/X/secret"; printf 'keep\n' > "$WORK/ct/X/dir/keep"
  }
  # tree_of DIR: names, types and contents (no modes or owners).
  tree_of() { (cd "$1" && find . -printf '%p %y\n' | sort && find . -type f -exec md5sum {} + | sort); }
  if ! bash -c '. "$1"; declare -F copy_tree >/dev/null' _ "$LIB"; then
    fail "root-paths.sh has copy_tree"
  else
    ct_setup
    assert_eq "into an empty folder: status 0" "status=0" "$(run_lib copy_tree "$WORK/ct/P" "$WORK/ct/S")"
    assert_eq "into an empty folder: the package's tree, dot files included" "$(tree_of "$WORK/ct/P")" \
      "$(tree_of "$WORK/ct/S")"
    ct_setup; cp -a "$WORK/ct/P/." "$WORK/ct/S/"
    printf 'mine\n' > "$WORK/ct/S/a/mine.txt"; printf 'edited\n' > "$WORK/ct/S/a/f.txt"; rm "$WORK/ct/S/top.txt"
    assert_eq "over a site: status 0" "status=0" "$(run_lib copy_tree "$WORK/ct/P" "$WORK/ct/S")"
    assert_eq "over a site: the site's own file stays, an edited file and a removed one are the package's again" \
      "mine f top" "$(cat "$WORK/ct/S/a/mine.txt" "$WORK/ct/S/a/f.txt" "$WORK/ct/S/top.txt" | tr '\n' ' ' | sed 's/ $//')"
    ct_setup; before="$(listing "$WORK/ct/X")"
    ln -s "$WORK/ct/X/secret" "$WORK/ct/S/top.txt"; ln -s "$WORK/ct/X/dir" "$WORK/ct/S/a"
    ln -s "$WORK/ct/X/missing" "$WORK/ct/S/.htaccess"
    assert_eq "links at a file, a folder and a dot file of the package: status 0" "status=0" \
      "$(run_lib copy_tree "$WORK/ct/P" "$WORK/ct/S")"
    assert_eq "links in the site: nothing outside changes (content, modes), nothing is made there" "$before" \
      "$(listing "$WORK/ct/X")"
    check "links in the site: each is a regular file or a real folder of the package now" \
      eval 'regular "$WORK/ct/S/top.txt" && real_dir "$WORK/ct/S/a" && regular "$WORK/ct/S/.htaccess" && regular "$WORK/ct/S/a/b/g.txt"'
    assert_eq "links in the site: the tree is the package's" "$(tree_of "$WORK/ct/P")" "$(tree_of "$WORK/ct/S")"
    ct_setup; printf 'a file\n' > "$WORK/ct/S/a"
    out="$(run_lib copy_tree "$WORK/ct/P" "$WORK/ct/S")"
    assert_eq "a file where the package has a folder: status 1 (cp -r failed there too)" "status=1" "$(last "$out")"
    # A shim cp that puts a link to the secret at every name it is about to write, just before it runs.
    mkdir -p "$WORK/shim-ct"
    cat > "$WORK/shim-ct/cp" <<'SH'
#!/bin/bash
PATH="${PATH#*:}"
seen=0
for a in "$@"; do
  if [ "$seen" = 1 ]; then ln -sfn -- "$SHIM_TARGET" "./${a##*/}"; fi
  [ "$a" = -- ] && seen=1
done
exec cp "$@"
SH
    chmod 755 "$WORK/shim-ct/cp"
    ct_setup; before="$(listing "$WORK/ct/X")"
    out="$(SHIM_TARGET="$WORK/ct/X/secret" PATH="$WORK/shim-ct:$PATH" run_lib copy_tree "$WORK/ct/P" "$WORK/ct/S")"
    assert_eq "a link put at each name just before cp writes it: nothing outside changes" "$before" \
      "$(listing "$WORK/ct/X")"
    assert_eq "a link put at each name just before cp writes it: the tree is the package's" "$(tree_of "$WORK/ct/P")" \
      "$(tree_of "$WORK/ct/S")"
    if command -v python3 >/dev/null 2>&1; then
      ct_setup; mkdir -p "$WORK/ct/X/b" "$WORK/ct/S/a"; printf 'keep\n' > "$WORK/ct/X/b/keep"
      ln -s "$WORK/ct/X" "$WORK/ct/S/alink"
      if start_flip "$WORK/ct/S/a" "$WORK/ct/S/alink"; then
        read -r hits odd <<< "$(race_loop 150 "$WORK/ct/X" copy_tree "$WORK/ct/P" "$WORK/ct/S")"
        stop_flip
        assert_eq "a/ exchanged with an outside link in a tight loop: none of 150 copies changes anything outside" "0" "$hits"
        assert_eq "a/ exchanged with an outside link: every copy returns 0 or 1" "0" "$odd"
      else
        echo "  (skipped) the copy_tree race: this filesystem can't exchange two names (renameat2)"
      fi
    fi
  fi

  echo " safe_put"
  if ! bash -c '. "$1"; declare -F safe_put >/dev/null' _ "$LIB"; then
    fail "root-paths.sh has safe_put"
  else
    fresh; printf 'old\n' > "$WORK/u/conf"; chmod 640 "$WORK/u/conf"
    assert_eq "over a regular file of mode 640: status 0, the new text, mode 640 kept" "status=0 new 640" \
      "$(printf 'new\n' | run_lib safe_put "$WORK/u/conf" | tr '\n' ' ')$(cat "$WORK/u/conf") $(stat -c %a "$WORK/u/conf")"
    fresh; printf 'old\n' > "$WORK/u/conf"; chmod 040 "$WORK/u/conf"
    out="$(printf 'new\n' | run_lib safe_put "$WORK/u/conf")"
    assert_eq "over a regular file of mode 040 (stat says 40): mode 40 kept, not taken for a bad value" "status=0 40" \
      "$(last "$out") $(stat -c %a "$WORK/u/conf")"
    chmod 600 "$WORK/u/conf"
    fresh; printf 'secret\n' > "$WORK/target"; chmod 600 "$WORK/target"; ln -s "$WORK/target" "$WORK/u/conf"
    assert_eq "over a link: the target keeps its text and mode, a new 644 file holds the text" "secret 600 new 644" \
      "$(printf 'new\n' | run_lib safe_put "$WORK/u/conf" >/dev/null; cat "$WORK/target") $(stat -c %a "$WORK/target") $(cat "$WORK/u/conf") $(stat -c %a "$WORK/u/conf")"
  fi

  echo " clear_temp_files (what a start cut off between dd and mv leaves)"
  if ! bash -c '. "$1"; declare -F clear_temp_files >/dev/null' _ "$LIB"; then
    fail "root-paths.sh has clear_temp_files"
  else
    fresh; printf 'secret\n' > "$WORK/target"; chmod 600 "$WORK/target"
    printf 'x\n' > "$WORK/u/.config.php.0123456789abcdef"; printf 'x\n' > "$WORK/u/.30.0.01.abcdef0123456789"
    ln -s "$WORK/target" "$WORK/u/.config.php.fedcba9876543210"; mkdir "$WORK/u/.config.php.1111111111111111"
    printf 'x\n' > "$WORK/u/.config.php.0123"; printf 'x\n' > "$WORK/u/.other.php.0123456789abcdef"
    printf 'keep\n' > "$WORK/u/config.php"
    assert_eq "status 0" "status=0" "$(run_lib clear_temp_files "$WORK/u" config.php 30.0.01)"
    assert_eq "regular files at .NAME.<16 hex> are removed; links, folders, other names and NAME itself stay" \
      "$(printf '%s\n' .config.php.0123 .config.php.1111111111111111 .config.php.fedcba9876543210 .other.php.0123456789abcdef config.php)" \
      "$(find "$WORK/u" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
    assert_eq "a link at such a name is never followed" "secret 600" "$(cat "$WORK/target") $(stat -c %a "$WORK/target")"
    fresh; mkdir "$WORK/real"; printf 'x\n' > "$WORK/real/.config.php.0123456789abcdef"; ln -s "$WORK/real" "$WORK/u/linked"
    assert_eq "in a folder reached through a link: status 0, nothing removed" "status=0 .config.php.0123456789abcdef" \
      "$(run_lib clear_temp_files "$WORK/u/linked" config.php) $(find "$WORK/real" -mindepth 1 -printf '%f\n')"
  fi
fi

# ----------------------------------------------------------------------------
echo
echo "Unit cases (installer/update-config.sh's config.php)"
# ----------------------------------------------------------------------------
# A copy of update-config.sh on a made-up site, with a fake mysql that answers every query (the URL query with an old
# address) and a fake sleep. CLOUVE_OPS_PASSWORD holds a made-up value, which must reach no file of the site.
mkdir -p "$WORK/bin" "$WORK/tmp"
cat > "$WORK/bin/mysql" <<'EOF'
#!/bin/bash
[ -t 0 ] || cat > /dev/null
case "$*" in *"SELECT value"*) echo "https://old.example.test" ;; esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/sleep"
chmod 755 "$WORK/bin/mysql" "$WORK/bin/sleep"
OPS="ops-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
# site CONFIG_KIND: a fresh $WORK/site with update-config.sh next to it; CONFIG_KIND is file (a config.php of Gibbon's
# shape), none, or nothing (the caller puts something there).
site() {
  chmod -R u+rwx "$WORK/site" "$WORK/target" 2>/dev/null; rm -rf "$WORK/site" "$WORK/target"
  mkdir -p "$WORK/site/html"
  cp "$INSTALLER/update-config.sh" "$WORK/site/update-config.sh"
  if [ "$1" = file ]; then
    printf '%s\n' "<?php" "\$databaseServer = 'x';" "\$databaseName = 'x';" "\$databaseUsername = 'x';" \
      "\$databasePassword = 'x';" "\$guid = 'keep-this';" > "$WORK/site/html/config.php"
  fi
}
# run_config: runs the copy; prints its output and then its status.
run_config() {
  (cd "$WORK/site" && timeout 30 env -i PATH="$WORK/bin:/usr/bin:/bin" TMPDIR="$WORK/tmp" GIBBON_INSTALL_PATH="$WORK/site/html" \
    DB_HOST=db.example.test DB_NAME=gibbon DB_USER=gibbon DB_PASSWORD=pw-new GIBBON_URL=https://new.example.test \
    CLOUVE_OPS_PASSWORD="$OPS" bash ./update-config.sh 2>&1 < /dev/null)
  echo "status=$?"
}
ops_in_site() { grep -rlsF -- "$OPS" "$WORK/site/html" | wc -l; }

site file; chmod 640 "$WORK/site/html/config.php"
out="$(run_config)"
assert_eq "a config.php: status 0" "status=0" "$(last "$out")"
assert_eq "a config.php: the four settings are written" \
  "\$databaseServer = 'db.example.test'; \$databaseName = 'gibbon'; \$databaseUsername = 'gibbon'; \$databasePassword = 'pw-new';" \
  "$(grep '^\$database' "$WORK/site/html/config.php" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "a config.php: its other lines stay" "\$guid = 'keep-this';" "$(grep '^\$guid' "$WORK/site/html/config.php")"
assert_eq "a config.php: it keeps its mode (640)" "640" "$(stat -c %a "$WORK/site/html/config.php")"
check "a config.php: a regular file, and no temporary file is left" \
  eval 'regular "$WORK/site/html/config.php" && no_temp_left "$WORK/site/html"'
check "a config.php: the URL update still runs" grep -q "absoluteURL updated successfully" <<< "$out"

site file; chmod 755 "$WORK/site/html/config.php"
out="$(run_config)"
assert_eq "a config.php of mode 755 (as after an upgrade): status 0, and it keeps its mode" "status=0 755" \
  "$(last "$out") $(stat -c %a "$WORK/site/html/config.php")"

# A hard link at config.php: the edit must replace the name, never change the other name's file.
site file; ln "$WORK/site/html/config.php" "$WORK/site/other.php"
before="$(md5sum < "$WORK/site/other.php")"
out="$(run_config)"
assert_eq "a config.php with a second name (a hard link): the other name's file is unchanged" "$before" \
  "$(md5sum < "$WORK/site/other.php")"

site none; printf 'secret %s\n' "$OPS" > "$WORK/target"; chmod 600 "$WORK/target"
ln -s "$WORK/target" "$WORK/site/html/config.php"
out="$(run_config)"
assert_eq "config.php a link to a file: status 0 (the start goes on)" "status=0" "$(last "$out")"
assert_eq "config.php a link to a file: the target keeps its content and mode" "secret $OPS 600" \
  "$(cat "$WORK/target") $(stat -c %a "$WORK/target")"
check "config.php a link to a file: the link is left as it is" test -L "$WORK/site/html/config.php"
check "config.php a link to a file: the warning names config.php" \
  grep -qF "$WORK/site/html/config.php is a link or not a regular file" <<< "$out"
assert_eq "config.php a link to a file: nothing of the target is in the output" "0" "$(grep -cF -- "$OPS" <<< "$out")"
check "config.php a link to a file: the URL update still runs" grep -q "absoluteURL updated successfully" <<< "$out"

site none; ln -s /proc/self/environ "$WORK/site/html/config.php"
out="$(run_config)"
assert_eq "config.php a link to /proc/self/environ: status 0" "status=0" "$(last "$out")"
assert_eq "config.php a link to /proc/self/environ: no file of the site holds the clouve-ops password" "0" \
  "$(ops_in_site)"
check "config.php a link to /proc/self/environ: the link is left as it is" test -L "$WORK/site/html/config.php"
assert_eq "config.php a link to /proc/self/environ: the output holds no clouve-ops password" "0" \
  "$(grep -cF -- "$OPS" <<< "$out")"

site none; mkdir "$WORK/site/html/config.php"
out="$(run_config)"
assert_eq "a folder at config.php: status 0, the folder is left" "status=0 yes" \
  "$(last "$out") $(real_dir "$WORK/site/html/config.php" && echo yes)"
check "a folder at config.php: the warning names it" \
  grep -qF "$WORK/site/html/config.php is a link or not a regular file" <<< "$out"

site none; mkfifo "$WORK/site/html/config.php"
out="$(run_config)"
assert_eq "a pipe at config.php: status 0 (no wait)" "status=0" "$(last "$out")"

site none
out="$(run_config)"
assert_eq "no config.php: status 0" "status=0" "$(last "$out")"
check "no config.php: it says Gibbon isn't installed yet, as before" grep -q "config.php not found" <<< "$out"

# config.php swapped for a link to the secret just before it is read (a shim dd): nothing of the secret is read.
mkdir -p "$WORK/shim-cfg"
cat > "$WORK/shim-cfg/dd" <<'SH'
#!/bin/bash
PATH="${PATH#*:}"
for a in "$@"; do case $a in if=config.php) rm -f config.php; ln -s -- "$SHIM_TARGET" config.php ;; esac; done
exec dd "$@"
SH
mkdir -p "$WORK/shim-cfg-mv"
cat > "$WORK/shim-cfg-mv/mv" <<'SH'
#!/bin/bash
PATH="${PATH#*:}"
src="${*: -2:1}"
case "$src" in .config.php.*) rm -f -- "$src" && ln -s -- "$SHIM_TARGET" "$src" ;; esac
exec mv "$@"
SH
chmod 755 "$WORK/shim-cfg/dd" "$WORK/shim-cfg-mv/mv"
for shim in shim-cfg shim-cfg-mv; do
  site file; printf 'secret %s\n' "$OPS" > "$WORK/target"; chmod 600 "$WORK/target"
  out="$(cd "$WORK/site" && timeout 30 env -i PATH="$WORK/$shim:$WORK/bin:/usr/bin:/bin" TMPDIR="$WORK/tmp" \
    SHIM_TARGET="$WORK/target" GIBBON_INSTALL_PATH="$WORK/site/html" DB_HOST=db.example.test DB_NAME=gibbon \
    DB_USER=gibbon DB_PASSWORD=pw-new CLOUVE_OPS_PASSWORD="$OPS" bash ./update-config.sh 2>&1 < /dev/null)"
  label="config.php swapped for a link just before it is read"
  [ "$shim" = shim-cfg-mv ] && label="the new config.php swapped for a link just before the rename"
  assert_eq "$label: the target keeps its content and mode" "secret $OPS 600" \
    "$(cat "$WORK/target") $(stat -c %a "$WORK/target")"
  assert_eq "$label: no file of the site holds what the target holds" "0" "$(ops_in_site)"
  assert_eq "$label: the output holds nothing of it" "0" "$(grep -cF -- "$OPS" <<< "$out")"
done

# ----------------------------------------------------------------------------
echo
echo "Static cases"
# ----------------------------------------------------------------------------
# code FILE: the file's lines without comments.
code() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1"; }
ep="$(code "$ENTRYPOINT")"
check "the entrypoint sources root-paths.sh" grep -qE '^[[:space:]]*(\.|source) "\$GIBBON_PACKAGE_INSTALLER/root-paths.sh"' <<< "$ep"
writes="$(grep -nE '(^|[^<])>>?[[:space:]]*"?\$INSTALLED_VERSIONS_PATH|touch[[:space:]]+"?\$INSTALLED_VERSIONS_PATH' <<< "$ep")"
assert_eq "no >, >> or touch writes anything in clouve/installed/" "" "$writes"
check "the version marker is written with safe_write" \
  grep -qF 'safe_write "$INSTALLED_VERSIONS_PATH/$GIBBON_VERSION" "$TIMESTAMP"' <<< "$ep"
check "the integration marker is written with safe_write" \
  grep -qF 'safe_write "$INSTALLED_VERSIONS_PATH/.moodle-integration-setup" "$TIMESTAMP"' <<< "$ep"
tests_of_markers="$(grep -nE '\[\[?[^]]*-f "\$INSTALLED_VERSIONS_PATH/' <<< "$ep")"
assert_eq "no marker is tested with -f (which follows a link); plain_file does it" "" "$tests_of_markers"
first_repair="$(grep -nE '^[[:space:]]*state_folders' <<< "$ep" | head -n 1 | cut -d: -f1)"
first_use="$(grep -nE 'INSTALLED_VERSIONS_PATH' <<< "$ep" | grep -vE 'export INSTALLED_VERSIONS_PATH|^[0-9]+:[[:space:]]*state_folders|state_folders\(\)' |
  head -n 1 | cut -d: -f1)"
in_order() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }
check "clouve/ and clouve/installed/ are repaired before their first use" in_order "$first_repair" "$first_use"
check "update-config.sh runs without CLOUVE_OPS_PASSWORD" \
  grep -qE 'env -u CLOUVE_OPS_PASSWORD "\$GIBBON_PACKAGE_INSTALLER"/update-config.sh' <<< "$ep"
uc="$(code "$INSTALLER/update-config.sh")"
assert_eq "update-config.sh has no sed -i" "" "$(grep -nE 'sed[[:space:]]+(-[a-zA-Z]*i|--in-place)' <<< "$uc")"
assert_eq "update-config.sh writes nothing through config.php's name (no > \"\$3\" or > \"\$CONFIG_FILE\")" "" \
  "$(grep -nE '>[[:space:]]*"\$(3|CONFIG_FILE)"' <<< "$uc")"
check "update-config.sh checks its folder with /bin/pwd -P" grep -qF '"$(/bin/pwd -P' <<< "$uc"
ins="$(code "$INSTALLER/install.sh")"
check "install.sh runs auto.php as www-data when it runs as root, without CLOUVE_OPS_PASSWORD" \
  grep -qE '^[[:space:]]*env -u CLOUVE_OPS_PASSWORD runuser -u www-data -- php auto.php$' <<< "$ins"
assert_eq "install.sh runs php in no other way (each php line drops CLOUVE_OPS_PASSWORD)" "" \
  "$(grep -E '(^|[[:space:]/])php[[:space:]]' <<< "$ins" | grep -vE '^[[:space:]]*env -u CLOUVE_OPS_PASSWORD (runuser -u www-data -- )?php auto.php$')"
rv="$(code "$INSTALLER/refresh-vendor.sh")"
check "refresh-vendor.sh checks a folder with /bin/pwd -P" grep -qF '"$(/bin/pwd -P' <<< "$rv"
assert_eq "refresh-vendor.sh makes no file by a full path in the state folder (no mktemp, no > into it)" "" \
  "$(grep -nE 'mktemp|>[[:space:]]*"?\$(STATE|MARKER|SUMS|tmp)' <<< "$rv")"
assert_eq "refresh-vendor.sh copies the image's vendor/ only into a folder it has just made (no cp -a to a full path)" "" \
  "$(grep -nE 'cp -a -- "\$PKG/vendor" "\$NEW"' <<< "$rv")"
up="$(code "$INSTALLER/upgrade.sh")"
assert_eq "upgrade.sh copies nothing over the site with cp -r (which writes through a link)" "" \
  "$(grep -nE '(^|[[:space:]])cp[[:space:]]+-[a-zA-Z]*r' <<< "$up")"
check "upgrade.sh copies the package with copy_tree" grep -qF 'copy_tree "$GIBBON_PACKAGE_PATH" "$GIBBON_INSTALL_PATH"' <<< "$up"
check "upgrade.sh runs chmod -R as www-data, from inside the site's folder" \
  grep -qF 'in_folder "$GIBBON_INSTALL_PATH" env -u CLOUVE_OPS_PASSWORD runuser -u www-data -- chmod -R 755 .' <<< "$up"
assert_eq "no script removes, chowns or chmods the uploads cache by its path (which follows a link)" "" \
  "$(cat "$ENTRYPOINT" "$INSTALLER/update-config.sh" | sed -e 's/^[[:space:]]*#.*$//' |
     grep -nE '(rm|chown|chmod)[^#]*(/var/www/html|\$GIBBON_INSTALL_PATH)/uploads/cache')"
assert_eq "no script of the image runs runuser or setpriv with CLOUVE_OPS_PASSWORD in reach" "" \
  "$(for f in "$INSTALLER"/*.sh; do code "$f" |
       grep -nE '(^|[[:space:]/])(runuser|setpriv)[[:space:]]' | grep -vE 'env -(u CLOUVE_OPS_PASSWORD|i)[^|;]*(runuser|setpriv)' |
       sed "s|^|${f##*/}:|"; done)"
check "the entrypoint clears what a cut-off write left in clouve/installed" \
  grep -qF 'clear_temp_files "$INSTALLED_VERSIONS_PATH" "$GIBBON_VERSION" .moodle-integration-setup' <<< "$ep"
check "the entrypoint clears what a cut-off write left beside config.php" \
  grep -qF 'clear_temp_files "$GIBBON_INSTALL_PATH" config.php' <<< "$ep"
assert_eq "the entrypoint writes no SQL file at a fixed name in /tmp (a file put there first would take its place)" "" \
  "$(grep -nE '/tmp/[A-Za-z0-9_.-]+\.sql' <<< "$ep")"
MOODLE_WWW="$REPO/apps/moodle/image/installer/www-data.sh"
if [ -f "$INSTALLER/www-data.sh" ] && [ -f "$MOODLE_WWW" ] &&
    cmp -s <(sed -n '/^# _www_data_live UID:/,$p' "$INSTALLER/www-data.sh") <(sed -n '/^# _www_data_live UID:/,$p' "$MOODLE_WWW"); then
  pass "www-data.sh's functions are the Moodle image's, word for word"
else
  fail "www-data.sh's functions are the Moodle image's, word for word"
fi
# followed_by_reap FILE ERE: the first code line after each line that matches ERE calls reap_www_data (as
# tests/moodle-root-paths.test.sh checks it, with patterns instead of text).
followed_by_reap() {
  RE="$2" awk '
    /^[[:space:]]*(#|$)/ { next }
    want { if ($0 !~ /reap_www_data/) bad = bad NR ": " $0 "\n"; want = 0 }
    $0 ~ ENVIRON["RE"] { want = 1; n++ }
    END { if (n == 0) print "no line matches"; printf "%s", bad }' "$1"
}
# A reap whose status is lost lets the start go on with a process of www-data's alive, so each call is a statement of
# its own that ends the script when the reap fails: never inside $( ), a pipeline, an if or a || true.
bad=""
for f in "$ENTRYPOINT" "$INSTALLER/install.sh" "$INSTALLER/upgrade.sh"; do
  bad+="$(code "$f" | grep -nE 'reap_www_data[[:space:]]+"' |
    grep -vE '^[0-9]+:[[:space:]]*reap_www_data "[^"$()|]*" \|\| exit 1[[:space:]]*$' | sed "s|^|${f##*/}:|")"$'\n'
done
assert_eq "every reap_www_data call is a statement of its own: reap_www_data \"...\" || exit 1" "" "$(grep . <<< "$bad")"
for re in '^[[:space:]]*"\$GIBBON_PACKAGE_INSTALLER"/install\.sh[[:space:]]*$' \
    '^[[:space:]]*"\$GIBBON_PACKAGE_INSTALLER"/upgrade\.sh[[:space:]]*$' '^clear_uploads_cache[[:space:]]*$' \
    '^env -u CLOUVE_OPS_PASSWORD "\$GIBBON_PACKAGE_INSTALLER"/update-config\.sh[[:space:]]*$'; do
  assert_eq "the entrypoint ends what www-data left after the line matching: $re" "" "$(followed_by_reap "$ENTRYPOINT" "$re")"
done
assert_eq "install.sh ends what auto.php left, right after its subshell" "" \
  "$(followed_by_reap "$INSTALLER/install.sh" '^\)[[:space:]]*$')"
assert_eq "upgrade.sh ends what its chmod as www-data left, right after it" "" \
  "$(followed_by_reap "$INSTALLER/upgrade.sh" 'runuser -u www-data -- chmod -R 755 \.[[:space:]]*$')"
assert_eq "update-config.sh's and root-paths.sh's mode checks take what stat %a prints for any mode (1 to 4 digits)" "" \
  "$(grep -nE '\^\[0-7\]\{3,4\}\$' "$INSTALLER/update-config.sh" "$LIB")"
if [ -f "$LIB" ]; then
  lib="$(code "$LIB")"
  check "root-paths.sh checks a folder with /bin/pwd -P (the kernel's answer)" grep -qF '"$(/bin/pwd -P' <<< "$lib"
  assert_eq "root-paths.sh never asks bash's builtin pwd" "" "$(grep -nE '(^|[^/a-z])pwd[[:space:]]+-P' <<< "$lib")"
fi

# ----------------------------------------------------------------------------
if [ "$DOCKER" = true ]; then
echo
echo "Docker cases (${IMAGE[gibbon]}, ${IMAGE[gibbon-mysql]})"
# ----------------------------------------------------------------------------
for name in gibbon gibbon-mysql; do
  if ! docker image inspect "${IMAGE[$name]}" >/dev/null 2>&1; then
    echo "The image ${IMAGE[$name]} isn't on this machine (./build.sh gibbon, or --image $name=REF)." >&2
    exit 2
  fi
done
echo " refresh-vendor.sh with a www-data process that swaps folders (as root in php:8.3-apache, no network)"
# Shims stand in for a www-data process that watches the site: just before the script makes its state file
# (mktemp or dd of=), it swaps clouve/ for a link to an outside folder that has an installed/ of its own; just before
# the script copies the image's vendor/ (cp -a), it puts a link to an outside folder at vendor.clouve-new (moving
# aside whatever is there). Nothing in the outside folders may change.
mkdir -p "$WORK/rv/shims"
cp "$INSTALLER/refresh-vendor.sh" "$WORK/rv/refresh.sh"
for tool in mktemp dd; do
  cat > "$WORK/rv/shims/$tool" <<SH
#!/bin/bash
PATH="\${PATH#*:}"
if [ "\$SWAP" = state ] && [ ! -e /rv/swapped ] && { [ $tool = mktemp ] || [[ " \$* " == *" of="* ]]; }; then
  : > /rv/swapped; mv -T /rv/site/clouve /rv/site/clouve.moved && ln -s /rv/out /rv/site/clouve
fi
exec $tool "\$@"
SH
done
cat > "$WORK/rv/shims/cp" <<'SH'
#!/bin/bash
PATH="${PATH#*:}"
if [ "$SWAP" = copy ] && [ ! -e /rv/swapped ] && [ "$1" = -a ]; then
  : > /rv/swapped
  { [ -e /rv/site/vendor.clouve-new ] || [ -L /rv/site/vendor.clouve-new ]; } && mv -T /rv/site/vendor.clouve-new /rv/site/moved
  ln -s /rv/out/dir /rv/site/vendor.clouve-new
fi
exec cp "$@"
SH
cat > "$WORK/rv/cases.sh" <<'INNER'
#!/bin/bash
set -u
listing() { (cd "$1" && find . -printf '%p %y %m\n' | sort && find . -type f -exec md5sum {} + | sort); }
for swap in state copy; do
  rm -rf /rv/site /rv/pkg /rv/out /rv/swapped
  PKG=/rv/pkg/clouve/gibbon/gibbon-30.0.01 SITE=/rv/site
  mkdir -p "$PKG/vendor/composer" "$PKG/vendor/twig" "$SITE/vendor/composer" "$SITE/vendor/twig" "$SITE/clouve/installed" \
    /rv/out/installed /rv/out/dir
  printf "<?php\n\$version = '30.0.01';\n" | tee "$PKG/version.php" > "$SITE/version.php"
  echo '{"packages":[{"name":"twig/twig","version":"v3.30.0"}]}' > "$PKG/vendor/composer/installed.json"
  echo image > "$PKG/vendor/twig/TREE"
  echo '{"packages":[{"name":"twig/twig","version":"v3.11.3"}]}' > "$SITE/vendor/composer/installed.json"
  echo upstream > "$SITE/vendor/twig/TREE"
  bash /rv/refresh.sh --id "$SITE/vendor" > /rv/pkg/clouve/gibbon/vendor-upstream.id
  bash /rv/refresh.sh --sums "$SITE/vendor" > /rv/pkg/clouve/gibbon/vendor-upstream.sums
  chown -R www-data:www-data "$SITE"
  echo keep > /rv/out/installed/keep; echo keep > /rv/out/dir/keep; chown -R www-data:www-data /rv/out
  before="$(listing /rv/out)"
  SWAP=$swap PATH="/rv/shims:$PATH" timeout 60 bash /rv/refresh.sh gibbon "$PKG" "$SITE" "$SITE/clouve/installed" >/dev/null 2>&1
  echo "$swap swapped=$([ -e /rv/swapped ] && echo yes || echo no) outside=$([ "$(listing /rv/out)" = "$before" ] && echo unchanged || echo changed)"
done
INNER
chmod 755 "$WORK"/rv/shims/* "$WORK/rv/cases.sh"
rvout="$(docker run --rm --network none -v "$WORK/rv:/rv" --entrypoint bash php:8.3-apache /rv/cases.sh 2>&1)"
docker run --rm --network none -v "$WORK/rv:/rv" --entrypoint rm php:8.3-apache -rf /rv/site /rv/pkg /rv/out >/dev/null 2>&1
assert_eq "clouve/ swapped for an outside link just before the state file is made: nothing outside changes" \
  "state swapped=yes outside=unchanged" "$(grep '^state ' <<< "$rvout")"
assert_eq "a link put at vendor.clouve-new just before the copy: nothing outside changes" \
  "copy swapped=yes outside=unchanged" "$(grep '^copy ' <<< "$rvout")"

echo " reap_www_data (installer/www-data.sh, as root in php:8.3-apache, no network)"
# Two processes of www-data's left detached (setsid, and a double fork), and one of root's. reap_www_data must stop
# both of www-data's, say so in one line, and leave root's; with none running it says nothing.
kw="$(docker run --rm --network none -v "$INSTALLER/www-data.sh:/t/www-data.sh:ro" --entrypoint bash php:8.3-apache -c '
  . /t/www-data.sh
  echo "none: $(reap_www_data "a step" 2>&1)"
  setsid -f runuser -u www-data -- sleep 300
  runuser -u www-data -- bash -c "(setsid sleep 301 </dev/null >/dev/null 2>&1 &) &"
  sleep 300 & root_pid=$!
  sleep 0.5
  left() { local d n=0; for d in /proc/[0-9]*; do grep -qE "^Uid:[[:space:]]+33[[:space:]]" "$d/status" 2>/dev/null && n=$((n + 1)); done; echo "$n"; }
  echo "before: $(left)"
  echo "said: $(reap_www_data "a step" 2>&1)"; echo "status: $?"
  sleep 0.2
  echo "after: $(left)"
  echo "root: $(kill -0 "$root_pid" 2>/dev/null && echo running || echo gone)"
  # The uid its kill borrows (65533) in use: the reap says the start stops, and the caller ends there.
  setsid -f perl -e "\$< = \$> = 65533; sleep 300"
  sleep 0.3
  echo "busy: $(bash -c ". /t/www-data.sh; reap_www_data \"a busy step\" || exit 1; echo CONTINUED" 2>&1 | tr "\n" " ")"
' 2>&1)"
assert_eq "with none running: it says nothing" "none: " "$(grep '^none: ' <<< "$kw")"
assert_eq "two detached processes of www-data's are running first" "before: 2" "$(grep '^before: ' <<< "$kw")"
assert_eq "it stops both and says so in one line" \
  "said: [clouve-www-data] a step: stopped 2 process(es) of www-data's that were still running" \
  "$(grep '^said: ' <<< "$kw")"
assert_eq "none of www-data's is left" "after: 0" "$(grep '^after: ' <<< "$kw")"
assert_eq "root's process runs on" "root: running" "$(grep '^root: ' <<< "$kw")"
check "the uid its kill borrows in use: one line says the start stops, and the caller's || exit 1 ends it" \
  eval 'grep -qE "^busy: \[clouve-www-data\] a busy step: .*so the start stops here" <<< "$kw" && ! grep -q CONTINUED <<< "$kw"'

echo " the Gibbon image"
A="$RUN-app" D="$RUN-db"
rand() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
DBPW="pw-$(rand)"
umask 077
printf '%s\n' MYSQL_DATABASE=gibbon MYSQL_USER=gibbon "MYSQL_PASSWORD=$DBPW" "MYSQL_ROOT_PASSWORD=pw-$(rand)" > "$WORK/db.env"
printf '%s\n' GIBBON_HOST=127.0.0.1 DB_HOST=127.0.0.1 DB_NAME=gibbon DB_USER=gibbon "DB_PASSWORD=$DBPW" \
  GIBBON_URL=http://localhost "GIBBON_TITLE=Test School" "GIBBON_SYSTEM_NAME=Test School" \
  "GIBBON_ORGANISATION_NAME=Test School" GIBBON_FIRSTNAME=Test GIBBON_LASTNAME=Admin GIBBON_EMAIL=admin@example.test \
  GIBBON_USERNAME=test_admin "GIBBON_PASSWORD=Aa1!-$(rand)" GIBBON_AUTOINSTALL=1 DEMO_DATA=N GIBBON_LOG_LEVEL=info \
  "GIBBON_CRON_INTERVAL=* * * * *" "CLOUVE_OPS_PASSWORD=$OPS" > "$WORK/app.env"
umask 022
docker run -d --pull=never --name "$D" --network none --env-file "$WORK/db.env" -v "$RUN-dbdata:/var/lib/mysql" \
  "${IMAGE[gibbon-mysql]}" >/dev/null
docker run -d --pull=never --name "$A" --network "container:$D" --env-file "$WORK/app.env" \
  -v "$RUN-site:/var/www/html" "${IMAGE[gibbon]}" >/dev/null

# ready: Apache is PID 1 and answers, within 600 s; status 1 when the container stops or time runs out.
ready() {
  local deadline=$((SECONDS + 600))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(docker exec "$A" cat /proc/1/comm 2>/dev/null)" = apache2 ] &&
       docker exec "$A" curl -s -o /dev/null http://127.0.0.1/ 2>/dev/null; then
      return 0
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "$A" 2>/dev/null)" = true ] || return 1
    sleep 2
  done
  return 1
}
asroot() { docker exec -u 0 "$A" bash -c "$1"; }
aswww() { docker exec -u www-data "$A" bash -c "cd /var/www/html && $1"; }
http_code() { docker exec "$A" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/index.php 2>/dev/null; }
# restart: restarts the app container and waits for the new start; LOG is what that start logged.
restart() {
  local since
  since="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
  docker restart -t 20 "$A" >/dev/null
  ready; READY=$?
  LOG="$(docker logs --since "$since" "$A" 2>&1)"
  if [ "$READY" -ne 0 ]; then
    echo "       the start didn't finish; the end of its log:"
    tail -n 15 <<< "$LOG" | sed 's/^/       | /'
  fi
}
ops_in_log() { grep -cF -- "$OPS" <<< "$LOG"; }
SITE=/var/www/html
# reset_state: the state folders as a working site has them, whatever an earlier round (or an image that followed a
# link) left: real folders of www-data's, and the version marker a regular file of root's.
reset_state() {
  asroot "cd $SITE && { [ ! -L clouve ] || rm -f clouve; } && { [ ! -L clouve/installed ] || rm -f clouve/installed; } &&
    mkdir -p clouve/installed && chown www-data:www-data clouve clouve/installed &&
    { [ -f clouve/installed/$VERSION ] && [ ! -L clouve/installed/$VERSION ] ||
      { rm -rf clouve/installed/$VERSION && date +%Y-%m-%d-%H-%M-%S > clouve/installed/$VERSION; }; }"
}

if ! ready; then
  fail "Gibbon installs and Apache answers within 600 s"
  docker logs --tail 30 "$A" 2>&1 | sed 's/^/       | /'
else
  pass "Gibbon installs and Apache (PID 1) answers"
  VERSION="$(docker exec "$A" printenv GIBBON_VERSION)"
  MARKER="$SITE/clouve/installed/$VERSION"
  echo "  (info) config.php after the install: $(asroot "stat -c '%U:%G %a' $SITE/config.php")"
  asroot "mkdir -p /root/s3-r2 /root/s3-r3/installed && cp -p $SITE/config.php /root/config.php.orig"

  echo " a restart with nothing planted, config.php root:www-data mode 640"
  asroot "chown root:www-data $SITE/config.php && chmod 640 $SITE/config.php"
  stamp_before="$(asroot "cat $MARKER")"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "no warning" "0" "$(grep -c 'Warning' <<< "$LOG")"
  assert_eq "no upgrade" "0" "$(grep -c 'UPGRADING' <<< "$LOG")"
  assert_eq "the marker is unchanged" "$stamp_before" "$(asroot "cat $MARKER")"
  assert_eq "config.php keeps its owner, group and mode" "root:www-data 640" "$(asroot "stat -c '%U:%G %a' $SITE/config.php")"
  assert_eq "config.php holds the database settings" "1" "$(asroot "grep -c \"^\\\$databaseServer = '127.0.0.1';\" $SITE/config.php")"
  assert_eq "GET /index.php answers 200" "200" "$(http_code)"

  echo " leftovers of a cut-off write in clouve/installed and beside config.php"
  reset_state
  aswww "printf x > clouve/installed/.$VERSION.0123456789abcdef && printf x > .config.php.0123456789abcdef &&
    ln -s /root/s3-r1 .config.php.fedcba9876543210"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "the regular leftovers are removed, the link at such a name is left" "gone gone link" \
    "$(asroot "cd $SITE && { [ -e clouve/installed/.$VERSION.0123456789abcdef ] && echo there || echo gone; } &&
      { [ -e .config.php.0123456789abcdef ] && echo there || echo gone; } &&
      { [ -L .config.php.fedcba9876543210 ] && echo link || echo other; }" | tr '\n' ' ' | sed 's/ $//')"
  aswww "rm -f .config.php.fedcba9876543210"

  echo " the version marker a link to a missing file outside the volume"
  reset_state
  aswww "rm -f clouve/installed/$VERSION && ln -s /root/s3-r1 clouve/installed/$VERSION"
  restart
  check "the start finishes" test "$READY" -eq 0
  check "root made nothing where the link pointed" asroot "[ ! -e /root/s3-r1 ]"
  check "the marker is a regular file again" asroot "[ -f $MARKER ] && [ ! -L $MARKER ]"
  check "the log names the marker" grep -qF "$MARKER is a link or not a regular file" <<< "$LOG"
  assert_eq "GET /index.php answers 200" "200" "$(http_code)"

  echo " clouve/installed a link to a folder outside the volume"
  reset_state
  mode_before="$(asroot "stat -c '%U:%G %a' $SITE/config.php")"
  aswww "rm -rf clouve/installed && ln -s /root/s3-r2 clouve/installed"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "nothing in the link's target changed" "" "$(asroot 'ls -A /root/s3-r2')"
  check "clouve/installed is a real folder again" asroot "[ -d $SITE/clouve/installed ] && [ ! -L $SITE/clouve/installed ]"
  check "the log names the folder" grep -qF "$SITE/clouve/installed is a link or not a folder" <<< "$LOG"
  assert_eq "GET /index.php answers 200" "200" "$(http_code)"
  assert_eq "config.php keeps its owner, group and mode through it" "$mode_before" \
    "$(asroot "stat -c '%U:%G %a' $SITE/config.php")"

  echo " clouve a link to a folder outside the volume"
  reset_state
  aswww "rm -rf clouve && ln -s /root/s3-r3 clouve"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "nothing in the link's target changed" "" "$(asroot 'ls -A /root/s3-r3/installed')"
  check "clouve and clouve/installed are real folders again" \
    asroot "[ -d $SITE/clouve/installed ] && [ ! -L $SITE/clouve ] && [ ! -L $SITE/clouve/installed ]"
  check "the log names the folder" grep -qF "$SITE/clouve is a link or not a folder" <<< "$LOG"
  assert_eq "GET /index.php answers 200" "200" "$(http_code)"

  # outside DIR: owners, modes and contents of an outside folder, read as root.
  outside() { asroot "cd $1 && find . -printf '%p %y %u:%g %m\n' | sort && find . -type f -exec md5sum {} + | sort"; }

  echo " uploads/cache a link to a folder of root's outside the volume"
  reset_state
  asroot 'mkdir -p /srv/s3-cache && chmod 700 /srv/s3-cache && echo keep > /srv/s3-cache/keep && chmod 600 /srv/s3-cache/keep'
  before="$(outside /srv/s3-cache)"
  aswww "rm -rf uploads/cache && ln -s /srv/s3-cache uploads/cache"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "nothing in the link's target changed (content, owner, modes)" "$before" "$(outside /srv/s3-cache)"
  assert_eq "uploads/cache is a real folder of www-data's again, mode 755" "folder www-data:www-data 755" \
    "$(asroot "[ -d $SITE/uploads/cache ] && [ ! -L $SITE/uploads/cache ] && echo folder \$(stat -c '%U:%G %a' $SITE/uploads/cache)")"
  check "the log names the folder" grep -qF "$SITE/uploads/cache is a link or not a folder" <<< "$LOG"
  assert_eq "GET /index.php answers 200" "200" "$(http_code)"

  echo " uploads a link to a folder of root's outside the volume"
  reset_state
  asroot 'mkdir -p /srv/s3-up/cache && chmod 700 /srv/s3-up/cache && echo keep > /srv/s3-up/cache/keep && chmod 600 /srv/s3-up/cache/keep'
  before="$(outside /srv/s3-up)"
  aswww "mv uploads uploads.s3 && ln -s /srv/s3-up uploads"
  restart
  check "the start finishes" test "$READY" -eq 0
  assert_eq "nothing in the link's target changed (content, owner, modes)" "$before" "$(outside /srv/s3-up)"
  check "the log says the cache was left" grep -qF "$SITE/uploads is a link or not a folder, so its cache was not cleared" <<< "$LOG"
  aswww "rm -f uploads && mv uploads.s3 uploads"

  echo " links at index.php and lib/, and the version marker taken away (the start copies the package again)"
  reset_state
  asroot 'echo original > /srv/s3-cp-target && chmod 600 /srv/s3-cp-target && mkdir -p /srv/s3-cp-dir && echo keep > /srv/s3-cp-dir/keep'
  before="$(outside /srv)"
  aswww "rm -f index.php && ln -s /srv/s3-cp-target index.php && mv lib lib.s3 && ln -s /srv/s3-cp-dir lib &&
    echo mine > mine.txt && rm -f clouve/installed/$VERSION"
  restart
  check "the start finishes" test "$READY" -eq 0
  check "the package was copied again (an upgrade ran)" grep -q 'UPGRADING Gibbon' <<< "$LOG"
  assert_eq "nothing outside the volume changed (content, owners, modes)" "$before" "$(outside /srv)"
  check "index.php is the package's file again, not a link" \
    asroot "[ -f $SITE/index.php ] && [ ! -L $SITE/index.php ] && cmp -s $SITE/index.php /clouve/gibbon/gibbon-$VERSION/index.php"
  check "lib is a real folder with the package's files" \
    asroot "[ -d $SITE/lib ] && [ ! -L $SITE/lib ] && diff -rq /clouve/gibbon/gibbon-$VERSION/lib $SITE/lib >/dev/null"
  assert_eq "the site's own file stays" "mine" "$(asroot "cat $SITE/mine.txt")"
  assert_eq "the site is www-data's, as after any upgrade (clouve/ holds root's markers)" "0" \
    "$(asroot "find $SITE \( -path $SITE/lib.s3 -o -path $SITE/clouve \) -prune -o ! -type l ! -user www-data -print | wc -l")"
  assert_eq "index.php and lib/ have mode 755, as after any upgrade" "755 755" \
    "$(asroot "stat -c %a $SITE/index.php $SITE/lib" | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "GET /index.php answers 200" "200" "$(http_code)"
  if [ "$READY" -ne 0 ]; then
    # The start died (code that copies with cp -r stops at the link at lib/). Put lib/, index.php and the marker back
    # from a throwaway container on the same volume, so that the next rounds have a site to work on.
    docker run --rm --pull=never --network none -u 0 -v "$RUN-site:$SITE" --entrypoint bash "${IMAGE[gibbon]}" -c "
      cd $SITE && rm -f lib index.php && mv lib.s3 lib && cp -p /clouve/gibbon/gibbon-$VERSION/index.php index.php &&
      chown www-data:www-data index.php && mkdir -p clouve/installed &&
      date +%Y-%m-%d-%H-%M-%S > clouve/installed/$VERSION" >/dev/null 2>&1
    docker start "$A" >/dev/null 2>&1
    ready || echo "       (the site didn't come back after the repair; the next rounds may fail for that reason)"
  fi
  aswww "rm -rf lib.s3 mine.txt"

  echo " config.php a link to /proc/self/environ"
  reset_state
  aswww "rm -f config.php && ln -s /proc/self/environ config.php"
  restart
  check "the start finishes" test "$READY" -eq 0
  # A regular config.php is read as root; a link is not read at all (through it, a reader sees its own environment).
  held="$(docker exec -i -u 0 "$A" env -u CLOUVE_OPS_PASSWORD bash -c \
    "if [ -L $SITE/config.php ]; then echo 0; else grep -cF -f - $SITE/config.php; fi" <<< "$OPS")"
  assert_eq "no regular config.php holds the clouve-ops password" "0" "${held:-0}"
  check "the log names config.php" grep -qF "$SITE/config.php is a link or not a regular file" <<< "$LOG"
  assert_eq "the log holds no clouve-ops password" "0" "$(ops_in_log)"
  aswww "rm -f clouve/installed/$VERSION"
  restart
  check "after one more start (an upgrade, which gives the site to www-data): it finishes" test "$READY" -eq 0
  found="$(docker exec -i -u www-data "$A" env -u CLOUVE_OPS_PASSWORD grep -rlsF -f - "$SITE" <<< "$OPS")"
  assert_eq "no file www-data can read holds the clouve-ops password" "" "$found"
  assert_eq "the log holds no clouve-ops password" "0" "$(ops_in_log)"
  asroot "rm -f $SITE/config.php && cp -p /root/config.php.orig $SITE/config.php"

  echo " a www-data process left running by the installer step, swapping clouve/installed for an outside link"
  # A stand-in for php that, for the installer (auto.php), leaves a detached process of www-data's behind and returns
  # at once. That process exchanges clouve/installed with a link to an outside folder in a loop, from the moment the
  # installer runs, while root goes on to write the version marker there. clouve/installed is taken away so that the
  # start runs the installer.
  reset_state
  asroot 'mkdir -p /srv/s3-left && mv /usr/local/bin/php /usr/local/bin/php.s3real && rm -f /tmp/s3-left.pid'
  docker exec -i -u 0 "$A" bash -c 'cat > /usr/local/bin/php && chmod 755 /usr/local/bin/php' <<'SH'
#!/bin/bash
if [ "${1:-}" = auto.php ]; then
  setsid -f bash -c 'echo $$ > /tmp/s3-left.pid
    cd /var/www/html/clouve || exit
    ln -sfn /srv/s3-left installed.s3link
    while :; do mv --exchange installed installed.s3link 2>/dev/null; done' </dev/null >/dev/null 2>&1
  sleep 0.5
  exit 0
fi
exec /usr/local/bin/php.s3real "$@"
SH
  before="$(outside /srv/s3-left)"
  aswww "rm -rf clouve/installed"
  restart
  check "the start finishes" test "$READY" -eq 0
  left_pid="$(asroot 'cat /tmp/s3-left.pid 2>/dev/null')"
  check "the installer step left its process (the stand-in ran)" test -n "$left_pid"
  assert_eq "that process is gone once the start is done" "gone" \
    "$(asroot "[ -n '$left_pid' ] && [ -d /proc/$left_pid ] && echo running || echo gone")"
  check "the log says how many processes of www-data's were stopped" \
    grep -qE "^\[clouve-www-data\] (auto\.php|the installer): stopped [1-9][0-9]* process\(es\) of www-data's" <<< "$LOG"
  assert_eq "nothing in the outside folder changed" "$before" "$(outside /srv/s3-left)"
  check "the version marker is a regular file in a real clouve/installed" \
    asroot "[ -d $SITE/clouve/installed ] && [ ! -L $SITE/clouve/installed ] && [ -f $MARKER ] && [ ! -L $MARKER ]"
  if [ -n "$left_pid" ]; then asroot "kill -KILL $left_pid 2>/dev/null; true"; fi
  asroot "mv -f /usr/local/bin/php.s3real /usr/local/bin/php && rm -rf $SITE/clouve/installed.s3link"

  echo " clouve/installed removed and PHP put in config.php: Gibbon installs again"
  reset_state
  asroot "rm -f /tmp/s3-cli-uids"
  docker exec -i -u www-data "$A" bash -c "cd $SITE && cat > config.php.new && cat config.php >> config.php.new &&
    mv -f config.php.new config.php && rm -rf clouve/installed" <<'PHP'
<?php if (PHP_SAPI === 'cli' && function_exists('posix_geteuid')) { @file_put_contents('/tmp/s3-cli-uids', posix_geteuid() . "\n", FILE_APPEND); } ?>
PHP
  restart
  docker cp "$A:/tmp/s3-cli-uids" "$WORK/uids" >/dev/null 2>&1 || : > "$WORK/uids"
  check "the planted line ran during the start (the installer loaded config.php)" test -s "$WORK/uids"
  assert_eq "it never ran as root" "0" "$(grep -cx 0 "$WORK/uids")"
  assert_eq "the log holds no clouve-ops password" "0" "$(ops_in_log)"
fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sGibbon root path checks passed (%s).%s\n' "$GREEN" "$PASSES" "$RESET"
  exit 0
fi
printf '%sGibbon root path checks failed: %s of %s.%s\n' "$RED" "$FAILED" "$((FAILED + PASSES))" "$RESET"
exit 1
