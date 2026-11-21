#!/bin/bash
# SC2016: many values here hold a $ on purpose (planted stamps, bash -c scripts). SC2329: check runs the helpers.
# shellcheck disable=SC2016,SC2329

# ============================================================================
# The Moodle image's version stamp is read and written safely
# ============================================================================
# The entrypoint runs as root and keeps the site's Moodle version in
# /var/www/html/clouve/installed/version, on the site's volume, which www-data
# can write. It compares that value with the image's version using [[ -gt ]],
# which bash evaluates as arithmetic, so the value must be plain digits; and it
# writes the stamp, the release timestamp and the Gibbon integration's marker
# in a folder that www-data could make a link, so every read and write there
# must stay in the folder that was checked.
#
# Unit cases, no Docker (installer/stamp.sh): stamp_read takes only a regular
# file of digits in a folder reached through no link, and prints nothing else;
# safe_write replaces a link, a folder or a pipe at the path, never touches what
# a link points to, refuses a folder reached through a link, and fails with
# status 1 in a folder it can't write; links put where a write is about to go
# (shims, and a flipper that exchanges the folder, or clouve above it, with an
# outside link in a tight loop, hundreds of calls each; python3, skipped without
# it) never make anything outside change, get its mode changed, or go; a folder
# at the new file's name under set -e gives only the ✗ Error line; stamp_folders
# removes a link (or a file) at clouve/ or clouve/installed/ without following
# it and, for an installed site, makes both folders again.
# Static cases: no line of entrypoint.sh reads the stamp except through
# stamp_read; no >, tee or touch writes anything in clouve/installed/; the
# release timestamp and the marker go through safe_write; both -gt operands are
# checked to be 1 to 18 digits; stamp.sh checks a folder with /bin/pwd -P (the
# kernel's answer), not bash's builtin pwd; stamp_folders runs before the first
# use of clouve/installed/.
#
# Docker cases: the Moodle image installs a site on new-disk volumes with no
# network (the app shares the database's network namespace, nothing published),
# then www-data plants something and the container restarts, five times:
#   - a[$(touch /tmp/pwned)] in the stamp: /tmp/pwned must not exist, the stamp
#     must hold the code's $version again, the log must name the stamp but not
#     show what was in it, no upgrade may run, and GET / must answer 200;
#   - the stamp a link to the process's environment: no CLOUVE_OPS_PASSWORD value in
#     the log, and the stamp a regular file again;
#   - clouve/installed a link to a folder outside the volume that holds an older
#     stamp, and then clouve itself such a link: nothing in the link's target
#     changes, both are real folders again, the stamp holds the code's $version,
#     the log names the folder, no upgrade runs, GET / answers 200;
#   - an older stamp of digits, as a site from an older image has: the upgrade
#     still runs, and records the code's $version and the release's timestamp.
#
# --image NAME=REF (moodle, moodle-mysql) picks the images; the default is
# r.clv.zone/e2eorg/<name>:latest, as ./build.sh moodle tags them. --no-docker
# runs only the unit and static cases. Every container, volume and file it
# makes is removed at the end.
#
# Usage: bash tests/moodle-version-stamp.test.sh [--image NAME=REF]... [--no-docker]
#   Exit status: 0 when every check passes, 1 when one fails, 2 when the test
#   can't run (no image, Docker missing).
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO/apps/moodle/image/installer"
ENTRYPOINT="$INSTALLER/entrypoint.sh"
STAMP_LIB="$INSTALLER/stamp.sh"

