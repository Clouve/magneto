#!/bin/bash

# ============================================================================
# Gibbon school year test
# ============================================================================
# Gibbon's gibbon.sql ships its school years with fixed statuses from the day
# the release was cut. v30.0.01 seeds 2025-2026 as Current and 2026-2027 as
# Upcoming, so a school installed in October 2026 started in last year.
# apps/gibbon/image/installer/school-year.sh fixes the statuses at first
# install, from the install date:
#   - the year that contains the date is Current, earlier years Past, later
#     years Upcoming;
#   - between two years (the summer gap) the coming year is Current;
#   - past every seeded year, the missing years are added (YYYY-YYYY, the last
#     seeded year's dates moved on by whole years, sequenceNumber continuing);
#   - one Upcoming year always follows Current, because Gibbon's rollover
#     refuses to run without a next year to move into.
#
# Checks the date logic on the v30.0.01 seed, the SQL the script sends to
# MySQL (through a stub `mysql`), and that install.sh runs it after Gibbon's
# own installer without letting a failure stop the install.
#
# Nothing is built, no container runs and no MySQL is needed.
#
# Usage: bash tests/gibbon-school-year.test.sh
# ============================================================================

set -uo pipefail
unset GIBBON_TIMEZONE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$SCRIPT_DIR/../apps/gibbon/image/installer"
SCHOOL_YEAR_SH="$INSTALLER_DIR/school-year.sh"
INSTALL_SH="$INSTALLER_DIR/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected:\n%s\n       actual:\n%s\n' \
    "$(sed 's/^/         /' <<< "$2")" "$(sed 's/^/         /' <<< "$3")"; fi; }
assert_not_contains() { if ! grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       did NOT want: %q\n' "$3"; fi; }

T=$'\t'
row() { local IFS="$T"; printf '%s\n' "$*"; }

# The school years in Gibbon v30.0.01's gibbon.sql, as `mysql -N -B` prints
# them (the ZEROFILL id keeps its leading zero).
SEED="$(row 025 2025-2026 Current 3 2025-05-19 2026-06-29
        row 026 2026-2027 Upcoming 4 2026-08-10 2027-06-29)"

if [[ -f "$SCHOOL_YEAR_SH" ]]; then
  # shellcheck source=/dev/null
  source "$SCHOOL_YEAR_SH"
else
  fail "school-year.sh exists at $SCHOOL_YEAR_SH"
fi

# plan DATE [ROWS]: school_year_plan on the seed (or ROWS, even when empty).
plan() {
  if declare -F school_year_plan >/dev/null; then
    school_year_plan "$1" <<< "${2-$SEED}"
  else
    echo "school_year_plan is not defined"; return 127
  fi
}

# ============================================================================
echo "Statuses from the install date (v30.0.01 seed)"
# ============================================================================
SEED_AS_SHIPPED="$(row 025 2025-2026 Current 3 2025-05-19 2026-06-29
                   row 026 2026-2027 Upcoming 4 2026-08-10 2027-06-29)"

assert_eq "before the first seeded year (2025-03-01): 2025-2026 Current" \
  "$SEED_AS_SHIPPED" "$(plan 2025-03-01)"
assert_eq "inside 2025-2026 (2025-12-01): 2025-2026 Current, 2026-2027 Upcoming" \
  "$SEED_AS_SHIPPED" "$(plan 2025-12-01)"
assert_eq "on 2025-2026's last day (2026-06-29): still 2025-2026" \
  "$SEED_AS_SHIPPED" "$(plan 2026-06-29)"

NEXT_YEAR_CURRENT="$(row 025 2025-2026 Past 3 2025-05-19 2026-06-29
                     row 026 2026-2027 Current 4 2026-08-10 2027-06-29
                     row new 2027-2028 Upcoming 5 2027-08-10 2028-06-29)"

assert_eq "summer gap (2026-07-15): the coming year 2026-2027 is Current, 2027-2028 added as Upcoming" \
  "$NEXT_YEAR_CURRENT" "$(plan 2026-07-15)"
assert_eq "today (2026-10-20): 2026-2027 Current, 2025-2026 Past, 2027-2028 added as Upcoming" \
  "$NEXT_YEAR_CURRENT" "$(plan 2026-10-20)"

assert_eq "past the seed (2027-10-01): 2027-2028 added as Current, 2028-2029 as Upcoming" \
  "$(row 025 2025-2026 Past 3 2025-05-19 2026-06-29
     row 026 2026-2027 Past 4 2026-08-10 2027-06-29
     row new 2027-2028 Current 5 2027-08-10 2028-06-29
     row new 2028-2029 Upcoming 6 2028-08-10 2029-06-29)" \
  "$(plan 2027-10-01)"

