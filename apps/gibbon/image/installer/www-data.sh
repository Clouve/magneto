# shellcheck shell=bash
# ============================================================================
# Ending what the site's PHP left running (entrypoint.sh sources this file)
# ============================================================================
# The start runs as root, and runs some of the site's own code as www-data on the way: Gibbon's installer (auto.php,
# which loads config.php), and the chmod of an upgrade's copy and of the cache cleanup. Code of the site's can leave a
# process behind (setsid, a double fork), and such a process could swap a folder of the site for a link at the moment
# root moves, writes or removes files there. So after each of those steps, before root touches files again,
# reap_www_data ends every process of www-data's. Before Apache and cron start, no process of www-data's has any
# business running, so nothing legitimate is stopped. The functions below are the Moodle image's
# installer/www-data.sh, word for word (tests/gibbon-root-paths.test.sh checks it).
# ============================================================================

# _www_data_live UID: the processes, one pid per line, whose real, effective, saved or filesystem uid is UID and that
# still run: a process whose main thread has ended (its status says Z) counts while any other thread of it hasn't. It
# reads /proc, so it needs no tool, and it matches by uid only, never by name. Its status is always 0: a process that
# ends while it reads must not stop a start that runs under set -e.
_www_data_live() {
  local d key a b c e state
  for d in /proc/[0-9]*; do
    state=""
    { while read -r key a b c e; do
        case "$key" in
          State:) state="$a" ;;
          Uid:)
            if [[ " $a $b $c $e " == *" $1 "* ]] && { [[ "$state" != [ZX] ]] || _www_data_threads_run "$d"; }; then
              echo "${d#/proc/}"
            fi
            break
            ;;
        esac
      done < "$d/status"; } 2>/dev/null
  done
  return 0
}

# _www_data_threads_run DIR: status 0 when a thread of the process at DIR (/proc/<pid>) still runs.
_www_data_threads_run() {
  local t key state rest
  for t in "$1"/task/[0-9]*; do
    { while read -r key state rest; do
        if [ "$key" = State: ]; then
          [[ "$state" == [ZX] ]] || return 0
          break
        fi
      done < "$t/status"; } 2>/dev/null
  done
  return 1
}

# reap_www_data STEP: ends every process of www-data's and makes sure none is left. It logs one line, naming STEP and
# the count, when /proc showed any. Only as root, where it matters: without root it does nothing. It belongs to the
# start, before Apache and cron: run in a container that serves, it would end their workers too.
#
# The SIGKILL goes out as kill -1: every process the sender may signal, in one kernel pass that no fork can get past,
# a process whose main thread has ended included. The sender is a process that www-data's processes can't signal,
# trace or read: perl, started by root with an empty environment (env -i, so it holds no password), sets its real uid
# to 65533 (a uid no process here has, which this checks first) and then its effective uid to www-data's, in that same
# process with no exec after, so its saved uid stays root's. A process may signal another only when one of its own
# uids matches the other's real or saved uid, so www-data's processes can't end or stop the sender, while the sender
# reaches every process whose real or saved uid is www-data's, and none of root's. Then /proc is checked, by uid, and
# any process still there gets SIGKILL by pid from root, for at most 5 seconds.
#
# Status 1, with one line that says the start stops, when it can't make sure no process of www-data's is left: the
# uid it borrows is in use, kill -1 couldn't be sent, /proc can't be read, or a process is still there after the 5
# seconds. Every caller then ends the start (`reap_www_data STEP || exit 1`, a statement of its own, never inside
# $( ), a pipeline or an if), so no file step of root's runs while a process of www-data's may.
reap_www_data() {
  local step="$1" uid spare=65533 found left="" i
  [ "$(id -u)" = 0 ] || return 0
  uid="$(id -u www-data 2>/dev/null)" || return 0
  [[ "$uid" =~ ^[1-9][0-9]*$ ]] || return 0
  if [ ! -r /proc/self/status ]; then
    _www_data_stop "$step" "/proc can't be read, so it can't check what www-data has running"
    return 1
  fi
  if [ -n "$(_www_data_live "$spare")" ]; then
    _www_data_stop "$step" "a process runs as uid $spare, which its kill needs unused"
    return 1
  fi
  found="$(_www_data_live "$uid")"
  # shellcheck disable=SC2016  # perl code, for perl
  if ! env -i /usr/bin/perl -e '
      my ($www, $spare) = @ARGV;
      $< = $spare;
      $> = $www;
      open(my $s, "<", "/proc/self/status") or exit 3;
      my ($ids) = grep { /^Uid:/ } <$s>;
      my (undef, $r, $e, $saved) = split(/\s+/, $ids // "");
      exit 3 unless defined($saved) && $r == $spare && $e == $www && $saved != $www;
      kill("KILL", -1);
      exit 0;
    ' -- "$uid" "$spare" 2> /dev/null; then
    _www_data_stop "$step" "its kill to every process of www-data's couldn't be sent"
    return 1
  fi
  for (( i = 0; i < 50; i++ )); do
    left="$(_www_data_live "$uid")"
    [ -n "$left" ] || break
    # shellcheck disable=SC2086  # one pid per word
    kill -KILL $left 2> /dev/null || :
    sleep 0.1
  done
  left="$(_www_data_live "$uid")"
  if [ -n "$found" ]; then
    echo "[clouve-www-data] $step: stopped $(grep -c . <<< "$found") process(es) of www-data's that were still running" >&2
  fi
  if [ -n "$left" ]; then
    _www_data_stop "$step" "$(grep -c . <<< "$left") process(es) of www-data's still running after 5 s"
    return 1
  fi
  return 0
}

# _www_data_stop STEP WHY: the line a reap that can't make sure logs.
_www_data_stop() {
  echo "[clouve-www-data] $1: $2, so the start stops here: root changes no file while a process of www-data's may run" >&2
}