usage() {
  sed -n 's/^# \{0,1\}//; /^Usage:/,/^ *can.t run/p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

declare -A IMAGE=([moodle]=r.clv.zone/e2eorg/moodle:latest [moodle-mysql]=r.clv.zone/e2eorg/moodle-mysql:latest)
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
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
# check LABEL COMMAND...: passes when the command succeeds.
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

WORK="$(mktemp -d)"
WORK="$(cd -P "$WORK" && pwd)"   # stamp_read and safe_write refuse a folder reached through a link
RUN="mvs-t-$$"
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  # The flipper first, by its PID: it exchanges two names under $WORK in a loop, which would race the removal below.
  if [ -n "${FLIP_PID:-}" ]; then kill "$FLIP_PID" 2>/dev/null; wait "$FLIP_PID" 2>/dev/null; fi
  if [ "$DOCKER" = true ]; then
    docker rm -f -v "$RUN-app" "$RUN-db" >/dev/null 2>&1
    docker volume rm -f "$RUN-db_data" "$RUN-moodle_data" "$RUN-moodledata" >/dev/null 2>&1
  fi
  chmod -R u+w "$WORK" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# regular PATH: a regular file, not a link. real_dir PATH: a folder, not a link.
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
real_dir() { [ -d "$1" ] && [ ! -L "$1" ]; }
# listing DIR: every entry under DIR with its type and content, to compare before and after.
listing() { (cd "$1" && find . -printf '%p %y %m\n' | sort && find . -type f -exec md5sum {} + | sort); }

# ----------------------------------------------------------------------------
echo "Unit cases (installer/stamp.sh)"
# ----------------------------------------------------------------------------
# read_case LABEL EXPECTED [FILE]: stamp_read on FILE (default version) in a shell of its own run from $WORK/u, so a
# command that a value ran would leave its file there. %q shows exactly what it printed.
read_case() {
  local out
  out="$(cd "$WORK/u" && bash -c '. "$1" && stamp_read "$2"' _ "$STAMP_LIB" "${3:-version}" 2>&1; echo x)"
  out="${out%x}"
  assert_eq "$1" "$2" "$out"
}
# fresh: an empty $WORK/u (and no $WORK/real or $WORK/target) for the next case.
fresh() { rm -rf "$WORK/u" "$WORK/real" "$WORK/target" && mkdir "$WORK/u"; }
# run_lib FUNCTION ARGS...: a function of stamp.sh in a shell of its own; prints what it said, then its status.
run_lib() {
  timeout 20 bash -c '. "$1"; shift; "$@"' _ "$STAMP_LIB" "$@" 2>&1
  echo "status=$?"
}
# no_temp_left DIR: no temporary file of safe_write's (a name that starts with a dot) is left in DIR.
no_temp_left() { [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -name '.*' -print -quit)" ]; }

if [ ! -f "$STAMP_LIB" ]; then
  fail "apps/moodle/image/installer/stamp.sh exists"
else
  echo " stamp_read"
  fresh; printf '2026100500' > "$WORK/u/version"
  read_case "digits" $'2026100500\n'
  fresh; printf '2026100500\n' > "$WORK/u/version"
  read_case "digits with a newline at the end" $'2026100500\n'
  fresh; : > "$WORK/u/version"
  read_case "an empty file gives nothing" ""
  fresh; printf 'a[$(touch M)]\n' > "$WORK/u/version"
  read_case "a[\$(touch M)] gives nothing" ""
  # What it gives goes into -gt, as the entrypoint uses it: a reader that passed the value on would run touch here.
  (cd "$WORK/u" && bash -c '. "$1"; v="$(stamp_read version)"; [[ 1 -gt "${v:-0}" ]]' _ "$STAMP_LIB" >/dev/null 2>&1)
  check "the command in a[\$(touch M)] never runs, through -gt either" test ! -e "$WORK/u/M"
  fresh; printf '2026100500\n' > "$WORK/u/digits"; ln -s digits "$WORK/u/version"
  read_case "a link to a file of digits gives nothing" ""
  fresh; mkdir "$WORK/u/version"
  read_case "a folder gives nothing" ""
  fresh
  read_case "a missing file gives nothing" ""
  fresh; printf ' 2026100500 \n' > "$WORK/u/version"
  read_case "spaces around the digits give nothing" ""
  fresh; printf '2026100500\n\n' > "$WORK/u/version"
  read_case "two newlines at the end give nothing" ""
  fresh; printf '%s\0%s\n' 2026 100500 > "$WORK/u/version"
  read_case "a NUL byte among the digits gives nothing" ""
  fresh; printf '2026100500\n1\n' > "$WORK/u/version"
  read_case "a second line gives nothing" ""
  fresh; printf '999999999999999999\n' > "$WORK/u/version"
  read_case "18 digits, the most that bash compares without wrapping" $'999999999999999999\n'
  fresh; printf '18446744073709551615\n' > "$WORK/u/version"
  read_case "more than 18 digits give nothing (18446744073709551615 wraps to -1 in -gt)" ""
  fresh; mkfifo "$WORK/u/version"
  read_case "a pipe gives nothing (and doesn't wait)" ""
  fresh; mkdir "$WORK/real"; printf '2026100500\n' > "$WORK/real/version"; ln -s "$WORK/real" "$WORK/u/linked"
  read_case "a file of digits in a folder reached through a link gives nothing" "" linked/version

  echo " safe_write"
  fresh
  assert_eq "a new file: status 0 and nothing said" "status=0" "$(run_lib safe_write "$WORK/u/version" 2026100500)"
  assert_eq "a new file: it holds the text and a newline" "$(printf '2026100500\nx')" "$(cat "$WORK/u/version"; echo x)"
  check "a new file: no temporary file is left" no_temp_left "$WORK/u"

  fresh; printf 'outside\n' > "$WORK/target"; ln -s "$WORK/target" "$WORK/u/version"
  assert_eq "over a link: status 0" "status=0" "$(run_lib safe_write "$WORK/u/version" 2026100500)"
  assert_eq "over a link: the link's target is unchanged" "outside" "$(cat "$WORK/target")"
  check "over a link: a regular file is left" regular "$WORK/u/version"
  assert_eq "over a link: the file holds the text" "2026100500" "$(cat "$WORK/u/version")"

  fresh; mkdir "$WORK/real"; ln -s "$WORK/real" "$WORK/u/version"
  assert_eq "over a link to a folder: status 0" "status=0" "$(run_lib safe_write "$WORK/u/version" 2026100500)"
  check "over a link to a folder: a regular file replaces the link (mv -T)" regular "$WORK/u/version"
  assert_eq "over a link to a folder: nothing is moved into the folder" "" "$(ls -A "$WORK/real")"

  fresh; mkdir -p "$WORK/u/version/sub"; printf 'keep\n' > "$WORK/target"; ln -s "$WORK/target" "$WORK/u/version/sub/link"
  assert_eq "over a planted folder: status 0" "status=0" "$(run_lib safe_write "$WORK/u/version" 2026100500)"
  check "over a planted folder: a regular file is left" regular "$WORK/u/version"
  assert_eq "over a planted folder: a link inside it was never followed" "keep" "$(cat "$WORK/target" 2>&1)"

  fresh; mkfifo "$WORK/u/version"
  assert_eq "over a pipe: status 0" "status=0" "$(run_lib safe_write "$WORK/u/version" 5)"
  check "over a pipe: a regular file is left" regular "$WORK/u/version"

  fresh; mkdir "$WORK/real"; ln -s "$WORK/real" "$WORK/u/linked"
  out="$(run_lib safe_write "$WORK/u/linked/version" 2026100500)"
  assert_eq "in a folder reached through a link: status 1" "status=1" "${out##*$'\n'}"
  check "in a folder reached through a link: it says why" test -n "${out%status=1}"
  assert_eq "in a folder reached through a link: nothing is written there" "" "$(ls -A "$WORK/real")"

  if [ "$(id -u)" -eq 0 ]; then
    echo "  (skipped) into a read-only folder: root can write there anyway"
  else
    fresh; chmod 555 "$WORK/u"
    out="$(run_lib safe_write "$WORK/u/version" 2026100500)"
    assert_eq "into a read-only folder: status 1" "status=1" "${out##*$'\n'}"
    check "into a read-only folder: it says why" test -n "${out%status=1}"
    check "into a read-only folder: nothing is left there" test -z "$(ls -A "$WORK/u")"
    chmod 755 "$WORK/u"
  fi

  # Shims that do what a www-data process watching the folder (inotify) could: put a link to $SHIM_TARGET where
  # safe_write is about to write. shim-open acts on the name of a new temporary file as soon as it is known: mktemp's
  # result, or dd's of=, before the real command runs. shim-rename acts on the temporary file just before mv renames it.
  mkdir -p "$WORK/shim-open" "$WORK/shim-rename"
  cat > "$WORK/shim-open/mktemp" <<'SH'
#!/bin/bash
PATH="${PATH#*:}"
t="$(mktemp "$@")" || exit
rm -f -- "$t" && ln -s -- "$SHIM_TARGET" "$t"
printf '%s\n' "$t"
SH
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
  chmod 755 "$WORK"/shim-*/*
  # swap_case SHIMS LABEL: safe_write with the shims in $WORK/SHIMS first on PATH, and a file of digits' would-be
  # target, $WORK/target ("secret", mode 600), behind the link. The write must fail or end in a new regular file that
  # holds the text, and the target must keep its content and its mode (no write, no chmod through the link).
  swap_case() {
    local out
    fresh; printf 'secret\n' > "$WORK/target"; chmod 600 "$WORK/target"
    out="$(SHIM_TARGET="$WORK/target" PATH="$WORK/$1:$PATH" run_lib safe_write "$WORK/u/version" 2026100500)"
    if [[ "${out##*$'\n'}" == status=1 ]] || { [[ "${out##*$'\n'}" == status=0 ]] && regular "$WORK/u/version" &&
        [[ "$(cat "$WORK/u/version")" == 2026100500 ]]; }; then
      pass "$2: the write fails, or a new regular file holds the text"
    else
      fail "$2: the write fails, or a new regular file holds the text"
      printf '       got: %q; version is %s\n' "$out" "$(if [ -L "$WORK/u/version" ]; then echo a link; else echo not a link; fi)"
    fi
    assert_eq "$2: the link's target keeps its content" "secret" "$(cat "$WORK/target")"
    assert_eq "$2: the link's target keeps its mode (no chmod through the link)" "600" "$(stat -c %a "$WORK/target")"
    check "$2: nothing of the write is left in the folder" no_temp_left "$WORK/u"
  }
  swap_case shim-open "a link put at the new file's name as soon as it is known"
  swap_case shim-rename "the new file swapped for a link just before the rename"
  fresh; rm -rf "$WORK/target"; mkfifo "$WORK/target"
  out="$(SHIM_TARGET="$WORK/target" PATH="$WORK/shim-open:$PATH" run_lib safe_write "$WORK/u/version" 2026100500)"
  assert_eq "a link to a pipe put at the new file's name: the write fails at once (it doesn't open the pipe)" \
    "status=1" "${out##*$'\n'}"
  rm -f "$WORK/target"

  # A folder on the way swapped for a link to an outside folder in the middle of a call. Every write and removal must
  # stay in the folder that was checked: nothing outside may change or go, and each call returns 0 (its work landed
  # in the checked folder) or 1. A flipper exchanges two names atomically (renameat2 RENAME_EXCHANGE) in a tight loop,
  # a real folder and a link to an outside folder, so the path is a link only for moments: what a check that reads a
  # path twice (such as bash's own pwd -P after cd -P) can miss. Needs python3 and a filesystem that can exchange two
  # names; otherwise these cases are skipped.
  cat > "$WORK/flip.py" <<'FLIP'
import ctypes, os, sys
a, b, stop, ready = (arg.encode() for arg in sys.argv[1:5])
work = os.path.dirname(stop)
exchange = ctypes.CDLL(None, use_errno=True).renameat2
exchange.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
AT_FDCWD, RENAME_EXCHANGE = -100, 2
if exchange(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE) != 0:
    sys.exit(3)
open(ready, "w").close()
parent = os.getppid()
n = 0
# It stops when told to, and also when the test is gone without telling it: its folder gone, or the test's shell ended
# (this process then has another parent).
while n % 1024 or not (os.path.exists(stop) or not os.path.isdir(work) or os.getppid() != parent):
    exchange(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)
    n += 1
if os.path.islink(a):
    exchange(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)
FLIP
  # start_flip A B: the flipper on A and B in the background (FLIP_PID), once it has made its first exchange; status 1
  # when it can't run here. stop_flip: stops it, with A as it started.
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
  # race_call FUNCTION ARGS...: one call of a stamp.sh function in a shell of its own; prints its status.
  race_call() { bash -c '. "$1"; shift; "$@"' _ "$STAMP_LIB" "$@" >/dev/null 2>&1; echo "$?"; }
  # race_loop N OUTSIDE FUNCTION ARGS...: N calls while a flipper runs; prints "<calls that changed OUTSIDE> <calls
  # that returned neither 0 nor 1>". OUTSIDE is put back as it was after each call that changed it.
  race_loop() {
    local n="$1" outside="$2" before hits=0 odd=0 saved="$WORK/race.saved"
    shift 2
    rm -rf "$saved"; cp -a "$outside" "$saved"; before="$(listing "$outside")"
    for _ in $(seq "$n"); do
      case "$(race_call "$@")" in 0 | 1) ;; *) odd=$((odd + 1)) ;; esac
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
    rm -rf "$WORK/rx"; mkdir -p "$WORK/rx/u" "$WORK/rx/out"; ln -s "$WORK/rx/out" "$WORK/rx/lnk"
    printf 'secret\n' > "$WORK/rx/out/version"; chmod 600 "$WORK/rx/out/version"
    if ! start_flip "$WORK/rx/u" "$WORK/rx/lnk"; then
      echo "  (skipped) the exchange races: this filesystem can't exchange two names (renameat2)"
    else
      read -r hits odd <<< "$(race_loop 400 "$WORK/rx/out" safe_write "$WORK/rx/u/version" 2026100500)"
      stop_flip
      assert_eq "the folder exchanged with an outside link in a tight loop: none of 400 writes changes anything outside" \
        "0" "$hits"
      assert_eq "the folder exchanged with an outside link: every call returns 0 or 1" "0" "$odd"

      # The folder above: S/clouve exchanged with S/clink, a link to the outside folder X.
      rm -rf "$WORK/rp"; mkdir -p "$WORK/rp/S/clouve/installed" "$WORK/rp/X/installed"
      printf '<?php\n' > "$WORK/rp/S/config.php"; ln -s "$WORK/rp/X" "$WORK/rp/S/clink"
      printf 'secret\n' > "$WORK/rp/X/installed/version"; chmod 600 "$WORK/rp/X/installed/version"
      # The first flipper ran here, so this one can too: if it can't start, the cases below would race nothing.
      if ! start_flip "$WORK/rp/S/clouve" "$WORK/rp/S/clink"; then
        fail "the flipper starts on clouve and its outside link"
      else
        read -r hits odd <<< "$(race_loop 300 "$WORK/rp/X" safe_write "$WORK/rp/S/clouve/installed/version" 2026100500)"
        assert_eq "clouve exchanged with an outside link in a tight loop: none of 300 writes changes anything outside" \
          "0" "$hits"
        assert_eq "clouve exchanged with an outside link: every call returns 0 or 1" "0" "$odd"
        # stamp_folders' removal and its making of folders again, in_folder <folder> rm -rf and mkdir -p, under the
        # same flipper: X/installed (with a file in it) must stay, and no X/made may appear.
        printf 'keep\n' > "$WORK/rp/X/installed/keep"
        read -r hits odd <<< "$(race_loop 600 "$WORK/rp/X" in_folder "$WORK/rp/S/clouve" rm -rf -- installed)"
        assert_eq "clouve exchanged with an outside link: none of 600 removals (rm -rf) removes anything outside" \
          "0" "$hits"
        read -r hits odd <<< "$(race_loop 300 "$WORK/rp/X" in_folder "$WORK/rp/S/clouve" mkdir -p -- made)"
        assert_eq "clouve exchanged with an outside link: none of 300 mkdir -p calls makes anything outside" "0" "$hits"
        stop_flip
      fi
    fi
  fi

  # Shims that swap $SWAP_DIR for a link to $SWAP_TO once, at a set moment: shim-folder when the random name is drawn
  # (od), shim-rm just before a removal (rm). shim-collide's od always gives the same name.
  mkdir -p "$WORK/shim-folder" "$WORK/shim-rm" "$WORK/shim-collide"
  for tool in od rm; do
    dir=shim-folder; [ "$tool" = rm ] && dir=shim-rm
    cat > "$WORK/$dir/$tool" <<SH
#!/bin/bash
PATH="\${PATH#*:}"
if [ ! -e "\$SHIM_ONCE" ]; then : > "\$SHIM_ONCE"; mv -T "\$SWAP_DIR" "\$SWAP_DIR.moved" && ln -s "\$SWAP_TO" "\$SWAP_DIR"; fi
exec $tool "\$@"
SH
  done
  printf '#!/bin/bash\nprintf " 01 23 45 67 89 ab cd ef\\n"\n' > "$WORK/shim-collide/od"
  chmod 755 "$WORK"/shim-folder/* "$WORK"/shim-rm/* "$WORK"/shim-collide/*
  # swapped SHIMS SWAP_DIR SWAP_TO FUNCTION ARGS...: a function of stamp.sh with the swap shims on PATH.
  swapped() {
    local shims="$1" from="$2" to="$3"
    shift 3
    rm -f "$WORK/once"
    SHIM_ONCE="$WORK/once" SWAP_DIR="$from" SWAP_TO="$to" PATH="$WORK/$shims:$PATH" run_lib "$@"
  }
  # out_dir: a fresh outside folder, $WORK/f/out, with a file "secret" (mode 600) and a folder holding a file at the
  # names a call works with; and the folder the call is given, $WORK/f/u.
  out_dir() {
    chmod -R u+rwx "$WORK/f" 2>/dev/null; rm -rf "$WORK/f"
    mkdir -p "$WORK/f/u" "$WORK/f/out/version" "$WORK/f/out/installed"
    printf 'keep\n' > "$WORK/f/out/version/keep"; printf 'keep\n' > "$WORK/f/out/installed/keep"
    printf 'secret\n' > "$WORK/f/out/secret"; chmod 600 "$WORK/f/out/secret"
  }

  out_dir; rm -rf "$WORK/f/out/version"; printf 'secret\n' > "$WORK/f/out/version"; chmod 600 "$WORK/f/out/version"
  before="$(listing "$WORK/f/out")"
  out="$(swapped shim-folder "$WORK/f/u" "$WORK/f/out" safe_write "$WORK/f/u/version" 2026100500)"
  assert_eq "the folder swapped for an outside link after the check: nothing outside changes" "$before" \
    "$(listing "$WORK/f/out")"
  if [[ "${out##*$'\n'}" == status=1 ]] || [[ "$(cat "$WORK/f/u.moved/version" 2>/dev/null)" == 2026100500 ]]; then
    pass "the folder swapped for an outside link after the check: the call fails or writes in the checked folder"
  else fail "the folder swapped for an outside link after the check: the call fails or writes in the checked folder"
    printf '       got: %q\n' "$out"; fi

  out_dir; mkdir -p "$WORK/f/u/version/sub"
  before="$(listing "$WORK/f/out")"
  out="$(swapped shim-rm "$WORK/f/u" "$WORK/f/out" safe_write "$WORK/f/u/version" 2026100500)"
  assert_eq "safe_write's removal of a planted folder, the folder swapped first: nothing outside goes" "$before" \
    "$(listing "$WORK/f/out")"

  out_dir; mkdir -p "$WORK/f/s/clouve"; printf '<?php\n' > "$WORK/f/s/config.php"; ln -s "$WORK/f/u" "$WORK/f/s/clouve/installed"
  before="$(listing "$WORK/f/out")"
  out="$(swapped shim-rm "$WORK/f/s/clouve" "$WORK/f/out" stamp_folders "$WORK/f/s")"
  assert_eq "stamp_folders' removal, clouve swapped first: nothing outside goes" "$before" "$(listing "$WORK/f/out")"
  case "${out##*$'\n'}" in status=0 | status=1) pass "stamp_folders' removal, clouve swapped first: status 0 or 1" ;;
    *) fail "stamp_folders' removal, clouve swapped first: status 0 or 1"; printf '       got: %q\n' "$out" ;; esac

  # A folder already at the new file's name (shim-collide), under the entrypoint's set -e.
  fresh; mkdir -p "$WORK/u/.version.0123456789abcdef/sub"
  out="$(PATH="$WORK/shim-collide:$PATH" timeout 20 bash -c 'set -e; . "$1"; safe_write "$2" 5; echo reached' \
    _ "$STAMP_LIB" "$WORK/u/version" 2>&1; echo "status=$?")"
  assert_eq "a folder at the new file's name, under set -e: status 1" "status=1" "${out##*$'\n'}"
  check "a folder at the new file's name: the ✗ Error line says so" grep -q "^✗ Error: can't write $WORK/u/version" <<< "$out"
  assert_eq "a folder at the new file's name: no other message" "" \
    "$(grep -v -e '^✗ Error: ' -e '^status=' <<< "$out")"
  check "a folder at the new file's name: nothing is left there" no_temp_left "$WORK/u"

  echo " stamp_folders"
  # site_with config|none: a fresh $WORK/u as an installed site (it has config.php) or as a new one.
  site_with() { fresh; [ "$1" = none ] || printf '<?php\n' > "$WORK/u/config.php"; }
  site_with config; mkdir -p "$WORK/target"; printf '2026100400\n' > "$WORK/target/version"
  mkdir "$WORK/u/clouve"; ln -s "$WORK/target" "$WORK/u/clouve/installed"; before="$(listing "$WORK/target")"
  out="$(run_lib stamp_folders "$WORK/u")"
  assert_eq "a linked clouve/installed: status 0" "status=0" "${out##*$'\n'}"
  check "a linked clouve/installed: the warning names the folder" grep -qF "$WORK/u/clouve/installed is a link" <<< "$out"
  check "a linked clouve/installed: a real folder again" real_dir "$WORK/u/clouve/installed"
  assert_eq "a linked clouve/installed: the new folder is empty" "" "$(ls -A "$WORK/u/clouve/installed")"
  assert_eq "a linked clouve/installed: the link's target is unchanged" "$before" "$(listing "$WORK/target")"
  read_case "a linked clouve/installed: the stamp is missing now (the target's isn't read)" "" clouve/installed/version

  site_with config; mkdir -p "$WORK/target/installed"; printf '2026100400\n' > "$WORK/target/installed/version"
  ln -s "$WORK/target" "$WORK/u/clouve"; before="$(listing "$WORK/target")"
  out="$(run_lib stamp_folders "$WORK/u")"
  assert_eq "a linked clouve: status 0" "status=0" "${out##*$'\n'}"
  check "a linked clouve: the warning names the folder" grep -qF "$WORK/u/clouve is a link" <<< "$out"
  check "a linked clouve: clouve and clouve/installed are real folders" eval 'real_dir "$WORK/u/clouve" && real_dir "$WORK/u/clouve/installed"'
  assert_eq "a linked clouve: the link's target is unchanged" "$before" "$(listing "$WORK/target")"

  site_with none; mkdir -p "$WORK/target/installed"; ln -s "$WORK/target" "$WORK/u/clouve"
  out="$(run_lib stamp_folders "$WORK/u")"
  assert_eq "a linked clouve on a site with no config.php: status 0" "status=0" "${out##*$'\n'}"
  check "a linked clouve on a site with no config.php: removed, and nothing made (it installs as new)" \
    eval '[ ! -e "$WORK/u/clouve" ] && [ ! -L "$WORK/u/clouve" ] && [ -d "$WORK/target/installed" ]'

  site_with config; printf 'not a folder\n' > "$WORK/u/clouve"
  out="$(run_lib stamp_folders "$WORK/u")"
  assert_eq "a file at clouve: status 0" "status=0" "${out##*$'\n'}"
  check "a file at clouve: clouve/installed is a real folder" real_dir "$WORK/u/clouve/installed"

  site_with config; mkdir -p "$WORK/u/clouve/installed"; printf '2026100500\n' > "$WORK/u/clouve/installed/version"
  before="$(listing "$WORK/u")"
  assert_eq "real folders: status 0 and nothing said" "status=0" "$(run_lib stamp_folders "$WORK/u")"
  assert_eq "real folders: nothing changes" "$before" "$(listing "$WORK/u")"

  site_with none
  assert_eq "a new site with no clouve/: status 0 and nothing said" "status=0" "$(run_lib stamp_folders "$WORK/u")"
  assert_eq "a new site with no clouve/: nothing is made" "" "$(ls -A "$WORK/u")"
fi

# ----------------------------------------------------------------------------
echo
echo "Static cases (installer/entrypoint.sh)"
# ----------------------------------------------------------------------------
# The entrypoint's lines without comments: a line that starts with # and the text after " #".
code="$(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$ENTRYPOINT")"
# Every mention of the stamp, once its allowed uses are taken out: its definition, stamp_read and safe_write on it,
# -e and -L tests on it, and log lines (echo with no redirection).
others="$(printf '%s\n' "$code" | grep -n -E 'INSTALLED_VERSION_STAMP|INSTALLED_VERSIONS_PATH\}?/version|installed/version' |
  sed -E -e 's/^([0-9]+:)[[:space:]]*export INSTALLED_VERSION_STAMP="\$INSTALLED_VERSIONS_PATH\/version"[[:space:]]*$/\1/' \
    -e 's/(stamp_read|safe_write) "\$INSTALLED_VERSION_STAMP"//g' \
    -e 's/-[eL] "\$INSTALLED_VERSION_STAMP"//g' \
    -e 's/^([0-9]+:)[[:space:]]*echo "[^">]*"[[:space:]]*$/\1/' |
  grep -E 'INSTALLED_VERSION_STAMP|/version' || true)"
if [ -z "$others" ]; then pass "no line reads the stamp except through stamp_read"; else
  fail "no line reads the stamp except through stamp_read"; printf '%s\n' "$others" | sed 's/^/       line /'; fi
writes="$(printf '%s\n' "$code" | grep -n -E \
  '(>|>>|tee[[:space:]].*|touch[[:space:]].*)[[:space:]]*"?\$\{?INSTALLED_VERSION(_STAMP|S_PATH)' || true)"
if [ -z "$writes" ]; then pass "no >, tee or touch writes anything in clouve/installed/"; else
  fail "no >, tee or touch writes anything in clouve/installed/"; printf '%s\n' "$writes" | sed 's/^/       line /'; fi
check "the release timestamp is written with safe_write" \
  grep -qE '^[[:space:]]*safe_write "\$INSTALLED_VERSIONS_PATH/\$MOODLE_RELEASE" "\$TIMESTAMP"$' "$ENTRYPOINT"
check "the Gibbon integration's marker is written with safe_write" \
  grep -qE '^[[:space:]]*safe_write "\$INSTALLED_VERSIONS_PATH/\.gibbon-integration-setup" "\$TIMESTAMP"$' "$ENTRYPOINT"
folders_line="$(grep -n -m 1 -E '^stamp_folders "\$MOODLE_INSTALL_PATH"$' "$ENTRYPOINT" | cut -d: -f1)"
first_use="$(printf '%s\n' "$code" | grep -n -E '\$\{?INSTALLED_VERSION(S_PATH|_STAMP)' | grep -v -E ':[[:space:]]*export ' |
  head -n 1 | cut -d: -f1)"
check "both -gt operands are checked to be 1 to 18 digits first" grep -qF \
  '"$IMAGE_VERSION" =~ ^[0-9]{1,18}$ && "$INSTALLED_VERSION" =~ ^[0-9]{1,18}$ ]]' "$ENTRYPOINT"
check "stamp.sh's folder check asks the kernel (/bin/pwd -P), not bash's builtin pwd" eval \
  'grep -qF "\$(/bin/pwd -P" "$STAMP_LIB" && ! grep -E "^[^#]*[^/]pwd -P" "$STAMP_LIB" | grep -q .'
check "stamp_folders runs before the first use of clouve/installed/" \
  test -n "$folders_line" -a -n "$first_use" -a "${folders_line:-0}" -lt "${first_use:-0}"

# ----------------------------------------------------------------------------
if [ "$DOCKER" = false ]; then
  echo
  if [ "$FAILED" -eq 0 ]; then printf '%sVersion stamp checks passed (no Docker cases).%s\n' "$GREEN" "$RESET"; exit 0; fi
  printf '%sVersion stamp checks failed.%s\n' "$RED" "$RESET"
  exit 1
fi
echo
echo "Docker cases (${IMAGE[moodle]}, ${IMAGE[moodle-mysql]})"
# ----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "The Docker cases need Docker (--no-docker runs the others)." >&2
  exit 2
fi
for ref in "${IMAGE[@]}"; do
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    echo "No image $ref on this machine (./build.sh moodle, or --image NAME=REF)." >&2
    exit 2
  fi
done
# shellcheck source=../lib/new-disk-volumes.sh
. "$REPO/lib/new-disk-volumes.sh"

DB="$RUN-db"
APP="$RUN-app"
SITE=/var/www/html
STAMP="$SITE/clouve/installed/version"
OPS_PW="ops-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
# The site's settings, all made up. The app shares the database's network namespace, so its database is 127.0.0.1.
DB_ENV=(-e MYSQL_DATABASE=moodle -e MYSQL_USER=moodle -e MYSQL_PASSWORD=moodle_password -e MYSQL_ROOT_PASSWORD=root_password)
APP_ENV=(-e DB_HOST=127.0.0.1 -e DB_NAME=moodle -e DB_USER=moodle -e DB_PASSWORD=moodle_password
  -e MOODLE_URL=http://localhost -e MOODLE_SITE_NAME="Sample Moodle Site" -e MOODLE_EMAIL=admin@example.invalid
  -e MOODLE_USERNAME=admin -e MOODLE_PASSWORD=Sample-Admin-1 -e CLOUVE_OPS_PASSWORD="$OPS_PW")

# log_since SKIP: the app container's log after its first SKIP lines.
log_since() { docker logs "$APP" 2>&1 | tail -n +"$(($1 + 1))"; }
# wait_started SKIP SECONDS: waits until the log after SKIP lines says DONE! and Apache (PID 1) answers; status 1 if the
# container stops or the time runs out.
wait_started() {
  local end=$((SECONDS + $2))
  while (( SECONDS < end )); do
    if grep -qx 'DONE!' <<< "$(log_since "$1")" && [ "$(docker exec "$APP" cat /proc/1/comm 2>/dev/null)" = apache2 ] &&
       docker exec "$APP" curl -s -o /dev/null http://localhost/ 2>/dev/null; then
      return 0
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "$APP" 2>/dev/null)" = true ] || return 1
    sleep 3
  done
  return 1
}
# restart_app: restarts the app container as a pod restart would, and waits for it. Prints the log's line count
# before the restart, so the checks can read only this start's log.
restart_app() {
  local skip
  skip="$(docker logs "$APP" 2>&1 | wc -l)"
  docker restart -t 30 "$APP" >/dev/null || return 1
  if ! wait_started "$skip" 600; then
    log_since "$skip" | tail -n 20 | sed 's/^/       | /' >&2
    return 1
  fi
  echo "$skip"
}
# assert_get_root LABEL: GET / from inside the container answers 200, or a redirect to a page that answers 200
# (Moodle sends a visitor to its login page).
assert_get_root() {
  local codes
  codes="$(docker exec "$APP" curl -s -o /dev/null -w '%{http_code}' http://localhost/) $(docker exec "$APP" \
    curl -s -L --max-redirs 5 -o /dev/null -w '%{http_code}' http://localhost/)"
  if [[ "$codes" == "200 200" || "$codes" =~ ^30[1-8]\ 200$ ]]; then pass "$1 ($codes)"; else
    fail "$1"; printf '       GET / then the end of its redirects: %s\n' "$codes"; fi
}
# state PATH: "link", "folder", "regular <content>", "missing" or "other", as root sees it.
state() {
  docker exec "$APP" bash -c 'if [ -L "$1" ]; then echo link; elif [ -d "$1" ]; then echo folder;
    elif [ -f "$1" ]; then echo "regular $(cat "$1")"; elif [ -e "$1" ]; then echo other; else echo missing; fi' _ "$1"
}
# in_app_listing DIR: every entry under DIR in the container with its owner, type and content.
in_app_listing() {
  docker exec "$APP" sh -c 'cd "$1" && find . -printf "%p %u %y\n" | sort && find . -type f -exec md5sum {} + | sort' _ "$1"
}
# after_restart LABEL SKIP: the checks every planted start shares: the stamp holds the code's $version, no upgrade
# ran, and GET / answers 200.
after_restart() {
  assert_eq "$1: the stamp holds the code's \$version" "regular $CODE_VERSION" "$(state "$STAMP")"
  if grep -q 'UPGRADING Moodle' <<< "$(log_since "$2")"; then fail "$1: no upgrade ran"; else pass "$1: no upgrade ran"; fi
  assert_get_root "$1: GET / answers 200"
}

nd_shaper_ready || exit 2
for key in db_data moodle_data moodledata; do
  nd_make_new_disk "$RUN-$key" "$RUN" "$key" || exit 2
done
docker run -d --pull=never --name "$DB" --network none "${DB_ENV[@]}" -v "$RUN-db_data:/var/lib/mysql" \
  "${IMAGE[moodle-mysql]}" >/dev/null || exit 2
docker run -d --pull=never --name "$APP" --network "container:$DB" "${APP_ENV[@]}" \
  -v "$RUN-moodle_data:$SITE" -v "$RUN-moodledata:/var/moodledata" "${IMAGE[moodle]}" >/dev/null || exit 2
if ! wait_started 0 900; then
  docker logs "$APP" 2>&1 | tail -n 20 | sed 's/^/       | /'
  fail "the site installs and Apache answers"
  exit 1
fi
pass "the site installs and Apache answers"
CODE_VERSION="$(docker exec "$APP" sed -nE 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
  "$SITE/public/version.php" | head -n 1)"
OLDER=$((CODE_VERSION - 100))   # a valid stamp of an older build, for the linked folders
assert_eq "after the install the stamp holds the code's \$version" "regular $CODE_VERSION" "$(state "$STAMP")"

echo " a command in the stamp"
# Put there as www-data, as the site's PHP code runs.
docker exec -u www-data "$APP" bash -c 'printf "%s\n" "a[\$(touch /tmp/pwned)]" > "$1"' _ "$STAMP"
assert_eq "www-data can write the stamp" 'regular a[$(touch /tmp/pwned)]' "$(state "$STAMP")"
if ! skip="$(restart_app)"; then
  fail "the site starts again with a command in the stamp"
else
  log="$(log_since "$skip")"
  if docker exec "$APP" test -e /tmp/pwned; then fail "the command in the stamp did not run (/tmp/pwned exists)"; else
    pass "the command in the stamp did not run (no /tmp/pwned)"; fi
  check "the log names the stamp" grep -qF "$STAMP" <<< "$log"
  if grep -qF -e 'touch /tmp/pwned' -e 'a[$(' <<< "$log"; then fail "the log doesn't show what was in the stamp"
    grep -nF -e 'touch /tmp/pwned' -e 'a[$(' <<< "$log" | head -n 3 | sed 's/^/       | /'
  else pass "the log doesn't show what was in the stamp"; fi
  after_restart "a command in the stamp" "$skip"
fi

echo " the stamp a link to /proc/self/environ"
docker exec -u www-data "$APP" ln -sfn /proc/self/environ "$STAMP"
assert_eq "www-data can make the stamp a link" "link" "$(state "$STAMP")"
if ! skip="$(restart_app)"; then
  fail "the site starts again with the stamp a link to /proc/self/environ"
else
  if grep -qF -- "$OPS_PW" <<< "$(docker logs "$APP" 2>&1)"; then fail "the log holds no CLOUVE_OPS_PASSWORD value"
  else pass "the log holds no CLOUVE_OPS_PASSWORD value"; fi
  after_restart "a linked stamp" "$skip"
fi

echo " clouve/installed a link to a folder outside the volume, with an older stamp in it"
docker exec -u www-data "$APP" bash -c 'mkdir /tmp/s1-installed && printf "%s\n" "$2" > /tmp/s1-installed/version &&
  rm -rf "$1/clouve/installed" && ln -s /tmp/s1-installed "$1/clouve/installed"' _ "$SITE" "$OLDER"
assert_eq "www-data can make clouve/installed a link" "link" "$(state "$SITE/clouve/installed")"
before="$(in_app_listing /tmp/s1-installed)"
if ! skip="$(restart_app)"; then
  fail "the site starts again with clouve/installed a link"
else
  assert_eq "a linked clouve/installed: nothing in the link's target changed" "$before" "$(in_app_listing /tmp/s1-installed)"
  assert_eq "a linked clouve/installed: a real folder again" "folder" "$(state "$SITE/clouve/installed")"
  check "a linked clouve/installed: the log names the folder" grep -qF "$SITE/clouve/installed is a link" <<< "$(log_since "$skip")"
  after_restart "a linked clouve/installed" "$skip"
fi

echo " clouve a link to a folder outside the volume, with an older stamp in it"
docker exec -u www-data "$APP" bash -c 'mkdir -p /tmp/s1-clouve/installed &&
  printf "%s\n" "$2" > /tmp/s1-clouve/installed/version && rm -rf "$1/clouve" && ln -s /tmp/s1-clouve "$1/clouve"' \
  _ "$SITE" "$OLDER"
assert_eq "www-data can make clouve a link" "link" "$(state "$SITE/clouve")"
before="$(in_app_listing /tmp/s1-clouve)"
if ! skip="$(restart_app)"; then
  fail "the site starts again with clouve a link"
else
  assert_eq "a linked clouve: nothing in the link's target changed" "$before" "$(in_app_listing /tmp/s1-clouve)"
  assert_eq "a linked clouve: a real folder again" "folder folder" \
    "$(state "$SITE/clouve") $(state "$SITE/clouve/installed")"
  check "a linked clouve: the log names the folder" grep -qF "$SITE/clouve is a link" <<< "$(log_since "$skip")"
  after_restart "a linked clouve" "$skip"
fi

echo " an older stamp of digits, as a site from an older image has: the upgrade still runs"
docker exec -u www-data "$APP" bash -c 'printf "%s\n" "$2" > "$1"' _ "$STAMP" "$OLDER"
RELEASE_FILE="$SITE/clouve/installed/$(docker exec "$APP" printenv MOODLE_RELEASE)"
if ! skip="$(restart_app)"; then
  fail "the site starts again with an older stamp"
else
  check "an older stamp: the upgrade runs, as before" grep -qF "UPGRADING Moodle $OLDER -> $CODE_VERSION" <<< "$(log_since "$skip")"
  assert_eq "an older stamp: the upgrade records the code's \$version" "regular $CODE_VERSION" "$(state "$STAMP")"
  check "an older stamp: the release's timestamp is a regular file" grep -qE '^regular [0-9]{4}(-[0-9]{2}){5}$' \
    <<< "$(state "$RELEASE_FILE")"
  assert_get_root "an older stamp: GET / answers 200"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sVersion stamp checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sVersion stamp checks failed.%s\n' "$RED" "$RESET"
exit 1