assert_eq "two years past the seed, in a summer gap (2029-07-01): missing years added, the coming one Current" \
  "$(row 025 2025-2026 Past 3 2025-05-19 2026-06-29
     row 026 2026-2027 Past 4 2026-08-10 2027-06-29
     row new 2027-2028 Past 5 2027-08-10 2028-06-29
     row new 2028-2029 Past 6 2028-08-10 2029-06-29
     row new 2029-2030 Current 7 2029-08-10 2030-06-29
     row new 2030-2031 Upcoming 8 2030-08-10 2031-06-29)" \
  "$(plan 2029-07-01)"

assert_eq "rows are taken in sequenceNumber order, whatever order they arrive in" \
  "$NEXT_YEAR_CURRENT" \
  "$(plan 2026-10-20 "$(row 026 2026-2027 Upcoming 4 2026-08-10 2027-06-29
                        row 025 2025-2026 Current 3 2025-05-19 2026-06-29)")"

assert_eq "a year ending on 29 February moves to the 28th in a year without one" \
  "$(row 001 2027-2028 Past 1 2027-03-01 2028-02-29
     row new 2028-2029 Current 2 2028-03-01 2029-02-28
     row new 2029-2030 Upcoming 3 2029-03-01 2030-02-28)" \
  "$(plan 2028-06-01 "$(row 001 2027-2028 Current 1 2027-03-01 2028-02-29)")"

# ============================================================================
echo
echo "Unexpected input changes nothing"
# ============================================================================
expect_refused() { # label date rows
  local out rc
  out="$(plan "$2" "$3" 2>/dev/null)"; rc=$?
  if [[ $rc -ne 0 && -z "$out" ]]; then pass "$1"; else
    fail "$1"; printf '       exit %s, output:\n%s\n' "$rc" "$(sed 's/^/         /' <<< "$out")"; fi
}
expect_refused "a date that isn't YYYY-MM-DD" "20261020" "$SEED"
expect_refused "a month that doesn't exist" "2026-13-01" "$SEED"
expect_refused "no school years at all" "2026-10-20" ""
expect_refused "a school year without a last day (NULL)" "2026-10-20" \
  "$(row 025 2025-2026 Current 3 2025-05-19 NULL)"

# ============================================================================
echo
echo "school-year.sh against a stub mysql"
# ============================================================================
# The stub answers the SELECT with $STUB_ROWS, records every other call's
# stdin (the SQL) in $WORK/applied.sql, and fails that call when
# $STUB_APPLY_FAILS=1. `date` is stubbed to print $STUB_TODAY and record the
# TZ it ran in.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/mysql" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK/mysql-args"
printf '%s\n' "${MYSQL_PWD:-}" >> "$WORK/mysql-pwd"
for a in "$@"; do
  if [[ "$a" == "-e" ]]; then printf '%s\n' "$STUB_ROWS"; exit 0; fi
done
cat >> "$WORK/applied.sql"
[[ "${STUB_APPLY_FAILS:-0}" != 1 ]]
EOF
cat > "$WORK/bin/date" <<'EOF'
#!/bin/bash
printf '%s\n' "${TZ:-}" >> "$WORK/date-tz"
printf '%s\n' "$STUB_TODAY"
EOF
chmod +x "$WORK/bin/mysql" "$WORK/bin/date"

DB_PW="db-pw-sentinel-7f3a"
# run_script [ARGS...] -> sets RC and APPLIED. Call it directly, not in $(...).
run_script() {
  rm -f "$WORK/applied.sql" "$WORK/mysql-args" "$WORK/mysql-pwd" "$WORK/date-tz"
  WORK="$WORK" PATH="$WORK/bin:$PATH" \
    DB_HOST=gibbon-mysql DB_USER=gibbon DB_NAME=gibbon DB_PASSWORD="$DB_PW" \
    bash "$SCHOOL_YEAR_SH" "$@" > "$WORK/out" 2>&1
  RC=$?
  APPLIED="$(cat "$WORK/applied.sql" 2>/dev/null)"
}

export STUB_ROWS="$SEED" STUB_TODAY="2026-10-20" STUB_APPLY_FAILS=0
run_script 2026-10-20
assert_eq "today (2026-10-20): exits 0" "0" "$RC"
assert_eq "today (2026-10-20): sends one transaction that moves 25 to Past, 26 to Current and adds 2027-2028" \
  "START TRANSACTION;
