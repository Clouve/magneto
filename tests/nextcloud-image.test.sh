#!/bin/bash

# ============================================================================
# Nextcloud image test: the installer scripts
# ============================================================================
# Checks the shell scripts in apps/nextcloud/image/installer/ inside the image
# they ship in, nextcloud:35.0.2-apache. The admin-name cleanup needs that
# image's PHP (the intl extension), and the scripts are written for its Debian
# userland, so a shell on the host would prove less.
#
# The file runs itself twice. On the host it starts the base image with no
# network, the installer folder mounted read-only at /clouve/nextcloud/installer
# and this file at /test.sh, and exits with the container's status. Inside the
# container (NC_TEST_IN_IMAGE=1) it runs the checks. Nothing here needs the
# internet, and the container is removed when it exits.
#
# What it covers:
#   lib.sh   nc_log and nc_warn; HTML entity decoding; the admin-name cleanup
#            (accents, other alphabets, HTML escapes, unfilled templates, null
#            and undefined, hyphens, refused names, length, and what happens
#            when PHP fails); URL scheme and host; the memory limit from
#            cgroup v2 and v1 and the Apache worker and preview numbers worked
#            out from it; trusted_domains merging; running occ (nc_occ,
#            nc_try_occ); reading occ's status and the app config markers;
#            the post-upgrade steps and their marker, with a repair that dies
#            on the way and leaves maintenance mode on; the marker files of
#            the AI Assistant's backups and restores (the note that tells
#            the hooks of a restore, a backup's name read safely, a backup
#            that was cut off); the first lines of occ's output; the sweep
#            of what a killed run leaves behind; a new disk's top folder of
#            root's, given to www-data; and the repair of the database
#            settings in config.php, as root and as www-data.
#   valkey.conf       the file is exactly the planned one.
#   start-valkey.sh   the socket directory (owner, mode, and one left wrong by
#                     an earlier run), the command it runs, the line it logs
#                     and the second it waits between runs, and that it keeps
#                     going whatever Valkey's exit status.
#   healthcheck.sh    the probe, run the way the platform runs it ("sh -c
#                     <path>", and sh is dash here). Once with fakes for flock,
#                     valkey-cli and curl that record what they were asked, to
#                     go through every case; once with the real flock and the
#                     real curl, a real lock and a stand-in web server.
#   the harness       load_lib and run_section report a lib.sh that cannot be
#                     loaded and a section that ran no checks, instead of
#                     letting them pass unnoticed.
#   nextcloud-config.sh   the settings kept in step with the environment, run
#                     against a fake occ that keeps its state in a config.php:
#                     the URL change line, overwriteprotocol, trusted_domains
#                     over a custom domain and back, the database settings and
#                     the private file that carries the password (mode, no
#                     leak, deleted right after), the proxies, the cache, the
#                     previews, the upload chunk size (set when it is missing,
#                     0 or less, or above the ingress's 50 MiB, and an admin's
#                     value from 1 byte to 50 MiB kept), failures that are
#                     warnings, and a config.php
#                     with a stale database host that occ cannot start with.
#   the hooks         pre-installation, post-installation, post-upgrade and
#                     before-starting, run the way the official entrypoint
#                     runs them, against the same fake occ and a fake flock:
#                     the refusal to start, the upgrade that was cut off (and
#                     the post-upgrade steps after it, and a second kill
#                     during them), the log level after one that failed, a
#                     restore that was cut off, the time limit on each
#                     first-start app download, the marker a finished first
#                     install leaves and the second run of its settings, under
#                     the init lock, after a first start that was cut off, the
#                     post-upgrade marker and the second run of those steps
#                     after a start cut off during them, the maintenance mode
#                     that a repair cut off leaves on and the next start turns
#                     off, HOME, and the order of every step.
#   the real occ      the same scripts as www-data against a SQLite install, to
#                     show that the fake answers as the real occ does: the
#                     settings, the chunk size Nextcloud itself reads and
#                     advertises, the repair as root and as www-data, the three
#                     hooks that call occ, an upgrade that fails and one that
#                     finishes, a first start whose own settings were cut off,
#                     the Fontconfig error that a HOME www-data cannot write to
#                     causes, a real repair killed half way (it leaves
#                     maintenance mode on), and the real post-upgrade and
#                     post-installation hooks killed during their repairs and
#                     finished by the next start. Skipped with
#                     NC_TEST_SKIP_REAL=1; it takes about a minute and a half.
#
# The file has four parts, in this order:
#   1. On the host: run this file again inside the image.
#   2. Helpers: pass, fail, eq, matches, contains, lacks, fake_cmd, with_path,
#      with_only_path. For a script that calls occ: nc_world, nc_run, cfg_reset,
#      cfg_get, logged, logged_in_order, not_logged and no_secret, with the
#      fake occ and flock they use (see the part headed "nextcloud-config.sh
#      and the hooks").
#   3. Sections: one function per section. Each runs in a subshell of its own,
#      so a PATH, variable or directory change in one never reaches the next.
#   4. The list of sections to run, and the summary.
# To add a section, write a function named section_<name> at the end of part 3
# and add one run_section line in part 4. Put fake commands (flock, curl, occ)
# in a directory under $WORK, write them with fake_cmd (or fake_spy, which also
# records each call), and run the script under test through with_path. A
# variable given in front of with_path reaches the fake:
#   FAKE_CURL_RC=22 with_path "$bin" sh -c "$INSTALLER/healthcheck.sh"
#
# Needs Docker and the base image (it is pulled if missing).
# Usage: bash tests/nextcloud-image.test.sh
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker.
# ============================================================================

set -uo pipefail

IMAGE="nextcloud:35.0.2-apache"
INSTALLER=/clouve/nextcloud/installer    # where the image keeps the installer scripts
LIB="$INSTALLER/lib.sh"

# ----------------------------------------------------------------------------
# 1. On the host: run this file again inside the image
# ----------------------------------------------------------------------------
if [[ -z "${NC_TEST_IN_IMAGE:-}" ]]; then
  SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  REPO="$(cd "$(dirname "$SELF")/.." && pwd)"
  INSTALLER_DIR="$REPO/apps/nextcloud/image/installer"

  # Checked before Docker starts: a bind mount of a folder that doesn't exist
  # would make Docker create it, as root, inside the repository.
  if [[ ! -f "$INSTALLER_DIR/lib.sh" ]]; then
    echo "FAIL: lib.sh not found ($INSTALLER_DIR/lib.sh)" >&2
    exit 1
  fi
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "This test needs Docker." >&2
    exit 2
  fi

  use_color=""
  if [[ -t 1 ]]; then use_color=1; fi
  docker run --rm --network none -e NC_TEST_IN_IMAGE=1 -e "NC_TEST_COLOR=$use_color" -e "NC_TEST_SKIP_REAL=${NC_TEST_SKIP_REAL:-}" \
    -v "$INSTALLER_DIR:$INSTALLER:ro" \
    -v "$SELF:/test.sh:ro" --entrypoint bash "$IMAGE" /test.sh
  exit $?
fi

# ----------------------------------------------------------------------------
# 2. Helpers (inside the image)
# ----------------------------------------------------------------------------
if [[ -n "${NC_TEST_COLOR:-}" ]]; then
  GREEN=$'\033[0;32m' RED=$'\033[0;31m' RESET=$'\033[0m'
else
  GREEN='' RED='' RESET=''
fi

WORK="$(mktemp -d)"
RESULTS="$WORK/results"    # one line per check, P or F; sections run in subshells, so counts live in a file
: > "$RESULTS"
trap 'rm -rf "$WORK"' EXIT
# The shell is PID 1 here, and PID 1 ignores a signal it has no handler for.
trap 'exit 130' INT
trap 'exit 143' TERM

pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; echo P >> "$RESULTS"; return 0; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; echo F >> "$RESULTS"; return 0; }

# eq EXPECTED ACTUAL LABEL: ACTUAL is exactly EXPECTED.
eq() {
  local label="${3:-$1}"
  if [[ "$2" == "$1" ]]; then
    pass "$label"
  else
    fail "$label"
    printf '       expected: %q\n       actual:   %q\n' "$1" "$2"
  fi
}

# matches REGEX ACTUAL LABEL: ACTUAL matches the extended regular expression.
matches() {
  local label="${3:-$1}"
  if [[ "$2" =~ $1 ]]; then
    pass "$label"
  else
    fail "$label"
    printf '       wanted a match for: %s\n       actual:             %q\n' "$1" "$2"
  fi
}

# contains NEEDLE TEXT LABEL: TEXT holds NEEDLE (as plain text, not a pattern).
contains() {
  local label="${3:-contains: $1}"
  if [[ "$2" == *"$1"* ]]; then
    pass "$label"
  else
    fail "$label"
    printf '       wanted: %q\n       in:     %q\n' "$1" "$2"
  fi
}

# lacks NEEDLE TEXT LABEL: TEXT does not hold NEEDLE.
lacks() {
  local label="${3:-lacks: $1}"
  if [[ "$2" != *"$1"* ]]; then
    pass "$label"
  else
    fail "$label"
    printf '       found: %q\n       in:    %q\n' "$1" "$2"
  fi
}

# fake_cmd DIR NAME: writes the script on stdin to DIR/NAME, executable, with a bash shebang.
fake_cmd() {
  mkdir -p "$1"
  { printf '#!/bin/bash\n'; cat; } > "$1/$2"
  chmod 755 "$1/$2"
}

# fake_spy DIR NAME: like fake_cmd, but the fake first appends one line to $FAKE_LOG: its name, then each argument,
# joined by "|". A test can then say exactly what the script under test ran, with which arguments, and in what order.
# shellcheck disable=SC2016  # the first line is the fake's own code, not ours
fake_spy() {
  { printf '%s\n' 'printf "%s" "${0##*/}" >> "$FAKE_LOG"; printf "|%s" "$@" >> "$FAKE_LOG"; echo >> "$FAKE_LOG"'; cat; } | fake_cmd "$1" "$2"
}

# with_path DIR COMMAND...: runs a function or program with DIR first on PATH (in a subshell).
with_path() {
  local dir="$1"
  shift
  ( PATH="$dir:$PATH"; hash -r; "$@" )
}

# with_only_path DIR COMMAND...: like with_path, but DIR is the whole PATH, so nothing else can be found.
with_only_path() {
  local dir="$1"
  shift
  # shellcheck disable=SC2123,SC2030  # replacing PATH, in a subshell, is the point
  ( PATH="$dir"; hash -r; "$@" )
}

# load_lib: sources lib.sh into the current section. If it can't, it records a failure and returns 1, so the section
# (which calls it as "load_lib || return 0") stops with a failure behind it instead of running no checks.
load_lib() {
  if [[ ! -f "$LIB" ]]; then
    fail "lib.sh not found: $LIB"
    return 1
  fi
  # shellcheck source=/dev/null
  source "$LIB" || { fail "lib.sh could not be sourced: $LIB"; return 1; }
}

heading() { printf '\n%s\n' "$1"; }

# run_section TITLE FUNCTION: runs the section in a subshell. A section that stops early counts as a failure, and so
# does one that finishes without having recorded a single check (a lib.sh that exits when sourced does that).
# The subshell runs in the background and the shell waits for it, so a Ctrl-C ends the run at once
# instead of after the section.
run_section() {
  local rc before after
  heading "$1"
  before="$(wc -l < "$RESULTS")"
  ( "$2" ) &
  wait $!
  rc=$?
  after="$(wc -l < "$RESULTS")"
  if [[ "$rc" -ne 0 ]]; then
    fail "$1: the section stopped with exit status $rc"
  elif [[ "$after" -eq "$before" ]]; then
    fail "$1: the section ran no checks"
  fi
}

finish() {
  local passed failed
  passed="$(grep -c '^P$' "$RESULTS")"
  failed="$(grep -c '^F$' "$RESULTS")"
  echo
  if [[ "$failed" -eq 0 ]]; then
    printf '%sAll %s Nextcloud image checks passed.%s\n' "$GREEN" "$passed" "$RESET"
  else
    printf '%s%s of %s Nextcloud image checks failed.%s\n' "$RED" "$failed" "$((passed + failed))" "$RESET"
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# 3. Sections
# ----------------------------------------------------------------------------

# fake_php DIR KIND: writes DIR/php, a php that goes wrong in one way, for with_path.
#   fails    prints an error on stdout (where this image's php prints them) and exits 255
#   junk     exits 0 after printing a warning, which is not a result
#   long     exits 0 after printing 65 letters
#   nothing  exits 0 and prints nothing
#   nointl   is the real php started with -n, which skips the ini files, so it has no intl
#   noisy    is the real php with a startup warning ("Module intl is already loaded")
fake_php() {
  local real
  real="$(command -v php)"
  case "$2" in
    fails)   fake_cmd "$1" php <<'EOF'
echo 'Fatal error: Uncaught Error: boom'
exit 255
EOF
      ;;
    junk)    fake_cmd "$1" php <<'EOF'
echo -n 'Warning: Module "intl" is already loaded (x)'
EOF
      ;;
    long)    fake_cmd "$1" php <<'EOF'
printf 'a%.0s' {1..65}
EOF
      ;;
    nothing) fake_cmd "$1" php <<'EOF'
exit 0
EOF
      ;;
    nointl)  fake_cmd "$1" php <<EOF
exec $real -n "\$@"
EOF
      ;;
    noisy)   fake_cmd "$1" php <<EOF
exec $real -d extension=intl "\$@"
EOF
      ;;
    *) echo "fake_php: unknown kind $2" >&2; return 1 ;;
  esac
}

# --- lib.sh: logging -----------------------------------------------------------
section_lib_log() {
  load_lib || return 0
  eq '[nextcloud] two words three' "$(nc_log 'two words' three 2>"$WORK/err")" 'nc_log: prefix, then the arguments joined by a space'
  eq '' "$(cat "$WORK/err")" 'nc_log: nothing on stderr'
  eq '[nextcloud] WARNING: low disk' "$(nc_warn 'low disk' 2>&1 >/dev/null)" 'nc_warn: WARNING: line on stderr'
  eq '' "$(nc_warn 'low disk' 2>/dev/null)" 'nc_warn: nothing on stdout'
  eq '[nextcloud] 100% done' "$(nc_log '100% done')" 'nc_log: a % in the message is printed as it is'
  eq '[nextcloud] -n' "$(nc_log -n)" 'nc_log: a message that looks like an option is printed'
  eq '[nextcloud] a b' "$(IFS=,; nc_log a b)" 'nc_log: the caller changing IFS does not change the join'
}

# --- lib.sh: HTML entities -----------------------------------------------------
# shellcheck disable=SC2016  # test data: shell and PHP syntax that has to stay text
section_lib_entities() {
  load_lib || return 0
  local marker="$WORK/injected" out rc

  eq "x&y'z" "$(nc_decode_entities 'x&amp;y&apos;z')" '&amp; and &apos; (named entities)'
  eq "O'Brien" "$(nc_decode_entities 'O&#x27;Brien')" "numeric reference in hex (what a JavaScript escaper writes)"
  eq "O'Brien" "$(nc_decode_entities 'O&#039;Brien')" "numeric reference in decimal (what PHP's htmlspecialchars writes)"
  eq '"q" <t> é' "$(nc_decode_entities '&quot;q&quot; &lt;t&gt; &eacute;')" 'quotes, angle brackets and a named letter'
  eq '&apos;' "$(nc_decode_entities '&amp;apos;')" 'decoded once, not twice'
  eq '&bogus; &#0;' "$(nc_decode_entities '&bogus; &#0;')" 'an unknown entity and a NUL reference stay as they are'
  eq 'plain text' "$(nc_decode_entities 'plain text')" 'text without & comes back unchanged'
  eq '' "$(nc_decode_entities '')" 'empty in, empty out'
  eq 'a@b.example' "$(nc_decode_entities 'a@b.example')" 'an email address is not touched'
  eq '$HOME & `id` $(id)' "$(nc_decode_entities '$HOME &amp; `id` $(id)')" 'shell syntax in the text stays text'
  eq '--version &' "$(nc_decode_entities '--version &amp;')" 'text that looks like a php option stays text'
  eq $'two\nlines & more' "$(nc_decode_entities $'two\nlines &amp; more')" 'a newline inside the text is kept'

  rm -f "$marker"
  nc_decode_entities "x'); file_put_contents('$marker', '1'); //&amp;" >/dev/null
  if [[ -e "$marker" ]]; then fail 'text is never run as PHP code'; else pass 'text is never run as PHP code'; fi

  # When php fails, the text comes back unchanged, with a warning, and the function still succeeds.
  fake_php "$WORK/bin-php-fails" fails
  out="$(with_path "$WORK/bin-php-fails" nc_decode_entities 'a&amp;b' 2>"$WORK/err")"
  rc=$?
  eq 'a&amp;b' "$out" 'php fails: the text comes back unchanged'
  lacks 'Fatal error' "$out" 'php fails: its error text is not in the result'
  eq 0 "$rc" 'php fails: exit status 0'
  contains '[nextcloud] WARNING:' "$(cat "$WORK/err")" 'php fails: a warning on stderr'
  # Text with no & never needs php.
  eq 'no ampersand' "$(with_path "$WORK/bin-php-fails" nc_decode_entities 'no ampersand' 2>&1)" 'no & in the text: php is not started'
  # A php startup warning must not end up in the result. Left on stdout, it would become part of an email address.
  fake_php "$WORK/bin-php-noisy" noisy
  contains 'Module "intl" is already loaded' "$(with_path "$WORK/bin-php-noisy" php -r 'echo 1;')" 'sanity check: without the flag this php prints its startup warning on stdout'
  eq 'a&b' "$(with_path "$WORK/bin-php-noisy" nc_decode_entities 'a&amp;b' 2>/dev/null)" 'php startup warning: the result is still only the decoded text'
}

# --- lib.sh: the admin name ----------------------------------------------------
# login_ok LABEL VALUE: VALUE is a login Nextcloud 35 accepts (the rules in its
# User\Manager::validateUserId, minus the check of the data folder), and one occ
# takes as the value after --admin-user, which can't start with a hyphen.
LOGIN_RE="^[A-Za-z0-9 _.@'-]+\$"
login_ok() {
  local v="$2" why=''
  if [[ ! "$v" =~ $LOGIN_RE ]]; then why='has a character Nextcloud refuses, or is empty'
  elif [[ "${#v}" -gt 64 ]]; then why='is longer than 64 characters'
  elif [[ "$v" == [[:space:]]* || "$v" == *[[:space:]] ]]; then why='has a space at the start or the end'
  elif [[ "$v" == . || "$v" == .. ]]; then why='is only dots'
  elif [[ "$v" == -* ]]; then why='starts with a hyphen, which occ reads as an option'
  fi
  if [[ -z "$why" ]]; then pass "$1"; else
    fail "$1"
    printf '       got %q, which %s\n' "$v" "$why"
  fi
}

# shellcheck disable=SC2016  # test data: shell and PHP syntax that has to stay text
section_lib_admin_user() {
  load_lib || return 0
  local name got a63 a70 marker="$WORK/injected" out rc

  echo ' basic cases'
  eq "John_Smith"      "$(nc_clean_admin_user 'John_Smith')"                  'plain name stays'
  eq "Jose_Garcia"     "$(nc_clean_admin_user 'José_García')"                 'accents become ASCII'
  eq "O'Brien_Smith"   "$(nc_clean_admin_user 'O&apos;Brien_Smith')"          'an escaped apostrophe is decoded and kept'
  eq "Mary Ann_Lee"    "$(nc_clean_admin_user 'Mary Ann_Lee')"                'a space inside a name is kept'
  eq "Dmitrij_Ivanov"  "$(nc_clean_admin_user 'Дмитрий_Иванов')"              'Cyrillic is transliterated'
  eq "Tom_Co_Ltd"      "$(nc_clean_admin_user 'Tom &amp; Co_Ltd')"            'an escaped & becomes one underscore'
  eq "John"            "$(nc_clean_admin_user 'John_null')"                   'a trailing _null goes'
  eq "admin"           "$(nc_clean_admin_user '')"                            'empty becomes admin'
  eq "admin"           "$(nc_clean_admin_user '_')"                           'only an underscore becomes admin'
  eq "admin"           "$(nc_clean_admin_user 'undefined_undefined')"         'undefined_undefined becomes admin'
  eq "admin"           "$(nc_clean_admin_user '{user.firstName}_{user.lastName}')" 'an unfilled template becomes admin'
  eq "a@b.example"     "$(nc_clean_admin_user 'a@b.example')"                 'an email-style login stays'
  eq 64                "$(nc_clean_admin_user "$(printf 'a%.0s' {1..70})" | tr -d '\n' | wc -c)" '70 characters are cut to 64'
  matches '^[A-Za-z0-9 _.@'"'"'-]+$' "$(nc_clean_admin_user '王_小明')"        'Chinese gives only allowed characters'

  echo ' more HTML escapes'
  eq "O'Brien"   "$(nc_clean_admin_user 'O&#x27;Brien')"        'hex numeric reference'
  eq "O'Brien"   "$(nc_clean_admin_user 'O&#039;Brien')"        'decimal numeric reference'
  eq "Zoe"       "$(nc_clean_admin_user 'Zo&euml;')"            'a named letter entity is decoded, then transliterated'
  eq "Tom_Jerry" "$(nc_clean_admin_user 'Tom&nbsp;&amp;&nbsp;Jerry')" 'non-breaking spaces and & become one underscore'
  eq "Ben_Jerry" "$(nc_clean_admin_user 'Ben &lt;&gt; Jerry')"  '< and > become underscores'

  echo ' unfilled templates'
  eq admin "$(nc_clean_admin_user '[user.firstName]_[user.lastName]')" 'square-bracket placeholders become admin'
  eq admin "$(nc_clean_admin_user 'John_{user.lastName}')"           'one unfilled half is enough'
  eq admin "$(nc_clean_admin_user '{user.firstName}')"               'one placeholder alone'

  echo ' null and undefined from empty fields'
  eq John "$(nc_clean_admin_user 'null_John')"                'a leading null_ goes'
  eq John "$(nc_clean_admin_user 'Undefined_John')"           'a leading Undefined_ goes (any case)'
  eq John "$(nc_clean_admin_user 'John_UNDEFINED')"           'a trailing _UNDEFINED goes (any case)'
  eq John "$(nc_clean_admin_user 'null_John_undefined')"      'both ends'
  eq admin "$(nc_clean_admin_user 'null')"                    'null alone becomes admin'
  eq admin "$(nc_clean_admin_user 'NULL')"                    'NULL alone becomes admin'
  eq admin "$(nc_clean_admin_user 'undefined')"               'undefined alone becomes admin'
  eq admin "$(nc_clean_admin_user 'null_null')"               'null_null becomes admin'
  eq admin "$(nc_clean_admin_user 'null_undefined')"          'null_undefined becomes admin'
  eq Nullman "$(nc_clean_admin_user 'Nullman')"               'a name that only starts with null stays'
  eq 'John_null_Smith' "$(nc_clean_admin_user 'John_null_Smith')" 'null in the middle stays'
  eq 'Null Island' "$(nc_clean_admin_user 'Null Island')"     'null followed by a space (not an underscore) stays'

  echo ' spaces and underscores'
  eq John "$(nc_clean_admin_user '  John  ')"                'spaces at both ends go'
  eq John "$(nc_clean_admin_user '__John__')"                'underscores at both ends go'
  eq John_Smith "$(nc_clean_admin_user 'John _ Smith')"      'a run of spaces and an underscore becomes one underscore'
  eq John_Smith "$(nc_clean_admin_user 'John___Smith')"      'a run of underscores becomes one'
  eq 'Mary  Ann' "$(nc_clean_admin_user 'Mary  Ann')"        'a run of only spaces is kept'
  eq John_Smith "$(nc_clean_admin_user $'John\nSmith')"      'a newline becomes an underscore'
  eq a_b "$(nc_clean_admin_user $'a\tb')"                    'a tab becomes an underscore'
  eq admin "$(nc_clean_admin_user '   ')"                    'only spaces becomes admin'
  eq admin "$(nc_clean_admin_user $'\n')"                    'only a newline becomes admin'

  echo ' hyphens (occ reads --admin-user -x as a missing value followed by an option)'
  eq x "$(nc_clean_admin_user '-x')"                         'a leading hyphen goes'
  eq admin "$(nc_clean_admin_user '-')"                      'a hyphen alone becomes admin'
  eq admin-user "$(nc_clean_admin_user '--admin-user')"      'leading hyphens go, the inner one stays'
  eq x "$(nc_clean_admin_user '_-x')"                        'underscore, then hyphen'
  eq x "$(nc_clean_admin_user 'null_-x')"                    'a hyphen left in front by removing null_ goes too'
  eq admin "$(nc_clean_admin_user '-null')"                  'a hyphen then null is null, so admin'
  eq admin "$(nc_clean_admin_user '-_-')"                    'only hyphens and underscores becomes admin'
  eq a-b "$(nc_clean_admin_user 'a-b')"                      'a hyphen inside a name stays'
  eq 'Smith-' "$(nc_clean_admin_user 'Smith-')"              'a hyphen at the end stays'
  eq version "$(nc_clean_admin_user '--version')"            'text that looks like a php option is only a name'
  eq h "$(nc_clean_admin_user '-h')"                         '-h too'

  echo ' dots and the names Nextcloud refuses'
  for name in . .. .htaccess files_external .ncdata owncloud.log nextcloud.log updater.log audit.log; do
    eq admin "$(nc_clean_admin_user "$name")" "refused name $name becomes admin"
  done
  eq admin "$(nc_clean_admin_user ' . ')"                    '. with spaces around it is still only a dot'
  eq admin "$(nc_clean_admin_user '_.._')"                   '.. with underscores around it is still only dots'
  eq admin "$(nc_clean_admin_user '_.htaccess_')"            '.htaccess with underscores around it'
  eq admin "$(nc_clean_admin_user 'files_external ')"        'files_external with a space after it'
  eq groupfolders "$(nc_clean_admin_user '__groupfolders')"  '__groupfolders loses its underscores first, so it is not a refused name'
  eq '. .' "$(nc_clean_admin_user '. .')"                    'a space between two dots is a valid name'
  eq .hidden "$(nc_clean_admin_user '.hidden')"              'a name that starts with a dot stays'
  eq admin "$(nc_clean_admin_user 'admin')"                  'admin stays admin'
  eq 'john.smith@example.com' "$(nc_clean_admin_user 'john.smith@example.com')" 'a dotted email-style login stays'

  echo ' length'
  a63="$(printf 'a%.0s' {1..63})"
  a70="$(printf 'a%.0s' {1..70})"
  eq "$a63" "$(nc_clean_admin_user "${a63}_bbbb")"           'cut at 64 leaves an underscore at the end, which goes'
  eq "$a63" "$(nc_clean_admin_user "${a63} bbbb")"           'cut at 64 leaves a space at the end, which goes'
  eq "${a63}b" "$(nc_clean_admin_user "${a63}bbbb")"         'exactly 64 characters are kept'
  eq "$(printf 'e%.0s' {1..64})" "$(nc_clean_admin_user "$(printf 'é%.0s' {1..70})")" 'accented letters are counted after they become ASCII'
  eq "${a70:0:64}" "$(nc_clean_admin_user "$a70")"           'the cut keeps the first 64'

  echo ' text that must stay text'
  eq HOME_Smith "$(nc_clean_admin_user '$HOME_Smith')"       '$HOME is not expanded'
  eq id_x "$(nc_clean_admin_user '`id`_x')"                  'backticks are not run'
  eq id_x "$(nc_clean_admin_user '$(id)_x')"                 '$(...) is not run'
  eq "a'_die_'PWNED'_b" "$(nc_clean_admin_user "a'); die('PWNED'); //b")" 'quotes and PHP code are only characters to clean'
  eq a_b "$(nc_clean_admin_user 'a\b')"                      'a backslash becomes an underscore'
  eq s_d "$(nc_clean_admin_user '%s%d')"                     'printf formats are only characters'
  eq script_alert_1_script "$(nc_clean_admin_user '<script>alert(1)</script>')" 'markup becomes underscores'
  rm -f "$marker"
  nc_clean_admin_user "x'); file_put_contents('$marker', '1'); //" >/dev/null
  if [[ -e "$marker" ]]; then fail 'a name is never run as PHP code'; else pass 'a name is never run as PHP code'; fi

  echo ' other alphabets and odd bytes'
  eq Jose_Garcia "$(nc_clean_admin_user $'Jose\xcc\x81_Garcia')" 'an accent as a separate combining character (decomposed form)'
  eq admin "$(nc_clean_admin_user '😀')"                     'an emoji alone becomes admin'
  eq x "$(nc_clean_admin_user '😀_x')"                       'an emoji next to an underscore goes with it'
  eq Zoe "$(nc_clean_admin_user 'Zoë 😀')"                   'an emoji after a name goes'
  eq admin "$(nc_clean_admin_user $'\xff\xfe')"              'bytes that are not UTF-8 become admin'
  eq ab_cd "$(nc_clean_admin_user $'ab\xffcd')"              'a stray byte becomes an underscore'
  for name in 'Γιώργος_Παπαδόπουλος' 'محمد_علي' 'דוד_כהן' 'สมชาย_ใจดี' 'たなか_たろう' '김_민수' 'a😀b' "‘Smith’" $'M\xc3\xbcller\xe2\x80\x93Schmidt'; do
    login_ok "a valid login from: $name" "$(nc_clean_admin_user "$name" 2>/dev/null)"
  done
  eq "O'Brien" "$(nc_clean_admin_user "O’Brien")"            'a curly apostrophe becomes a straight one'

  echo ' every awkward input gives a login Nextcloud accepts'
  for name in '-' '--' '-_-' '- -' '_-_' '..' '. .' ' . ' '@' "'" "''" '%' '%s%n' $'\\' '\\n' '"' '../../etc/passwd' \
              $'\t' $'\n' $'a\nb' $'\r\n' ' ' 'null' 'NULL' 'undefined' 'null_null' 'undefined_null_undefined' '_null_' \
              '{user.' '[user.x]' '&' '&;' '&#;' '&#x;' '&amp' "$(printf 'x%.0s' {1..200})" "$(printf ' %.0s' {1..200})x"; do
    got="$(nc_clean_admin_user "$name" 2>/dev/null)"
    login_ok "a valid login from: $(printf '%q' "$name" | cut -c1-60)" "$got"
  done

  echo ' the same under a UTF-8 locale'
  eq Jose_Garcia "$(LC_ALL=C.UTF-8 nc_clean_admin_user 'José_García')" 'accents become ASCII'
  eq admin "$(LC_ALL=C.UTF-8 nc_clean_admin_user '😀')" 'an emoji alone becomes admin'
  eq "O'Brien_Smith" "$(LC_ALL=C.UTF-8 nc_clean_admin_user 'O&apos;Brien_Smith')" 'an escaped apostrophe'
  eq 64 "$(LC_ALL=C.UTF-8 nc_clean_admin_user "$(printf 'é%.0s' {1..70})" | tr -d '\n' | wc -c)" '70 accented letters are cut to 64'

  echo ' php trouble: the first install must not fail on the name'
  # php stops with an error. This image's php prints errors on stdout, and that text must never become the login.
  fake_php "$WORK/bin-php-fails" fails
  out="$(with_path "$WORK/bin-php-fails" nc_clean_admin_user 'José' 2>"$WORK/err")"
  rc=$?
  eq admin "$out" 'php fails: the login is admin'
  lacks 'Fatal error' "$out" 'php fails: its error text is not in the result'
  eq 0 "$rc" 'php fails: exit status 0'
  contains '[nextcloud] WARNING:' "$(cat "$WORK/err")" 'php fails: a warning on stderr'
  # php exits 0 but prints something that isn't a login.
  fake_php "$WORK/bin-php-junk" junk
  eq admin "$(with_path "$WORK/bin-php-junk" nc_clean_admin_user 'John' 2>/dev/null)" 'php exits 0 with junk: the login is admin'
  fake_php "$WORK/bin-php-long" long
  eq admin "$(with_path "$WORK/bin-php-long" nc_clean_admin_user 'John' 2>/dev/null)" 'php exits 0 with 65 characters: the login is admin'
  fake_php "$WORK/bin-php-nothing" nothing
  eq admin "$(with_path "$WORK/bin-php-nothing" nc_clean_admin_user 'John' 2>/dev/null)" 'php exits 0 with nothing: the login is admin'
  # php prints a warning while it starts: the name must still come out right, so the warning has to go to stderr.
  fake_php "$WORK/bin-php-noisy" noisy
  eq Jose "$(with_path "$WORK/bin-php-noisy" nc_clean_admin_user 'José' 2>/dev/null)" 'php startup warning: the name is still cleaned'
  # php is not there at all.
  mkdir -p "$WORK/empty-path"
  out="$(with_only_path "$WORK/empty-path" nc_clean_admin_user 'José' 2>/dev/null)"
  eq admin "$out" 'no php on PATH: the login is admin'
  # php without the intl extension: ASCII names survive, and other letters become underscores.
  fake_php "$WORK/bin-php-nointl" nointl
  eq false "$(with_path "$WORK/bin-php-nointl" php -r 'echo class_exists("Transliterator") ? "true" : "false";')" 'sanity check: this php has no Transliterator'
  eq John_Smith "$(with_path "$WORK/bin-php-nointl" nc_clean_admin_user 'John_Smith' 2>/dev/null)" 'no intl: an ASCII name is kept'
  eq Jos_Garc_a "$(with_path "$WORK/bin-php-nointl" nc_clean_admin_user 'José_García' 2>/dev/null)" 'no intl: accented letters become underscores'
  # A name too big to pass to php (an environment variable holds at most 128 KiB) still gives a login.
  login_ok 'a name of 200000 characters' "$(nc_clean_admin_user "$(head -c 200000 /dev/zero | tr '\0' a)" 2>/dev/null)"
  login_ok 'a name of 100000 characters' "$(nc_clean_admin_user "$(head -c 100000 /dev/zero | tr '\0' a)" 2>/dev/null)"
}

# --- lib.sh: URLs --------------------------------------------------------------
section_lib_url() {
  load_lib || return 0

  echo ' nc_url_scheme'
  eq https             "$(nc_url_scheme 'https://ABC.clouve.app')"            'https'
  eq http              "$(nc_url_scheme 'http://t1.test.clv:8080')"           'http with a port'
  eq ""                "$(nc_url_scheme 'ftp://x')"                           'ftp is neither'
  eq https "$(nc_url_scheme 'HTTPS://x')"                                     'the scheme is case-insensitive and printed in lower case'
  eq http  "$(nc_url_scheme 'Http://x')"                                      'mixed case'
  eq '' "$(nc_url_scheme 'httpx://a')"                                        'httpx is not http'
  eq '' "$(nc_url_scheme 'http:/x')"                                          'one slash is not a scheme'
  eq '' "$(nc_url_scheme 'https')"                                            'a bare word'
  eq '' "$(nc_url_scheme 'abc.clouve.app')"                                   'a host with no scheme'
  eq '' "$(nc_url_scheme ' https://x')"                                       'a space in front'
  eq '' "$(nc_url_scheme '')"                                                 'empty'

  echo ' nc_url_host'
  eq abc.clouve.app    "$(nc_url_host 'https://ABC.clouve.app')"              'lower case'
  eq t1.test.clv       "$(nc_url_host 'http://t1.test.clv:8080/')"            'port and path go'
  eq cloud.example.com "$(nc_url_host 'https://user@cloud.example.com/path')" 'user name goes'
  eq abc.clouve.app "$(nc_url_host 'HTTPS://ABC.Clouve.App')"                 'upper case scheme'
  eq abc.clouve.app "$(nc_url_host 'https://abc.clouve.app:8443')"            'port with no path'
  eq abc.clouve.app "$(nc_url_host 'https://abc.clouve.app?x=1')"             'query with no path'
  eq abc.clouve.app "$(nc_url_host 'https://abc.clouve.app#top')"             'fragment with no path'
  eq cloud.example.com "$(nc_url_host 'https://user:p%40ss@cloud.example.com:8443/a/b?c=d#e')" 'user, password, port, path, query and fragment'
  eq cloud.example.com "$(nc_url_host 'https://user:p@ss@cloud.example.com/')" 'an @ in the password'
  eq host "$(nc_url_host 'https://host/a@b')"                                 'an @ in the path is not a user name'
  eq host "$(nc_url_host 'https://host?x=y@z')"                               'an @ in the query is not a user name'
  eq localhost "$(nc_url_host 'http://localhost')"                            'localhost'
  eq 127.0.0.1 "$(nc_url_host 'http://127.0.0.1:8080')"                       'an IPv4 address and port'
  eq '[::1]' "$(nc_url_host 'http://[::1]:8080/')"                            'IPv6 keeps its brackets, as a Host header has them'
  eq '[2001:db8::1]' "$(nc_url_host 'http://[2001:DB8::1]/x')"                'IPv6 in lower case, no port'
  eq '[2001:db8::1]' "$(nc_url_host 'http://me@[2001:db8::1]:80')"            'IPv6 with a user name and a port'
  eq x "$(nc_url_host 'ftp://x')"                                             'any scheme://, not only http'
  eq '' "$(nc_url_host '')"                                                   'empty'
  eq '' "$(nc_url_host 'abc.clouve.app')"                                     'no scheme://: no host'
  eq '' "$(nc_url_host '//abc.clouve.app')"                                   'no scheme: no host'
  eq '' "$(nc_url_host 'https://')"                                           'nothing after scheme://'
  eq '' "$(nc_url_host 'https:///path')"                                      'no host before the path'
  eq '' "$(nc_url_host 'https://:8080/')"                                     'only a port'
  eq 'a.example' "$(nc_url_host 'https://a.example:/')"                       'a colon with no port'
  eq '' "$(nc_url_host 'a.example:8080/x')"                                   'a host and port with no scheme'

  echo ' no output at all when there is no result'
  eq 0 "$(nc_url_scheme 'ftp://x' | wc -c)" 'nc_url_scheme prints nothing, not an empty line'
  eq 0 "$(nc_url_host 'https://' | wc -c)" 'nc_url_host prints nothing when the URL has no host, not an empty line'
  eq 0 "$(nc_url_host 'no scheme' | wc -c)" 'nc_url_host prints nothing when the URL has no scheme'

  echo ' the same under a UTF-8 locale'
  eq abc.clouve.app "$(LC_ALL=C.UTF-8 nc_url_host 'HTTPS://ABC.clouve.app:8443/x')" 'nc_url_host'
  eq https "$(LC_ALL=C.UTF-8 nc_url_scheme 'HTTPS://x')" 'nc_url_scheme'
}

# --- lib.sh: memory, Apache workers, preview concurrency -------------------------
# cg_tree V2 V1: makes a fresh cgroup tree under $WORK and points NC_CGROUP_ROOT at it. V2 is what memory.max
# holds and V1 what memory/memory.limit_in_bytes holds. "-" means the tree has no such file, and "@dir" makes
# it a folder, which can be opened but not read.
cg_tree() {
  local dir
  dir="$(mktemp -d "$WORK/cgroup.XXXXXX")" || return 1
  case "$1" in
    -) ;;
    @dir) mkdir "$dir/memory.max" ;;
    *) printf '%s\n' "$1" > "$dir/memory.max" ;;
  esac
  case "$2" in
    -) ;;
    @dir) mkdir -p "$dir/memory/memory.limit_in_bytes" ;;
    *) mkdir -p "$dir/memory"; printf '%s\n' "$2" > "$dir/memory/memory.limit_in_bytes" ;;
  esac
  export NC_CGROUP_ROOT="$dir"
}
cg2() { cg_tree "$1" -; }    # a cgroup v2 host: memory.max only
cg1() { cg_tree - "$1"; }    # a cgroup v1 host: memory/memory.limit_in_bytes only

# mem_case LABEL WANT V2 V1: on that tree nc_memory_limit_mb prints WANT (empty means no limit), prints nothing
# on stderr, and succeeds even under set -euo pipefail, which is how the entrypoint runs it.
mem_case() {
  local got rc
  got="$(set -euo pipefail; cg_tree "$3" "$4"; nc_memory_limit_mb 2>"$WORK/mem.err")"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "$1: exit status $rc under set -euo pipefail"
  elif [[ -s "$WORK/mem.err" ]]; then
    fail "$1: wrote to stderr: $(cat "$WORK/mem.err")"
  else
    eq "$2" "$got" "$1"
  fi
}

# size_case LABEL V2 V1 MB WORKERS PREVIEW: the chain the entrypoint runs, from a cgroup tree to the numbers.
size_case() {
  local mem workers preview
  mem="$(cg_tree "$2" "$3"; nc_memory_limit_mb)"
  workers="$(nc_apache_workers "$mem")"
  preview="$(nc_preview_concurrency "$mem")"
  eq "$4 MB, $5 workers, previews $6" "$mem MB, $workers workers, previews $preview" "$1"
}

# shellcheck disable=SC2016  # test data: shell and PHP syntax that has to stay text
section_lib_memory() {
  load_lib || return 0
  local mb w p n prev_w prev_n bad got rc junk marker="$WORK/injected"

  echo ' nc_memory_limit_mb, basic cases'
  eq 1024 "$(cg2 1073741824; nc_memory_limit_mb)"                'cgroup v2, 1 GiB'
  eq ""   "$(cg2 max; nc_memory_limit_mb)"                       'cgroup v2, max is no limit'
  eq 2048 "$(cg1 2147483648; nc_memory_limit_mb)"                'cgroup v1, 2 GiB'
  eq ""   "$(cg1 9223372036854771712; nc_memory_limit_mb)"       "cgroup v1, the kernel's no-limit number"

  echo ' nc_memory_limit_mb on made-up cgroup trees (same rows as the database wrapper test)'
  #        label                                       MB result         memory.max (v2)        memory.limit_in_bytes (v1)
  mem_case "v2, 64 MiB"                                64                 67108864               -
  mem_case "v2, 512 MiB"                               512                536870912              -
  mem_case "v2, 1 GiB"                                 1024               1073741824             -
  mem_case "v2, 2 GiB"                                 2048               2147483648             -
  mem_case "v2, 16 GiB"                                16384              17179869184            -
  mem_case "v2, 64 GiB"                                65536              68719476736            -
  mem_case "v2, 1000000000 bytes (rounds down)"        953                1000000000             -
  mem_case "v2, max (no limit)"                        ""                 max                    -
  mem_case "v1, 64 MiB"                                64                 -                      67108864
  mem_case "v1, 512 MiB"                               512                -                      536870912
  mem_case "v1, 1 GiB"                                 1024               -                      1073741824
  mem_case "v1, 2 GiB"                                 2048               -                      2147483648
  mem_case "v1, 16 GiB"                                16384              -                      17179869184
  mem_case "v1, 64 GiB"                                65536              -                      68719476736
  mem_case "v1, kernel's no limit (2^63 - 4096)"       ""                 -                      9223372036854771712
  mem_case "v1, 2^60 (no limit)"                       ""                 -                      1152921504606846976
  mem_case "v1, 2^60 - 1 (a limit)"                    1099511627775      -                      1152921504606846975
  mem_case "v1, 20 digits (no limit, no overflow)"     ""                 -                      18446744073709551615
  mem_case "v2 file present: v1 is not read"           ""                 max                    2147483648
  mem_case "v2 and v1 both set: v2 wins"               1024               1073741824             2147483648
  mem_case "neither file (no limit)"                   ""                 -                      -
  mem_case "v2 holds junk (no limit)"                  ""                 abc                    -
  mem_case "v2 empty (no limit)"                       ""                 ''                     -
  mem_case "v2 holds a negative number (no limit)"     ""                 -1                     -
  mem_case "v1 holds junk (no limit)"                  ""                 -                      abc

  echo ' nc_memory_limit_mb, more edges'
  mem_case "v2 junk: v1 is not read"                   ""                 abc                    2147483648
  mem_case "v1 holds a negative number (no limit)"     ""                 -                      -1
  mem_case "v1 empty (no limit)"                       ""                 -                      ''
  mem_case "v2, 2^63 (past the shell's integers)"      ""                 9223372036854775808    -
  mem_case "v2, 23 digits (past the shell's integers)" ""                 99999999999999999999999 -
  mem_case "v2, a leading zero is still decimal"       1024               01073741824            -
  mem_case "v2, a plus sign is not a number"           ""                 +1073741824            -
  mem_case "v2, a decimal point is not a number"       ""                 1.5                    -
  mem_case "v2, two numbers on one line"               ""                 '1024 2048'            -
  mem_case "v2, 0 bytes"                               0                  0                      -
  mem_case "v2, half a MiB (rounds down to 0)"         0                  524288                 -
  mem_case "memory.max is a folder (cannot be read)"   ""                 @dir                   -
  mem_case "memory.limit_in_bytes is a folder"         ""                 -                      @dir
  # Nothing set NC_CGROUP_ROOT here, so the function reads the container's own /sys/fs/cgroup: a number or nothing.
  got="$(unset NC_CGROUP_ROOT; set -euo pipefail; nc_memory_limit_mb 2>&1)"
  rc=$?
  eq 0 "$rc" 'default root /sys/fs/cgroup: exit status 0'
  matches '^[0-9]*$' "$got" 'default root /sys/fs/cgroup: a number of MB or nothing'

  echo ' nc_apache_workers'
  eq 150 "$(nc_apache_workers '')"      'no limit: 150';  eq 10 "$(nc_apache_workers 256)"    '256 MB: 10'
  eq 20  "$(nc_apache_workers 1024)"    '1024 MB: 20';    eq 40 "$(nc_apache_workers 2048)"   '2048 MB: 40'
  eq 150 "$(nc_apache_workers 16384)"   '16384 MB: 150'
  eq 10  "$(nc_apache_workers 0)"       '0 MB: the floor'
  eq 10  "$(nc_apache_workers 499)"     '499 MB: 9 raised to the floor'
  eq 10  "$(nc_apache_workers 549)"     '549 MB: 10'
  eq 11  "$(nc_apache_workers 550)"     '550 MB: 11'
  eq 149 "$(nc_apache_workers 7499)"    '7499 MB: 149'
  eq 150 "$(nc_apache_workers 7500)"    '7500 MB: 150'
  eq 150 "$(nc_apache_workers 7550)"    '7550 MB: 151 cut to the ceiling'
  eq 150 "$(nc_apache_workers 999999999999999)" '15 digits: the ceiling'
  eq 10  "$(nc_apache_workers 0256)"    'a leading zero is decimal, not octal'
  eq 20  "$(nc_apache_workers 000001024)" 'leading zeros'
  rm -f "$marker"
  for junk in abc -5 1.5 ' 100' 1e3 0x10 99999999999999999999 18446744073709551615 9223372036854775808 '1 2' '$(id)' "a[\$(touch $marker)]"; do
    eq 150 "$(nc_apache_workers "$junk" 2>/dev/null)" "not a number of MB (${junk//$marker/MARKER}): the no-limit default"
  done
  contains '[nextcloud] WARNING:' "$(nc_apache_workers abc 2>&1 >/dev/null)" 'not a number: a warning on stderr'
  eq '' "$(nc_apache_workers '' 2>&1 >/dev/null)" 'no limit is not a mistake: no warning'

  echo ' nc_preview_concurrency'
  eq "4 8" "$(nc_preview_concurrency '')"      'no limit: 4 8'; eq "1 2" "$(nc_preview_concurrency 1024)" '1024 MB: 1 2'
  eq "2 4" "$(nc_preview_concurrency 2048)"    '2048 MB: 2 4';  eq "2 4" "$(nc_preview_concurrency 3072)" '3072 MB: 2 4'
  eq "4 8" "$(nc_preview_concurrency 4096)"    '4096 MB: 4 8'
  eq "1 2" "$(nc_preview_concurrency 0)"       '0 MB: 1 2'
  eq "1 2" "$(nc_preview_concurrency 512)"     '512 MB: 1 2'
  eq "1 2" "$(nc_preview_concurrency 1535)"    '1535 MB: still 1 2'
  eq "2 4" "$(nc_preview_concurrency 1536)"    '1536 MB: 2 4'
  eq "2 4" "$(nc_preview_concurrency 3583)"    '3583 MB: still 2 4'
  eq "4 8" "$(nc_preview_concurrency 3584)"    '3584 MB: 4 8'
  eq "4 8" "$(nc_preview_concurrency 16384)"   '16384 MB: 4 8'
  eq "4 8" "$(nc_preview_concurrency 999999999999999)" '15 digits: 4 8'
  eq "1 2" "$(nc_preview_concurrency 0512)"    'a leading zero is decimal, not octal'
  for junk in abc -5 1.5 ' 100' 1e3 0x10 99999999999999999999 18446744073709551615 9223372036854775808 '1 2' '$(id)' "a[\$(touch $marker)]"; do
    eq "4 8" "$(nc_preview_concurrency "$junk" 2>/dev/null)" "not a number of MB (${junk//$marker/MARKER}): the no-limit default"
  done
  if [[ -e "$marker" ]]; then fail 'a size is never run as shell code'; else pass 'a size is never run as shell code'; fi
  contains '[nextcloud] WARNING:' "$(nc_preview_concurrency abc 2>&1 >/dev/null)" 'not a number: a warning on stderr'
  eq '' "$(nc_preview_concurrency '' 2>&1 >/dev/null)" 'no limit is not a mistake: no warning'

  echo ' from a cgroup tree to the numbers the entrypoint uses'
  #        label                        memory.max     memory.limit_in_bytes     MB     workers  previews
  size_case "no limit (v2 max)"         max            -                         ""     150      "4 8"
  size_case "neither file"              -              -                         ""     150      "4 8"
  size_case "64 MiB"                    67108864       -                         64     10       "1 2"
  size_case "512 MiB"                   536870912      -                         512    10       "1 2"
  size_case "1 GiB"                     1073741824     -                         1024   20       "1 2"
  size_case "1.5 GiB"                   1610612736     -                         1536   30       "2 4"
  size_case "2 GiB"                     2147483648     -                         2048   40       "2 4"
  size_case "3 GiB"                     3221225472     -                         3072   61       "2 4"
  size_case "4 GiB"                     4294967296     -                         4096   81       "4 8"
  size_case "16 GiB"                    17179869184    -                         16384  150      "4 8"
  size_case "cgroup v1, 512 MiB"        -              536870912                 512    10       "1 2"
  size_case "cgroup v1, 2 GiB"          -              2147483648                2048   40       "2 4"
  size_case "cgroup v1, 16 GiB"         -              17179869184               16384  150      "4 8"
  size_case "cgroup v1, no limit"       -              9223372036854771712       ""     150      "4 8"

  echo ' every size stays inside its bounds, and a bigger limit never gives less'
  bad='' prev_w=0 prev_n=0
  for ((mb = 0; mb <= 20000; mb += 53)); do
    w="$(nc_apache_workers "$mb")"
    p="$(nc_preview_concurrency "$mb")"
    case "$p" in '1 2') n=1 ;; '2 4') n=2 ;; '4 8') n=4 ;; *) n=0; bad="${bad:-$mb MB gives previews [$p]}" ;; esac
    if [[ ! "$w" =~ ^[0-9]+$ ]] || [[ "$w" -lt 10 || "$w" -gt 150 ]]; then bad="${bad:-$mb MB gives $w workers}"; fi
    if [[ "$w" =~ ^[0-9]+$ && "$w" -lt "$prev_w" ]]; then bad="${bad:-$mb MB gives fewer workers than the size before}"; fi
    if [[ "$n" -lt "$prev_n" ]]; then bad="${bad:-$mb MB gives fewer previews than the size before}"; fi
    prev_w="$w" prev_n="$n"
  done
  eq '' "$bad" 'workers are 10 to 150, previews are 1 2, 2 4 or 4 8, and neither falls as the limit grows (0 to 20000 MB)'
}

# --- lib.sh: trusted_domains ---------------------------------------------------
# shellcheck disable=SC2016  # test data: shell and PHP syntax that has to stay text
section_lib_trusted_domains() {
  load_lib || return 0
  local marker="$WORK/injected" out rc json got

  echo ' basic cases'
  eq "abc.clouve.app" "$(nc_missing_trusted_domains '["localhost","localhost"]' localhost abc.clouve.app)" 'a JSON array: only the new host is missing'
  eq ""               "$(nc_missing_trusted_domains '{"0":"localhost","3":"ABC.clouve.app"}' localhost abc.clouve.app)" 'a JSON object with gaps, host in another case: nothing missing'
  eq $'localhost\nx.example' "$(nc_missing_trusted_domains '' localhost x.example)" 'empty input: every host, one per line'

  echo ' what counts as the list'
  eq $'localhost\nx.example' "$(nc_missing_trusted_domains '[]' localhost x.example)"   'an empty array'
  eq $'localhost\nx.example' "$(nc_missing_trusted_domains '{}' localhost x.example)"   'an empty object'
  eq $'localhost\nx.example' "$(nc_missing_trusted_domains 'null' localhost x.example)" 'null'
  eq $'localhost\nx.example' "$(nc_missing_trusted_domains $' \n ' localhost x.example)" 'only white space'
  eq ''                      "$(nc_missing_trusted_domains '"localhost"' localhost)"    'a single string counts as one entry'
  eq $'x.example\n5'         "$(nc_missing_trusted_domains '["localhost", 5, null, true, ["x.example"], {"a":"x.example"}]' localhost x.example 5)" 'entries that are not strings (5, null, true, an array, an object) are ignored'
  eq ''                      "$(nc_missing_trusted_domains '["LOCALHOST","X.Example"]' localhost x.example)" 'upper case in the list'
  eq ''                      "$(nc_missing_trusted_domains '["localhost","x.example"]' LocalHost X.EXAMPLE)" 'upper case in the hosts'
  eq 'X.EXAMPLE'             "$(nc_missing_trusted_domains '["localhost"]' LocalHost X.EXAMPLE)" 'a missing host is printed as it was given'
  eq 'x.example:8080'        "$(nc_missing_trusted_domains '["x.example"]' x.example x.example:8080)" 'a host with a port is a different entry'

  echo ' the hosts'
  eq ''          "$(nc_missing_trusted_domains '["localhost"]')"                         'no hosts: nothing missing'
  eq 'localhost' "$(nc_missing_trusted_domains '[]' localhost localhost)"                'a host given twice is printed once'
  eq 'Localhost' "$(nc_missing_trusted_domains '[]' Localhost localhost LOCALHOST)"      'twice in other cases: the first spelling, once'
  eq 'localhost' "$(nc_missing_trusted_domains '[]' '' localhost '')"                    'empty hosts are skipped'
  eq ''          "$(nc_missing_trusted_domains '[]' '' '')"                              'only empty hosts: nothing'
  eq $'--version\n-h\na b\n$HOME\n*.x' "$(nc_missing_trusted_domains '[]' --version -h 'a b' '$HOME' '*.x')" 'odd hosts are printed as they are (not read as php options or shell syntax)'

  echo ' JSON that cannot be read'
  for json in 'oops' '[' '["a",]' "{'a':'b'}" 'Warning: something' '["a"] trailing'; do
    got="$(nc_missing_trusted_domains "$json" localhost 2>"$WORK/err")"
    rc=$?
    eq "1|" "$rc|$got" "invalid JSON ($json): status 1 and no output"
    contains '[nextcloud] WARNING:' "$(cat "$WORK/err")" "invalid JSON ($json): a warning on stderr"
  done

  echo ' php trouble and injection'
  fake_php "$WORK/bin-php-fails" fails
  out="$(with_path "$WORK/bin-php-fails" nc_missing_trusted_domains '["a"]' localhost 2>"$WORK/err")"
  rc=$?
  eq "1|" "$rc|$out" 'php fails: status 1 and no output'
  contains '[nextcloud] WARNING:' "$(cat "$WORK/err")" 'php fails: a warning on stderr'
  # A php startup warning must not become a host to trust.
  fake_php "$WORK/bin-php-noisy" noisy
  eq b "$(with_path "$WORK/bin-php-noisy" nc_missing_trusted_domains '["a"]' a b 2>/dev/null)" 'php startup warning: only the missing host is printed'
  rm -f "$marker"
  nc_missing_trusted_domains "[\"x');file_put_contents('$marker','1');//\"]" "y');file_put_contents('$marker','1');//" >/dev/null
  if [[ -e "$marker" ]]; then fail 'the list and the hosts are never run as PHP code'; else pass 'the list and the hosts are never run as PHP code'; fi
}

# --- lib.sh: running occ ------------------------------------------------------------
# fake_php_args DIR: writes DIR/php, a php that appends its arguments to $LOG, each followed by "|" (so that the borders of
# the arguments show), and then does what the environment says. FAKE_PHP_OUT is printed on stdout and FAKE_PHP_ERR on stderr.
# It exits with FAKE_PHP_RC when its arguments hold FAKE_PHP_FAIL_ON (every call, when that is empty or unset), and with 0
# otherwise.
fake_php_args() {
  fake_cmd "$1" php <<'EOF'
printf '%s|' "$@" >> "$LOG"
echo >> "$LOG"
if [ -n "${FAKE_PHP_OUT-}" ]; then printf '%s\n' "$FAKE_PHP_OUT"; fi
if [ -n "${FAKE_PHP_ERR-}" ]; then printf '%s\n' "$FAKE_PHP_ERR" >&2; fi
case " $* " in
  *"${FAKE_PHP_FAIL_ON-}"*) exit "${FAKE_PHP_RC:-0}" ;;
esac
exit 0
EOF
}

# shellcheck disable=SC2016  # test data: shell syntax in an argument has to stay text
section_lib_occ() {
  load_lib || return 0
  local bin="$WORK/bin-php-args" out rc
  export LOG="$WORK/lib-occ.log"
  unset OCC
  fake_php_args "$bin"
  # warn_for ARGS...: what nc_try_occ ARGS... warns when occ fails with status 3 (its stderr only, and not occ's own)
  # shellcheck disable=SC2069  # stderr goes to the pipe and stdout to /dev/null, on purpose
  warn_for() { FAKE_PHP_RC=3 with_path "$bin" nc_try_occ "$@" 2>&1 >/dev/null; }

  echo ' nc_occ'
  : > "$LOG"; with_path "$bin" nc_occ status --output=json
  eq '/var/www/html/occ|status|--output=json|' "$(cat "$LOG")" 'with no OCC it runs php /var/www/html/occ with the arguments given'
  : > "$LOG"; OCC='' with_path "$bin" nc_occ x
  eq '/var/www/html/occ|x|' "$(cat "$LOG")" 'an empty OCC is no OCC'
  : > "$LOG"; OCC='php -n -d display_errors=stderr /x/occ.php' with_path "$bin" nc_occ config:system:get trusted_domains
  eq '-n|-d|display_errors=stderr|/x/occ.php|config:system:get|trusted_domains|' "$(cat "$LOG")" 'OCC is the command and its first arguments, split at white space'
  : > "$LOG"; OCC=$'php\t-n\t/x/occ.php' with_path "$bin" nc_occ x
  eq '-n|/x/occ.php|x|' "$(cat "$LOG")" 'tabs split it too'
  : > "$LOG"; with_path "$bin" nc_occ config:system:set k --value='a  b' '' '*' '$HOME'
  eq '/var/www/html/occ|config:system:set|k|--value=a  b||*|$HOME|' "$(cat "$LOG")" 'every argument arrives whole: spaces, an empty one, a glob and a $ stay text'
  : > "$LOG"; ( IFS=:; OCC='php /y/occ' with_path "$bin" nc_occ a b )
  eq '/y/occ|a|b|' "$(cat "$LOG")" 'the caller changing IFS changes nothing'
  : > "$LOG"; ( set -u; unset OCC; with_path "$bin" nc_occ x )
  eq '/var/www/html/occ|x|' "$(cat "$LOG")" 'it works under set -u with OCC unset'
  out="$(FAKE_PHP_RC=7 FAKE_PHP_OUT=printed FAKE_PHP_ERR=complained with_path "$bin" nc_occ x 2>"$WORK/err")"
  rc=$?
  eq '7|printed|complained' "$rc|$out|$(cat "$WORK/err")" "occ's exit status, stdout and stderr come back as they are"

  echo ' nc_try_occ'
  out="$(FAKE_PHP_OUT=printed FAKE_PHP_ERR=complained with_path "$bin" nc_try_occ background:cron 2>"$WORK/err")"
  rc=$?
  eq '0|printed|complained' "$rc|$out|$(cat "$WORK/err")" "occ succeeds: its output and errors come through, there is no warning, and the status is 0"
  out="$(FAKE_PHP_RC=5 FAKE_PHP_OUT=printed FAKE_PHP_ERR=complained with_path "$bin" nc_try_occ app:install contacts 2>"$WORK/err")"
  rc=$?
  eq 0 "$rc" 'occ fails: the status is 0 all the same'
  eq printed "$out" 'occ fails: its stdout is still printed'
  eq $'complained\n[nextcloud] WARNING: occ app:install contacts failed (exit status 5)' "$(cat "$WORK/err")" 'occ fails: its errors come through, then one warning that names the command and its first argument'
  eq '[nextcloud] WARNING: occ maintenance:repair failed (exit status 3)' "$(warn_for maintenance:repair --include-expensive)" 'an option is not part of the name'
  eq '[nextcloud] WARNING: occ config:system:set trashbin_retention_obligation failed (exit status 3)' "$(warn_for config:system:set trashbin_retention_obligation --value='auto, 30')" 'a setting is named by its key, never by its value'
  eq "[nextcloud] WARNING: occ user:setting O'Brien Smith failed (exit status 3)" "$(warn_for user:setting "O'Brien Smith" settings email owner@example.com)" 'a user is named by the login and nothing after it (not the email)'
  eq '[nextcloud] WARNING: occ background:cron failed (exit status 3)' "$(warn_for background:cron)" 'a command with no argument'
  lacks hunter2 "$(warn_for config:system:set dbpassword --value=hunter2)" 'a value never reaches the warning'
  eq 'after' "$( set -e; FAKE_PHP_RC=1 with_path "$bin" nc_try_occ x 2>/dev/null; echo after )" 'a failure does not stop a caller that runs under set -e'
  out="$(FAKE_PHP_RC=1 with_path "$bin" nc_try_occ 2>&1)"
  rc=$?
  eq 0 "$rc" 'no arguments: status 0'
  contains 'WARNING' "$out" 'no arguments: and a warning, since occ failed'
  # nc_post_upgrade_steps reads occ's answers, so it is tested against the fake occ, in "lib.sh: the post-upgrade steps".
}

# --- lib.sh: nc_first_lines, nc_sweep_leftovers ------------------------------------------
# shellcheck disable=SC2016  # test data: shell syntax in the text has to stay text
section_lib_text_and_sweep() {
  load_lib || return 0
  local tmp="$WORK/sweep/tmp" conf="$WORK/sweep/conf" long1 long2
  long1="$(printf 'a%.0s' {1..400})"
  long2="$(printf 'b%.0s' {1..400})"

  echo ' nc_first_lines'
  eq 'one' "$(nc_first_lines 'one')" 'one line'
  eq 'one / two' "$(nc_first_lines $'one\ntwo\nthree')" 'the first two of three lines, joined by " / "'
  eq 'x / y' "$(nc_first_lines $'\n\n  \t\nx\n\n   \ny\nz')" 'blank lines and lines of only white space are skipped'
  eq '  indented / b' "$(nc_first_lines $'  indented\nb')" 'white space inside a line is kept'
  eq '' "$(nc_first_lines '')" 'empty text: nothing'
  eq 0 "$(nc_first_lines '' | wc -c)" 'empty text: not even a newline'
  eq 0 "$(nc_first_lines $'\n  \n' | wc -c)" 'only blank lines: nothing'
  eq 'a' "$(nc_first_lines $'\n\na')" 'one line after blank ones'
  eq 'a / b' "$(nc_first_lines $'a\r\nb' | tr -d '\r')" 'a line ending with a carriage return is a line'
  eq "$(printf 'a%.0s' {1..300}) / $(printf 'b%.0s' {1..300})" "$(nc_first_lines "$long1"$'\n'"$long2")" 'each line is cut to 300 characters'
  eq '%s %d \n $HOME `id` $(id) / --version -n' "$(nc_first_lines $'%s %d \\n $HOME `id` $(id)\n--version -n')" 'what is in the text stays text'
  eq 'a b / c' "$(IFS=,; nc_first_lines $'a b\nc')" 'the caller changing IFS changes nothing'
  eq 1 "$(nc_first_lines $'a\nb\nc' | wc -l)" 'the result is one line'
  eq '' "$( set -u; nc_first_lines )" 'no argument: nothing, and no complaint under set -u'

  echo ' nc_sweep_leftovers'
  # What an interrupted run leaves: a private file of the database settings ($NC_TMP_DIR/db.XXXXXX, which mktemp makes) and a
  # half-written copy of config.php (.config.php.<12 hex digits>, next to it). Names that only look a little like them stay.
  rm -rf "$WORK/sweep"
  mkdir -p "$tmp" "$conf"
  : > "$conf/config.php"
  : > "$tmp/db.AbC123"; : > "$tmp/db.9xYz0q"
  : > "$tmp/db.toolong"; : > "$tmp/db.abc"; : > "$tmp/xdb.AbC123"; : > "$tmp/keep.txt"; mkdir "$tmp/db.dirDIR"; ln -s keep.txt "$tmp/db.linkLK"
  : > "$conf/.config.php.0123456789ab"; : > "$conf/.config.php.ffffffffffff"
  : > "$conf/.config.php.bak"; : > "$conf/.config.php.0123456789abc"; : > "$conf/.config.php.012345678"; : > "$conf/config.php.bak"; : > "$conf/.other.0123456789ab"
  : > "$conf/.config.php.0123456789zz"; : > "$conf/.config.php.0123456789AB"
  eq '' "$(NC_TMP_DIR="$tmp" nc_sweep_leftovers "$conf/config.php" 2>&1)" 'it prints nothing'
  eq 'db.abc db.dirDIR db.linkLK db.toolong keep.txt xdb.AbC123' "$(find "$tmp" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" 'the private files are gone, and only those'
  eq '.config.php.012345678 .config.php.0123456789AB .config.php.0123456789abc .config.php.0123456789zz .config.php.bak .other.0123456789ab config.php config.php.bak' "$(find "$conf" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" 'the half-written copies of config.php are gone, and only those'
  NC_TMP_DIR="$tmp" nc_sweep_leftovers "$conf/config.php"
  eq 0 "$?" 'a second run: status 0'
  eq 0 "$(NC_TMP_DIR="$WORK/sweep/none" nc_sweep_leftovers "$WORK/sweep/none/config.php" 2>&1 | wc -c)" 'folders that do not exist: no output'
  : > "$conf/.config.php.0123456789ab"
  NC_TMP_DIR="$tmp" NC_CONFIG_FILE="$conf/config.php" nc_sweep_leftovers
  eq no "$([[ -e "$conf/.config.php.0123456789ab" ]] && echo yes || echo no)" 'with no argument it looks next to NC_CONFIG_FILE'
  : > "$conf/.config.php.0123456789ab"
  NC_TMP_DIR="$tmp" NC_CONFIG_FILE=/nonexistent/config.php nc_sweep_leftovers "$conf/config.php"
  eq no "$([[ -e "$conf/.config.php.0123456789ab" ]] && echo yes || echo no)" 'the argument beats NC_CONFIG_FILE'
  # The defaults: /run/clouve/tmp and /var/www/html/config/config.php.
  mkdir -p /run/clouve/tmp /var/www/html/config
  : > /run/clouve/tmp/db.AbC123
  : > /var/www/html/config/.config.php.0123456789ab
  (unset NC_TMP_DIR NC_CONFIG_FILE; nc_sweep_leftovers)
  eq 'no no' "$([[ -e /run/clouve/tmp/db.AbC123 ]] && echo yes || echo no) $([[ -e /var/www/html/config/.config.php.0123456789ab ]] && echo yes || echo no)" 'the defaults are /run/clouve/tmp and /var/www/html/config'
  rm -rf /run/clouve /var/www/html/config
}

# --- lib.sh: nc_repair_db_config -----------------------------------------------------------
# The repair edits config.php without occ, because occ cannot start while config.php names a database it cannot reach. The
# root entrypoint calls it as root, before the official entrypoint starts, and nextcloud-config.sh calls it as www-data. Both
# have to leave config.php with its owner and mode.
# shellcheck disable=SC2016  # test data: PHP code and shell syntax have to stay text
section_lib_repair() {
  load_lib || return 0
  local f rc wd weird same var key
  local stale='{"instanceid":"oc1234abcd","passwordsalt":"salty","secret":"keep-me","version":"35.0.2.2","installed":true,"dbtype":"mysql","dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"old-pass","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"nested":{"a":[1,2,{"b":true}],"c":null,"d":1.5}}'
  nc_world "$WORK/w-lib-repair"
  f="$NCW_CONF"
  # The four settings as plain shell variables, not exported: the function has to pass them on itself.
  # shellcheck disable=SC2034  # nc_repair_db_config reads these
  NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb NEXTCLOUD_DB_NAME=nextcloud NEXTCLOUD_DB_USER=nextcloud NEXTCLOUD_DB_PASSWORD=s3cret
  # repair ARGS...: runs nc_repair_db_config; leaves RP_RC, RP_OUT and RP_ERR.
  repair() {
    nc_repair_db_config "$@" >"$WORK/rp.out" 2>"$WORK/rp.err"
    RP_RC=$?
    RP_OUT="$(cat "$WORK/rp.out")"
    RP_ERR="$(cat "$WORK/rp.err")"
  }
  # other_keys FILE: every key except the two the repair changes, as JSON
  other_keys() { php -n -r '$CONFIG = []; include $argv[1]; unset($CONFIG["dbhost"], $CONFIG["dbpassword"]); echo json_encode($CONFIG);' -- "$1"; }

  echo ' as root (the root entrypoint): config.php is www-data'"'"'s'
  cfg_reset "$stale"
  chown www-data:www-data "$f"
  chmod 640 "$f"
  same="$(other_keys "$f")"
  repair "$f"
  eq 0 "$RP_RC" 'status 0: it changed config.php'
  eq '[nextcloud] database settings in config.php updated to match the environment' "$RP_OUT" 'stdout says so, once, and names no value'
  eq '' "$RP_ERR" 'nothing on stderr'
  eq '"tkt-9-nextcloud-mariadb"' "$(cfg_get dbhost)" 'dbhost is the environment'"'"'s'
  eq '"s3cret"' "$(cfg_get dbpassword)" 'dbpassword is the environment'"'"'s'
  eq "$same" "$(other_keys "$f")" 'every other key is exactly as it was, nested values and types too'
  eq 'www-data:www-data 640' "$(stat -c '%U:%G %a' "$f")" 'root leaves config.php with its owner and mode'
  eq 'config.php' "$(ls -A "$NCW/conf")" 'no temporary file is left'
  no_secret_in "$RP_OUT$RP_ERR" 'neither password appears in anything it printed' s3cret old-pass
  same="$(md5sum < "$f")"
  repair "$f"
  eq '1||' "$RP_RC|$RP_OUT|$RP_ERR" 'a second call: status 1 (nothing to change) and no output'
  eq "$same" "$(md5sum < "$f")" 'a second call: config.php is byte for byte the same'

  echo ' as root: config.php belongs to someone else, with another mode'
  cfg_reset "$stale"
  chown nobody:nogroup "$f"
  chmod 600 "$f"
  repair "$f"
  eq 0 "$RP_RC" 'status 0'
  eq 'nobody:nogroup 600' "$(stat -c '%U:%G %a' "$f")" 'owner and mode are kept'
  eq 'config.php' "$(ls -A "$NCW/conf")" 'no temporary file is left'

  echo ' as www-data (nextcloud-config.sh): the folder and config.php are www-data'"'"'s'
  wd="$(mktemp -d /tmp/nc-wd.XXXXXX)"
  chown www-data:www-data "$wd"
  chmod 755 "$wd"
  cfg_reset "$stale"
  cp "$f" "$wd/config.php"
  chown www-data:www-data "$wd/config.php"
  chmod 640 "$wd/config.php"
  rc="$(runuser -u www-data -- env NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb NEXTCLOUD_DB_NAME=nextcloud NEXTCLOUD_DB_USER=nextcloud NEXTCLOUD_DB_PASSWORD=s3cret \
        bash -c '. "$1"; nc_repair_db_config "$2"; echo "rc=$?"' _ "$LIB" "$wd/config.php" 2>"$WORK/rp.err")"
  eq $'[nextcloud] database settings in config.php updated to match the environment\nrc=0' "$rc" 'status 0, and the same line on stdout'
  eq '' "$(cat "$WORK/rp.err")" 'nothing on stderr'
  eq 'www-data:www-data 640' "$(stat -c '%U:%G %a' "$wd/config.php")" 'owner and mode are kept'
  eq 'config.php' "$(ls -A "$wd")" 'no temporary file is left'
  eq '"tkt-9-nextcloud-mariadb" "s3cret"' "$(php -n -r '$CONFIG = []; include $argv[1]; echo json_encode($CONFIG["dbhost"]), " ", json_encode($CONFIG["dbpassword"]);' -- "$wd/config.php")" 'dbhost and dbpassword are the environment'"'"'s'

  echo ' the new file is made next to config.php, whatever the temporary folder is (a rename stays on one filesystem)'
  cfg_reset "$stale"
  cp "$f" "$wd/config.php"
  chown www-data:www-data "$wd/config.php"
  chmod 640 "$wd/config.php"
  rc="$(runuser -u www-data -- env TMPDIR=/nonexistent NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb NEXTCLOUD_DB_NAME=nextcloud NEXTCLOUD_DB_USER=nextcloud NEXTCLOUD_DB_PASSWORD=s3cret \
        bash -c '. "$1"; nc_repair_db_config "$2"; echo "rc=$?"' _ "$LIB" "$wd/config.php" 2>"$WORK/rp.err")"
  eq $'[nextcloud] database settings in config.php updated to match the environment\nrc=0' "$rc" 'TMPDIR=/nonexistent: status 0 all the same'
  eq 'config.php' "$(ls -A "$wd")" 'TMPDIR=/nonexistent: no temporary file is left'

  echo ' as www-data: config.php is someone else'"'"'s in a sticky folder, so the rename is refused'
  chown root:root "$wd"
  chmod 1777 "$wd"
  cfg_reset "$stale"
  cp "$f" "$wd/config.php"
  chown root:root "$wd/config.php"
  chmod 644 "$wd/config.php"
  same="$(md5sum < "$wd/config.php")"
  rc="$(runuser -u www-data -- env NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb NEXTCLOUD_DB_NAME=nextcloud NEXTCLOUD_DB_USER=nextcloud NEXTCLOUD_DB_PASSWORD=s3cret \
        bash -c '. "$1"; nc_repair_db_config "$2"; echo "rc=$?"' _ "$LIB" "$wd/config.php" 2>"$WORK/rp.err")"
  eq 'rc=2' "$rc" 'status 2: it could not'
  eq "[nextcloud] WARNING: could not check the database settings in config.php: cannot replace $wd/config.php" "$(cat "$WORK/rp.err")" 'the warning is the function'"'"'s own, with no PHP message in it'
  eq "$same" "$(md5sum < "$wd/config.php")" 'config.php is untouched'
  eq 'config.php' "$(ls -A "$wd")" 'and the temporary file is gone'
  chmod 755 "$wd"

  echo ' as www-data: a folder that www-data cannot write to'
  chown root:root "$wd"
  cfg_reset "$stale"
  cp "$f" "$wd/config.php"
  chown www-data:www-data "$wd/config.php"
  chmod 640 "$wd/config.php"
  same="$(md5sum < "$wd/config.php")"
  rc="$(runuser -u www-data -- env NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb NEXTCLOUD_DB_NAME=nextcloud NEXTCLOUD_DB_USER=nextcloud NEXTCLOUD_DB_PASSWORD=s3cret \
        bash -c '. "$1"; nc_repair_db_config "$2"; echo "rc=$?"' _ "$LIB" "$wd/config.php" 2>"$WORK/rp.err")"
  eq 'rc=2' "$rc" 'status 2: it could not'
  contains "cannot write next to $wd/config.php" "$(cat "$WORK/rp.err")" 'the warning says where it could not write'
  eq "$same" "$(md5sum < "$wd/config.php")" 'config.php is untouched'
  eq 'config.php' "$(ls -A "$wd")" 'and nothing was left next to it'
  chmod 600 "$wd/config.php"
  chown root:root "$wd/config.php"
  rc="$(runuser -u www-data -- env NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb NEXTCLOUD_DB_NAME=nextcloud NEXTCLOUD_DB_USER=nextcloud NEXTCLOUD_DB_PASSWORD=s3cret \
        bash -c '. "$1"; nc_repair_db_config "$2"; echo "rc=$?"' _ "$LIB" "$wd/config.php" 2>"$WORK/rp.err")"
  eq 'rc=2' "$rc" 'a config.php that www-data cannot read: status 2'
  contains "cannot read $wd/config.php" "$(cat "$WORK/rp.err")" 'and the warning says so'
  rm -rf "$wd"

  echo ' the four variables'
  cfg_reset "$stale"
  same="$(md5sum < "$f")"
  for var in NEXTCLOUD_DB_HOST NEXTCLOUD_DB_NAME NEXTCLOUD_DB_USER NEXTCLOUD_DB_PASSWORD; do
    ( unset "$var"; nc_repair_db_config "$f" >"$WORK/rp.out" 2>"$WORK/rp.err"; echo $? > "$WORK/rp.rc" )
    eq 2 "$(cat "$WORK/rp.rc")" "$var unset: status 2"
    contains "$var is not set" "$(cat "$WORK/rp.err")" "$var unset: the warning names it"
    eq '' "$(cat "$WORK/rp.out")" "$var unset: nothing on stdout"
    ( printf -v "$var" ''; nc_repair_db_config "$f" >"$WORK/rp.out" 2>"$WORK/rp.err"; echo $? > "$WORK/rp.rc" )
    eq 2 "$(cat "$WORK/rp.rc")" "$var empty: status 2"
    eq "$same" "$(md5sum < "$f")" "$var missing: config.php is untouched, so no empty value is written"
  done
  for key in dbhost dbname dbuser dbpassword; do
    cfg_reset "$(php -n -r '$c = json_decode($argv[1], true); $c["dbhost"] = "tkt-9-nextcloud-mariadb"; $c["dbname"] = "nextcloud"; $c["dbuser"] = "nextcloud"; $c["dbpassword"] = "s3cret"; $c[$argv[2]] = "different"; echo json_encode($c);' -- "$stale" "$key")"
    repair "$f"
    eq 0 "$RP_RC" "only $key differs: status 0"
    eq "$(php -n -r 'echo json_encode(["dbhost" => "tkt-9-nextcloud-mariadb", "dbname" => "nextcloud", "dbuser" => "nextcloud", "dbpassword" => "s3cret"][$argv[1]]);' -- "$key")" "$(cfg_get "$key")" "only $key differs: it is the environment's again"
  done

  echo ' values that look like numbers are still text'
  cfg_reset "$(php -n -r '$c = json_decode($argv[1], true); $c["dbhost"] = "tkt-9-nextcloud-mariadb"; $c["dbname"] = "nextcloud"; $c["dbuser"] = "nextcloud"; $c["dbpassword"] = "1e3"; echo json_encode($c);' -- "$stale")"
  # shellcheck disable=SC2034  # nc_repair_db_config reads it
  NEXTCLOUD_DB_PASSWORD=1000
  repair "$f"
  eq 0 "$RP_RC" '1e3 in config.php and 1000 in the environment differ: status 0'
  eq '"1000"' "$(cfg_get dbpassword)" '1e3 in config.php and 1000 in the environment differ: it is 1000 now'
  # shellcheck disable=SC2034  # nc_repair_db_config reads it
  NEXTCLOUD_DB_PASSWORD=s3cret

  echo ' what the file holds'
  cfg_reset "$stale"
  weird='p"a\ss/w$ord'"'"'é<>& `x` $(y) %s'
  # shellcheck disable=SC2034  # nc_repair_db_config reads it
  NEXTCLOUD_DB_PASSWORD="$weird"
  repair "$f"
  eq 0 "$RP_RC" 'a password full of characters that quoting gets wrong: status 0'
  eq "$weird" "$(php -n -r '$CONFIG = []; include $argv[1]; echo $CONFIG["dbpassword"];' -- "$f")" 'config.php hands back exactly that password when PHP includes it'
  no_secret_in "$RP_OUT$RP_ERR" 'and it appears in nothing the function printed' "$weird"
  # shellcheck disable=SC2034  # nc_repair_db_config reads it
  NEXTCLOUD_DB_PASSWORD=s3cret

  echo ' files it cannot use'
  rm -f "$f"
  repair "$f"
  eq 2 "$RP_RC" 'no config.php: status 2'
  eq "[nextcloud] WARNING: could not check the database settings in config.php: cannot read $f" "$RP_ERR" 'no config.php: the warning says which file'
  eq no "$([[ -e "$f" ]] && echo yes || echo no)" 'no config.php: none is made'
  printf '<?php\nthis is not php (\n' > "$f"
  same="$(md5sum < "$f")"
  repair "$f"
  eq 2 "$RP_RC" 'a config.php that is not PHP: status 2'
  eq "[nextcloud] WARNING: could not check the database settings in config.php: cannot read $f" "$RP_ERR" 'a config.php that is not PHP: the warning says so, and quotes nothing from it'
  eq "$same" "$(md5sum < "$f")" 'a config.php that is not PHP: untouched'
  printf '<?php\n$CONFIG = "not an array";\n' > "$f"
  repair "$f"
  eq 2 "$RP_RC" 'a config.php that is not an array: status 2'
  contains 'does not define $CONFIG' "$RP_ERR" 'a config.php that is not an array: the warning says so'
  eq "[nextcloud] WARNING: could not check the database settings in config.php: $f does not define \$CONFIG" "$RP_ERR" 'a config.php that is not an array: and only that'
  # config.php is code, and what it prints can hold a secret: text outside <?php ?>, an echo, a warning that quotes a string.
  for weird in 'dbpassword is SECRET-IN-TEXT' '<?php echo "SECRET-ECHOED";' '<?php include "SECRET-IN-CODE.php";'; do
    printf '%s\n' "$weird" > "$f"
    same="$(md5sum < "$f")"
    repair "$f"
    eq 2 "$RP_RC" "a config.php that prints (${weird:0:22}...): status 2"
    eq "[nextcloud] WARNING: could not check the database settings in config.php: $f does not define \$CONFIG" "$RP_ERR" "a config.php that prints (${weird:0:22}...): the warning quotes nothing from it"
    eq "$same" "$(md5sum < "$f")" "a config.php that prints (${weird:0:22}...): untouched"
  done
  printf '<?php echo "SECRET-EXIT"; exit(5);\n' > "$f"
  repair "$f"
  eq 2 "$RP_RC" 'a config.php that ends the script itself: status 2'
  eq "[nextcloud] WARNING: could not check the database settings in config.php: php failed with status 5" "$RP_ERR" 'a config.php that ends the script itself: the warning has its status and none of its output'
  printf '<?php echo "SECRET-ECHOED"; $CONFIG = ["dbhost" => "old", "dbname" => "n", "dbuser" => "u", "dbpassword" => "old"];\n' > "$f"
  repair "$f"
  eq 0 "$RP_RC" 'a config.php that echoes and defines $CONFIG: status 0'
  no_secret_in "$RP_OUT$RP_ERR" 'a config.php that echoes and defines $CONFIG: its echo reaches nothing' SECRET-ECHOED
  eq '"tkt-9-nextcloud-mariadb"' "$(cfg_get dbhost)" 'a config.php that echoes and defines $CONFIG: and the repair is done'

  echo ' where config.php is'
  cfg_reset "$stale"
  NC_CONFIG_FILE="$f" repair
  eq 0 "$RP_RC" 'NC_CONFIG_FILE names it when there is no argument'
  cfg_reset "$stale"
  NC_CONFIG_FILE=/nonexistent/config.php repair "$f"
  eq 0 "$RP_RC" 'the argument beats NC_CONFIG_FILE'
  repair
  eq "[nextcloud] WARNING: could not check the database settings in config.php: cannot read /var/www/html/config/config.php" "$RP_ERR" 'with neither, it looks at /var/www/html/config/config.php'

  echo ' leftovers of an interrupted run'
  cfg_reset "$stale"
  nc_repair_db_config "$f" >/dev/null 2>&1
  : > "$NCW/conf/.config.php.0123456789ab"
  mkdir -p "$NCW/tmp"
  : > "$NCW/tmp/db.AbC123"
  NC_TMP_DIR="$NCW/tmp" repair "$f"
  eq '1||' "$RP_RC|$RP_OUT|$RP_ERR" 'nothing to change: status 1'
  eq 'config.php' "$(ls -A "$NCW/conf")" 'a half-written copy of config.php from an earlier run is removed even so'
  eq '' "$(ls -A "$NCW/tmp")" 'and so is a private file of the database settings'

  echo ' php is missing'
  cfg_reset "$stale"
  same="$(md5sum < "$f")"
  mkdir -p "$WORK/empty-path"
  with_only_path "$WORK/empty-path" nc_repair_db_config "$f" >"$WORK/rp.out" 2>"$WORK/rp.err"
  eq 2 "$?" 'status 2'
  eq "$same" "$(md5sum < "$f")" 'config.php is untouched'
}

# --- lib.sh: what sourcing and calling it does to the script that uses it ---------
# Scripts that source lib.sh often run under set -eu and use plain variable names of their own.
# So lib.sh has to be silent, leave the shell options alone, never stop a caller, and keep every
# variable it uses local.
# shellcheck disable=SC2016  # test data: shell and PHP syntax that has to stay text
section_lib_hygiene() {
  if [[ ! -f "$LIB" ]]; then fail "lib.sh not found: $LIB"; return 0; fi
  local fn tv_out tv_rc tv_names tv_v tv_clobbered tv_new tv_t1 tv_t2 tv_t3 tv_ifs tv_path tv_snippet

  # Compared from both ends: a fresh shell with the default options catches a lib.sh that turns one on,
  # and a shell with set -euo pipefail catches one that turns one off.
  tv_snippet='o1="$(set +o; shopt -p)"; source "$LIB" 2>&1; o2="$(set +o; shopt -p)"; if [[ "$o1" == "$o2" ]]; then echo same; else echo changed; fi'
  tv_out="$(LIB="$LIB" bash --noprofile --norc -c "$tv_snippet")"
  eq same "$tv_out" 'sourcing prints nothing and changes no shell option (default options)'
  tv_out="$(LIB="$LIB" bash --noprofile --norc -c "set -euo pipefail; $tv_snippet")"
  eq same "$tv_out" 'sourcing prints nothing and changes no shell option (set -euo pipefail)'

  # nc_occ (occ's own status), nc_repair_db_config (0, 1 or 2), nc_status_json and nc_status_version (1 with no answer),
  # nc_clouve_marker (2 with no occ), nc_marker_trusted, nc_restore_cut_off and nc_hold_upgrade_for_restore (tests) are
  # left out: with no arguments they do not return 0.
  for fn in nc_log nc_warn nc_decode_entities nc_clean_admin_user nc_url_scheme nc_url_host \
            nc_memory_limit_mb nc_apache_workers nc_preview_concurrency nc_missing_trusted_domains \
            nc_first_lines nc_try_occ nc_post_upgrade_steps nc_first_install_steps nc_sweep_leftovers \
            nc_json_line nc_marker_path nc_marker_name nc_note_restore_marker nc_clear_cut_off_backup \
            nc_claim_new_volume; do
    # shellcheck source=/dev/null
    tv_out="$( set -euo pipefail; source "$LIB"; "$fn" 2>&1 )"
    tv_rc=$?
    eq 0 "$tv_rc" "$fn with no arguments: exit status 0 under set -euo pipefail"
  done

  # Source it for real, name the variables its functions declare local, and give the caller a variable of each name.
  # shellcheck source=/dev/null
  source "$LIB"
  tv_names="$(grep -E '^[[:space:]]*local ' "$LIB" | sed -E 's/#.*//; s/^[[:space:]]*local[[:space:]]+//' | tr ' ' '\n' \
              | sed -E 's/=.*//' | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | grep -v '^IFS$' | sort -u)"
  if [[ -z "$tv_names" ]]; then fail 'found no local variables in lib.sh to check'; return 0; fi
  for tv_v in $tv_names; do printf -v "$tv_v" '%s' SENTINEL; done
  # shellcheck disable=SC2031  # with_path and with_only_path change PATH in subshells on purpose; this shell's PATH is what is checked
  tv_ifs="$IFS" tv_path="$PATH"
  tv_t1="$(cg_tree 536870912 -; echo "$NC_CGROUP_ROOT")"
  tv_t2="$(cg_tree - 2147483648; echo "$NC_CGROUP_ROOT")"
  tv_t3="$(cg_tree abc -; echo "$NC_CGROUP_ROOT")"
  compgen -v | sort > "$WORK/vars.before"
  export -p | sort > "$WORK/exports.before"

  # Every branch of every function, run in this shell (not in a $(...)), where a leak would show.
  nc_log hi >/dev/null
  nc_warn hi 2>/dev/null
  nc_decode_entities 'a&amp;b' >/dev/null
  nc_decode_entities 'plain' >/dev/null
  nc_clean_admin_user 'José_García' >/dev/null
  nc_clean_admin_user '{user.x}' >/dev/null
  nc_url_scheme 'https://x' >/dev/null
  nc_url_host 'https://u@X:80/p' >/dev/null
  nc_url_host '[::1]' >/dev/null
  NC_CGROUP_ROOT="$tv_t1" nc_memory_limit_mb >/dev/null
  NC_CGROUP_ROOT="$tv_t2" nc_memory_limit_mb >/dev/null
  NC_CGROUP_ROOT="$tv_t3" nc_memory_limit_mb >/dev/null
  nc_apache_workers 1024 >/dev/null
  nc_apache_workers abc >/dev/null 2>&1
  nc_apache_workers '' >/dev/null
  nc_preview_concurrency 2048 >/dev/null
  nc_preview_concurrency abc >/dev/null 2>&1
  nc_preview_concurrency '' >/dev/null
  nc_missing_trusted_domains '["a"]' a b >/dev/null
  nc_missing_trusted_domains oops a >/dev/null 2>&1
  nc_first_lines $'a\n\nb' >/dev/null
  nc_first_lines '' >/dev/null
  nc_sweep_leftovers "$WORK/none/config.php" >/dev/null 2>&1
  nc_occ >/dev/null 2>&1
  nc_try_occ >/dev/null 2>&1
  nc_json_line $'notice\n{"a":1}\nnotice' >/dev/null
  nc_json_line '' >/dev/null
  nc_status_json >/dev/null 2>&1
  nc_status_version '{"version":"35.0.2.2"}' >/dev/null
  nc_status_version '{"version":"x"}' >/dev/null
  nc_clouve_marker first_install_done >/dev/null 2>&1
  nc_post_upgrade_steps >/dev/null 2>&1
  nc_first_install_steps >/dev/null 2>&1
  NEXTCLOUD_ADMIN_USER=a NEXTCLOUD_ADMIN_EMAIL=a@b NC_APP_INSTALL_TIMEOUT=x nc_first_install_steps >/dev/null 2>&1
  nc_marker_path backup >/dev/null
  nc_restore_cut_off
  nc_note_restore_marker >/dev/null 2>&1
  mkdir -p "$WORK/hyg-mark" && chmod 700 "$WORK/hyg-mark" && printf 'n1\n' > "$WORK/hyg-mark/BACKUP-IN-PROGRESS"
  nc_marker_name "$WORK/hyg-mark/BACKUP-IN-PROGRESS" >/dev/null
  nc_marker_name "$WORK/none/BACKUP-IN-PROGRESS" >/dev/null
  nc_clear_cut_off_backup >/dev/null 2>&1
  mkdir -p "$WORK/hyg-disk" && chmod 755 "$WORK/hyg-disk"
  nc_claim_new_volume "$WORK/hyg-disk" >/dev/null
  nc_claim_new_volume "$WORK/hyg-disk" >/dev/null
  nc_claim_new_volume "$WORK/none" >/dev/null
  nc_repair_db_config "$WORK/none/config.php" >/dev/null 2>&1

  compgen -v | sort > "$WORK/vars.after"
  export -p | sort > "$WORK/exports.after"
  tv_new="$(comm -13 "$WORK/vars.before" "$WORK/vars.after" | tr '\n' ' ')"
  eq '' "$tv_new" 'no new variable is left behind (every one the functions use is local)'
  tv_clobbered=''
  for tv_v in $tv_names; do
    if [[ "${!tv_v-unset}" != SENTINEL ]]; then tv_clobbered="$tv_clobbered $tv_v"; fi
  done
  eq '' "$tv_clobbered" "the caller's variables (${tv_names//$'\n'/ }) keep their values"
  eq '' "$(diff "$WORK/exports.before" "$WORK/exports.after")" 'nothing is left exported'
  eq "$tv_ifs" "$IFS" 'IFS is unchanged'
  # shellcheck disable=SC2031  # as above
  eq "$tv_path" "$PATH" 'PATH is unchanged'
}

# --- the harness: load_lib and run_section ---------------------------------------
# Every section starts with load_lib and runs through run_section, so a hole in either one
# turns into checks that never run. These checks give the real functions bad input. They
# write to a scratch RESULTS file, so the failure they are meant to record does not count
# against the run.
# shellcheck disable=SC2329  # the helper functions inside are run by name, through recorded and run_section
section_harness() {
  local missing="$WORK/lib-missing.sh" syntax="$WORK/lib-syntax.sh" returns="$WORK/lib-returns.sh"
  local exits="$WORK/lib-exits.sh" good="$WORK/lib-good.sh"
  printf 'nc_oops() {\n' > "$syntax"       # a function that is never closed
  printf 'return 1\n' > "$returns"         # a lib.sh that gives up when it is sourced
  printf 'exit 0\n' > "$exits"             # a lib.sh that ends the shell that sources it
  printf 'nc_ok() { :; }\n' > "$good"

  # recorded COMMAND...: runs the command in a subshell with a scratch RESULTS file. Afterwards REC_OUT holds what it
  # printed, ending with "rc=<status>", and REC_RESULTS holds the checks it recorded: P for a pass, F for a failure.
  recorded() {
    local scratch="$WORK/results.scratch"
    : > "$scratch"
    REC_OUT="$( RESULTS="$scratch"; "$@" 2>&1; echo "rc=$?" )"
    REC_RESULTS="$(tr -d '\n' < "$scratch")"
  }
  # lib_from FILE: load_lib pointed at another file. Prints "loaded" when it worked.
  lib_from() { local LIB="$1"; load_lib && echo loaded; }
  # Sections for run_section to run.
  passing_section() { pass 'a check'; }
  quiet_section() { :; }
  stopped_section() { exit 7; }
  exiting_section() { local LIB="$exits"; load_lib; pass 'not reached'; }

  echo ' load_lib'
  recorded lib_from "$good"
  eq '' "$REC_RESULTS" 'a lib.sh that sources cleanly: nothing is recorded'
  eq $'loaded\nrc=0' "$REC_OUT" 'a lib.sh that sources cleanly: load_lib succeeds'
  recorded lib_from "$missing"
  eq F "$REC_RESULTS" 'a lib.sh that is missing: recorded as a failure'
  eq 'rc=1' "${REC_OUT##*$'\n'}" 'a lib.sh that is missing: load_lib fails, so the section stops'
  recorded lib_from "$syntax"
  eq F "$REC_RESULTS" 'a lib.sh with a syntax error: recorded as a failure'
  contains 'lib.sh could not be sourced' "$REC_OUT" 'a lib.sh with a syntax error: the failure says what happened'
  eq 'rc=1' "${REC_OUT##*$'\n'}" 'a lib.sh with a syntax error: load_lib fails, so the section stops'
  recorded lib_from "$returns"
  eq F "$REC_RESULTS" 'a lib.sh that returns 1 when sourced: recorded as a failure'
  contains 'lib.sh could not be sourced' "$REC_OUT" 'a lib.sh that returns 1 when sourced: the failure says what happened'
  eq 'rc=1' "${REC_OUT##*$'\n'}" 'a lib.sh that returns 1 when sourced: load_lib fails, so the section stops'

  echo ' run_section'
  recorded run_section 'a section' passing_section
  eq P "$REC_RESULTS" 'a section that runs a check: that check is the only thing recorded'
  recorded run_section 'a section' stopped_section
  eq F "$REC_RESULTS" 'a section that stops with an error: recorded as a failure'
  contains 'stopped with exit status 7' "$REC_OUT" 'a section that stops with an error: the failure names the status'
  recorded run_section 'a section' quiet_section
  eq F "$REC_RESULTS" 'a section that runs no checks: recorded as a failure'
  contains 'ran no checks' "$REC_OUT" 'a section that runs no checks: the failure says so'
  # A lib.sh that ends the shell that sources it is something load_lib cannot report. run_section has to.
  recorded run_section 'a section' exiting_section
  eq F "$REC_RESULTS" 'a lib.sh that ends the section while it is sourced: recorded as a failure'
  contains 'ran no checks' "$REC_OUT" 'a lib.sh that ends the section while it is sourced: the failure says so'
}

# --- valkey.conf -----------------------------------------------------------------
section_valkey_conf() {
  local conf="$INSTALLER/valkey.conf" want="$WORK/valkey.conf.want"
  # The planned file, written out by hand. Valkey is not in the base image, so this test cannot start it.
  cat > "$want" <<'EOF'
port 0
unixsocket /run/clouve/valkey/valkey.sock
unixsocketperm 700
daemonize no
save ""
appendonly no
maxmemory 128mb
maxmemory-policy allkeys-lru
databases 1
logfile ""
EOF
  if [[ ! -f "$conf" ]]; then fail "valkey.conf not found: $conf"; return 0; fi
  if cmp -s "$conf" "$want"; then
    pass 'valkey.conf is exactly the planned file'
  else
    fail 'valkey.conf is exactly the planned file'
    diff "$want" "$conf" | sed 's/^/       /'
  fi
}

# no_xtrace FILE: the script never turns on set -x (it could print a password into a log).
no_xtrace() {
  local name
  name="$(basename "$1")"
  if [[ ! -f "$1" ]]; then fail "$name never turns on set -x: file not found"
  elif grep -Eq '^[[:space:]]*set([[:space:]]+-[A-Za-z]+)*[[:space:]]+(-[A-Za-z]*x|-o[[:space:]]+xtrace)' "$1"; then fail "$name never turns on set -x"
  else pass "$name never turns on set -x"
  fi
}

# --- start-valkey.sh -------------------------------------------------------------
# The script makes the socket directory and then keeps valkey-server running. Here runuser and valkey-server are fakes
# that record how they were called (the base image has no Valkey), and sleep is a fake that waits only a moment, so four
# restarts do not take four seconds. Everything else is real: install, bash and the user www-data.
section_valkey_loop() {
  local script="$INSTALLER/start-valkey.sh" bin="$WORK/bin-valkey" dir=/run/clouve/valkey conf_dir rc
  export FAKE_LOG="$WORK/valkey.calls" FAKE_COUNT="$WORK/valkey.count"

  if [[ ! -x "$script" ]]; then fail "start-valkey.sh is missing or not executable: $script"; return 0; fi

  fake_spy "$bin" runuser <<'EOF'
# Checks the form "runuser -u www-data -- COMMAND...", then runs COMMAND as the current user.
if [ "$1" != -u ] || [ "$2" != www-data ] || [ "$3" != -- ]; then
  echo "fake runuser: unexpected arguments: $*" >&2
  exit 64
fi
shift 3
exec "$@"
EOF
  fake_spy "$bin" valkey-server <<'EOF'
# Counts its starts in $FAKE_COUNT and exits with the n-th status in $FAKE_VALKEY_RCS (the last one repeats).
# It prints a line on stdout, where Valkey logs.
n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_COUNT"
echo "valkey-server run $n"
read -r -a rcs <<< "$FAKE_VALKEY_RCS"
i=$(( n - 1 ))
if [ "$i" -ge "${#rcs[@]}" ]; then i=$(( ${#rcs[@]} - 1 )); fi
exit "${rcs[$i]}"
EOF
  fake_spy "$bin" sleep <<'EOF'
# Waits only a moment. The call was recorded first.
exec /usr/bin/sleep 0.05
EOF

  # run_loop STATUSES RUNS: starts the script in the background, as the entrypoint does, and lets the fake Valkey exit
  # RUNS times with the exit statuses in STATUSES (the last one repeats). Then it stops the script. LOOP_ALIVE says
  # whether the script was still running at that point.
  run_loop() {
    local i pid
    export FAKE_VALKEY_RCS="$1"
    rm -f "$FAKE_COUNT"
    : > "$FAKE_LOG"
    # shellcheck disable=SC2031  # with_path changes PATH in subshells on purpose; this shell's PATH is what is extended
    env PATH="$bin:$PATH" "$script" >"$WORK/valkey.out" 2>"$WORK/valkey.err" </dev/null &
    pid=$!
    for ((i = 0; i < 100; i++)); do
      if [[ "$(cat "$FAKE_COUNT" 2>/dev/null || echo 0)" -ge "$2" ]]; then break; fi
      sleep 0.1
    done
    LOOP_ALIVE=no
    if kill -0 "$pid" 2>/dev/null; then LOOP_ALIVE=yes; fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  }

  echo ' the socket directory'
  # A directory left with the wrong owner and mode is put right (the script runs again after every restart).
  rm -rf /run/clouve
  mkdir -p "$dir"
  chmod 777 "$dir"
  chown nobody:nogroup "$dir"
  run_loop 0 1
  eq 'www-data:www-data 700' "$(stat -c '%U:%G %a' "$dir")" 'a directory left with the wrong owner and mode is put right'
  # Made from nothing.
  rm -rf /run/clouve
  run_loop '0 1 137' 4
  eq 'www-data:www-data 700' "$(stat -c '%U:%G %a' "$dir")" 'made for www-data, mode 700'
  eq www-data "$(runuser -u www-data -- id -un 2>&1)" 'sanity check: this runuser accepts "-u www-data --"'
  if runuser -u www-data -- touch "$dir/socket-test" 2>/dev/null; then pass 'www-data can create the socket in it'; else fail 'www-data can create the socket in it'; fi
  if runuser -u nobody -- ls "$dir" >/dev/null 2>&1; then fail 'another user cannot open it'; else pass 'another user cannot open it'; fi
  conf_dir="$(dirname "$(awk '$1 == "unixsocket" { print $2 }' "$INSTALLER/valkey.conf" 2>/dev/null)")"
  eq "$dir" "$conf_dir" 'it is the directory valkey.conf puts the socket in'

  echo ' the loop (Valkey exits with 0, 1, 137 and 137)'
  eq yes "$LOOP_ALIVE" 'the script is still running after Valkey has exited four times'
  eq $'[valkey] exited with 0; restarting in 1 s\n[valkey] exited with 1; restarting in 1 s\n[valkey] exited with 137; restarting in 1 s' \
     "$(head -n 3 "$WORK/valkey.err")" 'each exit is logged on stderr, with its status'
  lacks '[valkey]' "$(cat "$WORK/valkey.out")" 'nothing of its own goes to stdout'
  eq $'runuser|-u|www-data|--|valkey-server|/clouve/nextcloud/installer/valkey.conf\nvalkey-server|/clouve/nextcloud/installer/valkey.conf\nsleep|1\nrunuser|-u|www-data|--|valkey-server|/clouve/nextcloud/installer/valkey.conf' \
     "$(head -n 4 "$FAKE_LOG")" 'it runs valkey-server as www-data with valkey.conf, waits 1 s once it exits, and runs it again'

  echo ' when the directory cannot be made'
  rm -rf /run/clouve
  mkdir -p /run/clouve
  : > "$dir"                        # a file where the directory should be
  : > "$FAKE_LOG"
  # shellcheck disable=SC2031  # as above
  env PATH="$bin:$PATH" timeout 5 "$script" >"$WORK/valkey.out" 2>"$WORK/valkey.err" </dev/null
  rc=$?
  eq 1 "$rc" 'it stops with status 1 instead of restarting Valkey for ever'
  contains "[valkey] cannot make $dir" "$(cat "$WORK/valkey.err")" 'it says which directory it could not make, in the same [valkey] form as its other lines'
  eq '' "$(cat "$FAKE_LOG")" 'it does not start Valkey'
  rm -rf /run/clouve

  echo ' the file'
  eq '#!/bin/bash' "$(head -n 1 "$script")" 'it starts with #!/bin/bash'
  no_xtrace "$script"
}

# --- healthcheck.sh --------------------------------------------------------------
# status.php as Nextcloud 35.0.2 answers it, captured from nextcloud:35.0.2-apache with a throwaway SQLite install: not
# installed yet, installed, in maintenance mode, with an upgrade pending, and both of those at once (what an `occ upgrade`
# that was killed leaves behind). All of them are HTTP 200. A host that is not in trusted_domains gets 400 and the last body.
STATUS_NEW='{"installed":false,"maintenance":false,"needsDbUpgrade":false,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","productname":"Nextcloud","extendedSupport":false}'
STATUS_OK='{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","productname":"Nextcloud","extendedSupport":false}'
STATUS_MAINT='{"installed":true,"maintenance":true,"needsDbUpgrade":false,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","productname":"Nextcloud","extendedSupport":false}'
STATUS_UPGRADE='{"installed":true,"maintenance":false,"needsDbUpgrade":true,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","productname":"Nextcloud","extendedSupport":false}'
STATUS_KILLED='{"installed":true,"maintenance":true,"needsDbUpgrade":true,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","productname":"Nextcloud","extendedSupport":false}'
STATUS_UNTRUSTED='{"error": "Trusted domain error.", "code": 15}'

# probe: runs healthcheck.sh the way the platform does ("sh -c <path>", so the file must be executable), with no stdin and
# the tools in $PROBE_BIN first on PATH. The manifest gives the probe 15 s. One that is still running after 20 s is stopped
# and fails its check, so a probe that regresses into a hang cannot hang the whole run. Its stdout and stderr go to
# $WORK/health.out and $WORK/health.err, and its exit status is the function's (124 when it was stopped).
probe() { with_path "$PROBE_BIN" timeout 20 sh -c "$INSTALLER/healthcheck.sh" </dev/null >"$WORK/health.out" 2>"$WORK/health.err"; }

# fake_health_tools DIR: writes into DIR the three tools healthcheck.sh calls. Each records its call (see fake_spy), then
# answers as a variable says:
#   flock       FAKE_FLOCK   free (the default: run the command), held (exit with -E's code, or 1, which is what flock -n
#               does when someone else has the lock) or real (run the real flock). It also adds the user it runs as to
#               $FAKE_LOG.who, since the probe asks the lock as www-data
#   valkey-cli  FAKE_VALKEY  pong (the default), down (an error on stderr and status 1, as with no server), silent (nothing,
#               status 0), loading (a reply that is not PONG) or hang (never answers)
#   curl        FAKE_CURL    fake (the default: exit with FAKE_CURL_RC and, when that is 0, print FAKE_CURL_BODY; with -f a
#               failing curl prints nothing on stdout) or real (run the real curl)
# valkey-cli is a fake in every case, because the base image does not have it.
fake_health_tools() {
  fake_spy "$1" flock <<'EOF'
id -un >> "$FAKE_LOG.who"
if [ "${FAKE_FLOCK:-free}" = real ]; then exec /usr/bin/flock "$@"; fi
code=1
while [ $# -gt 0 ]; do
  case $1 in
    -n | -s) shift ;;
    -E) code=$2; shift 2 ;;
    *) break ;;
  esac
done
shift          # FILE
if [ "${FAKE_FLOCK:-free}" = held ]; then exit "$code"; fi
exec "$@"
EOF
  fake_spy "$1" valkey-cli <<'EOF'
case "${FAKE_VALKEY:-pong}" in
  pong)    echo PONG ;;
  down)    echo "Could not connect to Valkey at $2: No such file or directory" >&2; exit 1 ;;
  silent)  ;;
  loading) echo "LOADING Valkey is loading the dataset in memory" ;;
  hang)    exec sleep 10 ;;
esac
EOF
  fake_spy "$1" curl <<'EOF'
if [ "${FAKE_CURL:-fake}" = real ]; then exec /usr/bin/curl "$@"; fi
if [ "${FAKE_CURL_RC:-0}" != 0 ]; then
  echo "curl: ($FAKE_CURL_RC) simulated failure" >&2
  exit "$FAKE_CURL_RC"
fi
printf '%s' "${FAKE_CURL_BODY-}"
EOF
}

# health_for_www_data BIN: the probe asks the lock as www-data, so www-data has to get through $WORK to the lock file
# and to the fakes in BIN, and the fakes, running as www-data, have to write their logs.
health_for_www_data() {
  chmod 711 "$WORK"
  chmod 755 "$1"
  : > "$FAKE_LOG"
  : > "$FAKE_LOG.who"
  chmod 666 "$FAKE_LOG" "$FAKE_LOG.who"
}

# The probe's cases. The lock, valkey-cli and curl are fakes that record their calls, so each case says exactly what the
# probe asked. The overrides (NC_HEALTH_LOCK and the other two) point at made-up paths, and a later check runs it without them.
section_healthcheck() {
  local hc="$INSTALLER/healthcheck.sh" bin="$WORK/bin-health" start elapsed conf_sock
  local lock="$WORK/health.lock" sock="$WORK/health.sock" url="http://127.0.0.1:8099/status.php"
  local ask_valkey ask_curl
  export FAKE_LOG="$WORK/health.calls" NC_HEALTH_LOCK="$lock" NC_HEALTH_SOCK="$sock" NC_HEALTH_URL="$url"
  export NC_HEALTH_MARKER="$WORK/hc-backups/RESTORE-IN-PROGRESS"
  fake_health_tools "$bin"
  health_for_www_data "$bin"
  ask_valkey="valkey-cli|-s|$sock|ping"
  ask_curl="curl|-fsS|-m|8|-H|Host: localhost|$url"
  PROBE_BIN="$bin"

  # row LABEL WANT LOCK VALKEY CURL_RC BODY WHY: one case.
  #   LOCK    held (the file exists and flock says someone has it), free (the file exists and nobody has it) or
  #           absent (no file; the fake flock says "held" anyway, so a probe that asks flock about a missing file is caught)
  #   VALKEY  pong, down, silent, loading or hang (see fake_health_tools)
  #   WHY     text that must be on stderr when the probe says no. Empty when it says yes: it must print nothing at all.
  row() {
    local flock_mode rc
    case "$3" in
      held)   : > "$lock"; flock_mode=held ;;
      free)   : > "$lock"; flock_mode=free ;;
      absent) rm -f "$lock"; flock_mode=held ;;
    esac
    : > "$FAKE_LOG"
    FAKE_FLOCK="$flock_mode" FAKE_VALKEY="$4" FAKE_CURL_RC="$5" FAKE_CURL_BODY="$6" probe
    rc=$?
    eq "$2" "$rc" "$1"
    if [[ -n "${7-}" ]]; then
      contains "$7" "$(cat "$WORK/health.err")" "$1: says why on stderr"
    elif [[ "$2" -eq 0 ]]; then
      eq '' "$(cat "$WORK/health.out" "$WORK/health.err")" "$1: prints nothing"
    fi
  }

  echo ' an install or upgrade holds the lock: healthy whatever else is true'
  #   label                                                          want lock   valkey  curl body
  row 'lock held, Valkey silent, curl fails (an install)'               0 held   silent  7  ''
  eq "flock|-n|-s|-E|75|$lock|true" "$(cat "$FAKE_LOG")" 'lock held: the probe asked the lock (shared, as www-data, held is 75) and nothing else'
  eq www-data "$(sort -u "$FAKE_LOG.who")" 'the lock is asked as www-data, never as root'
  row 'lock held, Valkey down, HTTP 500 (an upgrade)'                   0 held   down    22 ''
  row 'lock held, not installed yet'                                    0 held   pong    0  "$STATUS_NEW"

  echo ' nothing holds the lock: healthy only when Valkey and Nextcloud are'
  row 'normal, no lock file'                                            0 absent pong    0  "$STATUS_OK"
  eq "$ask_valkey"$'\n'"$ask_curl" "$(cat "$FAKE_LOG")" 'no lock file: Valkey, then status.php, and flock is not asked'
  row 'normal, lock file that nobody holds'                             0 free   pong    0  "$STATUS_OK"
  eq "flock|-n|-s|-E|75|$lock|true"$'\n'"$ask_valkey"$'\n'"$ask_curl" "$(cat "$FAKE_LOG")" 'lock free: the lock, then Valkey, then status.php'
  row 'maintenance mode'                                                0 free   pong    0  "$STATUS_MAINT"
  row 'upgrade pending'                                                 0 free   pong    0  "$STATUS_UPGRADE"
  row 'killed upgrade: maintenance on and upgrade pending'              0 free   pong    0  "$STATUS_KILLED"

  echo ' a restore that was cut off: healthy whatever else is true, and nothing else is asked'
  mkdir -p "$WORK/hc-backups"
  chmod 700 "$WORK/hc-backups"
  printf 'n1\n' > "$NC_HEALTH_MARKER"
  chmod 600 "$NC_HEALTH_MARKER"
  row 'a trusted restore marker, Valkey down, HTTP 500'                   0 free down 22 ''
  eq '' "$(cat "$FAKE_LOG")" 'a trusted restore marker: nothing else is asked'
  chmod 770 "$WORK/hc-backups"
  row 'a restore marker in a folder its group can write to: not a reason' 1 free down 0 "$STATUS_OK" 'Valkey'
  chmod 700 "$WORK/hc-backups"
  chown www-data "$NC_HEALTH_MARKER"
  row 'a restore marker that www-data owns: not a reason'                 1 free down 0 "$STATUS_OK" 'Valkey'
  rm -f "$NC_HEALTH_MARKER"
  printf 'n1\n' > "$WORK/hc-real-marker"
  ln -s "$WORK/hc-real-marker" "$NC_HEALTH_MARKER"
  row 'a symlink as the restore marker: not a reason'                     1 free down 0 "$STATUS_OK" 'Valkey'
  rm -rf "$WORK/hc-backups" "$WORK/hc-real-marker"
  # The root entrypoint's note is for the hooks, and only the next start removes it, so it outlives a restore that the
  # assistant finished or undid without a restart. The probe goes by the marker alone.
  mkdir -p /run/clouve
  : > /run/clouve/restore-cut-off
  row "the root entrypoint's restore note, and no marker (finished since): not a reason" 1 free down 0 "$STATUS_OK" 'Valkey'
  rm -f /run/clouve/restore-cut-off

  echo ' Valkey'
  row 'Valkey down: the socket refuses'                                 1 free   down    0  "$STATUS_OK"  'Valkey'
  eq "flock|-n|-s|-E|75|$lock|true"$'\n'"$ask_valkey" "$(cat "$FAKE_LOG")" 'Valkey down: status.php is not asked'
  row 'Valkey down, no lock file (flock would say held)'                1 absent down    0  "$STATUS_OK"  'Valkey'
  row 'Valkey answers nothing'                                          1 free   silent  0  "$STATUS_OK"  'Valkey'
  row 'Valkey answers, but not PONG'                                    1 free   loading 0  "$STATUS_OK"  'Valkey'

  echo ' status.php'
  row 'Apache down (curl exit 7)'                                       1 free   pong    7  ''            'curl exit 7'
  row 'database down: HTTP 500 (curl exit 22)'                          1 free   pong    22 ''            'curl exit 22'
  row 'no answer in time (curl exit 28)'                                1 free   pong    28 ''            'curl exit 28'
  row 'not installed'                                                   1 free   pong    0  "$STATUS_NEW" 'installed'
  row 'not installed, in maintenance mode (made up)'                    1 free   pong    0  "${STATUS_NEW/\"maintenance\":false/\"maintenance\":true}" 'installed'
  row 'a page that is not status.php output'                            1 free   pong    0  '<html><body>It works!</body></html>' 'installed'
  row 'an empty answer'                                                 1 free   pong    0  ''            'installed'

  echo ' a Valkey that never answers'
  # Timed in microseconds (EPOCHREALTIME without its decimal point), then cut to whole seconds. $SECONDS counts whole
  # seconds of the clock, so a run of 3.1 s could read as 4 and fail the check below for no reason.
  start=${EPOCHREALTIME//[!0-9]/}
  row 'Valkey hangs: the probe gives up on it' 1 free hang 0 "$STATUS_OK" 'Valkey'
  elapsed=$(( (${EPOCHREALTIME//[!0-9]/} - start) / 1000000 ))
  # The fake sleeps 10 s. With no limit on the call the probe would wait that long. A real hang would then run into
  # kubelet's 15 s timeout and leave valkey-cli running behind it. The probe gives Valkey 3 s, so it is done in 3 s and
  # a bit. 4 s or more means that limit grew, and with the lock's 3 s and curl's 8 s, 4 s takes all of kubelet's 15 s.
  if [[ "$(cat "$FAKE_LOG")" == *"$ask_valkey"* && "$elapsed" -lt 4 ]]; then
    pass "the probe asked Valkey and gave up on it after $elapsed s (less than 4)"
  else
    fail "the probe asked Valkey and gave up on it within 4 s (took $elapsed s; it ran: $(tr '\n' ' ' < "$FAKE_LOG"))"
  fi

  echo ' with none of the NC_HEALTH_* variables set'
  rm -f /var/www/html/nextcloud-init-sync.lock
  : > "$FAKE_LOG"
  ( unset NC_HEALTH_LOCK NC_HEALTH_SOCK NC_HEALTH_URL NC_HEALTH_MARKER; FAKE_CURL_BODY="$STATUS_OK" probe )
  eq 0 "$?" 'normal: healthy'
  eq $'valkey-cli|-s|/run/clouve/valkey/valkey.sock|ping\ncurl|-fsS|-m|8|-H|Host: localhost|http://127.0.0.1/status.php' "$(cat "$FAKE_LOG")" \
     'the defaults are the Valkey socket and http://127.0.0.1/status.php, and with no lock file flock is not asked'
  : > /var/www/html/nextcloud-init-sync.lock
  : > "$FAKE_LOG"
  ( unset NC_HEALTH_LOCK NC_HEALTH_SOCK NC_HEALTH_URL NC_HEALTH_MARKER; FAKE_FLOCK=held probe )
  eq 0 "$?" 'lock held: healthy'
  eq 'flock|-n|-s|-E|75|/var/www/html/nextcloud-init-sync.lock|true' "$(cat "$FAKE_LOG")" 'the default lock is /var/www/html/nextcloud-init-sync.lock'
  rm -f /var/www/html/nextcloud-init-sync.lock
  conf_sock="$(awk '$1 == "unixsocket" { print $2 }' "$INSTALLER/valkey.conf" 2>/dev/null)"
  eq /run/clouve/valkey/valkey.sock "$conf_sock" "the probe's default socket is the one valkey.conf makes"

  echo ' the file'
  if [[ -x "$hc" ]]; then pass 'healthcheck.sh is executable'; else fail "healthcheck.sh is missing or not executable: $hc"; fi
  eq /usr/bin/dash "$(readlink -f /bin/sh)" 'sanity check: sh is dash in this image, so a bashism in the probe would fail the cases above'
  eq '#!/bin/sh' "$(head -n 1 "$hc" 2>/dev/null)" 'it asks for /bin/sh, as the platform runs it'
  no_xtrace "$hc"
}

# The same probe with the real flock and the real curl. A real lock is held the two ways a start holds it, and a
# stand-in web server on 127.0.0.1:80 answers the default URL with what the test says. Only valkey-cli is a fake.
section_healthcheck_real() {
  local hc="$INSTALLER/healthcheck.sh" bin="$WORK/bin-health-real" www="$WORK/www" lock="$WORK/real.lock"
  local stub_pid='' holder='' rc made
  export FAKE_LOG="$WORK/health-real.calls" NC_HEALTH_LOCK="$lock" FAKE_FLOCK=real FAKE_CURL=real
  unset NC_HEALTH_SOCK NC_HEALTH_URL NC_HEALTH_MARKER
  fake_health_tools "$bin"
  health_for_www_data "$bin"
  PROBE_BIN="$bin"
  mkdir -p "$www"

  # The stand-in: /status.php answers with the status code and body the test leaves in two files, and every request is
  # logged with its Host header.
  cat > "$www/router.php" <<'PHP'
<?php
$dir = $_SERVER['DOCUMENT_ROOT'];
file_put_contents("$dir/requests.log", $_SERVER['REQUEST_METHOD'] . ' ' . $_SERVER['REQUEST_URI'] . ' Host=' . ($_SERVER['HTTP_HOST'] ?? '-') . "\n", FILE_APPEND);
if (parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) !== '/status.php') {
    http_response_code(404);
    return;
}
http_response_code((int) file_get_contents("$dir/status.code"));
header('Content-Type: application/json');
echo file_get_contents("$dir/status.body");
PHP
  start_stub() {
    local i
    printf '200' > "$www/status.code"
    : > "$www/status.body"
    : > "$www/requests.log"
    php -S 127.0.0.1:80 -t "$www" "$www/router.php" >"$www/server.log" 2>&1 &
    stub_pid=$!
    for ((i = 0; i < 50; i++)); do
      if curl -s -o /dev/null -m 2 http://127.0.0.1/status.php; then : > "$www/requests.log"; return 0; fi
      sleep 0.1
    done
    return 1
  }
  stop_stub() { kill "$stub_pid" 2>/dev/null; wait "$stub_pid" 2>/dev/null; }
  # stub_row LABEL WANT CODE BODY WHY: the stand-in answers the probe's request with this status code and body.
  stub_row() {
    local rc
    printf '%s' "$3" > "$www/status.code"
    printf '%s' "$4" > "$www/status.body"
    : > "$FAKE_LOG"
    FAKE_VALKEY=pong probe
    rc=$?
    eq "$2" "$rc" "$1"
    if [[ -n "${5-}" ]]; then contains "$5" "$(cat "$WORK/health.err")" "$1: says why on stderr"; fi
  }
  wait_for() {
    local i
    for ((i = 0; i < 50; i++)); do
      if [[ -e "$1" ]]; then return 0; fi
      sleep 0.1
    done
    return 1
  }
  # The two ways the lock is held in a real start. Nextcloud's entrypoint does its install or upgrade in a subshell
  # that has the lock on file descriptor 9. Our before-starting hook runs `flock <file> occ upgrade`. Both holders here
  # keep the lock until the test creates $WORK/release.
  hold_like_entrypoint() {
    rm -f "$WORK/holding" "$WORK/release"
    ( flock 9 && : > "$WORK/holding" && while [[ ! -e "$WORK/release" ]]; do sleep 0.1; done ) 9> "$lock" &
    holder=$!
    wait_for "$WORK/holding"
  }
  hold_like_hook() {
    rm -f "$WORK/holding" "$WORK/release"
    # shellcheck disable=SC2016  # the single-quoted text is the script for the inner bash
    flock "$lock" bash -c ': > "$1"; while [[ ! -e "$2" ]]; do sleep 0.1; done' _ "$WORK/holding" "$WORK/release" &
    holder=$!
    wait_for "$WORK/holding"
  }
  release_holder() { : > "$WORK/release"; wait "$holder" 2>/dev/null; }

  echo ' the real curl against the stand-in (http://127.0.0.1/status.php, Host: localhost)'
  if start_stub; then
    stub_row 'normal'                                                 0 200 "$STATUS_OK"
    eq 'GET /status.php Host=localhost' "$(tail -n 1 "$www/requests.log")" 'the request is GET /status.php with Host: localhost'
    stub_row 'maintenance mode'                                       0 200 "$STATUS_MAINT"
    stub_row 'upgrade pending'                                        0 200 "$STATUS_UPGRADE"
    stub_row 'killed upgrade: maintenance on and upgrade pending'     0 200 "$STATUS_KILLED"
    stub_row 'not installed'                                          1 200 "$STATUS_NEW"       'installed'
    stub_row 'a host that is not trusted: HTTP 400'                   1 400 "$STATUS_UNTRUSTED" 'curl exit 22'
    stub_row 'HTTP 500 with a body that says installed:true'          1 500 "$STATUS_OK"        'curl exit 22'
    stub_row 'HTTP 503 with no body'                                  1 503 ''                  'curl exit 22'
    stop_stub
  else
    fail 'the stand-in web server did not start on 127.0.0.1:80'
  fi
  : > "$FAKE_LOG"
  rm -f "$lock"
  FAKE_VALKEY=pong probe
  eq 1 "$?" 'nothing listens on port 80 (Apache is down): not healthy'
  contains 'curl exit 7' "$(cat "$WORK/health.err")" 'nothing listens on port 80: says why on stderr'

  echo ' the real flock (Apache is stopped and Valkey is down, so only the lock can make the probe healthy)'
  : > "$FAKE_LOG"
  rm -f "$lock"
  FAKE_VALKEY=down probe
  eq 1 "$?" 'no lock file: not healthy'
  # A bare "flock FILE true" creates FILE when it is missing, so the probe has to look first. One value holds both facts, so
  # the check cannot pass just because the probe never ran.
  made=''
  if [[ -e "$lock" ]]; then made=$'\n(and a lock file appeared)'; fi
  eq 'valkey-cli|-s|/run/clouve/valkey/valkey.sock|ping' "$(cat "$FAKE_LOG")$made" 'no lock file: flock is not run, and no lock file appears'
  : > "$lock"
  FAKE_VALKEY=down probe
  eq 1 "$?" 'a lock file that nobody holds: not healthy'
  if hold_like_entrypoint; then
    : > "$FAKE_LOG"
    FAKE_VALKEY=down probe
    rc=$?
    eq 0 "$rc" 'held like the entrypoint holds it during an install or upgrade: healthy'
    eq "flock|-n|-s|-E|75|$lock|true" "$(cat "$FAKE_LOG")" 'held like the entrypoint holds it: the probe asked the lock and nothing else'
    release_holder
    FAKE_VALKEY=down probe
    eq 1 "$?" 'the entrypoint let go of the lock: not healthy again'
  else
    fail 'the test could not take the lock like the entrypoint does'
  fi
  if hold_like_hook; then
    : > "$FAKE_LOG"
    FAKE_VALKEY=down probe
    rc=$?
    eq 0 "$rc" 'held like our before-starting hook holds it during upgrade recovery: healthy'
    eq "flock|-n|-s|-E|75|$lock|true" "$(cat "$FAKE_LOG")" 'held like the hook holds it: the probe asked the lock and nothing else'
    release_holder
    FAKE_VALKEY=down probe
    eq 1 "$?" 'the hook let go of the lock: not healthy again'
  else
    fail 'the test could not take the lock like the hook does'
  fi

  echo ' the real flock, the lock path swapped or shared (www-data owns the folder, so anything can be there)'
  rm -f "$lock"
  : > "$lock"
  rm -f "$WORK/holding" "$WORK/release"
  # shellcheck disable=SC2016  # the single-quoted text is the script for the inner bash
  flock -s "$lock" bash -c ': > "$1"; while [[ ! -e "$2" ]]; do sleep 0.1; done' _ "$WORK/holding" "$WORK/release" &
  holder=$!
  if wait_for "$WORK/holding"; then
    FAKE_VALKEY=down probe
    eq 1 "$?" 'another probe holds a shared lock: not "held", so the real checks run (not healthy)'
    release_holder
  else
    fail 'the test could not take a shared lock'
  fi
  chmod 600 "$lock"
  FAKE_VALKEY=down probe
  eq 1 "$?" 'a lock file only root can read: www-data cannot open it, which is not "held" (not healthy)'
  rm -f "$lock"
  mkdir -p "$WORK/root-only"
  chmod 700 "$WORK/root-only"
  ln -s "$WORK/root-only/created" "$lock"
  FAKE_VALKEY=down probe
  rc=$?
  made=no
  if [[ -e "$WORK/root-only/created" ]]; then made=yes; fi
  eq '1 no' "$rc $made" 'the lock path is a symlink into a folder only root can write to: not healthy, and nothing is created there'
  rm -f "$lock"
  mkfifo "$lock"
  chmod 666 "$lock"
  start=${EPOCHREALTIME//[!0-9]/}
  FAKE_VALKEY=down probe
  rc=$?
  elapsed=$(( (${EPOCHREALTIME//[!0-9]/} - start) / 1000000 ))
  if [[ "$rc" -eq 1 && "$elapsed" -lt 5 ]]; then
    pass "a named pipe at the lock path: the probe does not open it, and is done in $elapsed s (not healthy, Valkey is down)"
  else
    fail "a named pipe at the lock path: want exit 1 within 5 s, got exit $rc after $elapsed s"
  fi
  rm -f "$lock"
  : > "$lock"
  local i bad=0 r1 r2 p1 p2
  for ((i = 0; i < 20; i++)); do
    ( FAKE_VALKEY=down with_path "$PROBE_BIN" timeout 20 sh -c "$INSTALLER/healthcheck.sh" </dev/null >/dev/null 2>&1; echo $? > "$WORK/pair1" ) &
    p1=$!
    ( FAKE_VALKEY=down with_path "$PROBE_BIN" timeout 20 sh -c "$INSTALLER/healthcheck.sh" </dev/null >/dev/null 2>&1; echo $? > "$WORK/pair2" ) &
    p2=$!
    # Only these two: a stand-in server or a lock holder left running from above would make a bare wait hang the suite.
    wait "$p1" "$p2"
    r1=$(cat "$WORK/pair1") r2=$(cat "$WORK/pair2")
    if [[ "$r1" != 1 || "$r2" != 1 ]]; then bad=$((bad + 1)); fi
  done
  eq 0 "$bad" 'liveness and readiness at the same moment (20 pairs, lock free, Valkey down): neither ever says healthy because of the other'
  rm -f "$lock"
}

# ----------------------------------------------------------------------------
# nextcloud-config.sh and the hooks: a fake occ, a fake flock, and a world to run them in
# ----------------------------------------------------------------------------
# The scripts run against a fake occ that keeps its state in a config.php, as Nextcloud does, and a fake flock. Each
# section builds its own "world" directory (nc_world) with a log, a config.php and a private temp dir, and runs a
# script in it with nc_run. The real occ is only used at the end (section_real_occ), against a SQLite install.
CONFIG_SH="$INSTALLER/nextcloud-config.sh"
HOOKS="$INSTALLER/hooks"

# fake_occ DIR: writes DIR/occ.php, a stand-in for `php /var/www/html/occ`. Run it as
# `php -n -d display_errors=stderr DIR/occ.php ARGS`. Its state is a config.php ($NC_FAKE_CONFIG), and every call adds
# one line to $LOG: the arguments joined by a space. It answers as the real occ of nextcloud:35.0.2-apache does (every
# line below was probed there):
#   config:system:get NAME [INDEX]   a key that is not set gives exit 1 and no output at all (with --default-value: the
#                                    default and exit 0). --output=json prints an array, or an object when the indexes
#                                    have gaps
#   config:system:set NAME [INDEX]   "System config value ... set to <type> <value>", and an index changes one entry
#   config:system:delete NAME        works for a key that is not set too
#   config:app:get APP KEY           the app config value, kept in $NC_FAKE_APPCONFIG from one run to the next. A key
#                                    that is not set gives exit 1 and no output at all, as the real one does (with
#                                    --default-value: the default and exit 0, so --default-value= prints an empty line)
#   config:app:set APP KEY --value=V "Config value 'KEY' for app 'APP' is now set to 'V', stored as mixed in fast cache"
#                                    (lazy cache with --lazy)
#   config:app:delete APP KEY        "Config value KEY of app APP deleted", also for a key that is not set
#   config:import FILE               merges the keys under "system". The file is copied to $LOG.import and its mode to
#                                    $LOG.import.mode, because the script under test deletes it right after. $LOG.tmp has
#                                    one line per call: how many db.* files NC_TMP_DIR holds when that call starts, and
#                                    $LOG.home one line per call: the HOME it runs with
#   status                           prints $FAKE_STATUS_JSON, or the healthy answer. FAKE_STATUS_JSON=live reads it
#                                    from config.php instead, as the real one does: installed and maintenance from their
#                                    keys (false when unset), needsDbUpgrade when the key version is older than the
#                                    code's 35.0.2.2, and the code's version. Runs that follow one another then see what
#                                    the ones before them left
#   app:install APP                  "APP already installed" and exit 1 for an app on disk, which it leaves as it is.
#                                    Otherwise it puts APP on disk, enabled, and says "APP 1.0.0 installed", "APP enabled"
#   app:getpath APP                  the app's folder for an app on disk, and exit 1 and no output for any other
#   app:enable APP                   "APP already enabled" when it is. Otherwise it enables APP (downloading it first when
#                                    it is not on disk), and says "APP 1.0.0 enabled". $LOG.apps holds the apps on disk,
#                                    as {"APP": "enabled" or "disabled"}
#   upgrade                          what lib/private/Updater.php does to config.php: loglevel 0 while it runs, and
#                                    maintenance on unless it already was. At the end it turns maintenance off again
#                                    when it turned it on and the upgrade worked, and puts back the log level it found
#                                    (2 when none was set). One that worked sets version to the code's 35.0.2.2.
#                                    FAKE_UPGRADE_FAILS keeps maintenance on, as a failure does
#   maintenance:repair               what core/Command/Maintenance/Repair.php does to config.php: maintenance on for the
#                                    whole run, and the value it found put back at the end. So a repair that FAKE_HANG
#                                    holds (it waits after turning maintenance on) and NC_RUN_KILL kills leaves it on.
#                                    FAKE_REPAIR_CRASHES dies on the way as the real one does when an app's repair step
#                                    throws an Error: exit 1, a stack trace on stdout, and maintenance left on.
#                                    FAKE_REPAIR_ERRORS reaches the end, puts the value back and exits 1, as one whose
#                                    step reported an error does
#   maintenance:mode, ...            succeed and print little. A command or option the real occ lacks is an error. (The real
#                                    occ also takes a unique abbreviation of a command name, so it would accept
#                                    db:add-missing-primary-key. The fake does not, so that such a typo is caught.)
# Failures print on stdout, as the real occ prints "An unhandled exception has been thrown", so that a script cannot take
# one for a key that is not set (exit 1 with nothing on stdout). It reads stdin only for config:import with no file.
# Switches, as environment variables:
#   FAKE_STATUS_JSON    what status prints. "none" prints nothing at all
#   FAKE_STATUS_PRE     lines printed before it, and FAKE_STATUS_POST after it (the notices php prints)
#   FAKE_STATUS_RC      the exit status of status after it has printed
#   FAKE_STATUS_FAILS_FROM  every status call from the N-th on fails the way FAKE_OCC_DEAD does
#   FAKE_DB_HOST_OK     occ starts only while config.php's dbhost is this host. Otherwise every command fails the way
#                       the real occ does when it cannot reach the database
#   FAKE_OCC_DEAD       every command fails that way, whatever config.php says
#   FAKE_FAIL           commands whose arguments start with one of these (separated by |) fail. "*" is every command
#   FAKE_FAIL_ONCE      the same, but only the first call that matches fails, and the later ones work
#   FAKE_THROW          the same, but the way a command that throws on the way fails: the exception on stderr, exit 1,
#                       and nothing on stdout, so that it looks like a key that is not set unless --default-value is given
#   FAKE_UPGRADE_FAILS  upgrade fails with exit status 5, as it does when an app breaks it
#   FAKE_IMPORT_HANGS   config:import waits 5 s after it has read its file
#   FAKE_STDERR_NOTICE  every command first prints on stderr the two lines the real occ prints while an upgrade is pending
#   FAKE_TRUSTED_OUT    what `config:system:get trusted_domains --output=json` prints
#   FAKE_APPS_ON_DISK   apps (separated by |) that are on disk and disabled when the run starts, as an app that an
#                       earlier install left in custom_apps/ is
#   FAKE_HANG           commands whose arguments start with one of these (separated by |) wait 30 s before they do
#                       anything, as an app download from a host that stalls does. One that lives that long then runs
#                       as usual. maintenance:repair waits after it has turned maintenance on instead, as a slow repair
#                       step does. With FAKE_HANG_IGNORES_TERM set, the wait ignores SIGTERM (it needs php -d
#                       extension=pcntl in OCC, because -n loads no extensions)
# A command that starts while memcache.distributed or memcache.locking is \OC\Memcache\Redis and redis has no host adds
# a line to $LOG.nclog and then runs as usual. The real occ does the same: it connects to 127.0.0.1:6379 while it boots,
# logs "Could not boot ...: Connection refused" to nextcloud.log at level 4, and still exits 0 (probed on a first start).
fake_occ() {
  mkdir -p "$1"
  cat > "$1/occ.php" <<'PHP'
<?php
$args = array_slice($_SERVER['argv'], 1);
$log = (string) getenv('LOG');
$confFile = (string) getenv('NC_FAKE_CONFIG');
file_put_contents($log, implode(' ', $args) . "\n", FILE_APPEND);
// two more lines per call, in step with the log: how many private files (NC_TMP_DIR/db.*) exist when the call starts,
// and the HOME the call runs with
$tmpDir = (string) getenv('NC_TMP_DIR');
file_put_contents($log . '.tmp', count($tmpDir === '' ? [] : (glob($tmpDir . '/db.*') ?: [])) . "\n", FILE_APPEND);
file_put_contents($log . '.home', (string) getenv('HOME') . "\n", FILE_APPEND);

function out(string $s): void
{
    echo $s, "\n";
}
function stop(string $s, int $rc = 1): never
{
    out($s);
    exit($rc);
}
function usage_error(string $s): never
{
    fwrite(STDERR, $s . "\n");
    exit(1);
}
function conf_load(): array
{
    global $confFile;
    $CONFIG = [];
    if (is_file($confFile)) {
        include $confFile;
    }
    return is_array($CONFIG) ? $CONFIG : [];
}
function conf_save(array $c): void
{
    global $confFile;
    file_put_contents($confFile, "<?php\n\$CONFIG = " . var_export($c, true) . ";\n");
}
// The apps on disk, kept in $LOG.apps for the rest of the run. The first call of the run writes the starting state there:
// the apps in FAKE_APPS_ON_DISK, disabled.
function apps_load(): array
{
    global $log;
    if (is_file($log . '.apps')) {
        return (array) json_decode((string) file_get_contents($log . '.apps'), true);
    }
    $apps = [];
    foreach (array_filter(explode('|', (string) getenv('FAKE_APPS_ON_DISK')), 'strlen') as $app) {
        $apps[$app] = 'disabled';
    }
    apps_save($apps);
    return $apps;
}
function apps_save(array $apps): void
{
    global $log;
    file_put_contents($log . '.apps', json_encode($apps));
}
// The app config (oc_appconfig): {"APP": {"KEY": "VALUE"}} in $NC_FAKE_APPCONFIG. Like config.php, it lasts from one run
// to the next.
function appconfig_load(): array
{
    $file = (string) getenv('NC_FAKE_APPCONFIG');
    return is_file($file) ? (array) json_decode((string) file_get_contents($file), true) : [];
}
function appconfig_save(array $c): void
{
    file_put_contents((string) getenv('NC_FAKE_APPCONFIG'), json_encode($c));
}

$opts = [];
$pos = [];
foreach ($args as $a) {
    if (in_array($a, ['-n', '--no-interaction', '--no-warnings'], true)) {
        continue;
    }
    if (preg_match('/^--([a-z-]+)(?:=(.*))?$/s', $a, $m)) {
        $opts[$m[1]] = $m[2] ?? true;
        continue;
    }
    $pos[] = $a;
}
$cmd = $pos[0] ?? '';
$known = [
    'status' => ['output'],
    'config:system:get' => ['output', 'default-value'],
    'config:system:set' => ['output', 'type', 'value', 'update-only'],
    'config:system:delete' => ['error-if-not-exists'],
    'config:import' => [],
    'config:app:get' => ['output', 'default-value', 'details', 'key-details'],
    'config:app:set' => ['output', 'type', 'value', 'lazy', 'sensitive', 'update-only'],
    'config:app:delete' => ['error-if-not-exists'],
    'upgrade' => [],
    'maintenance:mode' => ['on', 'off'],
    'maintenance:repair' => ['include-expensive'],
    'background:cron' => [],
    'user:setting' => ['output', 'delete', 'default-value', 'update-only', 'error-if-not-exists'],
    'app:install' => [],
    'app:getpath' => [],
    'app:enable' => [],
    'app:disable' => [],
    'db:add-missing-indices' => [],
    'db:add-missing-columns' => [],
    'db:add-missing-primary-keys' => [],
];

// occ cannot start when it cannot reach the database: not even config:system:get works.
$conf = conf_load();
$host = (string) ($conf['dbhost'] ?? '');
$okHost = (string) getenv('FAKE_DB_HOST_OK');
$failsFrom = (int) getenv('FAKE_STATUS_FAILS_FROM');
$statusCalls = 0;
if ($failsFrom > 0 && $cmd === 'status') {
    foreach (explode("\n", (string) file_get_contents($log)) as $l) {
        if (str_starts_with($l, 'status')) {
            $statusCalls++;
        }
    }
}
if ((string) getenv('FAKE_OCC_DEAD') !== '' || ($okHost !== '' && $host !== $okHost) || ($failsFrom > 0 && $statusCalls >= $failsFrom)) {
    out('An unhandled exception has been thrown:');
    out('Doctrine\DBAL\Exception: Failed to connect to the database: An exception occurred in the driver: SQLSTATE[HY000] [2002] php_network_getaddresses: getaddrinfo for ' . $host . ' failed: Temporary failure in name resolution in /var/www/html/lib/private/DB/Connection.php:236');
    out('Stack trace:');
    out("#0 /var/www/html/3rdparty/doctrine/dbal/src/Connection.php(458): OC\\DB\\Connection->connect()");
    exit(1);
}
$cacheOnRedis = in_array('\\OC\\Memcache\\Redis', [$conf['memcache.distributed'] ?? null, $conf['memcache.locking'] ?? null], true);
if ($cacheOnRedis && !isset($conf['redis']['host'])) {
    file_put_contents($log . '.nclog', 'Could not boot: Connection refused (127.0.0.1:6379), during: ' . implode(' ', $args) . "\n", FILE_APPEND);
}
if ((string) getenv('FAKE_STDERR_NOTICE') !== '') {
    fwrite(STDERR, "Nextcloud or one of the apps require upgrade - only a limited number of commands are available\nYou may use your browser or the occ upgrade command to do the upgrade\n");
}
if (!isset($known[$cmd])) {
    usage_error("Command \"$cmd\" is not defined.");
}
foreach (array_keys($opts) as $o) {
    if (!in_array($o, $known[$cmd], true)) {
        usage_error("The \"--$o\" option does not exist.");
    }
}
$line = implode(' ', $args);
foreach (array_filter(explode('|', (string) getenv('FAKE_FAIL')), 'strlen') as $prefix) {
    if ($prefix === '*' || str_starts_with($line, $prefix)) {
        stop("Error: the fake occ was told to fail on \"$prefix\"");
    }
}
foreach (array_filter(explode('|', (string) getenv('FAKE_THROW')), 'strlen') as $prefix) {
    if (str_starts_with($line, $prefix)) {
        fwrite(STDERR, "In AppConfig.php line 1234:\n  An exception occurred while executing a query: the fake occ was told to throw on \"$prefix\"\n");
        exit(1);
    }
}
foreach (array_filter(explode('|', (string) getenv('FAKE_FAIL_ONCE')), 'strlen') as $prefix) {
    if (str_starts_with($line, $prefix)) {
        // The log already has this call, so it is the first one when the log has one line that matches.
        $seen = count(array_filter(explode("\n", (string) file_get_contents($log)), fn (string $l): bool => str_starts_with($l, $prefix)));
        if ($seen === 1) {
            stop("Error: the fake occ was told to fail once on \"$prefix\"");
        }
    }
}
// fake_hang: the wait of FAKE_HANG. maintenance:repair does it after it has turned maintenance on.
function fake_hang(): void
{
    if ((string) getenv('FAKE_HANG_IGNORES_TERM') !== '' && function_exists('pcntl_signal')) {
        pcntl_signal(SIGTERM, SIG_IGN);
    }
    sleep(30);
}
$hangs = false;
foreach (array_filter(explode('|', (string) getenv('FAKE_HANG')), 'strlen') as $prefix) {
    if (str_starts_with($line, $prefix)) {
        $hangs = true;
        break;
    }
}
if ($hangs && $cmd !== 'maintenance:repair') {
    fake_hang();
}

$names = array_slice($pos, 1);
switch ($cmd) {
    case 'status':
        foreach (explode("\n", (string) getenv('FAKE_STATUS_PRE')) as $l) {
            if ($l !== '') {
                out($l);
            }
        }
        $json = getenv('FAKE_STATUS_JSON');
        if ($json === 'live') {
            // core/Command/Status.php: the version is the code's, and an upgrade is needed while config.php has an older one
            out(json_encode([
                'installed' => (bool) ($conf['installed'] ?? false),
                'version' => '35.0.2.2',
                'versionstring' => '35.0.2',
                'edition' => '',
                'maintenance' => (bool) ($conf['maintenance'] ?? false),
                'needsDbUpgrade' => isset($conf['version']) && version_compare((string) $conf['version'], '35.0.2.2', '<'),
                'productname' => 'Nextcloud',
                'extendedSupport' => false,
            ]));
        } elseif ($json === 'none') {
            // prints nothing
        } elseif ($json === false || $json === '') {
            out('{"installed":true,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","maintenance":false,"needsDbUpgrade":false,"productname":"Nextcloud","extendedSupport":false}');
        } else {
            out($json);
        }
        foreach (explode("\n", (string) getenv('FAKE_STATUS_POST')) as $l) {
            if ($l !== '') {
                out($l);
            }
        }
        exit((int) getenv('FAKE_STATUS_RC'));

    case 'config:system:get':
        if (!$names) {
            usage_error('Not enough arguments (missing: "name").');
        }
        $name = array_shift($names);
        if ($name === 'trusted_domains' && ($opts['output'] ?? '') === 'json' && getenv('FAKE_TRUSTED_OUT') !== false) {
            out((string) getenv('FAKE_TRUSTED_OUT'));
            break;
        }
        $hasDefault = array_key_exists('default-value', $opts);
        $default = $hasDefault && $opts['default-value'] !== true ? (string) $opts['default-value'] : '';
        if (!array_key_exists($name, $conf)) {
            if (!$hasDefault) {
                exit(1);
            }
            $val = $default;
        } else {
            $val = $conf[$name];
            foreach ($names as $n) {
                if (is_array($val) && isset($val[$n])) {
                    $val = $val[$n];
                } elseif (!$hasDefault) {
                    exit(1);
                } else {
                    $val = $default;
                    break;
                }
            }
        }
        if (($opts['output'] ?? 'plain') === 'json') {
            out(json_encode($val));
        } elseif (is_array($val)) {
            foreach ($val as $v) {
                out(is_array($v) ? json_encode($v) : (string) $v);
            }
        } else {
            out(is_bool($val) ? ($val ? 'true' : 'false') : (string) $val);
        }
        break;

    case 'config:system:set':
        if (!$names) {
            usage_error('Not enough arguments (missing: "name").');
        }
        $type = (string) ($opts['type'] ?? 'string');
        $raw = isset($opts['value']) && $opts['value'] !== true ? (string) $opts['value'] : '';
        if ($type === 'string') {
            $val = $raw;
        } elseif ($type === 'integer') {
            if (!is_numeric($raw)) {
                usage_error('Non-numeric value specified');
            }
            $val = (int) $raw;
        } elseif ($type === 'boolean') {
            if ($raw !== 'true' && $raw !== 'false') {
                usage_error('Unable to parse value as boolean');
            }
            $val = $raw === 'true';
        } else {
            usage_error("Invalid type $type");
        }
        $path = $names;
        $name = array_shift($names);
        if ($names) {
            $existing = $conf[$name] ?? [];
            if (!is_array($existing)) {
                $existing = [];
            }
            $ref = &$existing;
            $last = array_key_last($names);
            foreach ($names as $i => $n) {
                if ($i === $last) {
                    $ref[$n] = $val;
                } else {
                    if (!isset($ref[$n]) || !is_array($ref[$n])) {
                        $ref[$n] = [];
                    }
                    $ref = &$ref[$n];
                }
            }
            unset($ref);
            $conf[$name] = $existing;
        } else {
            $conf[$name] = $val;
        }
        conf_save($conf);
        $sensitive = in_array($path[0], ['dbpassword', 'secret', 'passwordsalt', 'mail_smtppassword'], true)
            || ($path[0] === 'redis' && in_array($path[1] ?? '', ['host', 'password'], true));
        if ($sensitive) {
            $shown = '***REMOVED SENSITIVE VALUE***';
        } elseif ($raw === '' && $type === 'string') {
            $shown = 'empty string';
        } else {
            $shown = $type . ' ' . ($type === 'boolean' ? ($val ? 'true' : 'false') : $raw);
        }
        out('System config value ' . implode(' => ', $path) . ' set to ' . $shown);
        break;

    case 'config:system:delete':
        if (!$names) {
            usage_error('Not enough arguments (missing: "name").');
        }
        $path = $names;
        $name = array_shift($names);
        if ($names) {
            $ref = &$conf[$name];
            $last = array_key_last($names);
            foreach ($names as $i => $n) {
                if (!is_array($ref)) {
                    break;
                }
                if ($i === $last) {
                    unset($ref[$n]);
                } else {
                    $ref = &$ref[$n];
                }
            }
            unset($ref);
        } else {
            unset($conf[$name]);
        }
        conf_save($conf);
        out('System config value ' . implode(' => ', $path) . ' deleted');
        break;

    case 'config:import':
        $file = $names[0] ?? null;
        if ($file === null) {
            $content = (string) stream_get_contents(STDIN);
        } else {
            $content = @file_get_contents($file);
            if ($content === false) {
                $content = '';
            } else {
                copy($file, $log . '.import');
                file_put_contents($log . '.import.mode', decoct(fileperms($file) & 0777));
                if ((string) getenv('FAKE_IMPORT_HANGS') !== '') {
                    sleep(5);
                }
            }
        }
        $data = json_decode($content, true);
        if (!is_array($data) || !$data) {
            stop('The file must contain a valid json array');
        }
        $bad = array_diff(array_keys($data), ['system', 'apps']);
        if ($bad) {
            stop('Found invalid entries in root: ' . implode(', ', $bad));
        }
        foreach ($data['system'] ?? [] as $k => $v) {
            if ($v === null) {
                unset($conf[$k]);
            } else {
                $conf[$k] = $v;
            }
        }
        conf_save($conf);
        out('Config successfully imported from: ' . $file);
        break;

    case 'config:app:get':
        if (count($names) < 2) {
            usage_error('Not enough arguments (missing: "name").');
        }
        $apps = appconfig_load();
        if (!isset($apps[$names[0]][$names[1]])) {
            if (!array_key_exists('default-value', $opts)) {
                exit(1);
            }
            $val = $opts['default-value'] === true ? '' : (string) $opts['default-value'];
        } else {
            $val = (string) $apps[$names[0]][$names[1]];
        }
        out(($opts['output'] ?? 'plain') === 'json' ? json_encode($val) : $val);
        break;

    case 'config:app:set':
        if (count($names) < 2) {
            usage_error('Not enough arguments (missing: "name").');
        }
        if (!isset($opts['value']) || $opts['value'] === true) {
            usage_error('The fake occ only sets values given with --value=');
        }
        $apps = appconfig_load();
        $apps[$names[0]][$names[1]] = (string) $opts['value'];
        appconfig_save($apps);
        out(sprintf("Config value '%s' for app '%s' is now set to '%s', stored as mixed in %s", $names[1], $names[0],
            $opts['value'], isset($opts['lazy']) ? 'lazy cache' : 'fast cache'));
        break;

    case 'config:app:delete':
        if (count($names) < 2) {
            usage_error('Not enough arguments (missing: "name").');
        }
        $apps = appconfig_load();
        unset($apps[$names[0]][$names[1]]);
        appconfig_save($apps);
        out("Config value {$names[1]} of app {$names[0]} deleted");
        break;

    case 'maintenance:repair':
        // Repair::execute(): maintenance on for the run, and the value it found put back only at its end
        $wasOn = (bool) ($conf['maintenance'] ?? false);
        $conf['maintenance'] = true;
        conf_save($conf);
        out(' - Repair mime types');
        if ($hangs) {
            fake_hang();
        }
        if ((string) getenv('FAKE_REPAIR_CRASHES') !== '') {
            out('An unhandled exception has been thrown:');
            out('TypeError: an app repair step failed in /var/www/html/custom_apps/broken/lib/Step.php:12');
            exit(1);
        }
        $conf = conf_load();
        $conf['maintenance'] = $wasOn;
        conf_save($conf);
        if ((string) getenv('FAKE_REPAIR_ERRORS') !== '') {
            out('     - ERROR: a repair step reported an error');
            exit(1);
        }
        break;

    case 'maintenance:mode':
        if (isset($opts['on'])) {
            $conf['maintenance'] = true;
            conf_save($conf);
            out('Maintenance mode enabled');
        } elseif (isset($opts['off'])) {
            $conf['maintenance'] = false;
            conf_save($conf);
            out('Maintenance mode disabled');
        }
        break;

    case 'upgrade':
        // Updater::upgrade(): the level it found and whether maintenance was on decide how it leaves config.php.
        $level = $conf['loglevel'] ?? 2;
        $wasOn = (bool) ($conf['maintenance'] ?? false);
        $conf['loglevel'] = 0;
        out('Setting log level to debug');
        if (!$wasOn) {
            $conf['maintenance'] = true;
            out('Turned on maintenance mode');
        }
        conf_save($conf);
        $ok = (string) getenv('FAKE_UPGRADE_FAILS') === '';
        out($ok ? 'Update successful' : 'Update failed');
        if ($ok) {
            $conf['version'] = '35.0.2.2';
        }
        if (!$wasOn && $ok) {
            $conf['maintenance'] = false;
            out('Turned off maintenance mode');
        } else {
            out('Maintenance mode is kept active');
        }
        $conf['loglevel'] = $level;
        out('Resetting log level');
        conf_save($conf);
        if (!$ok) {
            exit(5);
        }
        break;

    case 'app:install':
        $app = $names[0] ?? usage_error('Not enough arguments (missing: "app-id").');
        $apps = apps_load();
        if (isset($apps[$app])) {
            stop("$app already installed");
        }
        $apps[$app] = 'enabled';
        apps_save($apps);
        out("$app 1.0.0 installed");
        out("$app enabled");
        break;

    case 'app:getpath':
        $app = $names[0] ?? usage_error('Not enough arguments (missing: "app").');
        if (!isset(apps_load()[$app])) {
            exit(1);
        }
        out("/var/www/html/custom_apps/$app");
        break;

    case 'app:enable':
        $app = $names[0] ?? usage_error('Not enough arguments (missing: "app-id").');
        $apps = apps_load();
        if (($apps[$app] ?? '') === 'enabled') {
            out("$app already enabled");
            break;
        }
        $apps[$app] = 'enabled';
        apps_save($apps);
        out("$app 1.0.0 enabled");
        break;

    default:
        // the other commands do their work without any state the scripts read back
        break;
}
PHP
}

# fake_flock DIR: writes DIR/flock. `flock FILE COMMAND...` logs "flock FILE COMMAND..." to $LOG, runs the command, logs
# "flock released" and exits with the command's status, as the real one does. It knows only that form: any option is an
# error, so a script that asks for -n or -w is caught. With FAKE_FLOCK_FAILS=66 it fails as the real one does when it
# cannot open the lock file, without running the command.
fake_flock() {
  fake_cmd "$1" flock <<'EOF'
case "${1-}" in
  -* | '') echo "fake flock: expected FILE COMMAND..., got: $*" >&2; exit 64 ;;
esac
echo "flock $*" >> "$LOG"
if [ -n "${FAKE_FLOCK_FAILS-}" ]; then
  echo "flock: cannot open lock file $1: Permission denied" >&2
  exit "$FAKE_FLOCK_FAILS"
fi
shift
"$@"
rc=$?
echo "flock released" >> "$LOG"
exit "$rc"
EOF
}

# nc_world DIR: a fresh world for one section. NCW is its directory, NCW_LOG the log the fakes write to, NCW_CONF the
# config.php both the fake occ and the scripts' own repair read, NCW_APPCONFIG the fake's app config, and NCW_ENV the
# environment every run starts from: what the platform and the root entrypoint give the scripts, with the fakes first on
# PATH. The two PHP_ variables are the image's own. Without them its php.ini expands to nothing and every php prints a
# memory limit warning. The app config starts with the two markers of an instance whose first install and last upgrade
# both finished (MARKERS_DONE), as on any instance after its first start. A section about a marker sets them with
# appcfg_reset.
nc_world() {
  NCW="$1"
  rm -rf "$NCW"
  mkdir -p "$NCW/bin" "$NCW/tmp" "$NCW/conf"
  chmod 700 "$NCW/tmp"
  fake_occ "$NCW/bin"
  fake_flock "$NCW/bin"
  NCW_LOG="$NCW/log"
  NCW_CONF="$NCW/conf/config.php"
  NCW_APPCONFIG="$NCW/appconfig.json"
  appcfg_reset "$MARKERS_DONE"
  : > "$NCW_LOG"
  # shellcheck disable=SC2031  # with_path and with_only_path change PATH in subshells on purpose; this shell's PATH is what is extended
  NCW_ENV=(
    "PATH=$NCW/bin:$PATH"
    "OCC=php -n -d display_errors=stderr $NCW/bin/occ.php"
    "LOG=$NCW_LOG"
    "NC_FAKE_CONFIG=$NCW_CONF"
    "NC_FAKE_APPCONFIG=$NCW_APPCONFIG"
    "NC_CONFIG_FILE=$NCW_CONF"
    "NC_TMP_DIR=$NCW/tmp"
    "PHP_MEMORY_LIMIT=512M"
    "PHP_UPLOAD_LIMIT=512M"
    "NEXTCLOUD_URL=https://abc.clouve.app"
    "NEXTCLOUD_DB_HOST=tkt-7-nextcloud-mariadb"
    "NEXTCLOUD_DB_NAME=nextcloud"
    "NEXTCLOUD_DB_USER=nextcloud"
    "NEXTCLOUD_DB_PASSWORD=s3cret"
  )
}

# env_merge BASE_ARRAY_NAME ITEM...: sets MERGED to the array named BASE_ARRAY_NAME, with NAME=VALUE items added or
# replaced and -NAME items removed.
env_merge() {
  local -n base="$1"
  local item e skip
  shift
  MERGED=()
  for e in "${base[@]}"; do
    skip=''
    for item in "$@"; do
      if [[ "$item" == -* && "${e%%=*}" == "${item#-}" ]]; then skip=1; fi
    done
    if [[ -z "$skip" ]]; then MERGED+=("$e"); fi
  done
  for item in "$@"; do
    if [[ "$item" != -* ]]; then MERGED+=("$item"); fi
  done
}

# nc_run SCRIPT [NAME=VALUE | -NAME]...: runs SCRIPT the way the official entrypoint runs a hook ("sh -c <path>"), in a
# clean environment: NCW_ENV, with NAME=VALUE added or replaced and -NAME removed. stdin is /dev/null, and a script that
# hangs is stopped after 2 minutes. Afterwards NC_RC, NC_OUT and NC_ERR hold its exit status, stdout and stderr, and the
# log (and the fake's apps on disk) starts over for the next run. SCRIPT may be a short shell command (`umask 0; /path/script`).
# With NC_RUN_KILL=N in front of it, SCRIPT and everything it started get SIGKILL after N seconds instead, as they do in a
# container that is killed in the middle of a start. NC_RC is then 137.
nc_run() {
  local script="$1"
  local -a limit=(120)
  shift
  if [[ -n "${NC_RUN_KILL:-}" ]]; then limit=(-s KILL "$NC_RUN_KILL"); fi
  env_merge NCW_ENV "$@"
  : > "$NCW_LOG"
  rm -f "$NCW_LOG.import" "$NCW_LOG.import.mode" "$NCW_LOG.tmp" "$NCW_LOG.php" "$NCW_LOG.home" "$NCW_LOG.apps" "$NCW_LOG.nclog" "$NCW_LOG.timeout"
  # The braces' 2>/dev/null takes bash's own "Killed" notice for an NC_RUN_KILL run. The script's stderr is in $NCW/err.
  { env -i "${MERGED[@]}" timeout "${limit[@]}" sh -c "$script" </dev/null >"$NCW/out" 2>"$NCW/err"; } 2>/dev/null
  NC_RC=$?
  NC_OUT="$(cat "$NCW/out")"
  NC_ERR="$(cat "$NCW/err")"
}

# fake_php_log DIR: writes DIR/php, a php that appends its arguments to $LOG.php and exits 1. Put it first on PATH to see
# which php command line a script runs, apart from the ones in the scripts it calls.
fake_php_log() {
  fake_cmd "$1" php <<'EOF'
echo "$*" >> "$LOG.php"
exit 1
EOF
}

# cfg_reset JSON: starts the world's config.php over with these keys.
# shellcheck disable=SC2016  # PHP code, not shell
cfg_reset() {
  php -n -r 'file_put_contents($argv[2], "<?php\n\$CONFIG = " . var_export(json_decode($argv[1], true), true) . ";\n");' -- "$1" "$NCW_CONF"
}

# cfg_get KEY: the value of a key in the world's config.php as JSON (strings in quotes, so 0 and "0" differ), or <unset>.
# shellcheck disable=SC2016  # PHP code, not shell
cfg_get() {
  php -n -r '$CONFIG = []; include $argv[1]; echo array_key_exists($argv[2], $CONFIG) ? json_encode($CONFIG[$argv[2]], JSON_UNESCAPED_SLASHES) : "<unset>";' -- "$NCW_CONF" "$1"
}

# The two markers, as the app config holds them once the first install's own settings all went in
# (clouve first_install_done, the UTC time) and the post-upgrade steps for the code's version ran to their end
# (clouve post_upgrade_done, the version).
MARKERS_DONE='{"clouve":{"first_install_done":"2026-10-23T08:00:00Z","post_upgrade_done":"35.0.2.2"}}'
# Only the first-install marker: an instance whose post-upgrade steps were cut off.
FIRST_INSTALL_ONLY='{"clouve":{"first_install_done":"2026-10-23T08:00:00Z"}}'
# How the first-install marker's value looks: the UTC time in ISO 8601, to the second.
ISO_UTC_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# appcfg_reset JSON: starts the world's app config over with these values ({"APP": {"KEY": "VALUE"}}).
appcfg_reset() { printf '%s' "$1" > "$NCW_APPCONFIG"; }

# appcfg_get APP KEY: the value in the world's app config, or <unset>.
# shellcheck disable=SC2016  # PHP code, not shell
appcfg_get() {
  php -n -r '$c = is_file($argv[1]) ? (array) json_decode((string) file_get_contents($argv[1]), true) : []; echo isset($c[$argv[2]][$argv[3]]) ? $c[$argv[2]][$argv[3]] : "<unset>";' -- "$NCW_APPCONFIG" "$1" "$2"
}

# fake_apps: the fake occ's apps on disk after the last run, as JSON sorted by app ({"APP":"enabled"}), or {} for none.
# shellcheck disable=SC2016  # PHP code, not shell
fake_apps() {
  php -n -r '$a = is_file($argv[1]) ? (array) json_decode((string) file_get_contents($argv[1]), true) : []; ksort($a); echo json_encode((object) $a);' -- "$NCW_LOG.apps"
}

# log_starting PREFIX: the lines of the log that start with PREFIX.
log_starting() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == "$1"* ]]; then printf '%s\n' "$line"; fi
  done < "$NCW_LOG"
}

# show_log: the log, indented, for the output of a failed check.
show_log() { sed 's/^/         | /' "$NCW_LOG"; }

# logged LINE [LABEL]: the log has exactly this line.
logged() {
  if grep -qxF -- "$1" "$NCW_LOG"; then
    pass "${2:-logged: $1}"
  else
    fail "${2:-logged: $1}"
    printf '       not in the log: %q\n' "$1"
    show_log
  fi
}

# logged_re REGEX [LABEL]: the log has a line that is all of the extended regular expression.
logged_re() {
  if grep -qxE -- "$1" "$NCW_LOG"; then
    pass "${2:-logged: $1}"
  else
    fail "${2:-logged: $1}"
    printf '       nothing in the log matches: %s\n' "$1"
    show_log
  fi
}

# not_logged PREFIX [LABEL]: no line of the log starts with PREFIX.
not_logged() {
  local found
  found="$(log_starting "$1")"
  if [[ -z "$found" ]]; then
    pass "${2:-not in the log: $1}"
  else
    fail "${2:-not in the log: $1}"
    printf '       found: %q\n' "$found"
  fi
}

# logged_in_order LABEL REGEX...: lines matching the expressions are in the log in this order. Other lines may lie
# between them. Each expression has to match a whole line.
logged_in_order() {
  local label="$1" want from=1 n
  shift
  for want in "$@"; do
    n="$(tail -n +"$from" "$NCW_LOG" | grep -nxE -- "$want" | head -n 1 | cut -d: -f1)"
    if [[ -z "$n" ]]; then
      fail "$label"
      printf '       not in the log after line %s: %s\n' "$((from - 1))" "$want"
      show_log
      return 0
    fi
    from=$((from + n))
  done
  pass "$label"
}

# home_is DIR [LABEL]: the last run made at least one occ call, and every one of them ran with HOME=DIR.
home_is() {
  local calls bad
  calls="$(wc -l < "$NCW_LOG.home" 2>/dev/null || echo 0)"
  bad="$(grep -vxF -- "$1" "$NCW_LOG.home" 2>/dev/null | sort -u | tr '\n' ' ')"
  if [[ "$calls" -gt 0 && -z "$bad" ]]; then
    pass "${2:-every occ call runs with HOME=$1}"
  else
    fail "${2:-every occ call runs with HOME=$1}"
    printf '       %s occ calls; HOME was also: %q\n' "$calls" "$bad"
  fi
}

# no_secret WORD LABEL: WORD is in none of stdout, stderr and the log. The log holds only the arguments the fake occ was
# called with. (The copy of an imported file, $LOG.import, is where a secret is allowed to be.)
no_secret() {
  local word="$1" where='' f
  for f in "$NCW/out" "$NCW/err" "$NCW_LOG"; do
    if grep -qF -- "$word" "$f"; then where="$where ${f##*/}"; fi
  done
  eq '' "$where" "${2:-$word appears in no output and no argument}"
}

# no_secret_in TEXT LABEL WORD...: none of the WORDs is in TEXT. A word may hold spaces.
no_secret_in() {
  local text="$1" label="$2" w hit=''
  shift 2
  for w in "$@"; do
    if [[ "$text" == *"$w"* ]]; then hit="$hit [$w]"; fi
  done
  eq '' "$hit" "$label"
}

# need_script PATH: the script exists and is executable. Otherwise the section records one failure and the caller returns.
need_script() {
  if [[ -x "$1" ]]; then return 0; fi
  fail "$(basename "$1") is missing or not executable: $1"
  return 1
}

# --- nextcloud-config.sh: the URL, the scheme and trusted_domains ----------------
# One deployment's life: a first start, the same again, a custom domain, back to the Clouve host, then a local http URL.
# The state carries over from one run to the next, as a restarting deployment's config.php does.
section_config_urls() {
  local before after
  need_script "$CONFIG_SH" || return 0
  nc_world "$WORK/w-urls"
  cfg_reset '{"overwrite.cli.url":"http://localhost","trusted_domains":["localhost"]}'

  echo ' first start: https://abc.clouve.app, and the database has none of the settings yet'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  eq '[nextcloud] Nextcloud URL has changed: http://localhost -> https://abc.clouve.app' "$(grep 'URL has changed' <<<"$NC_OUT")" 'stdout has the URL change line, once, in its exact form'
  logged 'config:system:set overwrite.cli.url --value=https://abc.clouve.app' 'overwrite.cli.url is set to the new URL'
  logged 'config:system:set overwriteprotocol --value=https' 'https: overwriteprotocol is set to https'
  logged 'config:system:set trusted_domains 1 --value=abc.clouve.app' 'the new host is added after localhost, at index 1'
  eq '"https://abc.clouve.app"' "$(cfg_get overwrite.cli.url)" 'config.php: overwrite.cli.url'
  eq '"https"' "$(cfg_get overwriteprotocol)" 'config.php: overwriteprotocol'
  eq '["localhost","abc.clouve.app"]' "$(cfg_get trusted_domains)" 'config.php: trusted_domains'
  eq '["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"]' "$(cfg_get trusted_proxies)" 'config.php: trusted_proxies are the three private ranges'
  eq '"\\OC\\Memcache\\Redis"' "$(cfg_get memcache.distributed)" 'config.php: memcache.distributed'
  eq '"\\OC\\Memcache\\Redis"' "$(cfg_get memcache.locking)" 'config.php: memcache.locking'
  eq '{"host":"/run/clouve/valkey/valkey.sock","port":0}' "$(cfg_get redis)" 'config.php: redis is the Valkey socket, with port 0 as an integer'
  # shellcheck disable=SC2016  # PHP code, not shell
  eq "$(awk '$1 == "unixsocket" { print $2 }' "$INSTALLER/valkey.conf")" "$(php -n -r '$CONFIG = []; include $argv[1]; echo $CONFIG["redis"]["host"] ?? "";' -- "$NCW_CONF")" 'the redis host is the socket that valkey.conf makes'
  eq '<unset>' "$(cfg_get preview_concurrency_new)" 'config.php: no preview concurrency without the environment variables'
  eq '"tkt-7-nextcloud-mariadb"' "$(cfg_get dbhost)" 'config.php: dbhost'
  eq '"s3cret"' "$(cfg_get dbpassword)" 'config.php: dbpassword'
  logged_in_order 'the steps run in order: database, URL, scheme, trusted domains, proxies, cache' \
    'status --output=json' 'config:system:get dbpassword' 'config:import .*' 'config:system:get overwrite.cli.url' \
    'config:system:set overwrite.cli.url .*' 'config:system:set overwriteprotocol .*' 'config:system:get trusted_domains --output=json' \
    'config:system:set trusted_domains 1 .*' 'config:system:set trusted_proxies 0 .*' \
    'config:system:set redis host --value=/run/clouve/valkey/valkey.sock' 'config:system:set redis port --type=integer --value=0' \
    'config:system:set memcache.distributed .*' 'config:system:set memcache.locking .*'
  eq '' "$(cat "$NCW_LOG.nclog" 2>/dev/null)" 'the Valkey socket is set before the cache classes: no occ call starts with the cache on Redis and no socket (the real one logs "Connection refused" errors then)'
  contains '[nextcloud] database settings updated' "$NC_OUT" 'stdout says the database settings were updated'
  contains '[nextcloud] trusted_domains: added abc.clouve.app at index 1' "$NC_OUT" 'stdout says which host was added, and where'
  no_secret s3cret 's3cret appears in no output and no argument'

  echo ' the same environment again: nothing changes'
  before="$(md5sum < "$NCW_CONF")"
  nc_run "$CONFIG_SH"
  after="$(md5sum < "$NCW_CONF")"
  eq 0 "$NC_RC" 'exit status 0'
  lacks 'URL has changed' "$NC_OUT" 'no URL change line'
  lacks 'database settings updated' "$NC_OUT" 'no database line'
  not_logged 'config:import' 'no config:import'
  not_logged 'config:system:set trusted_domains' 'no trusted_domains set'
  not_logged 'config:system:set trusted_proxies' 'no trusted_proxies set'
  not_logged 'config:system:set overwrite.cli.url' 'no overwrite.cli.url set'
  eq "$before" "$after" 'config.php is byte for byte the same after the run'
  eq '' "$NC_ERR" 'nothing on stderr'

  echo ' a custom domain: https://cloud.example.com'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=https://cloud.example.com
  eq 0 "$NC_RC" 'exit status 0'
  eq '[nextcloud] Nextcloud URL has changed: https://abc.clouve.app -> https://cloud.example.com' "$(grep 'URL has changed' <<<"$NC_OUT")" 'the change line names the old and the new URL'
  logged 'config:system:set trusted_domains 2 --value=cloud.example.com' 'the custom domain goes to index 2'
  eq '["localhost","abc.clouve.app","cloud.example.com"]' "$(cfg_get trusted_domains)" 'the Clouve host is still trusted'
  eq '"https"' "$(cfg_get overwriteprotocol)" 'overwriteprotocol is still https'
  not_logged 'config:import' 'the database settings are not imported again'

  echo ' back to the Clouve host: https://abc.clouve.app'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  eq '[nextcloud] Nextcloud URL has changed: https://cloud.example.com -> https://abc.clouve.app' "$(grep 'URL has changed' <<<"$NC_OUT")" 'the change line is logged again'
  not_logged 'config:system:set trusted_domains' 'no host is added again'
  eq '["localhost","abc.clouve.app","cloud.example.com"]' "$(cfg_get trusted_domains)" 'both hosts are still trusted'
  eq '"https://abc.clouve.app"' "$(cfg_get overwrite.cli.url)" 'overwrite.cli.url is the Clouve host again'

  echo ' a local http URL: http://t1.test.clv:8080'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=http://t1.test.clv:8080
  eq 0 "$NC_RC" 'exit status 0'
  eq '[nextcloud] Nextcloud URL has changed: https://abc.clouve.app -> http://t1.test.clv:8080' "$(grep 'URL has changed' <<<"$NC_OUT")" 'the change line'
  logged 'config:system:delete overwriteprotocol' 'http: overwriteprotocol is deleted'
  logged 'config:system:set trusted_domains 3 --value=t1.test.clv' 'the host is added without its port'
  eq '<unset>' "$(cfg_get overwriteprotocol)" 'config.php: overwriteprotocol is gone'
  eq '["localhost","abc.clouve.app","cloud.example.com","t1.test.clv"]' "$(cfg_get trusted_domains)" 'all four hosts are trusted'

  echo ' and to https again: overwriteprotocol follows the scheme'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  eq '"https"' "$(cfg_get overwriteprotocol)" 'overwriteprotocol is https again'
  eq '["localhost","abc.clouve.app","cloud.example.com","t1.test.clv"]' "$(cfg_get trusted_domains)" 'no host is lost or added'

  echo ' a setting changed by hand is put back, even when the URL is the same'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","overwriteprotocol":"http","trusted_domains":["localhost","abc.clouve.app"]}'
  nc_run "$CONFIG_SH"
  not_logged 'config:system:set overwrite.cli.url' 'https: the URL is the same, so it is not set again'
  eq '"https"' "$(cfg_get overwriteprotocol)" 'https: overwriteprotocol is https again'
  cfg_reset '{"overwrite.cli.url":"http://t1.test.clv:8080","overwriteprotocol":"https","trusted_domains":["localhost","t1.test.clv"]}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=http://t1.test.clv:8080
  not_logged 'config:system:set overwrite.cli.url' 'http: the URL is the same, so it is not set again'
  eq '<unset>' "$(cfg_get overwriteprotocol)" 'http: overwriteprotocol is removed again'

  echo ' trusted_domains with gaps in its indexes'
  cfg_reset '{"overwrite.cli.url":"https://old.example.com","trusted_domains":{"0":"localhost","7":"kept.example"}}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=https://new.example.com
  eq 0 "$NC_RC" 'exit status 0'
  logged 'config:system:set trusted_domains 8 --value=new.example.com' 'the new host goes after the highest index, 7'
  eq '{"0":"localhost","7":"kept.example","8":"new.example.com"}' "$(cfg_get trusted_domains)" 'nothing is overwritten'

  echo ' trusted_domains with its keys out of order (a gap that was filled later)'
  cfg_reset '{"overwrite.cli.url":"https://old.example.com","trusted_domains":{"0":"localhost","4":"gap.example","2":"two.example"}}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=https://new.example.com
  logged 'config:system:set trusted_domains 5 --value=new.example.com' 'the new host goes after the highest index, 4, not after the last key, 2'
  eq '{"0":"localhost","4":"gap.example","2":"two.example","5":"new.example.com"}' "$(cfg_get trusted_domains)" 'nothing is overwritten'

  echo ' trusted_domains that is not set at all'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app"}'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  logged 'config:system:set trusted_domains 0 --value=localhost' 'localhost goes to index 0'
  logged 'config:system:set trusted_domains 1 --value=abc.clouve.app' 'the host goes to index 1'

  echo ' hosts already there, in other cases'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["LocalHost","ABC.Clouve.App"]}'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  not_logged 'config:system:set trusted_domains' 'upper case in the list: nothing is added'
  cfg_reset '{"overwrite.cli.url":"http://old.example","overwriteprotocol":"https","trusted_domains":["localhost"]}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=http://localhost
  eq 0 "$NC_RC" 'exit status 0'
  not_logged 'config:system:set trusted_domains' 'http://localhost: localhost is not added twice'
  eq '<unset>' "$(cfg_get overwriteprotocol)" 'http://localhost: overwriteprotocol is deleted'
  cfg_reset '{"overwrite.cli.url":"http://old.example"}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=http://localhost
  eq '["localhost"]' "$(cfg_get trusted_domains)" 'http://localhost on an empty list: localhost is added once'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=https://ABC.Clouve.App
  not_logged 'config:system:set trusted_domains' 'upper case in the URL: nothing is added'
  cfg_reset '{"overwrite.cli.url":"http://old.example","trusted_domains":["localhost"]}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL='http://[2001:db8::1]:8080/'
  logged 'config:system:set trusted_domains 1 --value=[2001:db8::1]' 'an IPv6 host is added with its brackets, without its port'

  echo ' overwrite.cli.url was never set'
  cfg_reset '{"trusted_domains":["localhost"]}'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  eq '[nextcloud] Nextcloud URL has changed:  -> https://abc.clouve.app' "$(grep 'URL has changed' <<<"$NC_OUT")" 'the old URL is empty in the change line'
  eq '"https://abc.clouve.app"' "$(cfg_get overwrite.cli.url)" 'and it is set'

  echo ' an environment without a usable URL'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","overwriteprotocol":"https"}'
  nc_run "$CONFIG_SH" -NEXTCLOUD_URL
  eq 0 "$NC_RC" 'NEXTCLOUD_URL unset: exit status 0'
  contains 'NEXTCLOUD_URL' "$NC_ERR" 'NEXTCLOUD_URL unset: a warning names the variable'
  eq '"https://abc.clouve.app"' "$(cfg_get overwrite.cli.url)" 'NEXTCLOUD_URL unset: overwrite.cli.url is left alone'
  eq '"https"' "$(cfg_get overwriteprotocol)" 'NEXTCLOUD_URL unset: overwriteprotocol is left alone'
  eq '["localhost"]' "$(cfg_get trusted_domains)" 'NEXTCLOUD_URL unset: localhost is still trusted'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","overwriteprotocol":"https","trusted_domains":["localhost"]}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=abc.clouve.app
  eq 0 "$NC_RC" 'a URL with no scheme: exit status 0'
  contains 'NEXTCLOUD_URL' "$NC_ERR" 'a URL with no scheme: a warning names the variable'
  not_logged 'config:system:set overwrite.cli.url' 'a URL with no scheme: overwrite.cli.url is not set'
  not_logged 'config:system:set trusted_domains' 'a URL with no scheme: no host is added'
  not_logged 'config:system:delete overwriteprotocol' 'a URL with no scheme: overwriteprotocol stays'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost"]}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=ftp://files.example.com
  eq 0 "$NC_RC" 'an ftp URL: exit status 0'
  not_logged 'config:system:set overwrite.cli.url' 'an ftp URL: overwrite.cli.url is not set'

  echo ' what is read wrong is not written over'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","kept.example"]}'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=https://new.example.com FAKE_TRUSTED_OUT=oops
  eq 0 "$NC_RC" 'trusted_domains that is not JSON: exit status 0'
  contains 'WARNING' "$NC_ERR" 'trusted_domains that is not JSON: a warning'
  not_logged 'config:system:set trusted_domains' 'trusted_domains that is not JSON: nothing is written to it'
  logged 'config:system:set trusted_proxies 0 --value=10.0.0.0/8' 'trusted_domains that is not JSON: the later steps still run'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=https://new.example.com 'FAKE_FAIL=config:system:get trusted_domains'
  eq 0 "$NC_RC" 'trusted_domains that cannot be read: exit status 0'
  contains 'trusted_domains' "$NC_ERR" 'trusted_domains that cannot be read: a warning names it'
  not_logged 'config:system:set trusted_domains' 'trusted_domains that cannot be read: nothing is written to it'
  eq '["localhost","kept.example"]' "$(cfg_get trusted_domains)" 'trusted_domains that cannot be read: the entries are as they were'
  nc_run "$CONFIG_SH" NEXTCLOUD_URL=https://new.example.com 'FAKE_FAIL=config:system:get overwrite.cli.url'
  eq 0 "$NC_RC" 'an old URL that cannot be read: exit status 0'
  lacks 'URL has changed' "$NC_OUT" 'an old URL that cannot be read: no change line'
  not_logged 'config:system:set overwrite.cli.url' 'an old URL that cannot be read: overwrite.cli.url is not set'
}

# --- nextcloud-config.sh: the database settings ------------------------------------
# The password reaches occ only inside a private file that config:import reads and the script deletes right after.
# shellcheck disable=SC2016  # test data: shell syntax in a password has to stay text
section_config_database() {
  local weird got var pid i n
  need_script "$CONFIG_SH" || return 0
  nc_world "$WORK/w-db"
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'

  echo ' no database settings in config.php: all four are imported through a private file'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  logged_re 'config:import .*/tmp/db\.[A-Za-z0-9]+' 'config:import is called with a file in NC_TMP_DIR'
  eq '{"system":{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret"}}' "$(cat "$NCW_LOG.import")" 'the file holds the four settings as JSON, and nothing else'
  eq 600 "$(cat "$NCW_LOG.import.mode")" 'the file is mode 600 while occ reads it'
  eq '' "$(ls -A "$NCW/tmp")" 'the file is gone afterwards: NC_TMP_DIR is empty'
  n="$(grep -n '^config:import' "$NCW_LOG" | head -n 1 | cut -d: -f1)"
  eq 1 "$(sed -n "${n}p" "$NCW_LOG.tmp")" 'sanity check: the file existed when occ imported it'
  eq 0 "$(sed -n "$((n + 1)),\$p" "$NCW_LOG.tmp" | grep -vc '^0$')" 'and no occ call after the import found it: it is deleted right after'
  eq yes "$([[ "$(sed -n "$((n + 1)),\$p" "$NCW_LOG.tmp" | wc -l)" -gt 0 ]] && echo yes || echo no)" 'sanity check: there were occ calls after the import'
  contains '[nextcloud] database settings updated' "$NC_OUT" 'stdout says so, with no value'
  no_secret s3cret 's3cret appears in no output and no argument'
  lacks 'tkt-7-nextcloud-mariadb' "$NC_OUT" 'no value is logged, the host included'
  logged 'config:system:get dbpassword' 'the password is read with config:system:get, by its key name only'
  eq 1 "$(grep -c '^config:import' "$NCW_LOG")" 'one config:import'

  echo ' one setting differs: all four are written again'
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"old-password","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  eq 1 "$(grep -c '^config:import' "$NCW_LOG")" 'only the password differs: one config:import'
  eq '"s3cret"' "$(cfg_get dbpassword)" 'config.php: the password is the environment'"'"'s'
  contains '"dbhost":"tkt-7-nextcloud-mariadb"' "$(cat "$NCW_LOG.import")" 'the file still holds all four settings'
  no_secret old-password 'the old password appears in no output and no argument'
  no_secret s3cret 's3cret appears in no output and no argument'

  echo ' each of the four on its own'
  for var in dbhost dbname dbuser dbpassword; do
    cfg_reset "{\"dbhost\":\"tkt-7-nextcloud-mariadb\",\"dbname\":\"nextcloud\",\"dbuser\":\"nextcloud\",\"dbpassword\":\"s3cret\",\"$var\":\"different\",\"overwrite.cli.url\":\"https://abc.clouve.app\",\"trusted_domains\":[\"localhost\",\"abc.clouve.app\"]}"
    nc_run "$CONFIG_SH"
    eq 1 "$(grep -c '^config:import' "$NCW_LOG")" "only $var differs: one config:import"
    eq "$(php -n -r '$m = ["dbhost" => "tkt-7-nextcloud-mariadb", "dbname" => "nextcloud", "dbuser" => "nextcloud", "dbpassword" => "s3cret"]; echo json_encode($m[$argv[1]]);' -- "$var")" "$(cfg_get "$var")" "only $var differs: config.php has the environment's $var again"
  done

  echo ' a setting that cannot be read is not a setting that differs'
  cfg_reset '{"dbhost":"keep-host","dbname":"keep-name","dbuser":"keep-user","dbpassword":"keep-pass","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  for var in dbhost dbname dbuser dbpassword; do
    nc_run "$CONFIG_SH" "FAKE_FAIL=config:system:get $var"
    eq 0 "$NC_RC" "reading $var fails: exit status 0"
    contains "$var" "$NC_ERR" "reading $var fails: the warning names it"
    not_logged 'config:import' "reading $var fails: no config:import over settings that could not be read"
  done
  eq '"keep-pass"' "$(cfg_get dbpassword)" 'config.php: dbpassword is as it was'

  echo ' every setting is the same: nothing is written'
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  nc_run "$CONFIG_SH"
  not_logged 'config:import' 'no config:import'
  eq 4 "$(grep -c '^config:system:get db' "$NCW_LOG")" 'all four settings are read'
  eq '' "$(ls -A "$NCW/tmp")" 'NC_TMP_DIR is empty'

  echo ' a password with characters that quoting would get wrong'
  weird='p"a\ss/w$ord'"'"'é<>& `x` $(y) %s'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  nc_run "$CONFIG_SH" "NEXTCLOUD_DB_PASSWORD=$weird"
  eq 0 "$NC_RC" 'exit status 0'
  got="$(php -n -r 'echo json_decode(file_get_contents($argv[1]), true)["system"]["dbpassword"];' -- "$NCW_LOG.import")"
  eq "$weird" "$got" 'the JSON file decodes to exactly the password'
  eq "$(php -n -r 'echo json_encode($argv[1], JSON_UNESCAPED_SLASHES);' -- "$weird")" "$(cfg_get dbpassword)" 'config.php: the stored password is exactly the password'
  no_secret "$weird" 'the password appears in no output and no argument'
  nc_run "$CONFIG_SH" "NEXTCLOUD_DB_PASSWORD=$weird"
  not_logged 'config:import' 'the same password again: no config:import'

  echo ' the umask does not matter'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  nc_run "umask 000; $CONFIG_SH"
  eq 600 "$(cat "$NCW_LOG.import.mode")" 'umask 000: the file is still mode 600'

  echo ' an incomplete environment never overwrites config.php'
  cfg_reset '{"dbhost":"keep-host","dbname":"keep-name","dbuser":"keep-user","dbpassword":"keep-pass","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  for var in NEXTCLOUD_DB_HOST NEXTCLOUD_DB_NAME NEXTCLOUD_DB_USER NEXTCLOUD_DB_PASSWORD; do
    nc_run "$CONFIG_SH" "-$var"
    eq 0 "$NC_RC" "$var unset: exit status 0"
    contains "$var" "$NC_ERR" "$var unset: the warning names the variable"
    not_logged 'config:import' "$var unset: no config:import"
    nc_run "$CONFIG_SH" "$var="
    not_logged 'config:import' "$var empty: no config:import"
  done
  eq '"keep-host"' "$(cfg_get dbhost)" 'config.php: dbhost is as it was'
  eq '"keep-pass"' "$(cfg_get dbpassword)" 'config.php: dbpassword is as it was'

  echo ' no private directory: the password is not written anywhere else'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  nc_run "$CONFIG_SH" "NC_TMP_DIR=$NCW/no-such-dir"
  eq 0 "$NC_RC" 'NC_TMP_DIR missing: exit status 0'
  contains 'WARNING' "$NC_ERR" 'NC_TMP_DIR missing: a warning'
  contains "$NCW/no-such-dir" "$NC_ERR" 'NC_TMP_DIR missing: the warning names the directory'
  not_logged 'config:import' 'NC_TMP_DIR missing: no config:import'
  eq '<unset>' "$(cfg_get dbpassword)" 'NC_TMP_DIR missing: config.php has no password'
  no_secret s3cret 'NC_TMP_DIR missing: s3cret appears in no output and no argument'
  eq '' "$(find "$NCW" /tmp -name 'db.*' -newer "$NCW/bin/occ.php" 2>/dev/null)" 'NC_TMP_DIR missing: no db.* file anywhere else'
  : > "$NCW/a-file"
  nc_run "$CONFIG_SH" "NC_TMP_DIR=$NCW/a-file"
  eq 0 "$NC_RC" 'NC_TMP_DIR is a file: exit status 0'
  not_logged 'config:import' 'NC_TMP_DIR is a file: no config:import'
  nc_run "$CONFIG_SH" -NC_TMP_DIR
  contains '/run/clouve/tmp' "$NC_ERR" 'NC_TMP_DIR unset: the default is /run/clouve/tmp'

  echo ' config:import fails'
  nc_run "$CONFIG_SH" FAKE_FAIL=config:import
  eq 0 "$NC_RC" 'exit status 0'
  contains 'WARNING' "$NC_ERR" 'a warning'
  lacks 'database settings updated' "$NC_OUT" 'stdout does not claim the settings were updated'
  eq '' "$(ls -A "$NCW/tmp")" 'the private file is deleted all the same'
  no_secret s3cret 'config:import fails: s3cret appears in no output and no argument'
  logged_re 'config:system:set memcache.locking .*' 'the later steps still run'

  echo ' php fails while the private file is written'
  fake_cmd "$NCW/phpfail" php <<EOF
case " \$* " in *" -r "*) echo 'Fatal error: Uncaught Error: boom'; exit 255 ;; esac
exec $(command -v php) "\$@"
EOF
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  # shellcheck disable=SC2031  # as above: this shell's PATH is what is extended
  nc_run "$CONFIG_SH" "PATH=$NCW/phpfail:$NCW/bin:$PATH"
  eq 0 "$NC_RC" 'exit status 0'
  contains 'WARNING' "$NC_ERR" 'a warning'
  lacks 'database settings updated' "$NC_OUT" 'stdout does not claim the settings were updated'
  not_logged 'config:import' 'occ is not asked to import a file that was not written'
  eq '' "$(ls -A "$NCW/tmp")" 'the private file is deleted'
  no_secret s3cret 's3cret appears in no output and no argument'

  echo ' the script is stopped while occ reads the private file'
  # The fake occ waits 5 s after it has read the file. SIGTERM, which is how a stopped container ends the hook, has to
  # leave no file behind either.
  : > "$NCW_LOG"
  env -i "${NCW_ENV[@]}" FAKE_IMPORT_HANGS=1 sh -c "exec $CONFIG_SH" </dev/null >"$NCW/out" 2>"$NCW/err" &
  pid=$!
  for ((i = 0; i < 50; i++)); do
    if [[ -n "$(ls -A "$NCW/tmp")" ]]; then break; fi
    sleep 0.1
  done
  eq 1 "$(find "$NCW/tmp" -mindepth 1 | wc -l)" 'the private file exists while occ reads it'
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  eq '' "$(ls -A "$NCW/tmp")" 'SIGTERM: the private file is deleted'
  no_secret s3cret 'SIGTERM: s3cret appears in no output and no argument'
}

# --- nextcloud-config.sh: occ that cannot start, and a database host that moved ----
# A clone gets new host names, and its config.php (copied with the volume) keeps the old ones. occ cannot start with an
# unreachable database, not even for config:system:set, so config:import can never repair that. The script then edits
# config.php itself.
# shellcheck disable=SC2016  # test data: PHP code and PHP syntax have to stay text
section_config_repair() {
  local sum before
  need_script "$CONFIG_SH" || return 0
  nc_world "$WORK/w-repair"
  # A config.php as a clone leaves it: the old host and the old password, and keys the repair must keep.
  local stale='{"instanceid":"oc1234abcd","passwordsalt":"salty","secret":"keep-me","version":"35.0.2.2","installed":true,"dbtype":"mysql","dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"old-pass","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"nested":{"a":[1,2,{"b":true}],"c":null,"d":1.5}}'

  echo ' a clone: the host and the password in config.php are the old ones, and occ cannot start'
  cfg_reset "$stale"
  chmod 640 "$NCW_CONF"
  chown nobody:nogroup "$NCW_CONF"
  before="$(php -n -r '$CONFIG = []; include $argv[1]; unset($CONFIG["dbhost"], $CONFIG["dbpassword"]); echo json_encode($CONFIG);' -- "$NCW_CONF")"
  nc_run "$CONFIG_SH" NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb FAKE_DB_HOST_OK=tkt-9-nextcloud-mariadb
  eq 0 "$NC_RC" 'exit status 0'
  eq '"tkt-9-nextcloud-mariadb"' "$(cfg_get dbhost)" 'config.php: dbhost is the new host'
  eq '"s3cret"' "$(cfg_get dbpassword)" 'config.php: dbpassword is the environment'"'"'s'
  eq '' "$(php -n -r '$CONFIG = []; include $argv[1]; $d = []; foreach (json_decode($argv[2], true) as $k => $v) { if (!array_key_exists($k, $CONFIG) || $CONFIG[$k] !== $v) { $d[] = $k; } } echo implode(",", $d);' -- "$NCW_CONF" "$before")" 'every other key is exactly as it was, nested values and types too (keys that differ: none)'
  eq 'nobody:nogroup 640' "$(stat -c '%U:%G %a' "$NCW_CONF")" 'config.php keeps its owner and mode'
  eq 'config.php' "$(ls -A "$NCW/conf")" 'no temporary file is left next to it'
  contains 'config.php' "$NC_OUT" 'stdout says that config.php was updated'
  lacks 'tkt-9-nextcloud-mariadb' "$NC_OUT" 'stdout names no host'
  no_secret s3cret 's3cret appears in no output and no argument'
  no_secret old-pass 'the old password appears in no output and no argument'
  eq 2 "$(grep -c '^status --output=json' "$NCW_LOG")" 'occ status is called again after the repair'
  logged_re 'config:system:set trusted_proxies 0 .*' 'the settings are applied after the repair'
  not_logged 'config:import' 'the repair needed no config:import'

  echo ' only the host is stale'
  cfg_reset '{"installed":true,"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"]}'
  nc_run "$CONFIG_SH" NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb FAKE_DB_HOST_OK=tkt-9-nextcloud-mariadb
  eq 0 "$NC_RC" 'exit status 0'
  eq '"tkt-9-nextcloud-mariadb"' "$(cfg_get dbhost)" 'config.php: dbhost is the new host'
  eq '"s3cret"' "$(cfg_get dbpassword)" 'config.php: dbpassword is the same'

  echo ' occ is down for another reason: nothing is written, and the script stops'
  cfg_reset "$stale"
  sum="$(md5sum < "$NCW_CONF")"
  nc_run "$CONFIG_SH" NEXTCLOUD_DB_HOST=tkt-7-nextcloud-mariadb NEXTCLOUD_DB_NAME=nextcloud NEXTCLOUD_DB_USER=nextcloud NEXTCLOUD_DB_PASSWORD=old-pass FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'config.php already matches the environment: exit status 1'
  contains 'ERROR' "$NC_ERR" 'an ERROR line on stderr'
  contains 'Failed to connect to the database' "$NC_ERR" 'it shows what occ said'
  lacks '#0 ' "$NC_ERR" 'but not the stack trace'
  eq "$sum" "$(md5sum < "$NCW_CONF")" 'config.php is untouched'
  eq 1 "$(grep -c '^status' "$NCW_LOG")" 'occ status is not retried when nothing was repaired'
  not_logged 'config:system:set' 'no setting is applied'
  no_secret old-pass 'the password appears in no output and no argument'

  echo ' what occ said is cut short'
  local long
  long="$(printf 'h%.0s' {1..600})"
  cfg_reset "{\"dbhost\":\"$long\",\"dbname\":\"nextcloud\",\"dbuser\":\"nextcloud\",\"dbpassword\":\"s3cret\"}"
  nc_run "$CONFIG_SH" "NEXTCLOUD_DB_HOST=$long" FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'exit status 1'
  eq yes "$([[ "${#NC_ERR}" -lt 800 ]] && echo yes || echo no)" "the message holds two lines of occ's output cut to 300 characters each (it is ${#NC_ERR} long)"

  echo ' no NC_CONFIG_FILE: the repair looks at /var/www/html/config/config.php'
  nc_run "$CONFIG_SH" -NC_CONFIG_FILE FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'exit status 1'
  contains '/var/www/html/config/config.php' "$NC_ERR" 'the warning names that file'

  echo ' occ is down, and the environment is incomplete'
  cfg_reset "$stale"
  sum="$(md5sum < "$NCW_CONF")"
  nc_run "$CONFIG_SH" -NEXTCLOUD_DB_PASSWORD FAKE_DB_HOST_OK=tkt-9-nextcloud-mariadb NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb
  eq 1 "$NC_RC" 'exit status 1'
  eq "$sum" "$(md5sum < "$NCW_CONF")" 'config.php is untouched: no empty value is written'
  contains 'NEXTCLOUD_DB_PASSWORD' "$NC_ERR" 'the message names the variable'

  echo ' occ is down, and config.php is missing or broken'
  rm -f "$NCW_CONF"
  nc_run "$CONFIG_SH" FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'no config.php: exit status 1'
  contains "cannot read $NCW_CONF" "$NC_ERR" 'no config.php: the warning says which file it cannot read'
  eq 'no' "$([[ -e "$NCW_CONF" ]] && echo yes || echo no)" 'no config.php: none is made'
  printf '<?php\nthis is not php (\n' > "$NCW_CONF"
  sum="$(md5sum < "$NCW_CONF")"
  nc_run "$CONFIG_SH" FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'a config.php that is not PHP: exit status 1'
  eq "[nextcloud] WARNING: could not check the database settings in config.php: cannot read $NCW_CONF" "$(grep WARNING <<<"$NC_ERR")" 'a config.php that is not PHP: the repair says it cannot read it, and quotes nothing from the file'
  eq "$sum" "$(md5sum < "$NCW_CONF")" 'a config.php that is not PHP: untouched'
  printf '<?php\n$CONFIG = "not an array";\n' > "$NCW_CONF"
  sum="$(md5sum < "$NCW_CONF")"
  nc_run "$CONFIG_SH" FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'a config.php that is not an array: exit status 1'
  contains 'does not define $CONFIG' "$NC_ERR" 'a config.php that is not an array: the warning says so'
  eq "$sum" "$(md5sum < "$NCW_CONF")" 'a config.php that is not an array: untouched'
}

# --- nextcloud-config.sh: proxies, cache, previews, and occ failing ------------------
section_config_other() {
  local sp
  need_script "$CONFIG_SH" || return 0
  nc_world "$WORK/w-other"

  echo ' trusted_proxies: only the ranges that differ are set'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","trusted_proxies":["10.0.0.0/8","172.16.0.0/12","10.1.1.1","9.9.9.9"]}'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  not_logged 'config:system:set trusted_proxies 0' 'index 0 is right: not set'
  not_logged 'config:system:set trusted_proxies 1' 'index 1 is right: not set'
  logged 'config:system:set trusted_proxies 2 --value=192.168.0.0/16' 'index 2 differs: set'
  eq '["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","9.9.9.9"]' "$(cfg_get trusted_proxies)" 'an entry after the three is left alone'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret"}'
  nc_run "$CONFIG_SH"
  logged 'config:system:set trusted_proxies 0 --value=10.0.0.0/8' 'no proxies yet: index 0'
  logged 'config:system:set trusted_proxies 1 --value=172.16.0.0/12' 'no proxies yet: index 1'
  logged 'config:system:set trusted_proxies 2 --value=192.168.0.0/16' 'no proxies yet: index 2'

  echo ' preview concurrency'
  nc_run "$CONFIG_SH" CLV_PREVIEW_CONCURRENCY_NEW=2 CLV_PREVIEW_CONCURRENCY_ALL=4
  eq 0 "$NC_RC" 'both set: exit status 0'
  logged 'config:system:set preview_concurrency_new --type=integer --value=2' 'preview_concurrency_new is set'
  logged 'config:system:set preview_concurrency_all --type=integer --value=4' 'preview_concurrency_all is set'
  eq '2' "$(cfg_get preview_concurrency_new)" 'config.php: preview_concurrency_new is an integer'
  eq '4' "$(cfg_get preview_concurrency_all)" 'config.php: preview_concurrency_all is an integer'
  nc_run "$CONFIG_SH" CLV_PREVIEW_CONCURRENCY_NEW=1
  not_logged 'config:system:set preview_concurrency' 'only one variable: nothing is set'
  nc_run "$CONFIG_SH" CLV_PREVIEW_CONCURRENCY_ALL=8
  not_logged 'config:system:set preview_concurrency' 'only the other variable: nothing is set'
  nc_run "$CONFIG_SH" CLV_PREVIEW_CONCURRENCY_NEW= CLV_PREVIEW_CONCURRENCY_ALL=
  not_logged 'config:system:set preview_concurrency' 'both empty: nothing is set'
  nc_run "$CONFIG_SH" CLV_PREVIEW_CONCURRENCY_NEW=abc CLV_PREVIEW_CONCURRENCY_ALL=4
  eq 0 "$NC_RC" 'not a number: exit status 0'
  contains 'CLV_PREVIEW_CONCURRENCY' "$NC_ERR" 'not a number: a warning names the variables'
  not_logged 'config:system:set preview_concurrency' 'not a number: nothing is set'

  echo ' a setting that cannot be written is a warning, not the end'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret"}'
  nc_run "$CONFIG_SH" 'FAKE_FAIL=config:system:set trusted_proxies'
  eq 0 "$NC_RC" 'exit status 0'
  contains 'WARNING' "$NC_ERR" 'a warning'
  contains 'trusted_proxies' "$NC_ERR" 'the warning names the setting'
  lacks '10.0.0.0' "$NC_ERR" 'but not the value'
  lacks '--value' "$NC_ERR" 'and not the options'
  logged_re 'config:system:set memcache.locking .*' 'the steps after it still run'
  eq '{"host":"/run/clouve/valkey/valkey.sock","port":0}' "$(cfg_get redis)" 'the cache settings are applied'

  echo ' HOME is www-data'"'"'s, whatever the caller had'
  cfg_reset "$NCW_BASE"
  nc_run "$CONFIG_SH" HOME=/root
  eq 0 "$NC_RC" 'exit status 0'
  home_is /var/www 'every occ call runs with HOME=/var/www (su -p leaves HOME=/root, and PHP then logs Fontconfig errors)'

  echo ' leftovers of a run that was killed (a stop does not run the EXIT trap: PID 1 ignores SIGTERM)'
  cfg_reset "$NCW_BASE"
  : > "$NCW/tmp/db.AbC123"; : > "$NCW/tmp/keep.txt"
  : > "$NCW/conf/.config.php.0123456789ab"; : > "$NCW/conf/.config.php.bak"
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  eq 'keep.txt' "$(ls -A "$NCW/tmp")" 'the private file is removed, and a file that is not one stays'
  eq '.config.php.bak config.php' "$(find "$NCW/conf" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" 'the half-written copy of config.php is removed, and a backup of another name stays'
  eq 0 "$(head -n 1 "$NCW_LOG.tmp")" 'it was all gone before the first occ call'
  : > "$NCW/tmp/db.AbC123"; : > "$NCW/conf/.config.php.0123456789ab"
  nc_run "$CONFIG_SH" FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'occ will not start: exit status 1'
  eq 'keep.txt' "$(ls -A "$NCW/tmp")" 'and the private file is removed even so'
  eq '.config.php.bak config.php' "$(find "$NCW/conf" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" 'and so is the copy of config.php'

  echo ' occ prints a notice on stderr with every call while an upgrade is pending'
  cfg_reset '{"overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret"}'
  nc_run "$CONFIG_SH" FAKE_STDERR_NOTICE=1
  eq 0 "$NC_RC" 'exit status 0'
  eq '' "$NC_ERR" 'none of it reaches the log'
  logged_re 'config:system:set memcache.locking .*' 'and the settings are applied'

  echo ' occ status fails: the script stops before it changes anything'
  nc_run "$CONFIG_SH" FAKE_FAIL=status
  eq 1 "$NC_RC" 'exit status 1'
  contains 'ERROR' "$NC_ERR" 'an ERROR line on stderr'
  eq 'status --output=json' "$(cat "$NCW_LOG")" 'occ was asked for the status, and nothing else'
  nc_run "$CONFIG_SH" -OCC
  eq 1 "$NC_RC" 'no OCC set: exit status 1'
  contains '/var/www/html/occ' "$NC_ERR" 'no OCC set: it tried php /var/www/html/occ'

  echo ' a stdin that never delivers'
  mkfifo "$NCW/stdin"
  sleep 60 > "$NCW/stdin" &
  sp=$!
  timeout 30 env -i "${NCW_ENV[@]}" sh -c "$CONFIG_SH" < "$NCW/stdin" > "$NCW/out" 2> "$NCW/err"
  eq 0 "$?" 'the script does not wait for its stdin'
  kill "$sp" 2>/dev/null
  wait "$sp" 2>/dev/null

  echo ' the file'
  eq '#!/bin/bash' "$(head -n 1 "$CONFIG_SH")" 'it starts with #!/bin/bash'
  no_xtrace "$CONFIG_SH"
  eq 0 "$(grep -v '^[[:space:]]*#' "$CONFIG_SH" | grep -c flock)" 'it never runs flock (post-installation runs it inside the init lock, and a second lock would wait for ever)'
}

# --- nextcloud-config.sh: the upload chunk size ------------------------------------
# Nextcloud 35 takes the chunk size of browser uploads from the system key files.chunked_upload.max_size, and uses
# 100 MiB when it is not set (apps/files/lib/Service/ChunkedUploadConfig.php, which JSConfigHelper hands to the web UI).
# The ingress refuses a request body over 50 MiB, so the script sets 40 MiB when the key is not set or is above 50 MiB.
# It does the same for 0 or less, which turns chunking off: every browser upload is then one request, and any file over
# 50 MiB gets 413. A value from 1 byte to 50 MiB is the admin's, and it stays. Nextcloud reads the key with a cast to
# int, and so does the script.
section_config_chunk_size() {
  local key=files.chunked_upload.max_size set_line
  need_script "$CONFIG_SH" || return 0
  nc_world "$WORK/w-chunk"
  set_line="config:system:set $key --type=integer --value=41943040"

  # chunk_cfg VALUE_JSON: NCW_BASE with the key set to this value.
  chunk_cfg() { cfg_reset "${NCW_BASE%\}},\"$key\":$1}"; }

  echo ' not set: Nextcloud would use 100 MiB, so it becomes 40 MiB'
  cfg_reset "$NCW_BASE"
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  logged "$set_line" 'it is set to 41943040, as an integer'
  eq 41943040 "$(cfg_get "$key")" 'config.php: the integer 41943040'
  eq "[nextcloud] $key set to 41943040 (40 MiB), from Nextcloud's default of 100 MiB, so that an upload request fits under the ingress's 50 MiB limit" \
    "$(grep -F "$key" <<<"$NC_OUT")" 'stdout says so, in one line'
  eq '' "$NC_ERR" 'nothing on stderr'
  logged_in_order 'it comes after the other settings' 'config:system:set memcache.locking .*' "config:system:get $key --output=json" "$set_line"

  echo ' 40 MiB already: nothing is written, and nothing is said'
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  logged "config:system:get $key --output=json" 'it is read'
  not_logged "config:system:set $key" 'and not set again'
  lacks "$key" "$NC_OUT" 'stdout does not name it'

  echo ' 100 MiB, Nextcloud'"'"'s default written out (or an admin'"'"'s): back to 40 MiB'
  chunk_cfg 104857600
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  logged "$set_line" 'it is set to 41943040'
  eq 41943040 "$(cfg_get "$key")" 'config.php: 41943040'
  contains "[nextcloud] $key set to 41943040 (40 MiB), from 104857600, so that" "$NC_OUT" 'stdout names the value it replaced'

  echo ' 20 MiB, an admin'"'"'s value between 1 byte and 50 MiB: it stays'
  chunk_cfg 20971520
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'exit status 0'
  not_logged "config:system:set $key" 'it is not set'
  eq 20971520 "$(cfg_get "$key")" 'config.php: still 20971520'
  lacks "$key" "$NC_OUT" 'stdout does not name it'

  echo ' the limits: 1 byte and 50 MiB stay, 0 and one byte more than 50 MiB do not'
  chunk_cfg 1
  nc_run "$CONFIG_SH"
  not_logged "config:system:set $key" '1 stays (the web UI sends at least 5 MiB a chunk anyway)'
  chunk_cfg 52428800
  nc_run "$CONFIG_SH"
  not_logged "config:system:set $key" '52428800 (50 MiB) stays'
  chunk_cfg 52428801
  nc_run "$CONFIG_SH"
  logged "$set_line" '52428801 is set to 41943040'

  echo ' other forms of the value, read with a cast to int as Nextcloud does'
  chunk_cfg '"104857600"'
  nc_run "$CONFIG_SH"
  logged "$set_line" 'the string "104857600" (set without --type=integer) is too big too, and is set to 41943040'
  eq 41943040 "$(cfg_get "$key")" 'config.php: now the integer 41943040'
  chunk_cfg '"20971520"'
  nc_run "$CONFIG_SH"
  not_logged "config:system:set $key" 'the string "20971520" stays'
  eq '"20971520"' "$(cfg_get "$key")" 'config.php: still the string'
  echo ' 0 or less turns chunking off, so every upload would be one request: back to 40 MiB'
  chunk_cfg 0
  nc_run "$CONFIG_SH"
  eq 0 "$NC_RC" '0: exit status 0'
  logged "$set_line" '0 is set to 41943040'
  eq 41943040 "$(cfg_get "$key")" '0: config.php now holds the integer 41943040'
  contains "[nextcloud] $key set to 41943040 (40 MiB), from 0 (chunking off), so that" "$NC_OUT" '0: stdout says chunking was off'
  chunk_cfg -1
  nc_run "$CONFIG_SH"
  logged "$set_line" '-1 is set to 41943040'
  contains "from -1 (chunking off)" "$NC_OUT" '-1: stdout says chunking was off'
  chunk_cfg '"0"'
  nc_run "$CONFIG_SH"
  logged "$set_line" 'the string "0" is set to 41943040'
  chunk_cfg false
  nc_run "$CONFIG_SH"
  logged "$set_line" 'false, which Nextcloud reads as 0, is set to 41943040'
  chunk_cfg 1.5e8
  nc_run "$CONFIG_SH"
  logged "$set_line" 'a float of 150000000 is too big, and is set to 41943040'

  echo ' a read that fails: a warning, and nothing is written'
  chunk_cfg 104857600
  nc_run "$CONFIG_SH" "FAKE_FAIL=config:system:get $key"
  eq 0 "$NC_RC" 'exit status 0'
  contains "[nextcloud] WARNING: could not read $key, so it is left as it is" "$NC_ERR" 'the warning names the key'
  not_logged "config:system:set $key" 'it is not set'
  eq 104857600 "$(cfg_get "$key")" 'config.php: as it was'

  echo ' a write that fails: a warning, and the script still exits 0'
  cfg_reset "$NCW_BASE"
  nc_run "$CONFIG_SH" "FAKE_FAIL=config:system:set $key"
  eq 0 "$NC_RC" 'exit status 0'
  contains "occ config:system:set $key failed" "$NC_ERR" 'the warning names the key'
  lacks "$key set to" "$NC_OUT" 'stdout does not say it was set'
}

# --- the hooks ---------------------------------------------------------------------
# The official entrypoint runs each hook as www-data with `su -p`, which comes down to `sh -c <path>` with the container's
# environment. nc_run does the same, as root, in a clean environment.

# NCW_BASE: a config.php where the database settings match the environment, so the hook tests are not about those.
NCW_BASE='{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"http://localhost","trusted_domains":["localhost"]}'

# occ_status_json INSTALLED MAINTENANCE NEEDS_UPGRADE: what `occ status --output=json` prints, in its real field order.
occ_status_json() {
  printf '{"installed":%s,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","maintenance":%s,"needsDbUpgrade":%s,"productname":"Nextcloud","extendedSupport":false}' "$1" "$2" "$3"
}

# NCW_LIVE: a config.php for FAKE_STATUS_JSON=live, where the fake's status follows config.php: NCW_BASE on an
# installed instance at the code's version, with maintenance mode off. A kill in one run then shows in the next.
NCW_LIVE="${NCW_BASE%\}},\"installed\":true,\"version\":\"35.0.2.2\",\"maintenance\":false}"
# live_with JSON_PAIRS: NCW_LIVE with these keys changed or added, such as '"maintenance":true'.
# shellcheck disable=SC2016  # PHP code, not shell
live_with() { php -n -r 'echo json_encode(array_merge(json_decode($argv[1], true), json_decode("{" . $argv[2] . "}", true)), JSON_UNESCAPED_SLASHES);' -- "$NCW_LIVE" "$1"; }

# LIBCALL FUNCTION [ARG...]: a script that sources lib.sh and runs one of its functions, for nc_run, which runs a
# script in the world's environment.
LIBCALL="$WORK/libcall"
# shellcheck disable=SC2016  # "$@" is for the script being written
printf '#!/bin/bash\n. %q || exit 99\n"$@"\n' "$LIB" > "$LIBCALL"
chmod 755 "$LIBCALL"

# mark NAME [LINE]: the marker file NAME (RESTORE-IN-PROGRESS or BACKUP-IN-PROGRESS) holding LINE, in the AI Assistant's
# backups folder, made the way the skill's scripts make it: the folder root's with mode 700, the file root's with mode 600.
mark() {
  install -d -o root -g root -m 700 /var/www/html/data/clouve-backups
  printf '%s\n' "${2-}" > "/var/www/html/data/clouve-backups/$1"
  chmod 600 "/var/www/html/data/clouve-backups/$1"
}
# unmark: removes the data folder (and so every marker) and the root entrypoint's restore note.
unmark() { rm -rf /var/www/html/data /run/clouve/restore-cut-off; }
# exists PATH: yes or no.
exists() { if [[ -e "$1" || -L "$1" ]]; then echo yes; else echo no; fi; }

# --- pre-installation ------------------------------------------------------------
section_hook_pre_installation() {
  local hook="$HOOKS/pre-installation/10-clouve.sh" rc
  need_script "$hook" || return 0
  mkdir -p /var/www/html/config
  : > /var/www/html/config/CAN_INSTALL
  : > /var/www/html/config/config.php

  echo ' CAN_INSTALL is removed, so a half-finished install can never show the web installer'
  sh -c "$hook" </dev/null >"$WORK/hook.out" 2>"$WORK/hook.err"
  rc=$?
  eq 0 "$rc" 'exit status 0'
  eq no "$([[ -e /var/www/html/config/CAN_INSTALL ]] && echo yes || echo no)" 'config/CAN_INSTALL is gone'
  eq yes "$([[ -e /var/www/html/config/config.php ]] && echo yes || echo no)" 'the rest of config/ is untouched'
  eq '' "$(cat "$WORK/hook.out" "$WORK/hook.err")" 'it prints nothing'

  echo ' and it is no error when the file is not there'
  sh -c "$hook" </dev/null >"$WORK/hook.out" 2>"$WORK/hook.err"
  eq 0 "$?" 'exit status 0'
  rm -rf /var/www/html/config
  sh -c "$hook" </dev/null >"$WORK/hook.out" 2>"$WORK/hook.err"
  eq 0 "$?" 'no config folder at all: exit status 0'

  echo ' the file'
  matches '^#!/bin/(ba)?sh$' "$(head -n 1 "$hook")" 'it starts with a shell shebang'
  no_xtrace "$hook"
}

# --- post-installation -------------------------------------------------------------
# The first install's own settings, in their order, as lines of the fake's log (each one an extended regular expression
# for logged_in_order). lib.sh's nc_first_install_steps runs them. The post-installation hook calls it once, and the
# before-starting hook calls it again when a first start was cut off before the last line, the marker, was written. Before
# them comes `user:setting <admin> settings email <email>` when the admin and the email are known.
FIRST_INSTALL_STEPS=(
  'background:cron'
  'config:system:set maintenance_window_start --type=integer --value=1'
  'maintenance:repair --include-expensive'
  'config:system:set trashbin_retention_obligation --value=auto, 30'
  'config:system:set versions_retention_obligation --value=auto, 365'
  'app:disable app_api'
  'config:system:set files_external_allow_create_new_local --type=boolean --value=false'
  'config:app:set files_sharing hide_disabled_user_shares --value=yes'
  'config:system:set updatechecker --type=boolean --value=false'
  'config:system:set serverid --type=integer --value=1'
  'app:install calendar'
  'app:install contacts'
  'app:install groupfolders'
  "config:app:set clouve first_install_done --lazy --value=$ISO_UTC_RE"
)

section_hook_post_installation() {
  local hook="$HOOKS/post-installation/10-clouve.sh" i start elapsed value
  local -a steps=("user:setting O'Brien Smith settings email owner@example.com" "${FIRST_INSTALL_STEPS[@]}")
  # Each app is looked for once app:install has run, and enabled when it is on disk.
  local -a apps_enabled=(
    'app:install calendar' 'app:getpath calendar' 'app:enable calendar'
    'app:install contacts' 'app:getpath contacts' 'app:enable contacts'
    'app:install groupfolders' 'app:getpath groupfolders' 'app:enable groupfolders'
  )
  local all_enabled='{"calendar":"enabled","contacts":"enabled","groupfolders":"enabled"}'
  local admin="NEXTCLOUD_ADMIN_USER=O'Brien Smith" mail=NEXTCLOUD_ADMIN_EMAIL=owner@example.com pw=NEXTCLOUD_ADMIN_PASSWORD=adminpw-xyz
  need_script "$hook" || return 0
  nc_world "$WORK/w-post-install"
  cfg_reset "$NCW_BASE"
  appcfg_reset '{}'

  echo ' a normal first install'
  nc_run "$hook" "$admin" "$mail" "$pw"
  eq 0 "$NC_RC" 'exit status 0'
  logged_in_order 'nextcloud-config.sh runs first, then the steps, in their fixed order, and the marker last' \
    'status --output=json' 'config:system:set overwriteprotocol .*' "${steps[@]}"
  eq '"https"' "$(cfg_get overwriteprotocol)" 'nextcloud-config.sh ran: overwriteprotocol is https'
  eq '["localhost","abc.clouve.app"]' "$(cfg_get trusted_domains)" 'nextcloud-config.sh ran: abc.clouve.app is trusted'
  eq 41943040 "$(cfg_get files.chunked_upload.max_size)" 'nextcloud-config.sh ran: the upload chunk size is 40 MiB'
  logged_in_order 'each app is installed, then looked for and enabled' "${apps_enabled[@]}"
  eq "$all_enabled" "$(fake_apps)" 'the three apps are enabled'
  contains 'calendar already enabled' "$NC_OUT" 'app:enable finds an app that app:install has just enabled, and leaves it so'
  matches "^$ISO_UTC_RE\$" "$(appcfg_get clouve first_install_done)" 'the marker clouve first_install_done holds the UTC time the steps ended'
  eq "$(grep -c '' "$NCW_LOG")" "$(grep -n '^config:app:set clouve first_install_done ' "$NCW_LOG" | cut -d: -f1)" 'the marker is the last thing written'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the marker clouve post_upgrade_done holds the version: a fresh install needs no post-upgrade steps'
  logged_in_order 'occ status comes before the steps, and the post-upgrade marker just before the first-install one' \
    'status --output=json --no-warnings' "user:setting O'Brien Smith settings email owner@example.com" 'app:install groupfolders' \
    'config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2' "config:app:set clouve first_install_done --lazy --value=$ISO_UTC_RE"
  eq false "$(cfg_get maintenance)" 'maintenance mode is off: the repair put back the off it found'
  not_logged 'config:app:set files max_chunk_size' 'no files max_chunk_size app key: Nextcloud 35 never reads it'
  eq '' "$NC_ERR" 'nothing on stderr'
  not_logged 'flock' 'it takes no lock: the official entrypoint already holds it'
  no_secret adminpw-xyz 'the admin password appears in no output and no argument'
  no_secret s3cret 'the database password appears in no output and no argument'

  echo ' the start is cut off during the repair: maintenance mode stays on, no marker, and the next start finishes them'
  # The step that hangs is the repair, not an app download: an app download runs under a timeout of its own, which
  # moves it out of the process group that NC_RUN_KILL kills, and it would live on into the next run. The fake's repair
  # turns maintenance mode on before it waits, as the real one does, and the status follows config.php (live).
  cfg_reset "$NCW_LIVE"
  appcfg_reset '{}'
  NC_RUN_KILL=3 nc_run "$hook" "$admin" "$mail" 'FAKE_HANG=maintenance:repair' FAKE_STATUS_JSON=live
  eq 137 "$NC_RC" 'the hook and everything it started were killed (SIGKILL)'
  logged 'maintenance:repair --include-expensive' 'the kill came during maintenance:repair'
  not_logged 'app:install' 'no step after it ran'
  eq '<unset>' "$(appcfg_get clouve first_install_done)" 'the first-install marker was never written'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'nor the post-upgrade one'
  eq true "$(cfg_get maintenance)" 'maintenance mode is on: the repair turned it on, and the kill came before it put it back'
  nc_run "$HOOKS/before-starting/10-clouve.sh" "$admin" "$mail" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'the next start: the before-starting hook exits 0'
  contains 'Maintenance mode is on, left by a start that was cut off during the first-install settings' "$NC_OUT" 'the next start: it says that a cut-off first start left maintenance mode on'
  logged_in_order 'the next start: maintenance mode off first, then the steps, under the init lock' \
    'config:app:get clouve first_install_done --default-value= --no-warnings' 'maintenance:mode --off' \
    'flock /var/www/html/nextcloud-init-sync\.lock bash -c .*' "${steps[@]}" 'flock released'
  eq false "$(cfg_get maintenance)" 'the next start: maintenance mode is off at the end'
  matches "^$ISO_UTC_RE\$" "$(appcfg_get clouve first_install_done)" 'the next start: the first-install marker is written'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the next start: and the post-upgrade one'
  eq '{"calendar":"enabled","contacts":"enabled","groupfolders":"enabled"}' "$(fake_apps)" 'the next start: the three apps are enabled'
  nc_run "$HOOKS/before-starting/10-clouve.sh" "$admin" "$mail" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'the start after that: exit status 0'
  not_logged 'flock' 'the start after that: nothing runs again'
  not_logged 'maintenance:mode' 'the start after that: maintenance mode is not touched'
  cfg_reset "$NCW_BASE"

  echo ' the repair dies on the way (an app repair step throws an Error): maintenance mode goes off again'
  # occ catches only Exceptions in a repair step (lib/private/Repair.php), so an Error ends the repair before it puts
  # maintenance mode back, and nothing pending would make a later start turn it off.
  appcfg_reset '{}'
  nc_run "$hook" "$admin" "$mail" FAKE_REPAIR_CRASHES=1
  eq 0 "$NC_RC" 'exit status 0'
  contains '[nextcloud] WARNING: occ maintenance:repair failed (exit status 1)' "$NC_ERR" 'a warning names the repair'
  contains 'left maintenance mode on, so it was turned off again' "$NC_ERR" 'a second says that maintenance mode was turned off again'
  logged_in_order 'maintenance mode is read after the repair, turned off, and the steps go on' 'maintenance:repair --include-expensive' \
    'config:system:get maintenance --default-value=false --no-warnings' 'maintenance:mode --off' 'config:system:set trashbin_retention_obligation .*'
  eq false "$(cfg_get maintenance)" 'maintenance mode is off'
  matches "^$ISO_UTC_RE\$" "$(appcfg_get clouve first_install_done)" 'the markers are written: the pass ran to its end'
  appcfg_reset '{}'
  nc_run "$hook" "$admin" "$mail" FAKE_REPAIR_CRASHES=1 'FAKE_FAIL=maintenance:mode --off'
  eq 0 "$NC_RC" 'and maintenance mode cannot be turned off: exit status 0'
  contains 'could not be turned off, so the steps are not recorded as done' "$NC_ERR" 'and maintenance mode cannot be turned off: a warning says so'
  eq true "$(cfg_get maintenance)" 'and maintenance mode cannot be turned off: it is still on'
  eq '<unset> <unset>' "$(appcfg_get clouve first_install_done) $(appcfg_get clouve post_upgrade_done)" 'and maintenance mode cannot be turned off: no marker, so the next start turns it off and runs the steps again'
  logged 'app:install groupfolders' 'and maintenance mode cannot be turned off: the steps after the repair still ran'
  cfg_reset "$NCW_BASE"

  echo ' the admin email'
  nc_run "$hook" "$admin" NEXTCLOUD_ADMIN_EMAIL=no-at-sign
  not_logged 'user:setting' 'an email without @: not set'
  nc_run "$hook" "$admin" NEXTCLOUD_ADMIN_EMAIL=
  not_logged 'user:setting' 'an empty email: not set'
  nc_run "$hook" "$admin" -NEXTCLOUD_ADMIN_EMAIL
  not_logged 'user:setting' 'no email: not set'
  eq 0 "$NC_RC" 'no email: exit status 0'
  nc_run "$hook" -NEXTCLOUD_ADMIN_USER "$mail"
  not_logged 'user:setting' 'no admin user: not set'
  eq 0 "$NC_RC" 'no admin user: exit status 0'
  logged 'app:install groupfolders' 'no admin user: the other steps still run'

  echo ' one step fails'
  appcfg_reset '{}'
  nc_run "$hook" "$admin" "$mail" 'FAKE_FAIL=app:install contacts'
  eq 0 "$NC_RC" 'app:install contacts fails: exit status 0'
  contains '[nextcloud] WARNING:' "$NC_ERR" 'app:install contacts fails: a WARNING line'
  contains 'app:install contacts' "$NC_ERR" 'app:install contacts fails: the warning names the step'
  eq 1 "$(grep -c WARNING <<<"$NC_ERR")" 'app:install contacts fails: one warning'
  logged_in_order 'app:install contacts fails: groupfolders is still installed' 'app:install calendar' 'app:install contacts' 'app:install groupfolders'
  # The pass ran to its end, so the marker goes in: a store that can't be reached must not make every later start try
  # the downloads again. The AI Assistant adds the app later.
  matches "^$ISO_UTC_RE\$" "$(appcfg_get clouve first_install_done)" 'app:install contacts fails: the pass ran to its end, so the marker is written'
  nc_run "$hook" "$admin" "$mail" 'FAKE_FAIL=user:setting'
  eq 0 "$NC_RC" 'the first step fails: exit status 0'
  logged_in_order 'the first step fails: all the others still run' "${steps[@]:1}"

  echo ' an app that an earlier install left in custom_apps/'
  # app:install says "already installed" with exit status 1 and leaves such an app disabled, so app:enable has to run.
  nc_run "$hook" "$admin" "$mail" FAKE_APPS_ON_DISK=contacts
  eq 0 "$NC_RC" 'exit status 0'
  contains 'contacts already installed' "$NC_OUT" 'app:install says why it fails'
  eq '[nextcloud] WARNING: occ app:install contacts failed (exit status 1)' "$NC_ERR" 'one warning, for app:install contacts'
  logged_in_order 'app:getpath finds contacts and app:enable runs for it, and groupfolders comes after' \
    'app:install contacts' 'app:getpath contacts' 'app:enable contacts' 'app:install groupfolders'
  contains 'contacts 1.0.0 enabled' "$NC_OUT" 'app:enable enables it'
  eq "$all_enabled" "$(fake_apps)" 'all three apps end up enabled'
  nc_run "$hook" "$admin" "$mail" 'FAKE_APPS_ON_DISK=calendar|contacts|groupfolders'
  eq "$all_enabled" "$(fake_apps)" 'all three left behind: all three end up enabled'
  eq 3 "$(grep -c WARNING <<<"$NC_ERR")" 'all three left behind: one warning for each app:install'

  echo ' the app store is out of reach'
  # app:enable downloads an app that is not on disk. After a failed app:install it would add a second warning for the
  # same app, and after a failed release download it would try that download again: Nextcloud keeps a failed fetch of
  # the store's app list for 5 minutes, but it keeps no record of a failed release download. app:enable runs only for an
  # app on disk, so each missing app gets one warning and one download.
  nc_run "$hook" "$admin" "$mail" 'FAKE_FAIL=app:install|app:enable'
  eq 0 "$NC_RC" 'exit status 0'
  eq 3 "$(grep -c WARNING <<<"$NC_ERR")" 'one warning for each app:install'
  logged_in_order 'each app is still looked for' 'app:getpath calendar' 'app:getpath contacts' 'app:getpath groupfolders'
  not_logged 'app:enable' 'app:enable never runs: no app is on disk'
  eq '{}' "$(fake_apps)" 'no app is on disk'

  echo ' a download that stalls is stopped'
  # Run from occ, Nextcloud gives the release download no time limit (lib/private/Installer.php: $isCLI ? 0 : 120), so
  # the hook bounds each app:install and app:enable itself: NC_APP_INSTALL_TIMEOUT seconds, 300 when it is not set.
  # FAKE_HANG makes the fake wait 30 s first, as a download host that stalls does.
  start=$SECONDS
  nc_run "$hook" "$admin" "$mail" NC_APP_INSTALL_TIMEOUT=1 'FAKE_HANG=app:install contacts'
  elapsed=$((SECONDS - start))
  eq 0 "$NC_RC" 'exit status 0'
  matches '^[1-9]$' "$elapsed" "app:install contacts is stopped after 1 s, so the hook does not wait out the 30 s (it took $elapsed s)"
  eq '[nextcloud] WARNING: occ app:install contacts did not finish within 1 s and was stopped. The start goes on without contacts, and the AI Assistant can add it later.' \
    "$NC_ERR" 'one warning, which names the app and the time limit'
  logged_in_order 'the next app is still installed and enabled' \
    'app:install contacts' 'app:getpath contacts' 'app:install groupfolders' 'app:getpath groupfolders' 'app:enable groupfolders'
  not_logged 'app:enable contacts' 'contacts is not on disk, so app:enable is not tried for it'
  eq '{"calendar":"enabled","groupfolders":"enabled"}' "$(fake_apps)" 'the stopped app:install left nothing on disk'

  start=$SECONDS
  nc_run "$hook" "$admin" "$mail" NC_APP_INSTALL_TIMEOUT=1 FAKE_APPS_ON_DISK=contacts 'FAKE_HANG=app:enable contacts'
  elapsed=$((SECONDS - start))
  eq 0 "$NC_RC" 'app:enable stalls: exit status 0'
  matches '^[1-9]$' "$elapsed" "app:enable stalls: it is stopped after 1 s (the hook took $elapsed s)"
  eq $'[nextcloud] WARNING: occ app:install contacts failed (exit status 1)\n[nextcloud] WARNING: occ app:enable contacts did not finish within 1 s and was stopped. The start goes on without contacts, and the AI Assistant can add it later.' \
    "$NC_ERR" 'app:enable stalls: the "already installed" warning, then the time limit, both naming the app'
  eq '{"calendar":"enabled","contacts":"disabled","groupfolders":"enabled"}' "$(fake_apps)" 'app:enable stalls: contacts stays as it was, and the others are enabled'

  # An occ that ignores SIGTERM is killed 10 s after the time limit.
  start=$SECONDS
  nc_run "$hook" "$admin" "$mail" NC_APP_INSTALL_TIMEOUT=1 'FAKE_HANG=app:install calendar' FAKE_HANG_IGNORES_TERM=1 \
    "OCC=php -n -d extension=pcntl -d display_errors=stderr $NCW/bin/occ.php"
  elapsed=$((SECONDS - start))
  eq 0 "$NC_RC" 'an occ that ignores SIGTERM: exit status 0'
  if [[ "$elapsed" -ge 11 && "$elapsed" -lt 25 ]]; then pass "an occ that ignores SIGTERM is killed 10 s after the time limit (the hook took $elapsed s)"; else fail "an occ that ignores SIGTERM is killed 10 s after the time limit (the hook took $elapsed s, wanted 11 to 24)"; fi
  eq '[nextcloud] WARNING: occ app:install calendar did not finish within 1 s and was stopped. The start goes on without calendar, and the AI Assistant can add it later.' \
    "$(grep -F '[nextcloud] WARNING:' <<<"$NC_ERR")" 'an occ that ignores SIGTERM: the same warning'
  eq '{"contacts":"enabled","groupfolders":"enabled"}' "$(fake_apps)" 'an occ that ignores SIGTERM: calendar is not on disk'

  echo ' the time limit is 300 s, and only the app commands have one'
  fake_cmd "$NCW/spy" timeout <<'EOF'
printf '%s\n' "$*" >> "$LOG.timeout"
exec /usr/bin/timeout "$@"
EOF
  for value in unset abc 0 '' 5m; do
    if [[ "$value" == unset ]]; then
      # shellcheck disable=SC2031  # as above: this shell's PATH is what is extended
      nc_run "$hook" "$admin" "$mail" -NC_APP_INSTALL_TIMEOUT "PATH=$NCW/spy:$NCW/bin:$PATH"
    else
      # shellcheck disable=SC2031  # as above: this shell's PATH is what is extended
      nc_run "$hook" "$admin" "$mail" "NC_APP_INSTALL_TIMEOUT=$value" "PATH=$NCW/spy:$NCW/bin:$PATH"
    fi
    # nc_run's own `timeout 120 sh -c <hook>` finds the spy too. That line is the harness's, not the hook's.
    eq "$(printf -- "-k 10 300 php -n -d display_errors=stderr $NCW/bin/occ.php %s\n" 'app:install calendar' 'app:enable calendar' 'app:install contacts' 'app:enable contacts' 'app:install groupfolders' 'app:enable groupfolders')" \
      "$(grep -vxF "120 sh -c $hook" "$NCW_LOG.timeout" 2>/dev/null)" "NC_APP_INSTALL_TIMEOUT ${value}: each app:install and app:enable runs under timeout -k 10 300, and nothing else does"
    eq 0 "$NC_RC" "NC_APP_INSTALL_TIMEOUT ${value}: exit status 0"
  done

  echo ' nextcloud-config.sh fails'
  nc_run "$hook" "$admin" "$mail" FAKE_FAIL=status
  eq 0 "$NC_RC" 'exit status 0'
  contains 'nextcloud-config.sh' "$NC_ERR" 'a warning names nextcloud-config.sh'
  logged_in_order 'the steps still run' "${steps[@]}"

  echo ' everything fails'
  appcfg_reset '{}'
  nc_run "$hook" "$admin" "$mail" 'FAKE_FAIL=*'
  eq 0 "$NC_RC" 'exit status 0'
  eq 17 "$(grep -c '\[nextcloud\] WARNING:' <<<"$NC_ERR")" 'one warning for nextcloud-config.sh, one for each of the 14 steps and one for each marker (occ status gave no version for the first)'
  logged_in_order 'every step was still tried' "${steps[@]}"
  not_logged 'app:enable' 'app:getpath fails too, so app:enable is not tried'
  contains '[nextcloud] WARNING: could not record that the first-install settings are done' "$NC_ERR" 'a warning says the marker could not be written'
  contains '[nextcloud] WARNING: occ status gave no version, so the post-upgrade steps are not recorded as done' "$NC_ERR" 'and one that the post-upgrade marker has no version to hold'
  eq '<unset>' "$(appcfg_get clouve first_install_done)" 'no marker, so the next start tries the steps again'
  no_secret adminpw-xyz 'the admin password appears in no output and no argument'
  no_secret s3cret 'the database password appears in no output and no argument'

  echo ' HOME is www-data'"'"'s, whatever the caller had'
  nc_run "$hook" "$admin" "$mail" HOME=/root
  eq 0 "$NC_RC" 'exit status 0'
  home_is /var/www 'every occ call runs with HOME=/var/www, the ones of nextcloud-config.sh included'

  echo ' no OCC in the environment'
  fake_php_log "$NCW/phplog"
  # shellcheck disable=SC2031  # as above: this shell's PATH is what is extended
  nc_run "$hook" "$admin" "$mail" -OCC "PATH=$NCW/phplog:$NCW/bin:$PATH"
  eq 0 "$NC_RC" 'exit status 0'
  contains $'\n/var/www/html/occ background:cron\n' $'\n'"$(cat "$NCW_LOG.php")"$'\n' 'it runs php /var/www/html/occ'

  echo ' the file'
  eq '#!/bin/bash' "$(head -n 1 "$hook")" 'it starts with #!/bin/bash'
  no_xtrace "$hook"
  eq 0 "$(grep -v '^[[:space:]]*#' "$hook" | grep -c flock)" 'it never runs flock'
}

# --- post-upgrade ------------------------------------------------------------------
section_hook_post_upgrade() {
  local hook="$HOOKS/post-upgrade/10-clouve.sh"
  need_script "$hook" || return 0
  nc_world "$WORK/w-post-upgrade"
  cfg_reset "$NCW_BASE"

  echo ' the four repairs, in order, between the delete and the write of the marker, and nothing else'
  nc_run "$hook"
  eq 0 "$NC_RC" 'exit status 0'
  eq $'status --output=json --no-warnings\nconfig:app:delete clouve post_upgrade_done\ndb:add-missing-indices\ndb:add-missing-columns\ndb:add-missing-primary-keys\nmaintenance:repair --include-expensive\nconfig:app:set clouve post_upgrade_done --lazy --value=35.0.2.2' \
    "$(cat "$NCW_LOG")" 'occ was asked for exactly these: the status, the marker deleted, the four steps, the marker written'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the marker clouve post_upgrade_done holds the version occ status gave'
  contains '[nextcloud] post-upgrade steps done for 35.0.2.2' "$NC_OUT" 'stdout says they are done, and for which version'
  eq '' "$NC_ERR" 'nothing on stderr'

  echo ' a failing step does not stop the others'
  nc_run "$hook" FAKE_FAIL=db:add-missing-indices
  eq 0 "$NC_RC" 'the first fails: exit status 0'
  contains 'db:add-missing-indices' "$NC_ERR" 'the first fails: the warning names it'
  eq 4 "$(grep -cE '^(db:add-missing-|maintenance:repair )' "$NCW_LOG")" 'the first fails: all four were tried'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the first fails: the marker is still written, since the steps ran to their end'
  nc_run "$hook" 'FAKE_FAIL=maintenance:repair'
  eq 0 "$NC_RC" 'the last fails: exit status 0'
  contains '[nextcloud] WARNING:' "$NC_ERR" 'the last fails: a WARNING line'
  nc_run "$hook" 'FAKE_FAIL=*'
  eq 0 "$NC_RC" 'all fail: exit status 0'
  eq 1 "$(grep -c '\[nextcloud\] WARNING:' <<<"$NC_ERR")" 'all fail: one warning, since the delete of the marker fails first'
  eq 0 "$(grep -cE '^(db:add-missing-|maintenance:repair )' "$NCW_LOG")" 'all fail: and then no step runs, so that a cut-off run cannot leave the old marker behind'
  nc_run "$hook" 'FAKE_FAIL=db:add-missing|maintenance:repair'
  eq 4 "$(grep -c '\[nextcloud\] WARNING:' <<<"$NC_ERR")" 'all four steps fail: four warnings'
  eq 4 "$(grep -cE '^(db:add-missing-|maintenance:repair )' "$NCW_LOG")" 'all four steps fail: all four were tried'

  echo ' the start is cut off during the repair: maintenance mode stays on and the marker is gone, and the next start finishes them'
  cfg_reset "$NCW_LIVE"
  appcfg_reset "$MARKERS_DONE"
  NC_RUN_KILL=3 nc_run "$hook" FAKE_STATUS_JSON=live FAKE_HANG=maintenance:repair
  eq 137 "$NC_RC" 'the hook and everything it started were killed (SIGKILL)'
  logged_in_order 'the kill came during the repair, after the marker was deleted' 'config:app:delete clouve post_upgrade_done' 'maintenance:repair --include-expensive'
  eq true "$(cfg_get maintenance)" 'maintenance mode is on: the repair turned it on and never put it back'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'the marker is gone'
  nc_run "$HOOKS/before-starting/10-clouve.sh" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'the next start: the before-starting hook exits 0'
  contains 'Maintenance mode is on, left by a start that was cut off during the post-upgrade steps for 35.0.2.2' "$NC_OUT" 'the next start: it says why it turns maintenance mode off'
  logged_in_order 'the next start: maintenance mode off, then the post-upgrade steps under the init lock' \
    'config:app:get clouve post_upgrade_done --default-value= --no-warnings' 'maintenance:mode --off' 'flock /var/www/html/nextcloud-init-sync\.lock bash -c .*' \
    'db:add-missing-indices' 'maintenance:repair --include-expensive' 'config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2' 'flock released'
  eq false "$(cfg_get maintenance)" 'the next start: maintenance mode is off at the end'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the next start: the marker is written'

  echo ' that start was cut off too, and this one is an upgrade: occ upgrade keeps the maintenance mode it finds on'
  # The official entrypoint upgrades before any hook runs, so the before-starting hook would find the marker written by
  # this hook and maintenance mode still on. A missing marker says that the start before was cut off, so this hook turns
  # maintenance mode off first.
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$FIRST_INSTALL_ONLY"
  nc_run "$hook" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'exit status 0'
  contains 'Turning it off first' "$NC_OUT" 'stdout says why maintenance mode goes off'
  logged_in_order 'the marker is read, maintenance mode goes off, then the steps' 'status --output=json --no-warnings' \
    'config:app:get clouve post_upgrade_done --default-value= --no-warnings' 'maintenance:mode --off' 'config:app:delete clouve post_upgrade_done' \
    'db:add-missing-indices' 'maintenance:repair --include-expensive' 'config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2'
  eq false "$(cfg_get maintenance)" 'maintenance mode is off at the end'
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$MARKERS_DONE"
  nc_run "$hook" FAKE_STATUS_JSON=live
  not_logged 'maintenance:mode' 'the marker is there: maintenance mode was turned on some other way, maybe on purpose, so it is not touched'
  eq true "$(cfg_get maintenance)" 'the marker is there: maintenance mode is still on (the repair put back the on it found)'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the marker is there: the steps ran and wrote it again'
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$FIRST_INSTALL_ONLY"
  mark RESTORE-IN-PROGRESS 20261024-101500
  nc_run "$hook" FAKE_STATUS_JSON=live
  not_logged 'maintenance:mode' 'no marker, but a restore was cut off: maintenance mode is not touched'
  eq true "$(cfg_get maintenance)" 'no marker, but a restore was cut off: maintenance mode is still on'
  unmark
  cfg_reset "$NCW_BASE"

  echo ' HOME is www-data'"'"'s, whatever the caller had'
  nc_run "$hook" HOME=/root
  eq 0 "$NC_RC" 'exit status 0'
  home_is /var/www 'every occ call runs with HOME=/var/www'

  echo ' no OCC in the environment'
  fake_php_log "$NCW/phplog"
  # shellcheck disable=SC2031  # as above: this shell's PATH is what is extended
  nc_run "$hook" -OCC "PATH=$NCW/phplog:$NCW/bin:$PATH"
  eq 0 "$NC_RC" 'exit status 0'
  # This php fails every call, so the delete of the marker fails and the steps stop there.
  contains $'\n/var/www/html/occ config:app:delete clouve post_upgrade_done\n' $'\n'"$(cat "$NCW_LOG.php")"$'\n' 'it runs php /var/www/html/occ'

  echo ' the file'
  eq '#!/bin/bash' "$(head -n 1 "$hook")" 'it starts with #!/bin/bash'
  no_xtrace "$hook"
  eq 0 "$(grep -v '^[[:space:]]*#' "$hook" | grep -c flock)" 'it never runs flock'
}

# --- before-starting -----------------------------------------------------------------
# Runs at every start, after the official entrypoint has let go of its lock. The first line of the log is always the hook's own
# `occ status`; nextcloud-config.sh then adds its own calls.
section_hook_before_starting() {
  local hook="$HOOKS/before-starting/10-clouve.sh" refusal lockre marker=/var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS
  local healthy killed pending new sp
  need_script "$hook" || return 0
  refusal='[nextcloud] Nextcloud is not installed; refusing to start. See apps/nextcloud/README.md, "A half-finished first install".'
  lockre='flock /var/www/html/nextcloud-init-sync\.lock bash -c .*'
  healthy="$(occ_status_json true false false)"
  killed="$(occ_status_json true true true)"
  pending="$(occ_status_json true false true)"
  new="$(occ_status_json false false false)"
  nc_world "$WORK/w-before-starting"

  echo ' Nextcloud is not installed: refuse to start'
  cfg_reset "$NCW_BASE"
  nc_run "$hook" "FAKE_STATUS_JSON=$new"
  eq 1 "$NC_RC" 'exit status 1'
  eq "$refusal" "$NC_OUT" 'stdout is the refusal line, and only that'
  eq 'status --output=json --no-warnings' "$(cat "$NCW_LOG")" 'occ was asked for the status, and nothing else'
  nc_run "$hook" "FAKE_STATUS_JSON=$(occ_status_json false true true)"
  eq 1 "$NC_RC" 'not installed, whatever else the status says: exit status 1'
  eq "$refusal" "$NC_OUT" 'not installed, whatever else the status says: the refusal line'
  not_logged 'upgrade' 'not installed: no upgrade'
  not_logged 'flock' 'not installed: no lock'
  not_logged 'config:system:set' 'not installed: no setting is touched'

  echo ' installed and healthy: only the settings'
  cfg_reset "$NCW_BASE"
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" HOME=/root
  eq 0 "$NC_RC" 'exit status 0'
  home_is /var/www 'every occ call runs with HOME=/var/www (su -p leaves HOME=/root, and PHP then logs Fontconfig errors)'
  eq 'status --output=json --no-warnings' "$(head -n 1 "$NCW_LOG")" 'the first call is occ status --output=json --no-warnings'
  logged_re 'config:system:set memcache.locking .*' 'nextcloud-config.sh ran'
  eq '"https"' "$(cfg_get overwriteprotocol)" 'nextcloud-config.sh ran: overwriteprotocol is https'
  not_logged 'flock' 'no lock'
  not_logged 'upgrade' 'no upgrade'
  not_logged 'maintenance:mode' 'maintenance mode is not touched'
  eq '' "$NC_ERR" 'nothing on stderr'
  no_secret s3cret 's3cret appears in no output and no argument'

  echo ' an upgrade that was cut off: maintenance on, upgrade pending, log level 0'
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" HOME=/root
  eq 0 "$NC_RC" 'exit status 0'
  logged_in_order 'it turns maintenance off and resets the log level, then upgrades under the init lock and runs the post-upgrade steps under it, then applies the settings' \
    'status --output=json --no-warnings' 'maintenance:mode --off' 'config:system:get loglevel' 'config:system:set loglevel --type=integer --value=2' \
    "$lockre" 'upgrade --no-interaction' \
    'db:add-missing-indices' 'db:add-missing-columns' 'db:add-missing-primary-keys' 'maintenance:repair --include-expensive' \
    'flock released' 'status --output=json' 'config:system:set memcache.locking .*'
  eq 1 "$(grep -c '^upgrade' "$NCW_LOG")" 'occ upgrade runs once'
  eq 1 "$(grep -c '^config:system:get loglevel' "$NCW_LOG")" 'the log level is read once, before the upgrade: occ upgrade puts back what it found'
  eq 1 "$(grep -c '^flock /' "$NCW_LOG")" 'one flock, for the upgrade and the steps after it'
  eq 1 "$(grep -c '^db:add-missing-indices' "$NCW_LOG")" 'each post-upgrade step runs once'
  eq 1 "$(grep -c '^maintenance:mode' "$NCW_LOG")" 'maintenance mode is turned off once, before the upgrade (occ upgrade turns it on and off itself)'
  eq 1 "$(grep -c '^config:system:set loglevel' "$NCW_LOG")" 'the log level is set once, before the upgrade (occ upgrade puts back the level it found)'
  home_is /var/www 'every occ call runs with HOME=/var/www, the locked ones too'
  eq 'false' "$(cfg_get maintenance)" 'config.php: maintenance is off'
  eq '2' "$(cfg_get loglevel)" 'config.php: loglevel is the integer 2'
  eq '' "$NC_ERR" 'nothing on stderr'
  contains 'upgrade' "$NC_OUT" 'stdout says that an upgrade is being finished'

  echo ' the start is cut off again, during the steps after the upgrade'
  # The steps after occ upgrade can take minutes on a big instance. A kill then must leave an instance that works, because
  # nothing at the next start would finish it: no upgrade is pending any more. FAKE_HANG holds the first step for 30 s.
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"maintenance":true,"loglevel":0}'
  NC_RUN_KILL=3 nc_run "$hook" "FAKE_STATUS_JSON=$killed" FAKE_HANG=db:add-missing-indices
  eq 137 "$NC_RC" 'the hook and everything it started were killed (SIGKILL)'
  logged_in_order 'the kill came during the first step after the upgrade' 'upgrade --no-interaction' 'db:add-missing-indices'
  not_logged 'db:add-missing-columns' 'no step after it ran'
  eq 'false' "$(cfg_get maintenance)" 'config.php: maintenance mode is off, so the next start serves Nextcloud'
  eq '2' "$(cfg_get loglevel)" 'config.php: the log level is 2, not the 0 (debug) of a running upgrade'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'the marker clouve post_upgrade_done is gone (the steps delete it first), so the next start finishes them'

  echo ' the start is cut off during the repair after the upgrade: maintenance mode stays on, and the next start finishes the steps'
  # The status follows config.php here (live): a killed occ upgrade left maintenance on, an older version and log level 0.
  cfg_reset "$(live_with '"maintenance":true,"loglevel":0,"version":"35.0.1.0"')"
  appcfg_reset "$MARKERS_DONE"
  NC_RUN_KILL=3 nc_run "$hook" FAKE_STATUS_JSON=live FAKE_HANG=maintenance:repair
  eq 137 "$NC_RC" 'the hook and everything it started were killed (SIGKILL)'
  logged_in_order 'the kill came during the repair, after the upgrade' 'upgrade --no-interaction' 'maintenance:repair --include-expensive'
  eq '"35.0.2.2"|true|<unset>' "$(cfg_get version)|$(cfg_get maintenance)|$(appcfg_get clouve post_upgrade_done)" \
    'the upgrade is done, maintenance mode is on (the repair turned it on), and the marker is gone: nothing is pending'
  nc_run "$hook" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'the next start: exit status 0'
  not_logged 'upgrade' 'the next start: no upgrade (none is pending)'
  contains 'Maintenance mode is on, left by a start that was cut off during the post-upgrade steps for 35.0.2.2' "$NC_OUT" 'the next start: it says why it turns maintenance mode off'
  logged_in_order 'the next start: maintenance mode off, then the post-upgrade steps under the init lock, and the marker last' \
    'maintenance:mode --off' "$lockre" 'db:add-missing-indices' 'db:add-missing-columns' 'db:add-missing-primary-keys' \
    'maintenance:repair --include-expensive' 'config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2' 'flock released'
  eq 'false|2|35.0.2.2' "$(cfg_get maintenance)|$(cfg_get loglevel)|$(appcfg_get clouve post_upgrade_done)" \
    'the next start: maintenance mode is off, the log level is 2, and the marker holds the version'
  nc_run "$hook" FAKE_STATUS_JSON=live
  not_logged 'flock' 'the start after that: nothing runs again'
  appcfg_reset "$MARKERS_DONE"

  echo ' maintenance mode does not go off before the upgrade: it is tried once more after the upgrade has worked'
  # occ upgrade leaves on a maintenance mode it finds on, so without the second try the instance would stay in it.
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" 'FAKE_FAIL_ONCE=maintenance:mode --off'
  eq 0 "$NC_RC" 'exit status 0'
  eq '[nextcloud] WARNING: could not turn maintenance mode off before the upgrade, so it is tried again after it' "$(grep WARNING <<<"$NC_ERR")" 'one warning, which says it is tried again'
  logged_in_order 'the second try comes once the upgrade and the steps after it are done, before the settings' \
    'maintenance:mode --off' "$lockre" 'upgrade --no-interaction' 'maintenance:repair --include-expensive' 'flock released' \
    'maintenance:mode --off' 'status --output=json'
  eq 2 "$(grep -c '^maintenance:mode --off' "$NCW_LOG")" 'two tries'
  eq 'false' "$(cfg_get maintenance)" 'config.php: maintenance is off (occ upgrade found it on and left it on, and the second try turned it off)'
  eq '2' "$(cfg_get loglevel)" 'config.php: loglevel is 2'

  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" 'FAKE_FAIL=maintenance:mode --off'
  eq 0 "$NC_RC" 'both tries fail: exit status 0'
  eq 2 "$(grep -c '^maintenance:mode --off' "$NCW_LOG")" 'both tries fail: two tries, and no more'
  contains 'could not turn maintenance mode off after the upgrade either, so Nextcloud starts in maintenance mode' "$NC_ERR" 'both tries fail: a warning says that Nextcloud starts in maintenance mode'
  eq 'true' "$(cfg_get maintenance)" 'both tries fail: config.php: maintenance is still on'

  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" 'FAKE_FAIL_ONCE=maintenance:mode --off' FAKE_UPGRADE_FAILS=1
  eq 0 "$NC_RC" 'the upgrade fails too: exit status 0'
  eq 1 "$(grep -c '^maintenance:mode --off' "$NCW_LOG")" 'the upgrade fails too: no second try (the upgrade is still pending)'
  contains 'occ upgrade failed (exit status 5)' "$NC_ERR" 'the upgrade fails too: the warning says so'

  echo ' an upgrade is pending, and maintenance mode was off'
  cfg_reset "$NCW_BASE"
  nc_run "$hook" "FAKE_STATUS_JSON=$pending"
  eq 0 "$NC_RC" 'exit status 0'
  logged_in_order 'it upgrades under the lock, with the post-upgrade steps after it' "$lockre" 'upgrade --no-interaction' \
    'db:add-missing-indices' 'db:add-missing-columns' 'db:add-missing-primary-keys' 'maintenance:repair --include-expensive' 'flock released'
  not_logged 'maintenance:mode' 'maintenance mode was not on: it is not touched'
  not_logged 'config:system:set loglevel' 'no log level was set: none is written'

  echo ' maintenance mode is on and no upgrade is pending: someone turned it on, and it stays on'
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"http://localhost","trusted_domains":["localhost"],"maintenance":true}'
  nc_run "$hook" "FAKE_STATUS_JSON=$(occ_status_json true true false)"
  eq 0 "$NC_RC" 'exit status 0'
  not_logged 'flock' 'no lock'
  not_logged 'upgrade' 'no upgrade'
  not_logged 'maintenance:mode' 'maintenance mode is not touched'
  eq 'true' "$(cfg_get maintenance)" 'config.php: maintenance is still on'

  echo ' a post-upgrade step fails: the others still run, and so does the rest of the start'
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"http://localhost","trusted_domains":["localhost"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" FAKE_FAIL=db:add-missing-columns
  eq 0 "$NC_RC" 'exit status 0'
  eq '[nextcloud] WARNING: occ db:add-missing-columns failed (exit status 1)' "$(grep WARNING <<<"$NC_ERR")" 'one warning, naming the step'
  logged_in_order 'the steps after it still run, inside the lock' 'maintenance:mode --off' "$lockre" 'upgrade --no-interaction' \
    'db:add-missing-columns' 'db:add-missing-primary-keys' 'maintenance:repair --include-expensive' 'flock released'
  eq 'false' "$(cfg_get maintenance)" 'maintenance mode is off'

  echo ' the log level is only reset from 0'
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"http://localhost","trusted_domains":["localhost"],"loglevel":1}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed"
  not_logged 'config:system:set loglevel' 'log level 1 is left alone'
  logged 'maintenance:mode --off' 'log level 1: maintenance is still turned off'

  echo ' the upgrade fails: the instance stays in maintenance mode, reachable'
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"http://localhost","trusted_domains":["localhost"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" FAKE_UPGRADE_FAILS=1
  eq 0 "$NC_RC" 'exit status 0 (Apache starts, in maintenance mode, and the probe counts that as healthy)'
  contains '[nextcloud] WARNING:' "$NC_ERR" 'a WARNING line'
  contains 'occ upgrade failed (exit status 5)' "$NC_ERR" 'the warning says that occ upgrade failed, and with what status'
  contains 'starts with the upgrade unfinished' "$NC_ERR" 'a second warning says that Nextcloud starts with the upgrade unfinished'
  logged_in_order 'maintenance mode off and the log level back first, then the upgrade under the lock' \
    'maintenance:mode --off' 'config:system:set loglevel --type=integer --value=2' "$lockre" 'upgrade --no-interaction' 'flock released'
  not_logged 'db:add-missing' 'the post-upgrade steps do not run on an upgrade that failed'
  not_logged 'maintenance:repair' 'nor the repair'
  eq 1 "$(grep -c '^config:system:set loglevel' "$NCW_LOG")" 'the log level is set once: occ upgrade put back the 2 it found'
  eq '2' "$(cfg_get loglevel)" 'config.php: loglevel is the integer 2'
  eq 'true' "$(cfg_get maintenance)" 'config.php: maintenance is on: occ upgrade turned it on and keeps it on after a failure'
  logged_re 'config:system:set memcache.locking .*' 'the settings are still applied'

  echo ' flock cannot open the lock file (www-data may not open a root-owned file in a sticky folder)'
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"http://localhost","trusted_domains":["localhost"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" FAKE_FLOCK_FAILS=66
  eq 0 "$NC_RC" 'exit status 0 (Apache starts, with the upgrade unfinished)'
  contains 'flock could not open /var/www/html/nextcloud-init-sync.lock' "$NC_ERR" 'the warning says which file flock could not open'
  contains 'starts with the upgrade unfinished' "$NC_ERR" 'and that Nextcloud starts with the upgrade unfinished'
  not_logged 'upgrade' 'no upgrade ran'
  not_logged 'db:add-missing' 'no post-upgrade step ran'
  eq '2' "$(cfg_get loglevel)" 'the log level is back to 2 here too'
  eq 'false' "$(cfg_get maintenance)" 'config.php: maintenance mode is off and the upgrade still pending, which shows people only the page that asks for occ upgrade'

  echo ' a restore was cut off: its marker is there'
  mkdir -p "$(dirname "$marker")"
  : > "$marker"
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"http://localhost","trusted_domains":["localhost"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed"
  eq 0 "$NC_RC" 'exit status 0'
  contains 'RESTORE-IN-PROGRESS' "$NC_ERR" 'a warning names the marker'
  not_logged 'flock' 'no upgrade is run on a half-restored instance'
  not_logged 'upgrade' 'no upgrade is run on a half-restored instance (nothing starts it)'
  not_logged 'db:add-missing' 'no post-upgrade step runs either'
  not_logged 'config:system:set loglevel' 'and the log level is left alone'
  not_logged 'maintenance:mode' 'maintenance mode stays on'
  eq 'true' "$(cfg_get maintenance)" 'config.php: maintenance is still on'
  logged_re 'config:system:set memcache.locking .*' 'the settings are still applied'
  rm -rf /var/www/html/data

  echo " a restore was cut off, and only the root entrypoint's note says so (www-data can't see into the backups folder)"
  mkdir -p /run/clouve
  : > /run/clouve/restore-cut-off
  cfg_reset '{"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"http://localhost","trusted_domains":["localhost"],"maintenance":true,"loglevel":0}'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed"
  eq 0 "$NC_RC" 'exit status 0'
  contains 'A restore was cut off' "$NC_ERR" 'a warning says that a restore was cut off'
  not_logged 'upgrade' 'no upgrade is run'
  not_logged 'maintenance:mode' 'maintenance mode stays on'
  eq 'true' "$(cfg_get maintenance)" 'config.php: maintenance is still on'
  rm -f /run/clouve/restore-cut-off

  echo ' text from php around the JSON'
  cfg_reset "$NCW_BASE"
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" $'FAKE_STATUS_PRE=PHP Warning:  Module "intl" is already loaded\nNotice: something' $'FAKE_STATUS_POST=PHP Warning: at shutdown'
  eq 0 "$NC_RC" 'installed: exit status 0'
  not_logged 'upgrade' 'installed: no upgrade'
  nc_run "$hook" "FAKE_STATUS_JSON=$new" $'FAKE_STATUS_PRE=PHP Warning:  x' $'FAKE_STATUS_POST=PHP Warning: y'
  eq 1 "$NC_RC" 'not installed: exit status 1'
  eq "$refusal" "$NC_OUT" 'not installed: the refusal line'
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" $'FAKE_STATUS_PRE=PHP Warning:  x' $'FAKE_STATUS_POST=PHP Warning: y'
  logged 'maintenance:mode --off' 'a cut-off upgrade is still found: maintenance mode is turned off'

  echo ' occ cannot report the status'
  cfg_reset "$NCW_BASE"
  nc_run "$hook" FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'occ is down: exit status 1'
  lacks 'not installed' "$NC_OUT" 'occ is down: it does not say Nextcloud is not installed'
  contains 'ERROR' "$NC_ERR" 'occ is down: an ERROR line on stderr'
  contains 'Failed to connect to the database' "$(grep 'so Nextcloud is not started' <<<"$NC_ERR")" "occ is down: the hook's own error line shows what occ said"
  not_logged 'upgrade' 'occ is down: no upgrade'
  nc_run "$hook" FAKE_STATUS_JSON=none
  eq 1 "$NC_RC" 'occ prints no JSON: exit status 1'
  lacks 'not installed' "$NC_OUT" 'occ prints no JSON: it does not say Nextcloud is not installed'
  contains 'ERROR' "$NC_ERR" 'occ prints no JSON: an ERROR line on stderr'

  echo " occ cannot report the status while a restore is cut off: the start goes on, so the AI Assistant can reach Nextcloud"
  mkdir -p /run/clouve
  : > /run/clouve/restore-cut-off
  cfg_reset "$NCW_BASE"
  nc_run "$hook" FAKE_OCC_DEAD=1
  eq 0 "$NC_RC" 'occ is down and a restore was cut off: exit status 0, so Apache starts'
  contains 'a restore was cut off' "$NC_ERR" 'a warning says why the start goes on'
  contains 'Failed to connect to the database' "$NC_ERR" 'the warning shows what occ said'
  lacks 'so Nextcloud is not started' "$NC_ERR" 'no refusal'
  not_logged 'upgrade' 'no upgrade'
  not_logged 'maintenance:mode' 'maintenance mode is not touched'
  cfg_reset "$NCW_BASE"
  # occ answers the hook's own status call and then stops answering, so nextcloud-config.sh exits 1 (check_occ).
  nc_run "$hook" "FAKE_STATUS_JSON=$killed" FAKE_STATUS_FAILS_FROM=2
  eq 0 "$NC_RC" 'nextcloud-config.sh fails while a restore is cut off: exit status 0'
  contains 'nextcloud-config.sh failed' "$NC_ERR" 'a warning says that the settings failed and why the start goes on'
  not_logged 'upgrade' 'the pending upgrade still waits'
  rm -f /run/clouve/restore-cut-off
  cfg_reset "$NCW_BASE"
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" FAKE_STATUS_FAILS_FROM=2
  if [[ "$NC_RC" -ne 0 ]]; then pass "without a cut-off restore, nextcloud-config.sh's failure still stops the start (exit $NC_RC)"; else fail 'without a cut-off restore, a failing nextcloud-config.sh should still stop the start'; fi
  nc_run "$hook" FAKE_OCC_DEAD=1
  eq 1 "$NC_RC" 'without a cut-off restore, occ that is down still stops the start'

  echo ' occ prints the JSON and then exits with an error'
  cfg_reset "$NCW_BASE"
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" FAKE_STATUS_RC=1
  eq 1 "$NC_RC" 'exit status 1'
  contains 'so Nextcloud is not started' "$NC_ERR" 'the hook does not trust the JSON of an occ that failed'
  not_logged 'upgrade' 'no upgrade'

  echo ' a clone: config.php names the old database host, so occ cannot start'
  cfg_reset '{"installed":true,"dbhost":"tkt-7-nextcloud-mariadb","dbname":"nextcloud","dbuser":"nextcloud","dbpassword":"s3cret","overwrite.cli.url":"https://abc.clouve.app","trusted_domains":["localhost","abc.clouve.app"],"secret":"keep-me"}'
  nc_run "$hook" NEXTCLOUD_DB_HOST=tkt-9-nextcloud-mariadb FAKE_DB_HOST_OK=tkt-9-nextcloud-mariadb
  eq 0 "$NC_RC" 'exit status 0'
  eq '"tkt-9-nextcloud-mariadb"' "$(cfg_get dbhost)" 'config.php: dbhost is the new host'
  eq '"keep-me"' "$(cfg_get secret)" 'config.php: the other keys are kept'
  not_logged 'upgrade' 'no upgrade'
  logged_re 'config:system:set memcache.locking .*' 'the settings are applied'
  no_secret s3cret 's3cret appears in no output and no argument'

  echo ' the exit status is the settings script'"'"'s'
  cfg_reset "$NCW_BASE"
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" FAKE_STATUS_FAILS_FROM=2
  eq 1 "$NC_RC" 'nextcloud-config.sh exits 1: so does the hook'
  contains 'ERROR' "$NC_ERR" 'nextcloud-config.sh exits 1: its ERROR line is in the log'

  echo ' no OCC in the environment'
  fake_php_log "$NCW/phplog"
  # shellcheck disable=SC2031  # as above: this shell's PATH is what is extended
  nc_run "$hook" -OCC "PATH=$NCW/phplog:$NCW/bin:$PATH"
  eq 1 "$NC_RC" 'exit status 1'
  contains $'\n/var/www/html/occ status --output=json --no-warnings\n' $'\n'"$(cat "$NCW_LOG.php")"$'\n' 'it runs php /var/www/html/occ'

  echo ' a stdin that never delivers'
  mkfifo "$NCW/stdin"
  sleep 60 > "$NCW/stdin" &
  sp=$!
  cfg_reset "$NCW_BASE"
  timeout 30 env -i "${NCW_ENV[@]}" sh -c "$hook" < "$NCW/stdin" > "$NCW/out" 2> "$NCW/err"
  eq 0 "$?" 'the hook does not wait for its stdin'
  kill "$sp" 2>/dev/null
  wait "$sp" 2>/dev/null

  echo ' the file'
  eq '#!/bin/bash' "$(head -n 1 "$hook")" 'it starts with #!/bin/bash'
  no_xtrace "$hook"
}

# --- before-starting: the first install's own settings, after a first start that was cut off --------------------------
# The official entrypoint runs the post-installation hook once, right after `occ maintenance:install`. A container killed
# while it runs never gets those settings: the next start finds Nextcloud installed and runs only before-starting. So
# nc_first_install_steps writes a marker (the app config value clouve first_install_done) as its last step, and
# before-starting runs the steps again, under the init lock, when an installed Nextcloud has no marker. A kill during
# their repair leaves maintenance mode on, so before-starting turns it off first.
section_hook_first_install_resume() {
  local hook="$HOOKS/before-starting/10-clouve.sh" lockre marker=/var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS
  local healthy admin="NEXTCLOUD_ADMIN_USER=O'Brien Smith" mail=NEXTCLOUD_ADMIN_EMAIL=owner@example.com
  local read_first='config:app:get clouve first_install_done --default-value= --no-warnings'
  local read_post='config:app:get clouve post_upgrade_done --default-value= --no-warnings'
  local -a resumed=("user:setting O'Brien Smith settings email owner@example.com" "${FIRST_INSTALL_STEPS[@]}")
  need_script "$hook" || return 0
  lockre='flock /var/www/html/nextcloud-init-sync\.lock bash -c .*'
  healthy="$(occ_status_json true false false)"
  nc_world "$WORK/w-first-install"

  echo ' the markers are there (every start after a first start that worked): nothing more happens'
  cfg_reset "$NCW_BASE"
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail"
  eq 0 "$NC_RC" 'exit status 0'
  eq "$read_first"$'\n'"$read_post" "$(tail -n 2 "$NCW_LOG")" 'the last two occ calls read the two markers, with an empty --default-value'
  eq 1 "$(grep -c '^status --output=json --no-warnings' "$NCW_LOG")" 'the status is not asked again'
  not_logged 'flock' 'no lock'
  not_logged 'background:cron' 'no first-install step runs'
  eq '' "$NC_ERR" 'nothing on stderr'

  echo ' no marker: the steps run again, under the init lock, after the settings, and the markers go in last'
  cfg_reset "$NCW_BASE"
  appcfg_reset '{}'
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail" HOME=/root
  eq 0 "$NC_RC" 'exit status 0'
  logged_in_order 'the settings, then the marker is read, the status asked again, and the steps run under the lock' \
    'status --output=json --no-warnings' 'status --output=json' 'config:system:set memcache.locking .*' \
    "$read_first" 'status --output=json --no-warnings' "$lockre" "${resumed[@]}" 'flock released' "$read_post"
  eq 1 "$(grep -c '^flock /' "$NCW_LOG")" 'one flock: the steps wrote the post-upgrade marker too, so step 5 has nothing to do'
  eq 1 "$(grep -c '^background:cron' "$NCW_LOG")" 'each step runs once'
  eq 1 "$(grep -c '^app:install groupfolders' "$NCW_LOG")" 'each app install runs once'
  eq '{"calendar":"enabled","contacts":"enabled","groupfolders":"enabled"}' "$(fake_apps)" 'the three apps are enabled'
  matches "^$ISO_UTC_RE\$" "$(appcfg_get clouve first_install_done)" 'the marker is written'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'and the post-upgrade marker, with the version'
  eq '"auto, 30"' "$(cfg_get trashbin_retention_obligation)" 'config.php: a first-install setting is in place'
  contains 'first start was cut off' "$NC_OUT" 'stdout says why the steps run again'
  not_logged 'maintenance:mode' 'maintenance mode was off: it is not touched'
  eq '' "$NC_ERR" 'nothing on stderr'
  home_is /var/www 'every occ call runs with HOME=/var/www, the locked ones too'
  no_secret s3cret 'the database password appears in no output and no argument'

  echo ' the next start: the markers are there, and nothing runs again'
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail"
  eq 0 "$NC_RC" 'exit status 0'
  not_logged 'flock' 'no lock'
  not_logged 'background:cron' 'no first-install step runs'

  echo ' that start is cut off too, during the repair: maintenance mode is on, and the one after it turns it off and finishes the steps'
  # As in the post-installation section, the repair hangs, not an app download (that one would outlive the kill). The
  # status follows config.php (live), so the next start sees what the kill left.
  cfg_reset "$NCW_LIVE"
  appcfg_reset '{}'
  NC_RUN_KILL=3 nc_run "$hook" FAKE_STATUS_JSON=live "$admin" "$mail" 'FAKE_HANG=maintenance:repair'
  eq 137 "$NC_RC" 'the hook and everything it started were killed (SIGKILL)'
  logged_in_order 'the kill came during maintenance:repair, under the lock' "$lockre" 'maintenance:repair --include-expensive'
  not_logged 'app:install' 'no step after it ran'
  eq '<unset>|true' "$(appcfg_get clouve first_install_done)|$(cfg_get maintenance)" 'no marker, and maintenance mode is on (the repair turned it on)'
  nc_run "$hook" FAKE_STATUS_JSON=live "$admin" "$mail"
  eq 0 "$NC_RC" 'the start after it: exit status 0'
  contains 'Maintenance mode is on, left by a start that was cut off during the first-install settings' "$NC_OUT" 'the start after it: it says that a cut-off first start left maintenance mode on'
  logged_in_order 'the start after it: maintenance mode off first, then the steps under the lock' \
    "$read_first" 'maintenance:mode --off' "$lockre" "${resumed[@]}" 'flock released'
  eq false "$(cfg_get maintenance)" 'the start after it: maintenance mode is off at the end'
  matches "^$ISO_UTC_RE\$" "$(appcfg_get clouve first_install_done)" 'the start after it: the marker is written'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the start after it: and the post-upgrade marker'

  echo ' a step fails: a warning, the start goes on, and the marker still goes in (the pass ran to its end)'
  cfg_reset "$NCW_BASE"
  appcfg_reset '{}'
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail" 'FAKE_FAIL=app:install'
  eq 0 "$NC_RC" 'exit status 0'
  eq 3 "$(grep -c '\[nextcloud\] WARNING: occ app:install' <<<"$NC_ERR")" 'one warning for each app:install'
  matches "^$ISO_UTC_RE\$" "$(appcfg_get clouve first_install_done)" 'the marker is written'

  echo ' the marker cannot be written: the next start tries again'
  appcfg_reset '{}'
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail" 'FAKE_FAIL=config:app:set clouve'
  eq 0 "$NC_RC" 'exit status 0'
  contains 'could not record that the first-install settings are done' "$NC_ERR" 'a warning says so'
  eq '<unset>' "$(appcfg_get clouve first_install_done)" 'no marker'

  echo ' maintenance mode is on and nothing is pending: it goes off first, and the steps run'
  # With the marker missing, Apache has not served since the install, so nobody can have turned it on on purpose.
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset '{}'
  nc_run "$hook" FAKE_STATUS_JSON=live "$admin" "$mail"
  eq 0 "$NC_RC" 'exit status 0'
  contains 'Maintenance mode is on, left by a start that was cut off during the first-install settings' "$NC_OUT" 'stdout says why it goes off'
  logged_in_order 'maintenance mode goes off before the lock is taken' "$read_first" 'status --output=json --no-warnings' 'maintenance:mode --off' "$lockre"
  eq false "$(cfg_get maintenance)" 'maintenance mode is off at the end'
  matches "^$ISO_UTC_RE\$" "$(appcfg_get clouve first_install_done)" 'the marker is written'
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset '{}'
  nc_run "$hook" FAKE_STATUS_JSON=live "$admin" "$mail" 'FAKE_FAIL=maintenance:mode --off'
  eq 0 "$NC_RC" 'it cannot be turned off: exit status 0'
  contains 'could not turn maintenance mode off, so the first-install settings wait for a later start' "$NC_ERR" 'it cannot be turned off: a warning says that the steps wait'
  not_logged 'flock' 'it cannot be turned off: no lock'
  not_logged 'background:cron' 'it cannot be turned off: no step runs'
  eq '<unset>' "$(appcfg_get clouve first_install_done)" 'it cannot be turned off: no marker, so the next start tries again'

  echo ' an upgrade is still pending: the steps wait for a later start'
  appcfg_reset '{}'
  cfg_reset "${NCW_BASE%\}},\"maintenance\":true,\"loglevel\":0}"
  nc_run "$hook" "FAKE_STATUS_JSON=$(occ_status_json true true true)" "$admin" "$mail" FAKE_UPGRADE_FAILS=1
  eq 0 "$NC_RC" 'an upgrade that fails: exit status 0'
  contains 'an upgrade is pending, so they wait for a later start' "$NC_OUT" 'an upgrade that fails: stdout says the steps wait'
  eq 1 "$(grep -c '^flock /' "$NCW_LOG")" 'an upgrade that fails: one flock, the upgrade'"'"'s'
  not_logged 'background:cron' 'an upgrade that fails: no first-install step runs'
  eq '<unset>' "$(appcfg_get clouve first_install_done)" 'an upgrade that fails: no marker'

  echo ' a restore was cut off: the steps wait, like the upgrade'
  appcfg_reset '{}'
  cfg_reset "$NCW_BASE"
  mkdir -p "$(dirname "$marker")"
  : > "$marker"
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail"
  eq 0 "$NC_RC" 'exit status 0'
  contains 'RESTORE-IN-PROGRESS' "$NC_ERR" 'a warning names the restore marker'
  not_logged 'flock' 'no lock'
  not_logged 'background:cron' 'no first-install step runs'
  rm -rf /var/www/html/data
  mkdir -p /run/clouve
  : > /run/clouve/restore-cut-off
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail"
  contains 'RESTORE-IN-PROGRESS' "$NC_ERR" "only the root entrypoint's note says so: the same warning"
  not_logged 'background:cron' "only the root entrypoint's note says so: no first-install step runs"
  rm -f /run/clouve/restore-cut-off

  echo ' the marker cannot be read: a warning, and nothing runs'
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail" 'FAKE_FAIL=config:app:get'
  eq 0 "$NC_RC" 'exit status 0'
  contains 'could not read the marker clouve first_install_done' "$NC_ERR" 'a warning names the marker'
  not_logged 'flock' 'no lock'
  not_logged 'background:cron' 'no first-install step runs'

  echo ' flock cannot open the lock file: a warning, and the next start tries again'
  appcfg_reset '{}'
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail" FAKE_FLOCK_FAILS=66
  eq 0 "$NC_RC" 'exit status 0'
  contains 'flock could not open /var/www/html/nextcloud-init-sync.lock' "$NC_ERR" 'the warning names the lock file'
  not_logged 'background:cron' 'no first-install step runs'
  eq '<unset>' "$(appcfg_get clouve first_install_done)" 'no marker'

  echo ' nextcloud-config.sh fails: the hook stops with its status, before the marker is read'
  appcfg_reset '{}'
  nc_run "$hook" "FAKE_STATUS_JSON=$healthy" "$admin" "$mail" FAKE_STATUS_FAILS_FROM=2
  eq 1 "$NC_RC" 'exit status 1'
  not_logged 'config:app:get' 'the marker is not read'
  not_logged 'flock' 'no lock'
}

# --- before-starting: the post-upgrade steps, after a start that was cut off during them -------------------------------
# nc_post_upgrade_steps deletes the marker clouve post_upgrade_done first and writes the version last, so a start cut off
# during them leaves it missing, and an older one never deleted names an older version. before-starting then runs them
# again under the init lock, and turns maintenance mode off first when their repair left it on. The status follows
# config.php here (live), so what one run leaves is what the next one finds.
section_hook_post_upgrade_resume() {
  local hook="$HOOKS/before-starting/10-clouve.sh" lockre read_post='config:app:get clouve post_upgrade_done --default-value= --no-warnings'
  local -a steps=('config:app:delete clouve post_upgrade_done' 'db:add-missing-indices' 'db:add-missing-columns' 'db:add-missing-primary-keys'
                  'maintenance:repair --include-expensive' 'config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2')
  need_script "$hook" || return 0
  lockre='flock /var/www/html/nextcloud-init-sync\.lock bash -c .*'
  nc_world "$WORK/w-post-upgrade-resume"

  echo ' the marker holds the version (every start after an upgrade whose steps finished): nothing runs'
  cfg_reset "$NCW_LIVE"
  nc_run "$hook" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'exit status 0'
  eq "$read_post" "$(tail -n 1 "$NCW_LOG")" 'the last occ call reads the marker'
  eq 1 "$(grep -c '^status --output=json --no-warnings' "$NCW_LOG")" 'the status is not asked again'
  not_logged 'flock' 'no lock'
  not_logged 'db:add-missing' 'no post-upgrade step runs'
  eq '' "$NC_ERR" 'nothing on stderr'

  echo ' the marker is missing: the steps run under the init lock, and write it'
  appcfg_reset "$FIRST_INSTALL_ONLY"
  nc_run "$hook" FAKE_STATUS_JSON=live HOME=/root
  eq 0 "$NC_RC" 'exit status 0'
  contains 'The post-upgrade steps for 35.0.2.2 were cut off at an earlier start (the marker clouve post_upgrade_done is missing). Running them again, under the init lock.' "$NC_OUT" 'stdout says why they run'
  logged_in_order 'the marker is read, the status asked again, then the steps under the lock' \
    "$read_post" 'status --output=json --no-warnings' "$lockre" "${steps[@]}" 'flock released'
  eq 1 "$(grep -c '^flock /' "$NCW_LOG")" 'one flock'
  eq 1 "$(grep -c '^db:add-missing-indices' "$NCW_LOG")" 'each step runs once'
  not_logged 'maintenance:mode' 'maintenance mode was off: it is not touched'
  not_logged 'background:cron' 'the first-install steps do not run: their marker is there'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the marker holds the version'
  eq false "$(cfg_get maintenance)" 'maintenance mode is off'
  home_is /var/www 'every occ call runs with HOME=/var/www, the locked ones too'
  eq '' "$NC_ERR" 'nothing on stderr'
  nc_run "$hook" FAKE_STATUS_JSON=live
  not_logged 'flock' 'the next start: nothing runs again'

  echo ' the marker names an older version (the steps never began for this one): the steps run'
  appcfg_reset '{"clouve":{"first_install_done":"2026-10-23T08:00:00Z","post_upgrade_done":"35.0.1.1"}}'
  nc_run "$hook" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'exit status 0'
  contains 'The post-upgrade steps have not run for 35.0.2.2 yet (the marker clouve post_upgrade_done says 35.0.1.1). Running them now, under the init lock, with maintenance mode left as it is.' \
    "$NC_OUT" 'stdout names the version the marker held'
  logged_in_order 'the steps run under the lock' "$lockre" "${steps[@]}" 'flock released'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the marker holds the version now'

  echo ' the marker names an older version and maintenance mode is on: it was turned on some other way, so it stays on, and the steps run'
  # nc_post_upgrade_steps deletes its marker before the repair, so a start cut off there leaves it missing, never older.
  # An older one means the steps never began for this version, for example after the AI Assistant finished an upgrade
  # at runtime (occ.sh --init-lock upgrade runs none of them) and an admin then turned maintenance mode on.
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset '{"clouve":{"first_install_done":"2026-10-23T08:00:00Z","post_upgrade_done":"35.0.1.1"}}'
  nc_run "$hook" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'exit status 0'
  not_logged 'maintenance:mode' 'maintenance mode is not touched'
  lacks 'Turning it off' "$NC_OUT" 'stdout says nothing about turning it off'
  logged_in_order 'the steps run under the lock, and write the marker' "$lockre" "${steps[@]}" 'flock released'
  eq true "$(cfg_get maintenance)" 'maintenance mode is still on (the repair put back the on it found)'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the marker holds the version now'
  nc_run "$hook" FAKE_STATUS_JSON=live
  not_logged 'flock' 'the next start: nothing runs again, and maintenance mode is still not touched'
  eq true "$(cfg_get maintenance)" 'the next start: maintenance mode is still on'
  cfg_reset "$NCW_LIVE"

  echo " maintenance mode is on (a cut-off start's repair left it on): it goes off first"
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$FIRST_INSTALL_ONLY"
  nc_run "$hook" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'exit status 0'
  contains 'Maintenance mode is on, left by a start that was cut off during the post-upgrade steps for 35.0.2.2 (their occ maintenance:repair turns it on while it runs). Turning it off before they run again.' \
    "$NC_OUT" 'stdout says why it goes off'
  logged_in_order 'maintenance mode goes off before the lock is taken' "$read_post" 'status --output=json --no-warnings' 'maintenance:mode --off' \
    "$lockre" "${steps[@]}" 'flock released'
  eq 1 "$(grep -c '^maintenance:mode' "$NCW_LOG")" 'maintenance mode is turned off once: the steps then find it off'
  eq false "$(cfg_get maintenance)" 'maintenance mode is off at the end'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the marker is written'
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$FIRST_INSTALL_ONLY"
  nc_run "$hook" FAKE_STATUS_JSON=live 'FAKE_FAIL=maintenance:mode --off'
  eq 0 "$NC_RC" 'it cannot be turned off: exit status 0'
  contains 'could not turn maintenance mode off, so the post-upgrade steps for 35.0.2.2 wait for a later start' "$NC_ERR" 'it cannot be turned off: a warning says the steps wait'
  not_logged 'flock' 'it cannot be turned off: no lock'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'it cannot be turned off: no marker, so the next start tries again'

  echo ' maintenance mode is on and the marker holds the version: it was turned on some other way, and it stays on'
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$MARKERS_DONE"
  nc_run "$hook" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'exit status 0'
  not_logged 'maintenance:mode' 'maintenance mode is not touched'
  not_logged 'flock' 'no lock'
  eq true "$(cfg_get maintenance)" 'maintenance mode is still on'

  echo ' an upgrade is pending (and fails again): the steps wait for a later start'
  cfg_reset "$(live_with '"maintenance":true,"loglevel":0,"version":"35.0.1.0"')"
  appcfg_reset "$FIRST_INSTALL_ONLY"
  nc_run "$hook" FAKE_STATUS_JSON=live FAKE_UPGRADE_FAILS=1
  eq 0 "$NC_RC" 'exit status 0'
  contains 'The post-upgrade steps for 35.0.2.2 were never finished, but an upgrade is pending, so they wait for a later start.' "$NC_OUT" 'stdout says they wait'
  eq 1 "$(grep -c '^flock /' "$NCW_LOG")" "one flock, the upgrade's"
  not_logged 'db:add-missing' 'no post-upgrade step runs'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'no marker'

  echo " a restore was cut off (its marker, or only the root entrypoint's note): the steps wait, and maintenance mode stays on"
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$FIRST_INSTALL_ONLY"
  mark RESTORE-IN-PROGRESS 20261024-101500
  nc_run "$hook" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'the marker: exit status 0'
  contains 'RESTORE-IN-PROGRESS' "$NC_ERR" 'the marker: a warning names the restore marker'
  not_logged 'flock' 'the marker: no lock'
  not_logged 'maintenance:mode' 'the marker: maintenance mode is not touched'
  eq true "$(cfg_get maintenance)" 'the marker: maintenance mode is still on'
  unmark
  mkdir -p /run/clouve
  : > /run/clouve/restore-cut-off
  nc_run "$hook" FAKE_STATUS_JSON=live
  contains 'a restore was cut off' "$NC_ERR" "the note: a warning says that a restore was cut off"
  not_logged 'flock' 'the note: no lock'
  eq true "$(cfg_get maintenance)" 'the note: maintenance mode is still on'
  unmark

  echo ' the marker cannot be read: a warning, and nothing runs'
  cfg_reset "$NCW_LIVE"
  appcfg_reset "$FIRST_INSTALL_ONLY"
  nc_run "$hook" FAKE_STATUS_JSON=live 'FAKE_THROW=config:app:get clouve post_upgrade_done'
  eq 0 "$NC_RC" 'exit status 0'
  contains 'could not read the marker clouve post_upgrade_done' "$NC_ERR" 'a warning names the marker (occ threw: exit 1 and nothing on stdout is not a missing marker)'
  not_logged 'flock' 'no lock'

  echo ' occ status gives no version: a warning, and nothing runs'
  nc_run "$hook" 'FAKE_STATUS_JSON={"installed":true,"maintenance":false,"needsDbUpgrade":false}'
  eq 0 "$NC_RC" 'exit status 0'
  contains 'occ status gave no version, so this start does not check whether the post-upgrade steps were finished' "$NC_ERR" 'a warning says so'
  not_logged 'flock' 'no lock'

  echo ' flock cannot open the lock file: a warning, and the next start tries again'
  nc_run "$hook" FAKE_STATUS_JSON=live FAKE_FLOCK_FAILS=66
  eq 0 "$NC_RC" 'exit status 0'
  contains 'The post-upgrade steps for 35.0.2.2 did not run: flock could not open /var/www/html/nextcloud-init-sync.lock' "$NC_ERR" 'the warning names the lock file'
  not_logged 'db:add-missing' 'no post-upgrade step runs'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'no marker'
}

# --- lib.sh: the status of occ and the app config markers ---------------------------------------------------------
# The functions that read occ's answers, against the fake occ (through LIBCALL), and nc_json_line on its own.
section_lib_status() {
  load_lib || return 0
  local out rc
  nc_world "$WORK/w-lib-status"
  cfg_reset "$NCW_LIVE"

  echo ' nc_json_line'
  eq '{"a":1}' "$(nc_json_line $'PHP Warning: x\n{"a":1}\nPHP Notice: y')" 'the JSON line, with php notices before and after it'
  eq '{"b":2}' "$(nc_json_line $'{"a":1}\n{"b":2}')" 'the last one of two'
  eq '' "$(nc_json_line 'no JSON here')" 'nothing when there is none'

  echo ' nc_status_json'
  nc_run "$LIBCALL nc_status_json" FAKE_STATUS_JSON=live 'FAKE_STATUS_PRE=PHP Warning: x' 'FAKE_STATUS_POST=PHP Notice: y'
  eq "0|$(occ_status_json true false false)" "$NC_RC|$NC_OUT" 'the JSON line of occ status, without the notices around it'
  eq 'status --output=json --no-warnings' "$(cat "$NCW_LOG")" 'it asks with --no-warnings'
  nc_run "$LIBCALL nc_status_json" FAKE_STATUS_JSON=none
  eq '1|' "$NC_RC|$NC_OUT" 'occ prints no JSON: status 1 and nothing printed'
  nc_run "$LIBCALL nc_status_json" FAKE_OCC_DEAD=1
  eq '1|' "$NC_RC|$NC_OUT" 'occ cannot start: status 1 and nothing printed (its error is not taken for an answer)'
  nc_run "$LIBCALL nc_status_json" "FAKE_STATUS_JSON=$(occ_status_json true false false)" FAKE_STATUS_RC=1
  eq '1|' "$NC_RC|$NC_OUT" 'occ prints the JSON and exits 1: status 1'

  echo ' nc_status_version'
  eq 35.0.2.2 "$(nc_status_version "$(occ_status_json true false false)")" 'the version of a status line'
  out="$(nc_status_version '{"installed":true,"versionstring":"35.0.2"}')"; rc=$?
  eq '1|' "$rc|$out" 'versionstring is not the version: status 1 and nothing printed'
  for out in '{"version":""}' '{"version":"35.0.2.2-beta"}' '{"version":".35"}' '{"version":"35."}' '{"version":"35..2"}' '' 'version'; do
    nc_status_version "$out" >/dev/null
    eq 1 "$?" "no version made of digits and dots in $out: status 1"
  done

  echo ' nc_clouve_marker'
  appcfg_reset "$MARKERS_DONE"
  nc_run "$LIBCALL nc_clouve_marker post_upgrade_done"
  eq '0|35.0.2.2' "$NC_RC|$NC_OUT" 'a marker that is set: status 0 and its value'
  eq 'config:app:get clouve post_upgrade_done --default-value= --no-warnings' "$(cat "$NCW_LOG")" 'it reads with an empty --default-value and --no-warnings'
  nc_run "$LIBCALL nc_clouve_marker first_install_done" FAKE_STDERR_NOTICE=1
  eq '0|2026-10-23T08:00:00Z' "$NC_RC|$NC_OUT" 'what occ writes on stderr while maintenance mode is on or an upgrade is pending changes nothing'
  appcfg_reset '{}'
  nc_run "$LIBCALL nc_clouve_marker post_upgrade_done"
  eq '1|' "$NC_RC|$NC_OUT" 'a marker that is not set: status 1 and nothing printed'
  nc_run "$LIBCALL nc_clouve_marker post_upgrade_done" 'FAKE_THROW=config:app:get'
  eq '2|' "$NC_RC|$NC_OUT" 'occ throws in the command (exit 1, the error on stderr, nothing on stdout): status 2, not a marker that is not set'
  nc_run "$LIBCALL nc_clouve_marker post_upgrade_done" 'FAKE_FAIL=config:app:get'
  eq '2|' "$NC_RC|$NC_OUT" 'occ fails with its error on stdout: status 2'
  nc_run "$LIBCALL nc_clouve_marker post_upgrade_done" FAKE_OCC_DEAD=1
  eq '2|' "$NC_RC|$NC_OUT" 'occ cannot start: status 2'
}

# --- lib.sh: the post-upgrade steps and their marker -------------------------------------------------------------------
# nc_post_upgrade_steps against the fake occ, whose repair turns maintenance mode on while it runs, as the real one does.
section_lib_post_upgrade_steps() {
  load_lib || return 0
  local all
  all=$'status --output=json --no-warnings\nconfig:app:delete clouve post_upgrade_done\ndb:add-missing-indices\ndb:add-missing-columns\ndb:add-missing-primary-keys\nmaintenance:repair --include-expensive\nconfig:app:set clouve post_upgrade_done --lazy --value=35.0.2.2'
  nc_world "$WORK/w-lib-post-upgrade"
  cfg_reset "$NCW_LIVE"

  echo ' the steps: the marker is deleted first and written last'
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'status 0'
  eq "$all" "$(cat "$NCW_LOG")" 'occ was asked for exactly these: the status, the marker deleted, the four steps, the marker written'
  eq 35.0.2.2 "$(appcfg_get clouve post_upgrade_done)" 'the marker holds the version from occ status'
  eq false "$(cfg_get maintenance)" 'maintenance mode is off: the repair put back the off it found'
  eq '[nextcloud] post-upgrade steps done for 35.0.2.2 (the app config value clouve post_upgrade_done records the version)' \
    "$(grep -F 'post-upgrade steps done' <<<"$NC_OUT")" 'stdout says they are done, and for which version'
  eq '' "$NC_ERR" 'nothing on stderr'

  echo ' a step fails: the others run, and the marker still goes in'
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live FAKE_FAIL=db:add-missing-indices
  eq '[nextcloud] WARNING: occ db:add-missing-indices failed (exit status 1)' "$NC_ERR" 'one warning, naming the step'
  logged_in_order 'the steps after it run' 'db:add-missing-columns' 'db:add-missing-primary-keys' 'maintenance:repair --include-expensive' \
    'config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2'

  echo ' a repair that reaches its end and fails there (a step reported an error) has put maintenance mode back itself'
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live FAKE_REPAIR_ERRORS=1
  eq 0 "$NC_RC" 'status 0'
  eq '[nextcloud] WARNING: occ maintenance:repair failed (exit status 1)' "$NC_ERR" 'one warning, naming the repair'
  logged_in_order 'maintenance mode is read after the repair, and the marker written' 'maintenance:repair --include-expensive' \
    'config:system:get maintenance --default-value=false --no-warnings' 'config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2'
  not_logged 'maintenance:mode' 'maintenance mode is not touched'
  eq 'false|35.0.2.2' "$(cfg_get maintenance)|$(appcfg_get clouve post_upgrade_done)" 'maintenance mode is off, and the marker is written'

  echo ' a repair that dies on the way (an Error in an app repair step) leaves maintenance mode on: it goes off again'
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live FAKE_REPAIR_CRASHES=1
  eq 0 "$NC_RC" 'status 0'
  contains '[nextcloud] WARNING: occ maintenance:repair failed (exit status 1)' "$NC_ERR" 'a warning names the repair'
  contains '[nextcloud] WARNING: occ maintenance:repair stopped before its end and left maintenance mode on, so it was turned off again' "$NC_ERR" 'a second says that maintenance mode was turned off again'
  logged_in_order 'maintenance mode is read, turned off, and the marker written' 'maintenance:repair --include-expensive' \
    'config:system:get maintenance --default-value=false --no-warnings' 'maintenance:mode --off' 'config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2'
  eq 'false|35.0.2.2' "$(cfg_get maintenance)|$(appcfg_get clouve post_upgrade_done)" 'maintenance mode is off, and the marker is written'
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live FAKE_REPAIR_CRASHES=1 'FAKE_FAIL=maintenance:mode --off'
  eq 0 "$NC_RC" 'and it cannot be turned off: status 0'
  contains 'left maintenance mode on, and it could not be turned off, so the steps are not recorded as done' "$NC_ERR" 'and it cannot be turned off: a warning says so'
  eq 'true|<unset>' "$(cfg_get maintenance)|$(appcfg_get clouve post_upgrade_done)" 'and it cannot be turned off: maintenance mode is on and there is no marker, so the next start turns it off and runs the steps again'
  not_logged 'config:app:set clouve post_upgrade_done' 'and it cannot be turned off: the marker is not written'
  cfg_reset "$NCW_LIVE"
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live FAKE_REPAIR_CRASHES=1 'FAKE_FAIL=config:system:get maintenance'
  contains 'maintenance mode could not be read after the repair failed, so the steps are not recorded as done' "$NC_ERR" 'and maintenance mode cannot be read: a warning says so'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'and maintenance mode cannot be read: no marker'
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$MARKERS_DONE"
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live FAKE_REPAIR_CRASHES=1
  not_logged 'maintenance:mode' 'maintenance mode was on before a repair that dies: it is left as it was'
  not_logged 'config:system:get maintenance' 'maintenance mode was on before a repair that dies: it is not even read'
  eq 'true|35.0.2.2' "$(cfg_get maintenance)|$(appcfg_get clouve post_upgrade_done)" 'maintenance mode was on before a repair that dies: still on, and the marker written'
  cfg_reset "$NCW_LIVE"

  echo ' occ status gives no answer: the steps run, and no marker'
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=none
  eq 0 "$NC_RC" 'status 0'
  logged_in_order 'the four steps run' 'db:add-missing-indices' 'db:add-missing-columns' 'db:add-missing-primary-keys' 'maintenance:repair --include-expensive'
  eq '[nextcloud] WARNING: occ status gave no version, so the post-upgrade steps are not recorded as done, and the next start runs them again' "$NC_ERR" 'one warning says why there is no marker'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'no marker (the steps deleted it first)'

  echo ' the marker cannot be deleted, or cannot be written'
  # A run that could not delete the marker and was then cut off would leave the old version behind, and that says "the
  # steps never began", which leaves maintenance mode as it is. So the steps do not run at all.
  appcfg_reset '{"clouve":{"first_install_done":"2026-10-23T08:00:00Z","post_upgrade_done":"35.0.1.1"}}'
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live 'FAKE_FAIL=config:app:delete'
  eq 0 "$NC_RC" 'not deleted: status 0'
  eq '[nextcloud] WARNING: could not delete the marker clouve post_upgrade_done, so the steps after the upgrade do not run (a run cut off now would leave the old version behind), and the next start tries again' \
    "$NC_ERR" 'not deleted: one warning says why the steps do not run'
  not_logged 'db:add-missing' 'not deleted: no step runs'
  not_logged 'maintenance:repair' 'not deleted: not the repair either'
  eq 35.0.1.1 "$(appcfg_get clouve post_upgrade_done)" 'not deleted: the marker keeps its old version, so the next start tries again'
  appcfg_reset "$MARKERS_DONE"
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live 'FAKE_FAIL=config:app:set clouve'
  contains 'could not record that the post-upgrade steps are done (occ config:app:set clouve post_upgrade_done, exit status 1), so the next start runs them again' "$NC_ERR" 'not written: a warning says so'
  eq '<unset>' "$(appcfg_get clouve post_upgrade_done)" 'not written: no marker'
  lacks 'post-upgrade steps done' "$NC_OUT" 'not written: and stdout does not say they are done'

  echo ' maintenance mode is on and the marker missing (a cut-off start), and it cannot be turned off: the steps run, and write no marker'
  cfg_reset "$(live_with '"maintenance":true')"
  appcfg_reset "$FIRST_INSTALL_ONLY"
  nc_run "$LIBCALL nc_post_upgrade_steps" FAKE_STATUS_JSON=live 'FAKE_FAIL=maintenance:mode --off'
  eq 0 "$NC_RC" 'status 0'
  contains '[nextcloud] WARNING: could not turn maintenance mode off before the steps after the upgrade, so they run but write no marker, and a later start tries again' "$NC_ERR" 'a warning says that no marker is written'
  logged_in_order 'the steps still run' 'maintenance:mode --off' 'config:app:delete clouve post_upgrade_done' 'db:add-missing-indices' 'maintenance:repair --include-expensive'
  not_logged 'config:app:set clouve post_upgrade_done' 'the marker is not written'
  eq 'true|<unset>' "$(cfg_get maintenance)|$(appcfg_get clouve post_upgrade_done)" 'maintenance mode is on and the marker missing: the next start turns it off and runs the steps again'
  lacks 'post-upgrade steps done' "$NC_OUT" 'stdout does not say they are done'
  cfg_reset "$NCW_LIVE"
  appcfg_reset "$MARKERS_DONE"

  echo ' every call fails'
  nc_run "$LIBCALL nc_post_upgrade_steps" 'FAKE_FAIL=*'
  eq 0 "$NC_RC" 'status 0'
  eq '[nextcloud] WARNING: could not delete the marker clouve post_upgrade_done, so the steps after the upgrade do not run (a run cut off now would leave the old version behind), and the next start tries again' \
    "$(grep '\[nextcloud\] WARNING:' <<<"$NC_ERR")" 'one warning: the delete of the marker fails first, so no step runs'
  not_logged 'db:add-missing' 'no step runs'
  printf '#!/bin/bash\nset -euo pipefail\n. %q\nnc_post_upgrade_steps >/dev/null 2>&1\necho after\n' "$LIB" > "$NCW/sete"
  chmod 755 "$NCW/sete"
  nc_run "$NCW/sete" 'FAKE_FAIL=*'
  eq after "$NC_OUT" 'and a caller that runs under set -euo pipefail is not stopped'
}

# --- lib.sh: the marker files of the AI Assistant's backups and restores --------------------------------------------
# The skill's scripts keep data/clouve-backups root's, with mode 700 (mark makes it that way), so www-data, which runs the
# hooks, can't see into it. Root, which runs these functions from the root entrypoint, can.
# shellcheck disable=SC2016  # the scripts for the inner bash, and test data, have to stay text
section_lib_markers() {
  load_lib || return 0
  local restore backup note out
  restore="$(nc_marker_path restore)" backup="$(nc_marker_path backup)" note="$(nc_marker_path restore-note)"
  # as_www_data_cut_off: whether nc_restore_cut_off says that a restore was cut off when www-data asks, as the hooks do
  as_www_data_cut_off() { runuser -u www-data -- bash -c '. "$1"; if nc_restore_cut_off; then echo yes; else echo no; fi' _ "$LIB" 2>&1; }
  # hold_lock FILE: a process that holds an exclusive flock on FILE, as backup.sh does while it holds maintenance mode
  # on, until release_lock. It waits until the lock is held.
  hold_lock() {
    local i
    ( exec 8<"$1"; flock -x 8 && exec sleep 120 ) &
    LOCK_HOLDER=$!
    for ((i = 0; i < 50; i++)); do
      flock -n -E 75 "$1" true
      if [[ $? -eq 75 ]]; then return 0; fi
      sleep 0.1
    done
    fail "hold_lock: the lock on $1 was never taken"
  }
  release_lock() { kill "$LOCK_HOLDER" 2>/dev/null; wait "$LOCK_HOLDER" 2>/dev/null; }
  nc_world "$WORK/w-lib-markers"
  # This section never runs a hook, and nc_clear_cut_off_backup needs the real flock, so the world's fake one goes.
  rm -f "$NCW/bin/flock"
  unmark

  echo ' nc_marker_path'
  eq /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS "$restore" 'restore: in the backups folder of the data folder'
  eq /var/www/html/data/clouve-backups/BACKUP-IN-PROGRESS "$backup" 'backup: next to it'
  eq /run/clouve/restore-cut-off "$note" "restore-note: in /run/clouve, which www-data can read"
  eq '' "$(nc_marker_path other)" 'any other name: nothing'

  echo ' nc_restore_cut_off and nc_note_restore_marker'
  nc_restore_cut_off
  eq 1 "$?" 'no marker and no note: no restore was cut off'
  mark RESTORE-IN-PROGRESS 20261024-101500
  nc_restore_cut_off
  eq 0 "$?" 'the marker is there: root sees it'
  eq no "$(as_www_data_cut_off)" 'but www-data, which runs the hooks, does not: the folder is root'"'"'s alone'
  out="$(nc_note_restore_marker 2>&1)"
  eq "[nextcloud] WARNING: A restore was cut off: $restore is there. Until the AI Assistant finishes or undoes it, the start leaves maintenance mode and any pending upgrade alone, and runs none of the steps that a cut-off start left undone." \
    "$out" 'the root entrypoint warns once'
  eq 'root:root 644' "$(stat -c '%U:%G %a' "$note" 2>&1)" 'and writes the note, root'"'"'s and readable by all'
  eq yes "$(as_www_data_cut_off)" 'www-data now sees, through the note, that a restore was cut off'
  rm -f "$restore"
  out="$(nc_note_restore_marker 2>&1)"
  eq '' "$out" 'the marker is gone: nothing printed'
  eq no "$(exists "$note")" 'and the note is removed (Docker keeps /run when it restarts a container)'
  eq no "$(as_www_data_cut_off)" 'so www-data sees no restore'
  out="$(nc_note_restore_marker 2>&1)"
  eq "0|" "$?|$out" 'no marker and no note: status 0 and nothing printed'
  ln -s /etc/hostname "$note"
  nc_note_restore_marker
  eq no "$(exists "$note")" 'a note that is a symlink is removed too'
  eq yes "$(exists /etc/hostname)" 'and not what it points to'
  unmark

  echo ' a restore marker that the AI Assistant did not make'
  # www-data owns the data folder, so it can make a clouve-backups of its own before any backup has.
  install -d -o www-data -g www-data -m 755 /var/www/html/data /var/www/html/data/clouve-backups
  runuser -u www-data -- sh -c 'printf "%s\n" 20261024-101500 > "$1"' _ "$restore"
  nc_restore_cut_off
  eq 1 "$?" "www-data's own folder and marker: root does not count a restore as cut off"
  eq no "$(as_www_data_cut_off)" 'nor does www-data'
  out="$(nc_note_restore_marker 2>&1)"
  eq "[nextcloud] WARNING: $restore is there, but it is not a file of root's in a folder that only root can write to, so the AI Assistant's restore did not make it. It is ignored." \
    "$out" 'the root entrypoint says that it ignores it'
  eq no "$(exists "$note")" 'and writes no note'
  unmark
  mark RESTORE-IN-PROGRESS 20261024-101500
  chmod 770 /var/www/html/data/clouve-backups
  nc_restore_cut_off
  eq 1 "$?" 'a marker of root'"'"'s in a folder of root'"'"'s that its group can write to: not trusted'
  chmod 700 /var/www/html/data/clouve-backups
  chown www-data "$restore"
  nc_restore_cut_off
  eq 1 "$?" 'a marker that root does not own: not trusted'
  rm -f "$restore"
  ln -s /etc/hostname "$restore"
  nc_restore_cut_off
  eq 1 "$?" 'a marker that is a symlink: not trusted'
  rm -f "$restore"
  mark RESTORE-IN-PROGRESS 20261024-101500
  nc_restore_cut_off
  eq 0 "$?" 'a marker made the way restore.sh makes it: trusted again'
  unmark

  echo ' nc_marker_name'
  mark BACKUP-IN-PROGRESS 20261024-101500
  eq 20261024-101500 "$(nc_marker_name "$backup")" 'the first line of a marker that root wrote in the root-only folder'
  printf '20261024-101500\nsomething else\n' > "$backup"
  eq 20261024-101500 "$(nc_marker_name "$backup")" 'only the first line'
  printf 'a b/c$d\033[31m;\n' > "$backup"
  eq 'a_b_c_d__31m_' "$(nc_marker_name "$backup")" 'anything but letters, digits, dot, hyphen and underscore becomes _'
  printf '%s\n' "$(printf 'x%.0s' {1..100})" > "$backup"
  eq 64 "$(nc_marker_name "$backup" | tr -d '\n' | wc -c)" 'a long name is cut to 64 characters'
  printf '20261024-101500' > "$backup"
  eq 20261024-101500 "$(nc_marker_name "$backup")" 'a first line with no newline'
  : > "$backup"
  eq unnamed "$(nc_marker_name "$backup")" 'an empty marker: unnamed'
  eq unnamed "$(nc_marker_name /var/www/html/data/clouve-backups/NO-SUCH-FILE)" 'no file: unnamed'
  rm -f "$backup"
  ln -s /proc/1/environ "$backup"
  eq unnamed "$(nc_marker_name "$backup")" 'a symlink (to /proc/1/environ, say) is never read'
  rm -f "$backup"
  printf 'by-www-data\n' > "$backup"
  chown www-data "$backup"
  eq unnamed "$(nc_marker_name "$backup")" 'a marker that root does not own is not read'
  chown root "$backup"
  chmod 703 /var/www/html/data/clouve-backups
  eq unnamed "$(nc_marker_name "$backup")" 'nor one in a folder that others can write to'
  chmod 700 /var/www/html/data/clouve-backups
  chown www-data /var/www/html/data/clouve-backups
  eq unnamed "$(nc_marker_name "$backup")" 'nor one in a folder that root does not own'
  chown root /var/www/html/data/clouve-backups
  eq by-www-data "$(nc_marker_name "$backup")" 'once both are root'"'"'s again, it is read'
  rm -f "$backup"
  mkfifo "$backup"
  eq unnamed "$(timeout 5 bash -c '. "$1"; nc_marker_name "$2"' _ "$LIB" "$backup" 2>&1)" 'a named pipe is not read, so it cannot hold up the start'
  unmark

  echo ' nc_clear_cut_off_backup (as root, as the root entrypoint runs it)'
  cfg_reset "$NCW_LIVE"
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  eq '0||' "$NC_RC|$NC_OUT|$NC_ERR" 'no marker: status 0, and nothing printed'
  eq '' "$(cat "$NCW_LOG")" 'no marker: occ is not even asked'

  cfg_reset "$(live_with '"maintenance":true')"
  mark BACKUP-IN-PROGRESS 20261024-101500
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'maintenance mode on: status 0'
  eq $'status --output=json --no-warnings\nmaintenance:mode --off' "$(cat "$NCW_LOG")" 'maintenance mode on: the status, then maintenance mode off'
  eq false "$(cfg_get maintenance)" 'maintenance mode on: it is off'
  eq no "$(exists "$backup")" 'maintenance mode on: the marker is gone'
  contains '[nextcloud] A backup (20261024-101500) was cut off when the container stopped. Maintenance mode, which it had turned on, is off again, and its marker is gone.' \
    "$NC_OUT" 'maintenance mode on: one line names the backup and says what was done'
  eq '' "$NC_ERR" 'maintenance mode on: nothing on stderr'
  no_secret s3cret 'maintenance mode on: the database password appears in no output and no argument'

  mark BACKUP-IN-PROGRESS 20261024-101500
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  eq 'status --output=json --no-warnings' "$(cat "$NCW_LOG")" 'maintenance mode already off: only the status'
  eq no "$(exists "$backup")" 'maintenance mode already off: the marker is gone'
  contains 'Maintenance mode was already off, and its marker is gone.' "$NC_OUT" 'maintenance mode already off: the line says so'

  cfg_reset "$(live_with '"maintenance":true')"
  mark BACKUP-IN-PROGRESS 20261024-101500
  mark RESTORE-IN-PROGRESS 20261020-090000
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  eq '' "$(cat "$NCW_LOG")" 'a restore was cut off too: occ is not asked'
  eq 'yes yes true' "$(exists "$backup") $(exists "$restore") $(cfg_get maintenance)" 'a restore was cut off too: both markers stay, and maintenance mode stays on'
  contains 'A backup (20261024-101500) and a restore were both cut off, so maintenance mode and both markers are left as they are' "$NC_ERR" 'a restore was cut off too: a warning says so'
  rm -f "$restore"
  mkdir -p /run/clouve
  : > "$note"
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  eq 'yes true' "$(exists "$backup") $(cfg_get maintenance)" "only the root entrypoint's note says a restore was cut off: the same"
  rm -f "$note"

  echo ' nc_clear_cut_off_backup: a backup that is still running holds the lock on its marker, and owns it'
  cfg_reset "$(live_with '"maintenance":true')"
  hold_lock "$backup"
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  eq 0 "$NC_RC" 'locked: status 0'
  eq '' "$(cat "$NCW_LOG")" 'locked: occ is not even asked'
  eq 'yes true' "$(exists "$backup") $(cfg_get maintenance)" 'locked: the marker stays, and maintenance mode stays on'
  eq "[nextcloud] A backup (20261024-101500) is still running: it holds the lock on its marker, $backup. Maintenance mode and the marker are left to it." \
    "$NC_OUT" 'locked: one line says that a backup is still running'
  release_lock
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  eq 'no false' "$(exists "$backup") $(cfg_get maintenance)" 'the backup is gone and its lock with it: maintenance mode goes off, and the marker goes'
  mark BACKUP-IN-PROGRESS 20261024-101500
  cfg_reset "$(live_with '"maintenance":true')"
  fake_cmd "$NCW/bin" flock <<'EOF2'
exit 64
EOF2
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  rm -f "$NCW/bin/flock"
  eq 'yes true' "$(exists "$backup") $(cfg_get maintenance)" 'the lock cannot be checked: the marker and maintenance mode are left as they are'
  contains 'could not tell whether a backup (20261024-101500) still holds the lock on its marker' "$NC_ERR" 'the lock cannot be checked: a warning says so'
  eq '' "$(cat "$NCW_LOG")" 'the lock cannot be checked: occ is not asked'

  cfg_reset "$(live_with '"maintenance":true,"version":"35.0.1.0"')"
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  not_logged 'maintenance:mode' 'an upgrade is pending: maintenance mode is not touched (the before-starting hook turns it off for the upgrade)'
  eq yes "$(exists "$backup")" 'an upgrade is pending: the marker waits for a later start'
  contains 'an upgrade is pending' "$NC_OUT" 'an upgrade is pending: the line says so'

  cfg_reset "$(live_with '"maintenance":true')"
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live 'FAKE_FAIL=maintenance:mode --off'
  eq 'yes true' "$(exists "$backup") $(cfg_get maintenance)" 'maintenance mode cannot be turned off: the marker stays for the next start'
  contains 'occ could not turn it off. The backup'"'"'s marker stays, so the next start tries again.' "$NC_ERR" 'maintenance mode cannot be turned off: a warning says so'
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_OCC_DEAD=1
  eq 'yes true' "$(exists "$backup") $(cfg_get maintenance)" 'occ cannot report the status: the marker stays'
  contains 'occ did not report the status' "$NC_ERR" 'occ cannot report the status: a warning says so'
  cfg_reset "$(live_with '"installed":false')"
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  eq yes "$(exists "$backup")" 'Nextcloud is not installed: the marker is left as it is'
  contains 'Nextcloud is not installed' "$NC_ERR" 'Nextcloud is not installed: a warning says so'

  cfg_reset "$(live_with '"maintenance":true')"
  rm -f "$backup"
  ln -s /etc/hostname "$backup"
  nc_run "$LIBCALL nc_clear_cut_off_backup" FAKE_STATUS_JSON=live
  contains 'A backup (unnamed) was cut off' "$NC_OUT" 'a marker that is a symlink: its target is never read'
  eq 'no yes false' "$(exists "$backup") $(exists /etc/hostname) $(cfg_get maintenance)" 'a marker that is a symlink: the link goes, not its target, and maintenance mode is off'
  unmark

  echo ' nc_hold_upgrade_for_restore: a cut-off restore holds back an upgrade to this image'
  rm -f /var/www/html/version.php
  nc_hold_upgrade_for_restore
  eq 1 "$?" 'no restore marker: no hold'
  mark RESTORE-IN-PROGRESS 20261024-101500
  nc_hold_upgrade_for_restore
  eq 1 "$?" 'a cut-off restore before any install (no version.php on the volume): no hold'
  cp /usr/src/nextcloud/version.php /var/www/html/version.php
  nc_hold_upgrade_for_restore
  eq 1 "$?" "a cut-off restore, and the volume has this image's code: no hold (nothing to upgrade)"
  printf '%s\n' '// the code of an older image' >> /var/www/html/version.php
  nc_hold_upgrade_for_restore
  eq 0 "$?" "a cut-off restore, and the volume's code is not this image's: hold"
  chmod 770 /var/www/html/data/clouve-backups
  nc_hold_upgrade_for_restore
  eq 1 "$?" 'a marker in a folder its group can write to is not trusted: no hold'
  chmod 700 /var/www/html/data/clouve-backups
  rm -f /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS
  ln -s /etc/hostname /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS
  nc_hold_upgrade_for_restore
  eq 1 "$?" 'a symlink as the marker is not trusted: no hold'
  unmark
  rm -f /var/www/html/version.php
}

# --- a new disk's top folder -----------------------------------------------------------------------------------------
# nc_claim_new_volume as the root entrypoint's step 1 runs it: as root, before anything else writes to the volume. A new
# Kubernetes disk (on GKE, a persistent disk's empty ext4) has a top folder of root's, mode 755, with lost+found in it,
# and www-data can make nothing there. Docker fills a new named volume from the image instead, owner and mode included,
# so there the folder is www-data's already. Every case here runs on a folder under $WORK, never on /var/www/html.
section_lib_new_volume() {
  load_lib || return 0
  local dir="$WORK/disk" target="$WORK/disk-target" link="$WORK/disk-link" bin="$WORK/disk-bin" out err rc line
  line="[nextcloud] $dir was root's, as on a new disk, so it is now www-data's (1777, as in the image)"
  # claim PATH: nc_claim_new_volume on PATH, with its stdout in $out, its stderr in $err and its status in $rc
  claim() { out="$(nc_claim_new_volume "$1" 2>"$WORK/disk.err")"; rc=$?; err="$(cat "$WORK/disk.err")"; }
  state() { stat -c '%U:%G %a' -- "$1" 2>&1; }
  chmod 711 "$WORK"    # so that www-data can reach the folders below

  mkdir -p "$dir/lost+found"
  chmod 755 "$dir"
  chmod 700 "$dir/lost+found"
  eq 'root:root 755' "$(state "$dir")" "sanity check: the folder is root's, mode 755, as on a new disk"
  claim "$dir"
  eq "0|www-data:root 1777" "$rc|$(state "$dir")" "a folder of root's becomes www-data's, 1777, as in the image"
  eq 'root:root 700' "$(state "$dir/lost+found")" "... and what is in it stays as it was"
  eq "$line" "$out" "... and one line says so"
  eq '' "$err" "... with no warning"
  # shellcheck disable=SC2016  # $1 is for the inner sh, which gets the folder as its first argument
  runuser -u www-data -- sh -c ': > "$1/nextcloud-init-sync.lock"' _ "$dir"
  eq yes "$(exists "$dir/nextcloud-init-sync.lock")" "www-data can now make the init lock there, as step 8 has it do"
  claim "$dir"
  eq "0|||www-data:root 1777" "$rc|$out|$err|$(state "$dir")" "a second run changes nothing and prints nothing"
  rm -f "$dir/nextcloud-init-sync.lock"

  chown www-data:www-data "$dir"
  chmod 755 "$dir"
  claim "$dir"
  eq "0|||www-data:www-data 755" "$rc|$out|$err|$(state "$dir")" \
     "a folder of www-data's is left as it is (755: what an older image's first install left on a new disk)"
  chown nobody:nogroup "$dir"
  claim "$dir"
  eq "0|||nobody:nogroup 755" "$rc|$out|$err|$(state "$dir")" "a folder of another user's is left as it is"

  mkdir -p "$target"
  chmod 755 "$target"
  ln -s "$target" "$link"
  claim "$link"
  eq "0|||root:root 755|link" "$rc|$out|$err|$(state "$target")|$(if [[ -L "$link" ]]; then echo link; fi)" \
     "a link to a folder of root's: the link stays, and its target is left as it is"
  claim "$WORK/disk-none"
  eq "0|||no" "$rc|$out|$err|$(exists "$WORK/disk-none")" "nothing at the path: nothing is made"
  : > "$WORK/disk-file"
  chmod 644 "$WORK/disk-file"
  claim "$WORK/disk-file"
  eq "0|||root:root 644" "$rc|$out|$err|$(state "$WORK/disk-file")" "a file of root's is left as it is"

  # A chown that fails, as on a disk mounted read-only: status 1 and a warning, and the folder keeps root's owner.
  chown root:root "$dir"
  fake_cmd "$bin" chown <<'EOF'
echo "chown: changing ownership: Read-only file system" >&2
exit 1
EOF
  out="$(with_path "$bin" nc_claim_new_volume "$dir" 2>"$WORK/disk.err")"
  rc=$?
  err="$(cat "$WORK/disk.err")"
  eq "1|root:root 755" "$rc|$(state "$dir")" "chown fails: status 1, and the folder is still root's"
  contains "could not give $dir to www-data" "$err" "... and a warning says so"
  rm -rf "$dir" "$target" "$link" "$WORK/disk-file" "$bin" "$WORK/disk.err"
}

# --- the init lock file ----------------------------------------------------------------------------------------------
# nc_make_init_lock as the root entrypoint's step 8 runs it: as root, on www-data's /var/www/html (1777, as in the image).
section_lib_init_lock() {
  load_lib || return 0
  local lock=/var/www/html/nextcloud-init-sync.lock root_only="$WORK/root-only" target racer='' i out rc ino
  target="$root_only/RESTORE-IN-PROGRESS"
  chmod 711 "$WORK"
  mkdir -p "$root_only"
  chmod 700 "$root_only"
  owner() { stat -c %U -- "$1" 2>/dev/null; }
  kind() {
    if [[ -L "$1" ]]; then echo link; elif [[ -f "$1" ]]; then echo file; elif [[ -d "$1" ]]; then echo folder
    elif [[ -p "$1" ]]; then echo pipe; elif [[ -e "$1" ]]; then echo other; else echo none; fi
  }
  # make_lock: nc_make_init_lock on the lock, as root, with what it printed in $out and its status in $rc
  make_lock() { out="$(nc_make_init_lock "$lock" 2>&1)"; rc=$?; }

  eq '1777 www-data' "$(stat -c '%a %U' /var/www/html)" "sanity check: /var/www/html is www-data's and 1777, as in the image"
  rm -rf "$lock"
  make_lock
  eq '0||file www-data' "$rc|$out|$(kind "$lock") $(owner "$lock")" 'no file: www-data makes a plain file, and nothing is printed'
  printf 'x' > "$lock"
  chown www-data:www-data "$lock"
  ino="$(stat -c %i "$lock")"
  make_lock
  eq "0|x|$ino" "$rc|$(cat "$lock")|$(stat -c %i "$lock")" "a plain file of www-data's is left as it is"
  rm -f "$lock"
  : > "$lock"
  make_lock
  eq '0|file www-data' "$rc|$(kind "$lock") $(owner "$lock")" "a file of root's goes and www-data makes its own (with fs.protected_regular the hook could not open root's)"
  rm -f "$lock"
  printf 'keep\n' > "$target"
  ln -s "$target" "$lock"
  make_lock
  eq '0|file www-data|keep root' "$rc|$(kind "$lock") $(owner "$lock")|$(cat "$target") $(owner "$target")" \
     'a link to a file in a root-only folder: the link goes, and the file is left alone'
  rm -f "$target" "$lock"
  ln -s "$target" "$lock"
  make_lock
  eq '0|file|no' "$rc|$(kind "$lock")|$(exists "$target")" 'a link to a missing file in a root-only folder: that file is not made'
  rm -f "$lock"
  mkdir "$lock"
  chown www-data:www-data "$lock"
  make_lock
  eq '0|file' "$rc|$(kind "$lock")" "a folder of www-data's goes"
  rm -f "$lock"
  mkfifo "$lock"
  chown www-data:www-data "$lock"
  # shellcheck disable=SC2016  # $1 and $2 are for the inner bash
  out="$(timeout 5 bash -c '. "$1"; nc_make_init_lock "$2"' _ "$LIB" "$lock" 2>&1)"
  rc=$?
  eq '0|file' "$rc|$(kind "$lock")" 'a named pipe goes, and is never opened (no hang)'
  rm -f "$lock"
  mkdir "$lock"
  : > "$lock/root-file"
  chmod 700 "$lock"
  make_lock
  eq 1 "$rc" "a folder of root's that www-data can't empty: status 1"
  contains "could not make $lock a plain file" "$out" '... and a warning says so'
  rm -rf "$lock"

  echo ' a www-data process that swaps a link in and out at the same time'
  # The old step 8 and the window it left, step by step: its test found nothing there, a www-data process put a link
  # there, and its touch followed the link. A free-running race hits that window only by chance.
  rm -rf "$lock" "$target"
  if [ ! -e "$lock" ]; then
    runuser -u www-data -- ln -s "$target" "$lock"
    touch -- "$lock" 2>/dev/null
  fi
  eq yes "$(exists "$target")" "sanity check: the old step 8 (root's test, then touch) makes a link's target in a root-only folder"
  rm -rf "$target" "$lock"
  # race_start TARGET: www-data puts a link to TARGET at the lock's path and removes it, as fast as it can, until
  # race_stop, which leaves the number of swaps in $swaps. That is what a www-data process can do while the root
  # entrypoint runs, since steps 6 and 7 start PHP.
  mkdir -p "$WORK/race"
  chown www-data "$WORK/race"
  race_start() {
    rm -f "$WORK/race/stop" "$WORK/race/count"
    # shellcheck disable=SC2016  # the loop is for the inner sh, which gets the paths as $1 to $3
    runuser -u www-data -- sh -c 'n=0
      while [ ! -e "$3/stop" ]; do
        ln -sfn "$2" "$1.new" 2>/dev/null && mv -fT "$1.new" "$1" 2>/dev/null
        rm -f "$1" 2>/dev/null
        n=$((n + 1))
      done
      echo "$n" > "$3/count"' _ "$lock" "$1" "$WORK/race" &
    racer=$!
  }
  race_stop() {
    : > "$WORK/race/stop"
    wait "$racer" 2>/dev/null
    swaps=$(cat "$WORK/race/count" 2>/dev/null)
    rm -f "$WORK/race/stop" "$WORK/race/count" "$lock.new"
  }
  local swaps=''
  race_start "$target"
  for ((i = 0; i < 300; i++)); do nc_make_init_lock "$lock" > /dev/null 2>&1; done
  race_stop
  if [[ "${swaps:-0}" =~ ^[0-9]+$ && "${swaps:-0}" -ge 20 ]]; then
    pass "sanity check: the www-data process swapped a link in $swaps times meanwhile"
  else
    fail "the www-data process swapped a link in only ${swaps:-0} times, so the check below proves little"
  fi
  eq no "$(exists "$target")" 'nc_make_init_lock, 300 times during that race: the target is never made'
  rm -rf "$WORK/race"

  rm -rf "$lock"
  make_lock
  runuser -u www-data -- flock -n "$lock" true
  eq 0 "$?" 'afterwards www-data can lock the file, as the before-starting hook does'
  rm -rf "$lock" "$root_only"
}

# --- the build's edits to the official entrypoint ----------------------------------------------------------------------
# patch-official-entrypoint.sh on this image's own /entrypoint.sh, the file the Dockerfile runs it on. Then the patched
# copy runs as a start runs the official entrypoint, as root, with NEXTCLOUD_UPDATE=1 and `true` as the command: it
# takes the init lock, reads the volume's version.php, runs the before-starting hooks (this image has none) and runs
# the command. The volume holds the image's own version, so nothing is installed or upgraded.
section_patch_entrypoint() {
  local patch="$INSTALLER/patch-official-entrypoint.sh" dir="$WORK/ep" out="$WORK/ep-out" ver_line old_version
  # shellcheck disable=SC2016  # the official entrypoint's line, as it is
  old_version='            installed_version="$(php -r '"'"'require "/var/www/html/version.php"; echo implode(".", $OC_Version);'"'"')"'
  mkdir -p "$dir" "$out"
  chmod 711 "$WORK"
  chmod 1777 "$out"
  cp -p /entrypoint.sh "$dir/entrypoint.sh"
  cp -p /entrypoint.sh "$dir/upstream.sh"
  eq 1 "$(grep -cFx -- "$old_version" "$dir/upstream.sh")" 'sanity check: the official entrypoint reads version.php with this line, as root'
  "$patch" "$dir/entrypoint.sh" > "$WORK/patch.out" 2>&1
  eq 0 "$?" 'the patch applies to the official entrypoint of nextcloud:35.0.2-apache'
  eq '' "$(cat "$WORK/patch.out")" '... and prints nothing'
  eq '1 0 0' "$(grep -cFx '    ) 9< /var/www/html/nextcloud-init-sync.lock' "$dir/entrypoint.sh") $(grep -c '9> */var/www/html/nextcloud-init-sync.lock' "$dir/entrypoint.sh") $(grep -cFx -- "$old_version" "$dir/entrypoint.sh")" \
     'the init lock is opened read-only and nowhere with 9>, and the read of version.php as root is gone'
  # shellcheck disable=SC2016  # literal text to look for
  eq 1 "$(grep -cF 'installed_version="$(run_as '"'"'php -d display_errors=stderr -r ' "$dir/entrypoint.sh")" \
     "version.php is read through run_as, with PHP's messages on stderr"
  sh -n "$dir/entrypoint.sh"
  eq 0 "$?" 'the patched file is still valid sh'
  eq "$(stat -c '%a %U' /entrypoint.sh)" "$(stat -c '%a %U' "$dir/entrypoint.sh")" 'it keeps its mode and owner'

  # volume PHP: /var/www/html/version.php holding this PHP, and the init lock file, both www-data's, as a start finds them
  volume() {
    printf '<?php\n%s\n' "$1" > /var/www/html/version.php
    : > /var/www/html/nextcloud-init-sync.lock
    chown www-data:www-data /var/www/html/version.php /var/www/html/nextcloud-init-sync.lock
  }
  # start FILE: runs FILE as the official entrypoint, as root; its output goes to $WORK/ep.log
  start() { ( cd / && NEXTCLOUD_UPDATE=1 NC_TEST_OUT="$out" sh "$1" true ) > "$WORK/ep.log" 2>&1; }
  # shellcheck disable=SC2016  # a pattern, not a shell expansion
  ver_line="$(grep '^\$OC_Version = ' /usr/src/nextcloud/version.php)"
  # shellcheck disable=SC2016  # PHP code
  volume "file_put_contents(getenv('NC_TEST_OUT') . '/uid', (string) posix_getuid());
$ver_line"
  rm -f "$out/uid"
  start "$dir/upstream.sh"
  eq '0|0' "$?|$(cat "$out/uid" 2>/dev/null)" 'sanity check: the unpatched entrypoint runs version.php as root (uid 0)'
  rm -f "$out/uid"
  start "$dir/entrypoint.sh"
  eq '0|33' "$?|$(cat "$out/uid" 2>/dev/null)" 'the patched one runs it as www-data (uid 33), and the start goes on to the command'
  # A PHP warning while version.php runs goes to stderr, so it can't spoil the version.
  # shellcheck disable=SC2016  # PHP code
  volume "\$x = \$not_set;
$ver_line"
  start "$dir/entrypoint.sh"
  eq 0 "$?" 'a PHP warning while version.php runs (an undefined variable) does not stop the start'
  contains 'Undefined variable' "$(cat "$WORK/ep.log")" '... and the warning is in the log'
  # shellcheck disable=SC2016  # PHP code
  volume '$OC_Version = array("35", "0", "2", "2 or anything");'
  start "$dir/entrypoint.sh"
  eq 1 "$?" 'a version.php that gives no version number stops the start'
  contains 'does not give a version number' "$(cat "$WORK/ep.log")" '... and says why'
  volume 'this is not PHP ('
  start "$dir/entrypoint.sh"
  eq 1 "$?" 'a version.php that PHP cannot run stops the start too'
  contains 'does not give a version number' "$(cat "$WORK/ep.log")" '... with the same message'

  echo ' a file that is not as the patch expects is refused and left as it was'
  cp -p /entrypoint.sh "$dir/missing.sh"
  # shellcheck disable=SC2016  # a sed address, not a shell expansion
  sed -i '/installed_version="\$(php -r/d' "$dir/missing.sh"
  cp -p "$dir/missing.sh" "$dir/missing.before"
  "$patch" "$dir/missing.sh" > "$WORK/patch.out" 2>&1
  eq 1 "$?" 'the version line is missing: exit 1'
  contains 'version.php' "$(cat "$WORK/patch.out")" '... and the message shows the line it looked for'
  if cmp -s "$dir/missing.sh" "$dir/missing.before"; then
    pass '... and the file is as it was, the lock line included'
  else
    fail 'the file changed although the patch failed'
  fi
  "$patch" "$dir/entrypoint.sh" > "$WORK/patch.out" 2>&1
  eq 1 "$?" 'a second run on a patched file: exit 1 (the lines are not there any more)'
  rm -rf /var/www/html/version.php /var/www/html/nextcloud-init-sync.lock "$dir" "$out"
}

# --- the hooks as a set ---------------------------------------------------------------
section_hook_files() {
  local phase f
  echo ' the layout the Dockerfile copies from'
  eq 'before-starting post-installation post-upgrade pre-installation' "$(find "$HOOKS" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')" 'hooks/ has the four phases the official entrypoint runs'
  for phase in pre-installation post-installation post-upgrade before-starting; do
    eq '10-clouve.sh' "$(ls -A "$HOOKS/$phase" 2>/dev/null)" "$phase holds 10-clouve.sh and nothing else"
    if [[ -x "$HOOKS/$phase/10-clouve.sh" ]]; then pass "$phase/10-clouve.sh is executable"; else fail "$phase/10-clouve.sh is missing or not executable"; fi
  done
  echo ' the first install'"'"'s own settings are written once, in lib.sh'
  # post-installation runs them once, and before-starting again after a first start that was cut off. Both call
  # nc_first_install_steps, so the two can never drift apart.
  for phase in post-installation before-starting; do
    contains nc_first_install_steps "$(grep -v '^[[:space:]]*#' "$HOOKS/$phase/10-clouve.sh" 2>/dev/null)" "$phase calls nc_first_install_steps"
  done
  eq 0 "$(cat "$HOOKS"/*/10-clouve.sh | grep -v '^[[:space:]]*#' | grep -cE 'background:cron|app:install|retention_obligation|config:app:set clouve')" \
    'no hook has a copy of the steps (background:cron, app:install, the retention, the write of a marker)'
  contains 'nc_first_install_steps()' "$(cat "$LIB")" 'lib.sh defines nc_first_install_steps'
  echo ' the post-upgrade steps are written once, in lib.sh'
  # post-upgrade runs them after the official entrypoint's upgrade, and before-starting after the upgrade it finishes
  # and after a start that was cut off during them.
  for phase in post-upgrade before-starting; do
    contains nc_post_upgrade_steps "$(grep -v '^[[:space:]]*#' "$HOOKS/$phase/10-clouve.sh" 2>/dev/null)" "$phase calls nc_post_upgrade_steps"
  done
  eq 0 "$(cat "$HOOKS"/*/10-clouve.sh | grep -v '^[[:space:]]*#' | grep -cE 'db:add-missing|config:app:delete clouve')" \
    'no hook has a copy of them (db:add-missing-*, the delete of the marker)'
  eq 0 "$(cat "$HOOKS"/*/10-clouve.sh | grep -v '^[[:space:]]*#' | grep -c 'RESTORE-IN-PROGRESS')" \
    'no hook names a marker file itself: lib.sh has the paths (nc_marker_path)'
  echo ' all of the scripts'
  for f in "$CONFIG_SH" "$HOOKS"/*/10-clouve.sh; do
    if [[ -f "$f" ]]; then
      eq 0 "$(grep -c $'\r' "$f")" "$(basename "$(dirname "$f")")/$(basename "$f") has no CR characters"
      eq 0 "$(LC_ALL=C grep -c -P '\xe2\x80[\x93\x94]' "$f")" "$(basename "$(dirname "$f")")/$(basename "$f") has no em or en dash"
    fi
  done
}

# --- the real occ ----------------------------------------------------------------------
# Every section above runs the scripts against a fake occ, and a fake is only worth trusting if the real occ answers the
# same way. This section installs Nextcloud (SQLite, no network) and runs the scripts as www-data against the real occ,
# the way the official entrypoint runs a hook. What it cannot do is use a cache, because nothing here runs Valkey. The
# cache settings are applied all the same, and the one command that needs a working cache, occ upgrade, runs after they
# have been removed. With the cache settings in place and no server behind them, occ upgrade and occ user:setting fail
# (Redis server went away), and the scripts have to cope. Set NC_TEST_SKIP_REAL=1 to leave this section out (it takes
# about a minute and a half).
# shellcheck disable=SC2034  # read by name, through env_merge
REAL_ENV=(
  "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  # su -p, which runs a hook, keeps root's HOME, and www-data cannot write there. The scripts have to deal with that.
  "HOME=/root"
  "PHP_MEMORY_LIMIT=512M"
  "PHP_UPLOAD_LIMIT=512M"
  "NEXTCLOUD_URL=https://abc.clouve.app"
  "NEXTCLOUD_DB_HOST=db.example.test"
  "NEXTCLOUD_DB_NAME=ncdb"
  "NEXTCLOUD_DB_USER=nextcloud"
  "NEXTCLOUD_DB_PASSWORD=s3cret"
)

# real_run SCRIPT [NAME=VALUE | -NAME]...: like nc_run, but as www-data, in the real tree, with REAL_ENV (what the container
# gives a hook, and none of the fakes' variables).
real_run() {
  local script="$1"
  shift
  env_merge REAL_ENV "$@"
  runuser -u www-data -- env -i "${MERGED[@]}" timeout 120 sh -c "$script" </dev/null >"$WORK/real.out" 2>"$WORK/real.err"
  NC_RC=$?
  NC_OUT="$(cat "$WORK/real.out")"
  NC_ERR="$(cat "$WORK/real.err")"
}

# real_occ ARGS...: the real occ, as www-data. real_capture runs it with stdin closed and leaves R_RC, R_OUT and R_ERR.
real_occ() { runuser -u www-data -- php /var/www/html/occ "$@"; }
real_capture() {
  R_OUT="$(real_occ "$@" 2>"$WORK/real.err" </dev/null)"
  R_RC=$?
  R_ERR="$(cat "$WORK/real.err")"
}
real_status() { real_occ status --output=json 2>/dev/null; }

# fontconfig_errors HOME: how many "Fontconfig error" lines PHP's Imagick logs when www-data starts it with this HOME.
fontconfig_errors() {
  runuser -u www-data -- env -i PATH=/usr/local/bin:/usr/bin:/bin "HOME=$1" php -r '(new Imagick())->queryFonts();' 2>&1 >/dev/null </dev/null | grep -c 'Fontconfig error'
}

# The real occ behind a wrapper, for OCC=$REAL_WRAP. It writes down every call (the arguments, the HOME it runs with, and
# whether someone holds the init lock while it runs) and starts Imagick before occ. With a HOME that www-data cannot write
# to, that is where "Fontconfig error: No writable cache directories" appears, as it did for the first `occ user:setting`
# of a first install. REAL_CALLS, REAL_HOMES and REAL_LOCKS are empty again for each script (real_run_wrapped).
REAL_WRAP_DIR=/tmp/nc-real
REAL_WRAP="$REAL_WRAP_DIR/occ"
REAL_CALLS="$REAL_WRAP_DIR/calls"
REAL_HOMES="$REAL_WRAP_DIR/homes"
REAL_LOCKS="$REAL_WRAP_DIR/locks"
# shellcheck disable=SC2016  # the wrapper's own code, not ours
make_real_wrapper() {
  install -d -m 777 "$REAL_WRAP_DIR"
  cat > "$REAL_WRAP" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/nc-real/calls
printf '%s\n' "$HOME" >> /tmp/nc-real/homes
if flock -n /var/www/html/nextcloud-init-sync.lock true; then echo free; else echo held; fi >> /tmp/nc-real/locks
php -r '(new Imagick())->queryFonts();' >/dev/null
exec php /var/www/html/occ "$@"
EOF
  chmod 755 "$REAL_WRAP"
}

# real_run_wrapped SCRIPT [NAME=VALUE | -NAME]...: real_run with the wrapper as the occ. Leaves the calls in REAL_SEEN_CALLS,
# the distinct HOME values in REAL_SEEN_HOMES, and the calls again in REAL_SEEN_LOCKED, each after "held " or "free ".
real_run_wrapped() {
  rm -f "$REAL_CALLS" "$REAL_HOMES" "$REAL_LOCKS"
  real_run "$@" "OCC=$REAL_WRAP"
  REAL_SEEN_CALLS="$(cat "$REAL_CALLS" 2>/dev/null)"
  REAL_SEEN_HOMES="$(sort -u "$REAL_HOMES" 2>/dev/null)"
  REAL_SEEN_LOCKED="$(paste -d ' ' "$REAL_LOCKS" "$REAL_CALLS" 2>/dev/null)"
}

# real_chunk_size: the chunk size of browser uploads as Nextcloud itself reads it, then as the files app advertises it,
# as "SIZE MAX_SIZE". SIZE is ChunkedUploadConfig::getMaxChunkSize(), which JSConfigHelper hands to the web UI, and
# MAX_SIZE is chunked_upload.max_size in the files app's capabilities (what /ocs/v2.php/cloud/capabilities shows).
# shellcheck disable=SC2016  # PHP code, not shell
real_chunk_size() {
  runuser -u www-data -- php -d display_errors=stderr -r '
    require "/var/www/html/lib/base.php";
    \OC_App::loadApp("files");
    echo \OCA\Files\Service\ChunkedUploadConfig::getMaxChunkSize(), " ",
      \OCP\Server::get(\OCA\Files\Capabilities::class)->getCapabilities()["files"]["chunked_upload"]["max_size"], "\n";' 2>/dev/null </dev/null
}

# A test app, nctrslow, whose repair step waits 60 s while $SLOW_DIR/armed exists, after touching $SLOW_DIR/started.
# occ maintenance:repair turns maintenance mode on before it runs any step, and an app's steps come after the core ones,
# so once that file is there the repair is half way, with maintenance mode on. A kill then is what a container killed
# during the repair gets. (The whole expensive repair of this small install takes about a third of a second, too
# short to hit by timing.)
SLOW_DIR=/tmp/nctrslow
SLOW_APP=/var/www/html/custom_apps/nctrslow
make_slow_repair_app() {
  mkdir -p "$SLOW_APP/appinfo" "$SLOW_APP/lib"
  cat > "$SLOW_APP/appinfo/info.xml" <<'XML'
<?xml version="1.0"?>
<info>
    <id>nctrslow</id>
    <name>Slow repair step</name>
    <summary>A repair step that waits, for a test</summary>
    <description>A repair step that waits while a flag file exists, for tests/nextcloud-image.test.sh.</description>
    <version>1.0.0</version>
    <licence>agpl</licence>
    <author>test</author>
    <namespace>NcTrSlow</namespace>
    <category>tools</category>
    <dependencies>
        <nextcloud min-version="35" max-version="35"/>
    </dependencies>
    <repair-steps>
        <post-migration>
            <step>OCA\NcTrSlow\SlowStep</step>
        </post-migration>
    </repair-steps>
</info>
XML
  cat > "$SLOW_APP/lib/SlowStep.php" <<'PHP'
<?php
namespace OCA\NcTrSlow;

use OCP\Migration\IOutput;
use OCP\Migration\IRepairStep;

class SlowStep implements IRepairStep {
	public function getName(): string {
		return 'nctrslow: wait while /tmp/nctrslow/armed exists';
	}

	public function run(IOutput $output): void {
		if (!file_exists('/tmp/nctrslow/armed')) {
			return;
		}
		touch('/tmp/nctrslow/started');
		sleep(60);
	}
}
PHP
  chown -R www-data:www-data "$SLOW_APP"
  install -d -m 777 "$SLOW_DIR"
}
slow_arm() { rm -f "$SLOW_DIR/started"; : > "$SLOW_DIR/armed"; }
slow_disarm() { rm -f "$SLOW_DIR/armed" "$SLOW_DIR/started"; }
# slow_started: waits up to 60 s for the slow step to begin. Succeeds once it has.
slow_started() {
  local i
  for ((i = 0; i < 600; i++)); do
    if [[ -e "$SLOW_DIR/started" ]]; then return 0; fi
    sleep 0.1
  done
  return 1
}
# real_kill_in_repair LABEL COMMAND...: starts COMMAND as www-data in a session of its own, waits for the slow repair
# step, then kills the whole session with SIGKILL, as a container that is killed then. Records whether the step came.
real_kill_in_repair() {
  local label="$1" pid i
  shift
  slow_arm
  setsid runuser -u www-data -- "$@" </dev/null >"$WORK/real-bg.out" 2>&1 &
  pid=$!
  if slow_started; then pass "$label: the kill comes in the middle of the repair"; else fail "$label: the kill comes in the middle of the repair"; fi
  kill -KILL -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  for ((i = 0; i < 50; i++)); do
    pgrep -u www-data >/dev/null || break
    sleep 0.1
  done
  slow_disarm
}

# real_cfg_set JSON: sets keys in the real config.php, as www-data. A null value removes the key.
# shellcheck disable=SC2016  # PHP code, not shell
real_cfg_set() {
  runuser -u www-data -- env "CHANGES=$1" php -r 'include "/var/www/html/config/config.php"; foreach (json_decode((string) getenv("CHANGES"), true) as $k => $v) { if ($v === null) { unset($CONFIG[$k]); } else { $CONFIG[$k] = $v; } } file_put_contents("/var/www/html/config/config.php", "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n");'
}

# shellcheck disable=SC2016  # PHP code, not shell
section_real_occ() {
  local hook="$HOOKS/before-starting/10-clouve.sh" conf=/var/www/html/config/config.php lock=/var/www/html/nextcloud-init-sync.lock
  local before after pw out rc row app key want
  need_script "$CONFIG_SH" || return 0
  need_script "$hook" || return 0

  echo ' the official entrypoint installs Nextcloud'
  find /var/www/html -mindepth 1 -delete
  if ! NEXTCLOUD_UPDATE=1 SQLITE_DATABASE=ncdb NEXTCLOUD_ADMIN_USER=admin NEXTCLOUD_ADMIN_PASSWORD=throwaway-admin-1 \
       /entrypoint.sh true >"$WORK/real-install.log" 2>&1; then
    fail 'the official entrypoint could not install Nextcloud'
    tail -n 15 "$WORK/real-install.log" | sed 's/^/       /'
    return 0
  fi
  pass 'the official entrypoint installed Nextcloud'
  # What the root entrypoint makes ready: the private folder, and a lock file that is www-data's. www-data cannot open a
  # root-owned file in /var/www/html (sticky and world-writable in the official image) when fs.protected_regular is on.
  install -d -o www-data -g www-data -m 700 /run/clouve/tmp
  : > "$lock"
  chown www-data:www-data "$lock"
  make_real_wrapper

  echo " HOME: su -p leaves root's, which www-data cannot write to"
  matches '^[1-9][0-9]*$' "$(fontconfig_errors /root)" 'with HOME=/root, Imagick logs "Fontconfig error: No writable cache directories"'
  eq 0 "$(fontconfig_errors /var/www)" 'with HOME=/var/www (www-data'"'"'s home), it does not'

  echo ' the real occ answers as the fake does'
  real_capture config:system:get nosuchkey
  eq '1||' "$R_RC|$R_OUT|$R_ERR" 'a key that is not set: exit status 1 and no output at all'
  real_capture config:system:get dbhost
  eq '1||' "$R_RC|$R_OUT|$R_ERR" 'dbhost is not set on a SQLite install: the same'
  real_capture config:system:get trusted_domains --output=json
  eq '0|["localhost"]|' "$R_RC|$R_OUT|$R_ERR" 'trusted_domains as JSON is an array'
  real_capture config:system:set trusted_domains 4 --value=gap.example
  eq 'System config value trusted_domains => 4 set to string gap.example' "$R_OUT" 'config:system:set prints the value it set'
  real_capture config:system:get trusted_domains --output=json
  eq '{"0":"localhost","4":"gap.example"}' "$R_OUT" 'with a gap in its indexes it is an object'
  real_capture config:system:delete trusted_domains 4
  real_capture config:system:get trusted_domains --output=json
  eq '["localhost"]' "$R_OUT" 'and an array again once the entry is gone'
  real_capture config:system:delete nosuchkey
  eq 0 "$R_RC" 'deleting a key that is not set succeeds'
  real_capture app:install files
  eq '1|files already installed|' "$R_RC|$R_OUT|$R_ERR" 'app:install of an app on disk: "already installed" and exit status 1'
  real_capture app:getpath files
  eq '0|/var/www/html/apps/files|' "$R_RC|$R_OUT|$R_ERR" 'app:getpath prints the folder of an app on disk'
  real_capture app:getpath calendar
  eq '1||' "$R_RC|$R_OUT|$R_ERR" 'app:getpath of an app that is not on disk: exit status 1 and no output at all'
  real_capture app:enable files
  eq '0|files already enabled|' "$R_RC|$R_OUT|$R_ERR" 'app:enable of an enabled app: "already enabled" and exit status 0'
  real_capture config:app:get clouve nokey --default-value= --no-warnings
  eq '0||' "$R_RC|$R_OUT|$R_ERR" 'an app config key that is not set, read with an empty --default-value: exit status 0 and no output'
  real_capture config:app:delete clouve nokey
  eq '0|Config value nokey of app clouve deleted|' "$R_RC|$R_OUT|$R_ERR" 'config:app:delete of a key that is not set: exit status 0, and the line the fake prints'
  real_capture config:system:get maintenance --default-value=false --no-warnings
  eq '0|false|' "$R_RC|$R_OUT|$R_ERR" 'maintenance mode, read as the repair step reads it after a failure: false'
  real_capture config:system:set redis port --value=0
  real_capture config:system:set redis port --type=integer --value=0
  eq '0|System config value redis => port set to integer 0' "$R_RC|$R_OUT" 'changing a string to an integer asks nothing (stdin is closed)'
  real_capture config:system:delete redis
  real_capture status --output=json
  eq "$(occ_status_json true false false)|" "$R_OUT|$R_ERR" 'status prints one line of JSON, with the fields the hook reads, and nothing on stderr'
  cp -p "$conf" "$WORK/config.php.good"
  real_cfg_set '{"dbtype":"mysql","dbhost":"old.invalid","dbname":"old","dbuser":"old","dbpassword":"old-pass"}'
  real_capture config:system:get overwrite.cli.url
  eq '1||' "$R_RC||$R_ERR" 'a database it cannot reach: exit status 1, nothing on stderr'
  matches '^An unhandled exception has been thrown:' "$R_OUT" 'and what went wrong is on stdout'

  echo ' occ cannot start because of a stale database host: the script repairs config.php itself'
  real_run "$CONFIG_SH"
  eq 1 "$NC_RC" 'exit status 1 (the new host does not exist either)'
  matches 'ERROR.*occ does not start.*An unhandled exception' "$NC_ERR" 'an ERROR line with what occ said'
  eq '["db.example.test","ncdb","nextcloud","s3cret"]' "$(php -n -r 'include $argv[1]; echo json_encode([$CONFIG["dbhost"], $CONFIG["dbname"], $CONFIG["dbuser"], $CONFIG["dbpassword"]]);' -- "$conf")" 'config.php now has the four settings of the environment'
  eq 'www-data:www-data 640' "$(stat -c '%U:%G %a' "$conf")" 'config.php keeps its owner and mode'
  eq '' "$(find /var/www/html/config -maxdepth 1 -name '.config.php.*')" 'no temporary file is left in config/'
  eq '' "$(grep -F s3cret "$WORK/real.out" "$WORK/real.err")" 's3cret appears in no output'
  real_cfg_set '{"dbtype":"sqlite3"}'
  eq "$(occ_status_json true false false)" "$(real_status)" 'the file the repair wrote is a config.php the real occ starts with'
  cp -p "$WORK/config.php.good" "$conf"

  echo ' the same repair as root, the way the root entrypoint runs it before the official entrypoint'
  real_cfg_set '{"dbtype":"mysql","dbhost":"old.invalid","dbname":"old","dbuser":"old","dbpassword":"old-pass"}'
  env_merge REAL_ENV
  out="$(env -i "${MERGED[@]}" bash -c '. "$1" && nc_repair_db_config "$2"' _ "$LIB" "$conf" 2>&1)"
  rc=$?
  eq '0|[nextcloud] database settings in config.php updated to match the environment' "$rc|$out" 'exit status 0, and the one line it prints'
  eq '["db.example.test","ncdb","nextcloud","s3cret"]' "$(php -n -r 'include $argv[1]; echo json_encode([$CONFIG["dbhost"], $CONFIG["dbname"], $CONFIG["dbuser"], $CONFIG["dbpassword"]]);' -- "$conf")" 'config.php has the four settings of the environment'
  eq 'www-data:www-data 640' "$(stat -c '%U:%G %a' "$conf")" 'config.php is still www-data'"'"'s, with the same mode'
  eq '' "$(find /var/www/html/config -maxdepth 1 -name '.config.php.*')" 'no temporary file is left in config/'
  eq '' "$(printf '%s\n' "$out" | grep -F s3cret)" 's3cret appears in no output'
  real_cfg_set '{"dbtype":"sqlite3"}'
  eq "$(occ_status_json true false false)" "$(real_status)" 'www-data can read the file, and the real occ starts with it'
  cp -p "$WORK/config.php.good" "$conf"

  echo ' nextcloud-config.sh: the first start, a restart, a custom domain, and a local http URL'
  eq '104857600 104857600' "$(real_chunk_size)" 'before it: Nextcloud uses its default chunk size of 100 MiB, which the ingress would refuse'
  real_run "$CONFIG_SH"
  eq 0 "$NC_RC" 'first start: exit status 0'
  eq $'[nextcloud] database settings updated\n[nextcloud] Nextcloud URL has changed: http://localhost -> https://abc.clouve.app\n[nextcloud] trusted_domains: added abc.clouve.app at index 1\n'"[nextcloud] files.chunked_upload.max_size set to 41943040 (40 MiB), from Nextcloud's default of 100 MiB, so that an upload request fits under the ingress's 50 MiB limit" \
    "$NC_OUT" 'first start: stdout is those four lines'
  eq '' "$NC_ERR" 'first start: nothing on stderr'
  real_capture config:system:get files.chunked_upload.max_size --output=json
  eq '0|41943040|' "$R_RC|$R_OUT|$R_ERR" 'files.chunked_upload.max_size is the integer 41943040'
  eq '41943040 41943040' "$(real_chunk_size)" 'Nextcloud now reads 40 MiB as the chunk size, and its capabilities advertise it'
  real_capture config:system:get dbhost
  eq 'db.example.test' "$R_OUT" 'config:import wrote dbhost'
  pw="$(real_occ config:system:get dbpassword 2>/dev/null)"
  eq yes "$([[ "$pw" == s3cret ]] && echo yes || echo no)" 'config:import wrote dbpassword'
  real_capture config:system:get dbname
  eq 'ncdb' "$R_OUT" 'dbname is the same (the SQLite database)'
  eq '' "$(ls -A /run/clouve/tmp)" 'the private file is gone'
  eq 'www-data:www-data 640' "$(stat -c '%U:%G %a' "$conf")" 'config.php keeps its owner and mode'
  real_capture config:system:get trusted_domains --output=json
  eq '["localhost","abc.clouve.app"]' "$R_OUT" 'trusted_domains'
  real_capture config:system:get overwriteprotocol
  eq 'https' "$R_OUT" 'overwriteprotocol'
  real_capture config:system:get trusted_proxies --output=json
  eq '["10.0.0.0\/8","172.16.0.0\/12","192.168.0.0\/16"]' "$R_OUT" 'trusted_proxies'
  real_capture config:system:get memcache.locking
  eq '\OC\Memcache\Redis' "$R_OUT" 'memcache.locking'
  real_capture config:system:get redis --output=json
  eq '{"host":"\/run\/clouve\/valkey\/valkey.sock","port":0}' "$R_OUT" 'redis: the Valkey socket, and port 0 as an integer'
  before="$(md5sum < "$conf")"
  real_run "$CONFIG_SH"
  after="$(md5sum < "$conf")"
  eq "0||$before" "$NC_RC|$NC_OUT$NC_ERR|$after" 'restart: exit status 0, nothing printed, config.php byte for byte the same'
  real_run "$CONFIG_SH" NEXTCLOUD_URL=https://cloud.example.com
  eq $'[nextcloud] Nextcloud URL has changed: https://abc.clouve.app -> https://cloud.example.com\n[nextcloud] trusted_domains: added cloud.example.com at index 2' "$NC_OUT" 'custom domain: the change line, and the new host at index 2'
  real_capture config:system:get trusted_domains --output=json
  eq '["localhost","abc.clouve.app","cloud.example.com"]' "$R_OUT" 'custom domain: the Clouve host is still trusted'
  real_run "$CONFIG_SH" NEXTCLOUD_URL=http://t1.test.clv:8080
  eq 0 "$NC_RC" 'local http: exit status 0'
  real_capture config:system:get overwriteprotocol
  eq '1|' "$R_RC|$R_OUT" 'local http: overwriteprotocol is gone'
  real_run "$CONFIG_SH"
  real_capture config:system:get overwriteprotocol
  eq 'https' "$R_OUT" 'and back to https: overwriteprotocol is back'

  echo ' nextcloud-config.sh: an upload chunk size set by an admin'
  real_capture config:system:set files.chunked_upload.max_size --type=integer --value=104857600
  real_run "$CONFIG_SH"
  eq 0 "$NC_RC" '100 MiB: exit status 0'
  contains 'files.chunked_upload.max_size set to 41943040 (40 MiB), from 104857600' "$NC_OUT" '100 MiB: stdout says it was put back'
  eq '41943040 41943040' "$(real_chunk_size)" '100 MiB: Nextcloud reads 40 MiB again'
  real_capture config:system:set files.chunked_upload.max_size --type=integer --value=0
  eq '0 0' "$(real_chunk_size)" 'sanity check: with 0, Nextcloud reads 0 (the web UI then sends every file as one request)'
  real_run "$CONFIG_SH"
  eq 0 "$NC_RC" '0: exit status 0'
  contains 'files.chunked_upload.max_size set to 41943040 (40 MiB), from 0 (chunking off)' "$NC_OUT" '0: stdout says it was put back'
  eq '41943040 41943040' "$(real_chunk_size)" '0: Nextcloud reads 40 MiB again'
  real_capture config:system:set files.chunked_upload.max_size --type=integer --value=20971520
  real_run "$CONFIG_SH"
  eq '0||' "$NC_RC|$NC_OUT|$NC_ERR" '20 MiB: exit status 0, and nothing printed'
  eq '20971520 20971520' "$(real_chunk_size)" '20 MiB, smaller than the limit: it stays'
  real_capture config:system:set files.chunked_upload.max_size --type=integer --value=41943040

  echo ' with HOME=/root, which is what su -p leaves: every occ call of a script runs with HOME=/var/www'
  real_run_wrapped "$CONFIG_SH"
  eq '0|' "$NC_RC|$NC_OUT$NC_ERR" 'nextcloud-config.sh: nothing to change, nothing printed (so no Fontconfig error)'
  eq /var/www "$REAL_SEEN_HOMES" 'nextcloud-config.sh: HOME=/var/www for every call'
  real_run_wrapped "$HOOKS/post-upgrade/10-clouve.sh"
  eq 0 "$NC_RC" 'post-upgrade: exit status 0'
  eq $'status --output=json --no-warnings\nconfig:app:delete clouve post_upgrade_done\ndb:add-missing-indices\ndb:add-missing-columns\ndb:add-missing-primary-keys\nmaintenance:repair --include-expensive\nconfig:app:set clouve post_upgrade_done --lazy --value=35.0.2.2' \
    "$REAL_SEEN_CALLS" 'post-upgrade: the status, the marker deleted, the four steps in this order, and the marker written'
  real_capture config:app:get clouve post_upgrade_done
  eq '0|35.0.2.2' "$R_RC|$R_OUT" 'post-upgrade: the marker clouve post_upgrade_done holds the version'
  lacks WARNING "$NC_ERR" 'post-upgrade: none of them failed'
  lacks Fontconfig "$NC_OUT$NC_ERR" 'post-upgrade: no Fontconfig error'
  eq /var/www "$REAL_SEEN_HOMES" 'post-upgrade: HOME=/var/www for every call'
  # The cache settings are in place and nothing serves them, so occ user:setting fails (Redis server went away), and the app
  # store is out of reach. The hook says so for those four and goes on.
  real_run_wrapped "$HOOKS/post-installation/10-clouve.sh" NEXTCLOUD_ADMIN_USER=admin NEXTCLOUD_ADMIN_EMAIL=owner@example.test
  eq 0 "$NC_RC" 'post-installation: exit status 0'
  eq $'[nextcloud] WARNING: occ user:setting admin failed (exit status 1)\n[nextcloud] WARNING: occ app:install calendar failed (exit status 1)\n[nextcloud] WARNING: occ app:install contacts failed (exit status 1)\n[nextcloud] WARNING: occ app:install groupfolders failed (exit status 1)' \
     "$(printf '%s\n' "$NC_ERR" | grep -o '\[nextcloud\] WARNING: .*')" 'post-installation: the four calls this setup cannot serve fail, and nothing else does'
  lacks Fontconfig "$NC_OUT$NC_ERR" 'post-installation: no Fontconfig error'
  eq /var/www "$REAL_SEEN_HOMES" 'post-installation: HOME=/var/www for every call'
  lacks s3cret "$REAL_SEEN_CALLS" 'post-installation: no occ command line holds the database password'
  eq $'app:install calendar\napp:getpath calendar\napp:install contacts\napp:getpath contacts\napp:install groupfolders\napp:getpath groupfolders' \
     "$(printf '%s\n' "$REAL_SEEN_CALLS" | grep -E '^app:(install|getpath|enable) ')" 'post-installation: with no app store, app:getpath finds none of the three apps, so app:enable never runs'
  for row in 'maintenance_window_start|1' 'trashbin_retention_obligation|auto, 30' 'versions_retention_obligation|auto, 365' \
             'files_external_allow_create_new_local|false' 'updatechecker|false' 'serverid|1'; do
    key="${row%%|*}" want="${row#*|}"
    real_capture config:system:get "$key"
    eq "$want" "$R_OUT" "post-installation: $key is $want"
  done
  for row in 'files_sharing|hide_disabled_user_shares|yes' 'core|backgroundjobs_mode|cron' 'app_api|enabled|no'; do
    IFS='|' read -r app key want <<<"$row"
    real_capture config:app:get "$app" "$key"
    eq "$want" "$R_OUT" "post-installation: $app $key is $want"
  done
  real_capture config:app:get clouve first_install_done
  matches "^0\\|$ISO_UTC_RE\$" "$R_RC|$R_OUT" 'post-installation: the marker clouve first_install_done is written last, with the UTC time'
  # Nextcloud 35 reads only the system key. The app key files max_chunk_size is left over from older versions, and only
  # a one-time migration (Version2003Date20241021095629) ever read it.
  real_capture config:app:get files max_chunk_size
  eq '1|' "$R_RC|$R_OUT" 'post-installation: it writes no files max_chunk_size app key, which Nextcloud 35 never reads'
  eq '41943040 41943040' "$(real_chunk_size)" 'post-installation: Nextcloud reads 40 MiB as the chunk size (nextcloud-config.sh set it)'

  echo ' before-starting: a half-finished install'
  real_cfg_set '{"installed":null}'
  real_run "$hook"
  eq 1 "$NC_RC" 'exit status 1'
  eq '[nextcloud] Nextcloud is not installed; refusing to start. See apps/nextcloud/README.md, "A half-finished first install".' "$NC_OUT" 'stdout is the refusal line'
  real_cfg_set '{"installed":true}'

  echo ' before-starting: an upgrade that fails (the cache settings are in place, and no server answers: Redis server went away)'
  real_occ maintenance:mode --on >/dev/null 2>&1
  real_cfg_set '{"version":"35.0.1.0","loglevel":0}'
  eq "$(occ_status_json true true true)" "$(real_status)" 'sanity check: this is the state a killed occ upgrade leaves'
  real_run_wrapped "$hook"
  eq 0 "$NC_RC" 'exit status 0: the start goes on'
  matches 'WARNING: occ upgrade failed \(exit status [0-9]+\)' "$NC_ERR" 'a warning says that the upgrade failed'
  eq $'status --output=json --no-warnings\nmaintenance:mode --off\nconfig:system:get loglevel\nconfig:system:set loglevel --type=integer --value=2\nupgrade --no-interaction\nconfig:system:get loglevel' "$(head -n 6 <<<"$REAL_SEEN_CALLS")" 'maintenance mode off and the log level back first, then the upgrade, and no post-upgrade step'
  contains 'Turned on maintenance mode' "$NC_OUT" 'occ upgrade turned maintenance mode on itself'
  real_capture config:system:get loglevel
  eq 2 "$R_OUT" 'the log level is 2 (the Updater put back the 2 it found)'
  eq "$(occ_status_json true true true)" "$(real_status)" 'maintenance mode is on again (occ upgrade keeps it on after a failure), and the upgrade is still pending'
  eq 0 "$(flock -n "$lock" true; echo $?)" 'the lock is free again'

  echo ' occ upgrade leaves on a maintenance mode that it finds on (which is why before-starting turns it off first)'
  # The cache settings go, because occ upgrade needs a cache that works. before-starting puts them back further down.
  real_capture config:system:delete memcache.distributed
  real_capture config:system:delete memcache.locking
  real_capture config:system:delete redis
  real_occ maintenance:mode --on >/dev/null 2>&1
  real_cfg_set '{"version":"35.0.1.0"}'
  eq "$(occ_status_json true true true)" "$(real_status)" 'sanity check: maintenance mode is on, and an upgrade is pending'
  real_capture upgrade --no-interaction
  eq 0 "$R_RC" 'occ upgrade works'
  contains 'Maintenance mode is kept active' "$R_OUT" 'occ upgrade says that it keeps maintenance mode on'
  eq "$(occ_status_json true true false)" "$(real_status)" 'maintenance mode is still on, and no upgrade is pending that a later start would finish'

  echo ' before-starting: an upgrade that was cut off'
  real_occ maintenance:mode --on >/dev/null 2>&1
  real_cfg_set '{"version":"35.0.1.0","loglevel":0}'
  eq "$(occ_status_json true true true)" "$(real_status)" 'sanity check: this is the state a killed occ upgrade leaves'
  real_run_wrapped "$hook"
  eq 0 "$NC_RC" 'exit status 0'
  contains 'Update successful' "$NC_OUT" 'occ upgrade ran, under the init lock'
  eq $'status --output=json --no-warnings\nmaintenance:mode --off\nconfig:system:get loglevel\nconfig:system:set loglevel --type=integer --value=2\nupgrade --no-interaction\nstatus --output=json --no-warnings\nconfig:app:delete clouve post_upgrade_done\ndb:add-missing-indices\ndb:add-missing-columns\ndb:add-missing-primary-keys\nmaintenance:repair --include-expensive\nconfig:app:set clouve post_upgrade_done --lazy --value=35.0.2.2\nstatus --output=json' \
    "$(head -n 13 <<<"$REAL_SEEN_CALLS")" 'maintenance mode off and the log level first, then the upgrade and the post-upgrade steps with their marker, then nextcloud-config.sh'
  matches 'Turned on maintenance mode.*Update successful.*Turned off maintenance mode' "$(tr '\n' ' ' <<<"$NC_OUT")" 'occ upgrade turned maintenance mode on and, once it had worked, off again itself'
  matches 'Update successful.*Repair mime types' "$NC_OUT" 'the expensive repair ran after the upgrade'
  lacks WARNING "$NC_ERR" 'no step failed'
  lacks Fontconfig "$NC_OUT$NC_ERR" 'no Fontconfig error'
  eq /var/www "$REAL_SEEN_HOMES" 'HOME=/var/www for every call'
  eq "$(occ_status_json true false false)" "$(real_status)" 'maintenance mode is off and nothing is pending'
  real_capture config:system:get loglevel
  eq '2' "$R_OUT" 'the log level is back to 2'
  real_capture config:system:get memcache.locking
  eq '\OC\Memcache\Redis' "$R_OUT" 'the settings were applied afterwards'
  eq 0 "$(flock -n "$lock" true; echo $?)" 'the lock is free again'
  real_run "$hook"
  eq "0||" "$NC_RC|$NC_OUT|$NC_ERR" 'the next start prints nothing and changes nothing'

  echo ' before-starting: a first start that was cut off before its own settings were all in place'
  # What a container killed during the post-installation hook leaves: Nextcloud installed, no marker, and the settings
  # after the kill missing. The trash retention stands for those.
  real_capture config:app:delete clouve first_install_done
  real_capture config:system:delete trashbin_retention_obligation
  real_capture config:app:get clouve first_install_done
  eq '1|' "$R_RC|$R_OUT" 'sanity check: no marker'
  real_run_wrapped "$hook"
  eq 0 "$NC_RC" 'exit status 0'
  contains 'first start was cut off' "$NC_OUT" 'stdout says why the first-install settings run again'
  eq $'[nextcloud] WARNING: occ app:install calendar failed (exit status 1)\n[nextcloud] WARNING: occ app:install contacts failed (exit status 1)\n[nextcloud] WARNING: occ app:install groupfolders failed (exit status 1)' \
     "$(printf '%s\n' "$NC_ERR" | grep -o '\[nextcloud\] WARNING: .*')" 'the app store is out of reach, so the three app installs fail, and nothing else does'
  real_capture config:system:get trashbin_retention_obligation
  eq 'auto, 30' "$R_OUT" 'the trash retention is in place'
  real_capture config:app:get clouve first_install_done
  matches "^0\\|$ISO_UTC_RE\$" "$R_RC|$R_OUT" 'the marker is written'
  contains $'held background:cron\n' "$REAL_SEEN_LOCKED"$'\n' 'background:cron ran while the init lock was held'
  eq '' "$(sed -n '/ background:cron$/,/ config:app:set clouve first_install_done /p' <<<"$REAL_SEEN_LOCKED" | grep -v '^held ')" \
     'every first-install step, the marker included, ran while the init lock was held'
  matches '^free status --output=json --no-warnings' "$REAL_SEEN_LOCKED" 'the first status call ran with the lock free (sanity check of the recording)'
  eq 0 "$(flock -n "$lock" true; echo $?)" 'the lock is free again'
  eq /var/www "$REAL_SEEN_HOMES" 'HOME=/var/www for every call'
  real_run "$hook"
  eq "0||" "$NC_RC|$NC_OUT|$NC_ERR" 'the next start finds the marker: it prints nothing and runs nothing again'

  echo ' the premise: a real occ maintenance:repair killed on the way leaves maintenance mode on, with nothing pending'
  make_slow_repair_app
  real_capture app:enable nctrslow
  eq 0 "$R_RC" 'sanity check: the test app with a slow repair step is enabled'
  real_kill_in_repair 'occ maintenance:repair' php /var/www/html/occ maintenance:repair --include-expensive
  eq "$(occ_status_json true true false)" "$(real_status)" 'killed half way: maintenance mode is on, and no upgrade is pending that a later start would finish'
  real_occ maintenance:mode --off >/dev/null 2>&1

  echo ' the real post-upgrade hook is killed during its repair: the real before-starting hook finishes the steps'
  env_merge REAL_ENV
  real_kill_in_repair 'post-upgrade' env -i "${MERGED[@]}" sh -c "$HOOKS/post-upgrade/10-clouve.sh"
  eq "$(occ_status_json true true false)" "$(real_status)" 'after the kill: maintenance mode is on, and no upgrade is pending'
  real_capture config:app:get clouve post_upgrade_done
  eq '1|' "$R_RC|$R_OUT" 'after the kill: the marker clouve post_upgrade_done is gone (the steps delete it first)'
  real_run_wrapped "$hook"
  eq 0 "$NC_RC" 'the next start: exit status 0'
  contains 'Maintenance mode is on, left by a start that was cut off during the post-upgrade steps for 35.0.2.2' "$NC_OUT" 'the next start: it says why it turns maintenance mode off'
  matches 'maintenance:mode --off'$'\n''.*'$'\n''db:add-missing-indices' "$REAL_SEEN_CALLS" 'the next start: maintenance mode off, then the steps'
  contains $'held db:add-missing-indices\n' "$REAL_SEEN_LOCKED"$'\n' 'the next start: db:add-missing-indices ran while the init lock was held'
  contains $'held config:app:set clouve post_upgrade_done --lazy --value=35.0.2.2\n' "$REAL_SEEN_LOCKED"$'\n' 'the next start: and the write of the marker'
  eq '' "$(sed -n '/ db:add-missing-indices$/,/ config:app:set clouve post_upgrade_done /p' <<<"$REAL_SEEN_LOCKED" | grep -v '^held ')" \
     'the next start: every post-upgrade step, the marker included, ran while the init lock was held'
  lacks WARNING "$NC_ERR" 'the next start: no step failed'
  eq "$(occ_status_json true false false)" "$(real_status)" 'the next start: maintenance mode is off, and nothing is pending'
  real_capture config:app:get clouve post_upgrade_done
  eq '0|35.0.2.2' "$R_RC|$R_OUT" 'the next start: the marker holds the version'
  real_run "$hook"
  eq "0||" "$NC_RC|$NC_OUT|$NC_ERR" 'the start after that prints nothing and runs nothing again'

  echo ' the real post-installation hook is killed during its repair: the real before-starting hook turns maintenance mode off and finishes the steps'
  # A fresh install has neither marker yet.
  real_capture config:app:delete clouve first_install_done
  real_capture config:app:delete clouve post_upgrade_done
  real_capture config:system:delete trashbin_retention_obligation
  env_merge REAL_ENV NEXTCLOUD_ADMIN_USER=admin NEXTCLOUD_ADMIN_EMAIL=owner@example.test
  real_kill_in_repair 'post-installation' env -i "${MERGED[@]}" sh -c "$HOOKS/post-installation/10-clouve.sh"
  eq "$(occ_status_json true true false)" "$(real_status)" 'after the kill: maintenance mode is on, and no upgrade is pending'
  real_capture config:app:get clouve first_install_done
  eq '1|' "$R_RC|$R_OUT" 'after the kill: no first-install marker'
  real_run_wrapped "$hook" NEXTCLOUD_ADMIN_USER=admin NEXTCLOUD_ADMIN_EMAIL=owner@example.test
  eq 0 "$NC_RC" 'the next start: exit status 0'
  contains 'Maintenance mode is on, left by a start that was cut off during the first-install settings' "$NC_OUT" 'the next start: it says that a cut-off first start left maintenance mode on'
  contains $'held background:cron\n' "$REAL_SEEN_LOCKED"$'\n' 'the next start: background:cron ran while the init lock was held'
  eq '' "$(sed -n '/ background:cron$/,/ config:app:set clouve first_install_done /p' <<<"$REAL_SEEN_LOCKED" | grep -v '^held ')" \
     'the next start: every first-install step, the markers included, ran while the init lock was held'
  eq "$(occ_status_json true false false)" "$(real_status)" 'the next start: maintenance mode is off, and nothing is pending'
  real_capture config:app:get clouve first_install_done
  matches "^0\\|$ISO_UTC_RE\$" "$R_RC|$R_OUT" 'the next start: the first-install marker is written'
  real_capture config:app:get clouve post_upgrade_done
  eq '0|35.0.2.2' "$R_RC|$R_OUT" 'the next start: and the post-upgrade one'
  real_capture config:system:get trashbin_retention_obligation
  eq 'auto, 30' "$R_OUT" 'the next start: a setting after the repair is in place'
  real_run "$hook"
  eq "0||" "$NC_RC|$NC_OUT|$NC_ERR" 'the start after that prints nothing and runs nothing again'
  real_occ app:disable nctrslow >/dev/null 2>&1
  rm -rf "$SLOW_APP" "$SLOW_DIR"

  echo ' before-starting: the post-upgrade marker names an older version and maintenance mode is on: the steps run, and maintenance mode stays on'
  # As after an upgrade that the AI Assistant finished at runtime (occ.sh --init-lock upgrade runs none of the steps),
  # with maintenance mode then turned on by an admin. A cut-off run would have left the marker missing, not older.
  real_capture config:app:set clouve post_upgrade_done --lazy --value=35.0.1.1
  real_occ maintenance:mode --on >/dev/null 2>&1
  real_run_wrapped "$hook"
  eq 0 "$NC_RC" 'exit status 0'
  contains 'The post-upgrade steps have not run for 35.0.2.2 yet (the marker clouve post_upgrade_done says 35.0.1.1).' "$NC_OUT" 'stdout says why the steps run'
  lacks 'maintenance:mode' "$REAL_SEEN_CALLS" 'maintenance mode is not touched'
  contains $'held db:add-missing-indices\n' "$REAL_SEEN_LOCKED"$'\n' 'the steps run under the init lock'
  eq "$(occ_status_json true true false)" "$(real_status)" 'maintenance mode is still on, and nothing is pending'
  real_capture config:app:get clouve post_upgrade_done
  eq '0|35.0.2.2' "$R_RC|$R_OUT" 'the marker holds the version'
  real_occ maintenance:mode --off >/dev/null 2>&1

  echo " the root entrypoint's step 7, run as it is in entrypoint.sh: a backup marker in a root-only folder, and maintenance mode on"
  # The lines between the headings of steps 7 and 8, so the test runs the entrypoint's own call, with the OCC it sets.
  local step7 backup=/var/www/html/data/clouve-backups/BACKUP-IN-PROGRESS holder i
  step7="$(sed -n '/^# --- 7\. /,/^# --- 8\. /p' "$INSTALLER/entrypoint.sh")"
  contains "OCC='runuser -u www-data -- php /var/www/html/occ' nc_clear_cut_off_backup" "$step7" 'sanity check: step 7 runs nc_clear_cut_off_backup with occ as www-data'
  install -d -o root -g root -m 700 /var/www/html/data/clouve-backups
  printf '20261024-120000\n' > "$backup"
  chmod 600 "$backup"
  real_occ maintenance:mode --on >/dev/null 2>&1
  env_merge REAL_ENV
  # holding the lock as backup.sh does, for as long as it holds maintenance mode on
  ( exec 8<"$backup"; flock -x 8 && exec sleep 120 ) &
  holder=$!
  for ((i = 0; i < 50; i++)); do flock -n -E 75 "$backup" true; [[ $? -eq 75 ]] && break; sleep 0.1; done
  out="$(env -i "${MERGED[@]}" bash -c '. "$1" && eval "$2"' _ "$LIB" "$step7" 2>&1)"
  eq "[nextcloud] A backup (20261024-120000) is still running: it holds the lock on its marker, $backup. Maintenance mode and the marker are left to it." \
     "$out" 'a backup still holds its lock: step 7 says so and does nothing else'
  eq "$(occ_status_json true true false)|yes" "$(real_status)|$(exists "$backup")" 'a backup still holds its lock: maintenance mode is on and the marker is there'
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  out="$(env -i "${MERGED[@]}" bash -c '. "$1" && eval "$2"' _ "$LIB" "$step7" 2>&1)"
  contains '[nextcloud] A backup (20261024-120000) was cut off when the container stopped. Maintenance mode, which it had turned on, is off again, and its marker is gone.' \
     "$out" 'nobody holds the lock: step 7 names the backup and says what it did'
  eq "$(occ_status_json true false false)" "$(real_status)" 'nobody holds the lock: maintenance mode is off (occ ran as www-data through runuser)'
  eq no "$(exists "$backup")" 'nobody holds the lock: the marker is gone'
  eq 'www-data:www-data 640' "$(stat -c '%U:%G %a' "$conf")" 'config.php is still www-data'"'"'s, with its mode'
  rm -rf /var/www/html/data/clouve-backups
}

# ----------------------------------------------------------------------------
# 4. Run the sections
# ----------------------------------------------------------------------------
run_section "the harness: load_lib and run_section"                       section_harness
run_section "lib.sh: nc_log and nc_warn"                                  section_lib_log
run_section "lib.sh: nc_decode_entities"                                  section_lib_entities
run_section "lib.sh: nc_clean_admin_user"                                 section_lib_admin_user
run_section "lib.sh: nc_url_scheme and nc_url_host"                       section_lib_url
run_section "lib.sh: memory limit, Apache workers, preview concurrency"   section_lib_memory
run_section "lib.sh: nc_missing_trusted_domains"                          section_lib_trusted_domains
run_section "lib.sh: nc_occ and nc_try_occ"                              section_lib_occ
run_section "lib.sh: nc_first_lines, nc_sweep_leftovers"                   section_lib_text_and_sweep
run_section "lib.sh: nc_repair_db_config (as root and as www-data)"        section_lib_repair
run_section "lib.sh: sourcing and calling it from another script"         section_lib_hygiene
run_section "valkey.conf"                                                 section_valkey_conf
run_section "start-valkey.sh: the socket directory and the restart loop"  section_valkey_loop
run_section "healthcheck.sh: the cases (fake flock, valkey-cli, curl)"    section_healthcheck
run_section "healthcheck.sh: the real flock and curl"                     section_healthcheck_real
run_section "nextcloud-config.sh: the URL, the scheme and trusted_domains"  section_config_urls
run_section "nextcloud-config.sh: the database settings"                  section_config_database
run_section "nextcloud-config.sh: occ that cannot start, a moved database" section_config_repair
run_section "nextcloud-config.sh: proxies, cache, previews, failures"     section_config_other
run_section "nextcloud-config.sh: the upload chunk size"                  section_config_chunk_size
run_section "lib.sh: occ status and the app config markers"              section_lib_status
run_section "lib.sh: the post-upgrade steps and their marker"            section_lib_post_upgrade_steps
run_section "lib.sh: the marker files of backups and restores"           section_lib_markers
run_section "lib.sh: nc_claim_new_volume, a new disk's top folder"       section_lib_new_volume
run_section "lib.sh: nc_make_init_lock, the init lock file"               section_lib_init_lock
run_section "patch-official-entrypoint.sh: the edits to /entrypoint.sh"   section_patch_entrypoint
run_section "hooks: pre-installation"                                     section_hook_pre_installation
run_section "hooks: post-installation"                                    section_hook_post_installation
run_section "hooks: post-upgrade"                                         section_hook_post_upgrade
run_section "hooks: before-starting"                                      section_hook_before_starting
run_section "hooks: before-starting finishes a cut-off first install"     section_hook_first_install_resume
run_section "hooks: before-starting finishes cut-off post-upgrade steps"  section_hook_post_upgrade_resume
run_section "hooks: the set"                                              section_hook_files
if [[ -z "${NC_TEST_SKIP_REAL:-}" ]]; then
  run_section "the real occ: the scripts against a SQLite install"          section_real_occ
fi

finish
