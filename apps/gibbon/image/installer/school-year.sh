#!/bin/bash

# ============================================================================
# Gibbon school year at first install
# ============================================================================
# Gibbon's gibbon.sql ships its school years with the statuses they had when
# the release was cut. v30.0.01 seeds 2025-2026 as Current and 2026-2027 as
# Upcoming, so a school installed in October 2026 started in last year and
# every enrolment landed there until someone ran the year rollover.
#
# install.sh runs this once, right after Gibbon's installer (auto.php) has
# loaded gibbon.sql. entrypoint.sh only calls install.sh on a fresh volume, so
# a school that is already running never goes through it, not even after an
# image upgrade.
#
# From the install date (today in GIBBON_TIMEZONE, the timezone auto.php gives
# Gibbon, unless a YYYY-MM-DD argument is passed):
#   - the year that contains the date is Current, earlier years Past, later
#     years Upcoming;
#   - between two years (after one's lastDay, before the next one's firstDay)
#     the coming year is Current;
#   - past every seeded year, the missing years are added: named YYYY-YYYY,
#     with the last seeded year's dates moved on by whole years and the
#     sequenceNumber continuing;
#   - one Upcoming year always follows Current, because Gibbon's rollover
#     moves the school into the next year and won't start without one.
# Terms are left alone. A year added here has none; the school sets its own.
#
# Usage: school-year.sh [YYYY-MM-DD]
#   Needs DB_HOST, DB_USER, DB_PASSWORD and DB_NAME. Sourcing this file only
#   defines the functions (tests/gibbon-school-year.test.sh does).
# ============================================================================

# _sy_valid_date DATE: true for a YYYY-MM-DD date.
_sy_valid_date() {
  [[ "$1" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]
}

# _sy_daynum DATE: the date as the number YYYYMMDD, for comparing dates.
_sy_daynum() {
  local d="${1//-/}"
  echo "$((10#$d))"
}

# _sy_shift DATE YEARS: the same day YEARS later. 29 February becomes the
# 28th in a year that has no 29th.
_sy_shift() {
  local y=$((10#${1:0:4} + $2)) md="${1:5}"
  if [[ "$md" == 02-29 ]] && (( y % 4 != 0 || (y % 100 == 0 && y % 400 != 0) )); then
    md=02-28
  fi
  printf '%04d-%s\n' "$y" "$md"
}

# school_year_plan DATE: reads the school years on stdin, one per line, tab
# separated the way `mysql -N -B` prints them:
#   gibbonSchoolYearID  name  status  sequenceNumber  firstDay  lastDay
# and prints them in sequenceNumber order with the status each one should
# have on DATE, followed by any years to add (id "new"). Prints nothing and
# returns 1 when DATE or a row isn't what it expects.
school_year_plan() {
  local today="${1:-}"
  if ! _sy_valid_date "$today"; then
    echo "school-year: '$today' is not a YYYY-MM-DD date" >&2
    return 1
  fi

  local -a ids=() names=() seqs=() firsts=() lasts=()
  local rows id name status seq first last
  rows="$(LC_ALL=C sort -t $'\t' -k4,4n)"
  while IFS=$'\t' read -r id name status seq first last; do
    [[ -z "$id$name$status$seq$first$last" ]] && continue
    if [[ ! "$id" =~ ^[0-9]+$ || -z "$name" || ! "$status" =~ ^(Past|Current|Upcoming)$ \
          || ! "$seq" =~ ^[0-9]+$ ]] || ! _sy_valid_date "$first" || ! _sy_valid_date "$last"; then
      echo "school-year: unexpected school year row: $id $name $status $seq $first $last" >&2
      return 1
    fi
    ids+=("$id"); names+=("$name"); seqs+=("$((10#$seq))"); firsts+=("$first"); lasts+=("$last")
  done <<< "$rows"
  if (( ${#ids[@]} == 0 )); then
    echo "school-year: no school years found" >&2
    return 1
  fi

  # Current is the first year that hasn't ended by the install date: the one
  # that contains it or, in the gap between two years, the coming one.
  local t cur=-1 i
  t="$(_sy_daynum "$today")"
  for ((i = 0; i < ${#ids[@]}; i++)); do
    if (( $(_sy_daynum "${lasts[i]}") >= t )); then cur=$i; break; fi
  done

  # Add the last seeded year moved on by 1, 2, ... years until one hasn't
  # ended by the install date, then one more so that a year follows Current.
  local base=$((${#ids[@]} - 1)) k=0
  while (( cur < 0 || cur == ${#ids[@]} - 1 )); do
    k=$((k + 1))
    first="$(_sy_shift "${firsts[base]}" "$k")"
    last="$(_sy_shift "${lasts[base]}" "$k")"
    ids+=(new); names+=("${first:0:4}-${last:0:4}"); seqs+=("$((seqs[base] + k))")
    firsts+=("$first"); lasts+=("$last")
    if (( cur < 0 )) && (( $(_sy_daynum "$last") >= t )); then cur=$((${#ids[@]} - 1)); fi
  done

  for ((i = 0; i < ${#ids[@]}; i++)); do
    if (( i < cur )); then status=Past; elif (( i == cur )); then status=Current; else status=Upcoming; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${ids[i]}" "${names[i]}" "$status" "${seqs[i]}" "${firsts[i]}" "${lasts[i]}"
  done
}

# school_year_sql: reads school_year_plan's output on stdin and prints the SQL
# that applies it, as one transaction.
school_year_sql() {
  local id name status seq first last
  echo "START TRANSACTION;"
  while IFS=$'\t' read -r id name status seq first last; do
    [[ -z "$id" ]] && continue
    if [[ "$id" == new ]]; then
      echo "INSERT INTO gibbonSchoolYear (name, status, sequenceNumber, firstDay, lastDay) VALUES ('$name', '$status', $seq, '$first', '$last');"
    else
      echo "UPDATE gibbonSchoolYear SET status='$status' WHERE gibbonSchoolYearID=$((10#$id));"
    fi
  done
  echo "COMMIT;"
}

main() {
  local today="${1:-$(TZ="${GIBBON_TIMEZONE:-America/Los_Angeles}" date +%F)}"
  local rows plan
  export MYSQL_PWD="${DB_PASSWORD:-}"
  local -a db=(mysql --skip-ssl -h "${DB_HOST:-}" -u "${DB_USER:-}" "${DB_NAME:-}")

  rows="$("${db[@]}" -N -B -e "SELECT gibbonSchoolYearID, name, status, sequenceNumber, firstDay, lastDay FROM gibbonSchoolYear ORDER BY sequenceNumber")" || return 1
  plan="$(school_year_plan "$today" <<< "$rows")" || return 1

  echo "Install date: $today"
  echo "School years as Gibbon ships them:"
  sed 's/^/  /; s/\t/  /g' <<< "$rows"
  echo "School years from the install date:"
  sed 's/^/  /; s/\t/  /g' <<< "$plan"
  school_year_sql <<< "$plan" | "${db[@]}" || return 1
  echo "✓ School years set"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