UPDATE gibbonSchoolYear SET status='Past' WHERE gibbonSchoolYearID=25;
UPDATE gibbonSchoolYear SET status='Current' WHERE gibbonSchoolYearID=26;
INSERT INTO gibbonSchoolYear (name, status, sequenceNumber, firstDay, lastDay) VALUES ('2027-2028', 'Upcoming', 5, '2027-08-10', '2028-06-29');
COMMIT;" "$APPLIED"
assert_not_contains "the database password stays off the mysql command line" \
  "$(cat "$WORK/mysql-args" 2>/dev/null)" "$DB_PW"
assert_eq "mysql gets the password from MYSQL_PWD on every call" \
  "$DB_PW
$DB_PW" "$(cat "$WORK/mysql-pwd" 2>/dev/null)"

STUB_TODAY="2027-10-01" run_script
assert_eq "no date given: the install date comes from the clock (2027-10-01 adds 2027-2028 as Current)" \
  "START TRANSACTION;
UPDATE gibbonSchoolYear SET status='Past' WHERE gibbonSchoolYearID=25;
UPDATE gibbonSchoolYear SET status='Past' WHERE gibbonSchoolYearID=26;
INSERT INTO gibbonSchoolYear (name, status, sequenceNumber, firstDay, lastDay) VALUES ('2027-2028', 'Current', 5, '2027-08-10', '2028-06-29');
INSERT INTO gibbonSchoolYear (name, status, sequenceNumber, firstDay, lastDay) VALUES ('2028-2029', 'Upcoming', 6, '2028-08-10', '2029-06-29');
COMMIT;" "$APPLIED"
assert_eq "no date given: the clock is read in Gibbon's default timezone (as auto.php sets it)" \
  "America/Los_Angeles" "$(cat "$WORK/date-tz" 2>/dev/null)"

GIBBON_TIMEZONE="Pacific/Auckland" run_script
assert_eq "no date given: the clock is read in the school's GIBBON_TIMEZONE" \
  "Pacific/Auckland" "$(cat "$WORK/date-tz" 2>/dev/null)"

STUB_ROWS="$(row 025 2025-2026 Current 3 2025-05-19 NULL)" run_script 2026-10-20
assert_eq "unexpected rows: nothing is sent to MySQL" "" "$APPLIED"
if [[ "$RC" -ne 0 ]]; then pass "unexpected rows: exits non-zero"; else fail "unexpected rows: exits non-zero"; fi

STUB_APPLY_FAILS=1 run_script 2026-10-20
if [[ "$RC" -ne 0 ]]; then pass "MySQL rejects the SQL: exits non-zero"; else fail "MySQL rejects the SQL: exits non-zero"; fi

# ============================================================================
echo
echo "install.sh runs it once Gibbon's installer has loaded gibbon.sql"
# ============================================================================
# Stubs for the scripts and php that install.sh calls; each one appends its
# name to $WORK/order. The stub school-year.sh fails when $SY_FAILS=1.
I="$WORK/install"
mkdir -p "$I/pkg" "$I/html/installer" "$I/bin"
for s in upgrade school-year; do
  printf '#!/bin/bash\necho %s >> "$ORDER"\n' "$s" > "$I/pkg/$s.sh"
done
echo '[[ "${SY_FAILS:-0}" != 1 ]]' >> "$I/pkg/school-year.sh"
printf '#!/bin/bash\necho "php $*" >> "$ORDER"\n' > "$I/bin/php"
chmod +x "$I/pkg/"*.sh "$I/bin/php"

run_install() { # -> sets RC, ORDER_TXT
  rm -f "$I/order"
  ORDER="$I/order" PATH="$I/bin:$PATH" GIBBON_PACKAGE_INSTALLER="$I/pkg" \
    GIBBON_INSTALL_PATH="$I/html" bash "$INSTALL_SH" > "$I/out" 2>&1
  RC=$?
  ORDER_TXT="$(cat "$I/order" 2>/dev/null)"
}

run_install
assert_eq "install.sh: files, then auto.php, then the school year" \
  "upgrade
php auto.php
school-year" "$ORDER_TXT"
assert_eq "install.sh: exits 0" "0" "$RC"

SY_FAILS=1 run_install
assert_eq "install.sh: a failed school-year step doesn't stop the install" "0" "$RC"

echo
if [ "$FAILED" -eq 0 ]; then
  printf "${GREEN}All Gibbon school year checks passed.${NC}\n"
else
  printf "${RED}Gibbon school year checks failed.${NC}\n"
fi
exit "$FAILED"
