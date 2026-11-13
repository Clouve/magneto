#!/bin/bash

# ============================================================================
# The database password stays out of the log and off command lines
# ============================================================================
# Gibbon's and Moodle's update-config.sh run at every container start. They
# write the database settings into config.php and, when the app's URL is set,
# compare and update it in the database with the mysql client.
#
# For each script this test checks that:
#   - when one of the four database settings is empty, the warning says only
#     whether the password is set, never what it is;
#   - with everything set, no mysql, sed or awk command line holds the
#     password, every mysql call gets it in MYSQL_PWD instead, nothing the
#     script prints holds it, and config.php still gets it;
#   - a password with a ' and a \ lands in config.php as a PHP string that
#     reads back the same.
# Moodle's install.sh, with a fake php that records its arguments, puts
# neither the database password nor the admin's on php's command line.
# The scripts run in a temporary folder with a made-up config.php and fake
# mysql and sleep commands on PATH; the fake mysql records its arguments and
# whether MYSQL_PWD was the password ("match" or "no", never the value).
#
# It also reads every shell script of the Gibbon, Moodle, WordPress,
# LimeSurvey and SuiteCRM images (the last two's database images too)
# and fails on a line that passes a password as an argument: -p"$...",
# --password, any --...pass...= option, or a variable whose name holds PASS
# expanded into a command that runs as its own process (a sed script, php -r
# code). A process's arguments can be read by every process in the container.
#
# Needs bash and python3 only: no Docker, no database.
#
# Usage: bash tests/installer-db-password.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# A made-up password with characters sed and the shell treat specially. CORE is its random part, which any escaped
# form of it still holds.
CORE="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
PW="pw-$CORE/&x"
printf '%s' "$PW" > "$WORK/expected"
chmod 600 "$WORK/expected"

# The fake mysql: one line per call in calls (its arguments) and one in pwd (match or no). It reads any SQL piped in.
# A SELECT of a URL answers with an old one, so the scripts take their "URL changed" path and make every call.
cat > "$WORK/bin/mysql" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE/calls"
if [ "${MYSQL_PWD-}" = "$(cat "$FAKE/expected")" ]; then echo match >> "$FAKE/pwd"; else echo no >> "$FAKE/pwd"; fi
[ -t 0 ] || cat > /dev/null
case "$*" in
  *"SELECT value"*) echo "https://old.example.test" ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/sleep"
# sed and awk run as themselves, after recording their arguments in tools (a password in a sed script is on a command
# line too).
for tool in sed awk; do
  real="$(command -v "$tool")"
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "$FAKE/tools"\nexec %s "$@"\n' "$tool" "$real" > "$WORK/bin/$tool"
done
chmod +x "$WORK/bin/mysql" "$WORK/bin/sleep" "$WORK/bin/sed" "$WORK/bin/awk"

# run_script <app> <db host> <url> [password]: runs a copy of the app's update-config.sh with the made-up password (or
# the one given). Sets OUT, CALLS (mysql's recorded arguments), PWDS (match/no per call), TOOLS (sed's and awk's
# recorded arguments) and CONFIG (config.php after the run).
run_script() {
  local app="$1" host="$2" url="$3" dir="$WORK/run-$1-$RANDOM" config pw="${4:-$PW}"
  printf '%s' "$pw" > "$WORK/expected"
  mkdir -p "$dir/install"
  cp "$REPO_DIR/apps/$app/image/installer/update-config.sh" "$dir/update-config.sh"
  config="$dir/install/config.php"
  if [ "$app" = gibbon ]; then
    printf '%s\n' "<?php" "\$databaseServer = 'x';" "\$databaseName = 'x';" "\$databaseUsername = 'x';" \
      "\$databasePassword = 'x';" > "$config"
  else
    printf '%s\n' "<?php" "\$CFG->dbhost    = 'x';" "\$CFG->dbname    = 'x';" "\$CFG->dbuser    = 'x';" \
      "\$CFG->dbpass    = 'x';" "\$CFG->wwwroot   = 'x';" > "$config"
  fi
  : > "$WORK/calls"; : > "$WORK/pwd"; : > "$WORK/tools"
  cp "$WORK/expected" "$WORK/expected.copy"
  OUT="$(cd "$dir" && env -i PATH="$WORK/bin:/usr/bin:/bin" FAKE="$WORK" \
    GIBBON_INSTALL_PATH="$dir/install" MOODLE_INSTALL_PATH="$dir/install" \
    DB_HOST="$host" DB_NAME=app DB_USER=app DB_PASSWORD="$pw" GIBBON_URL="$url" MOODLE_URL="$url" \
    bash ./update-config.sh 2>&1 < /dev/null)"
  CALLS="$(cat "$WORK/calls")"
  PWDS="$(cat "$WORK/pwd")"
  CONFIG="$(cat "$config")"
  TOOLS="$(cat "$WORK/tools")"
  printf '%s' "$PW" > "$WORK/expected"
}

holds_pw() { grep -cF -- "$PW" <<< "$1"; }

for app in gibbon moodle; do
  echo "$app: a database setting is empty"
  run_script "$app" "" ""
  assert_eq "the output doesn't hold the password" "0" "$(holds_pw "$OUT")"
  assert_eq "it says the password is set" "1" "$(grep -c 'DB_PASSWORD: (set)' <<< "$OUT")"

  echo "$app: every setting and the URL are set"
  run_script "$app" db.example.test "https://new.example.test"
  calls="$(grep -c . <<< "$CALLS")"
  if [ "$calls" -ge 4 ]; then pass "the script ran mysql ($calls calls)"; else fail "the script ran mysql ($calls calls)"; fi
  assert_eq "no mysql command line holds the password" "0" "$(holds_pw "$CALLS")"
  assert_eq "every mysql call had the password in MYSQL_PWD" "$calls" "$(grep -c '^match$' <<< "$PWDS")"
  assert_eq "the output doesn't hold the password" "0" "$(holds_pw "$OUT")"
  assert_eq "config.php holds the password" "1" "$(holds_pw "$CONFIG")"
  assert_eq "no sed or awk command line holds the password, escaped or not" "0" "$(grep -cF -- "$CORE" <<< "$TOOLS")"

  echo "$app: a password with a quote and a backslash"
  odd_core="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  odd="pw-'q'-\\-$odd_core"
  run_script "$app" db.example.test "" "$odd"
  # PHP's single-quoted form: each \ doubled, each ' after a \.
  quoted="${odd//\\/\\\\}"; quoted="'${quoted//\'/\\\'}'"
  if [ "$app" = gibbon ]; then want="\$databasePassword = $quoted;"; else want="\$CFG->dbpass    = $quoted;"; fi
  assert_eq "config.php gets it as a PHP string that reads back the same" "1" "$(grep -cxF -- "$want" <<< "$CONFIG")"
  assert_eq "no sed or awk command line holds it" "0" "$(grep -cF -- "$odd_core" <<< "$TOOLS")"
done

echo "moodle: the first install passes no password on a command line"
# install.sh runs upgrade.sh, then php with install.php's options. The fake php records its arguments; the image's
# real php is exercised by tests/app-ops-password.test.sh.
mkdir -p "$WORK/moodle-pkg" "$WORK/moodle-install/admin/cli" "$WORK/moodledata"
printf '#!/bin/sh\nexit 0\n' > "$WORK/moodle-pkg/upgrade.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "php $*" >> "$FAKE/tools"\nexit 0\n' > "$WORK/bin/php"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/chown"
chmod +x "$WORK/moodle-pkg/upgrade.sh" "$WORK/bin/php" "$WORK/bin/chown"
: > "$WORK/tools"
ADMIN_PW="admin-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
out="$(env -i PATH="$WORK/bin:/usr/bin:/bin" FAKE="$WORK" MOODLE_PACKAGE_INSTALLER="$WORK/moodle-pkg" \
  MOODLE_INSTALL_PATH="$WORK/moodle-install" MOODLEDATA_PATH="$WORK/moodledata" DB_HOST=db DB_NAME=moodle \
  DB_USER=moodle DB_PASSWORD="$PW" MOODLE_PASSWORD="$ADMIN_PW" \
  bash "$REPO_DIR/apps/moodle/image/installer/install.sh" 2>&1 < /dev/null)"
assert_eq "php ran once" "1" "$(grep -c '^php ' "$WORK/tools")"
assert_eq "its command line holds neither the database password nor the admin's" "0" \
  "$(grep -cF -e "$PW" -e "$ADMIN_PW" "$WORK/tools")"
assert_eq "nor does the output" "0" "$(grep -cF -e "$PW" -e "$ADMIN_PW" <<< "$out")"

echo "No image script passes a password as an argument"
# Every shell script in the three apps' images, read as logical lines (a line ending in \ joined with the next, a line
# whose quote is still open joined until it closes, heredoc bodies left out) with their single-quoted text blanked,
# but only where the quote opens outside double quotes: "... '$X_PASSWORD' ..." is expanded. A line fails when it
# holds an option such as --password,
# --dbpass= or --admin_password=, a -p"$..." option, or expands a variable whose name holds PASS into the arguments of
# a command that runs as its own process. Expanding it is fine in an assignment (NAME="$X_PASSWORD" cmd, export) and
# in the shell's own builtins ([, [[, test, echo, printf), which start no process.
cat > "$WORK/scan.py" <<'SCAN'
import glob
import os
import re
import sys

OPTIONS = [
    (re.compile(r"""(^|\s)-p["']?\$"""), "mysql -p with a variable"),
    (re.compile(r"--password[= ]"), "--password"),
    (re.compile(r"--[A-Za-z_-]*pass[A-Za-z_-]*=", re.I), "a --...pass...= option"),
]
EXPANSION = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*PASS[A-Za-z0-9_]*)")
SEPARATOR = re.compile(r"(;|&&|\|\||\||\$\(|`|\(|\b(?:then|do|else|if|elif|while|until)\s)")
BUILTINS = {"[", "[[", "test", "echo", "printf", "export", "local", "declare", "readonly", ":", "!"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")


HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")


def blank_single_quotes(text):
    """(text, state): text with each single-quoted span that opens outside double quotes made '' (the shell expands
    nothing in it), a comment cut off, and the quote still open at the end ('' when none is). Inside double quotes a '
    is an ordinary character, and $NAME there is expanded."""
    out, state, i = [], "", 0
    while i < len(text):
        c = text[i]
        if state == "'":
            if c == "'":
                state = ""
                out.append("''")
            i += 1
            continue
        if c == "\\" and i + 1 < len(text):
            out.append(text[i:i + 2])
            i += 2
            continue
        if state == '"':
            if c == '"':
                state = ""
            out.append(c)
            i += 1
            continue
        if c == "'":
            state = "'"
            i += 1
            continue
        if c == '"':
            state = '"'
        elif c == "#" and (i == 0 or text[i - 1].isspace()):
            break
        out.append(c)
        i += 1
    return "".join(out), state


def logical_lines(path):
    """(first line number, text) per command line: a line ending in \\ joined with the next, a line whose quote is
    still open joined until it closes (a php -r or awk program over several lines), and heredoc bodies left out (they
    go to a command's input, not its arguments). The text has its single-quoted spans blanked."""
    lines = open(path, encoding="utf-8").read().split("\n")
    out, i, heredoc = [], 0, None
    while i < len(lines):
        if heredoc is not None:
            if lines[i].lstrip("\t") == heredoc:
                heredoc = None
            i += 1
            continue
        start, raw = i + 1, lines[i]
        while True:
            text, state = blank_single_quotes(raw)
            if state and i + 1 < len(lines):
                i += 1
                raw += "\n" + lines[i]
                continue
            if not state and raw.endswith("\\") and not raw.endswith("\\\\") and i + 1 < len(lines):
                i += 1
                raw = raw[:-1] + " " + lines[i]
                continue
            break
        out.append((start, text))
        m = HEREDOC.search(text.replace("''", "")) or HEREDOC.search(raw)
        if m:
            heredoc = m.group(1)
        i += 1
    return out


def runs_as_process(text, pos):
    """Whether the expansion at pos is an argument of a command that runs as its own process."""
    seg_start = 0
    for m in SEPARATOR.finditer(text, 0, pos):
        seg_start = m.end()
    words = text[seg_start:pos].split()
    current = words[-1] if words and not text[pos - 1].isspace() else ""
    if ASSIGNMENT.match(current):
        return False
    for word in words:
        if ASSIGNMENT.match(word):
            continue
        return word.strip("\"'") not in BUILTINS
    return False


root = sys.argv[1]
for app in sys.argv[2:]:
    for path in sorted(glob.glob(os.path.join(root, "apps/%s/image/**/*.sh" % app), recursive=True)):
        # Single-quoted text (a sed or awk program, php -r code) is never expanded by the shell, so an option name or
        # a $NAME in it carries no value onto a command line; logical_lines has blanked it.
        for number, text in logical_lines(path):
            for pattern, label in OPTIONS:
                if pattern.search(text):
                    print("%s:%d %s" % (os.path.relpath(path, root), number, label))
            for m in EXPANSION.finditer(text):
                if runs_as_process(text, m.start()):
                    print("%s:%d %s in a command's arguments" % (os.path.relpath(path, root), number, m.group(1)))
SCAN

# The scan itself, on a probe script: the lines marked "caught" must be found, the others not.
mkdir -p "$WORK/probe/apps/gibbon/image"
cat > "$WORK/probe/apps/gibbon/image/probe.sh" <<'PROBE'
mysql -h db -e "SET PASSWORD FOR x = '$DB_PASSWORD';"
sed -i "s/^\$CFG->dbpass[[:space:]]*=.*$/\$CFG->dbpass    = '${DB_PASSWORD_ESCAPED}';/" "$CONFIG_FILE"
php -r "
    \$c = mysqli_connect('db', 'u', '$DB_PASSWORD');"
CLV_DB_PASSWORD="$DB_PASSWORD" awk -v x=1 '{ print ENVIRON["CLV_DB_PASSWORD"] }' f
MYSQL_PWD="$DB_PASSWORD" mysql -e "SELECT 'a'"
[ -z "$DB_PASSWORD" ] && echo "DB_PASSWORD: (set)"
echo "clouve-ops:$CLOUVE_OPS_PASSWORD" | chpasswd
awk '
    { print "$X_PASSWORD" }' f
mysql <<EOF
SET x = "$DB_PASSWORD";
EOF
PROBE
probe="$(python3 -I -B "$WORK/scan.py" "$WORK/probe" gibbon)"
for line in 1 2 3; do
  assert_eq "the scan catches probe line $line" "1" "$(grep -c "^apps/gibbon/image/probe.sh:$line " <<< "$probe")"
done
assert_eq "and nothing else in the probe" "3" "$(grep -c . <<< "$probe")"

found="$(python3 -I -B "$WORK/scan.py" "$REPO_DIR" gibbon moodle wordpress limesurvey suitecrm)"
if [ -z "$found" ]; then
  pass "none does"
else
  while IFS= read -r line; do fail "$line"; done <<< "$found"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sThe database password stays out of the log and off command lines.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sA password reached the log or a command line.%s\n' "$RED" "$RESET"
exit 1
