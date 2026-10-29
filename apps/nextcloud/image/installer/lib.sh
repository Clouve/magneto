#!/bin/bash
# Shared shell functions for the Nextcloud image: logging, the admin-name
# cleanup, URL parsing, memory sizing, the trusted_domains merge, running occ
# and reading its status, the steps after an upgrade and after the first
# install with the markers that record them, the markers of the AI Assistant's
# backups and restores, and the repair of the database settings in config.php,
# with the sweep of what a killed run leaves behind.
#
# Source this file, don't run it. It only defines functions and changes no
# shell options, so it behaves the same under `set -eu` and without it. Every
# function prints its result on stdout, and prints nothing when it has none.
# Warnings go to stderr, through nc_warn. Every function returns 0 except
# nc_missing_trusted_domains (1 when it can't read its JSON), nc_occ (the exit
# status of occ itself), nc_repair_db_config (0 when it changed config.php,
# 1 when there was nothing to change, 2 when it could not), nc_status_json and
# nc_status_version (1 when there is no answer), nc_clouve_marker (1 when the
# marker is not set, 2 when occ failed), nc_marker_trusted (a test: 0 when a
# marker can be the AI Assistant's, 1 when not), nc_restore_cut_off (a
# test: 0 when a restore was cut off, 1 when not), nc_hold_upgrade_for_restore
# (a test: 0 when a cut-off restore holds back an upgrade to this image),
# nc_claim_new_volume (1 when a new disk's top folder could not be given to
# www-data) and nc_make_init_lock (1 when the init lock file could not be made).
#
# The functions that run occ (nc_occ, nc_try_occ, nc_post_upgrade_steps,
# nc_first_install_steps) pass occ's own stdout and stderr through as they are.
# A try-occ helper prints occ's output and goes on whatever occ does: nc_try_occ,
# and the two step functions through it, add one warning when occ fails, and
# their status is still 0. The functions that read an answer from occ
# (nc_status_json, nc_clouve_marker) keep its stdout and print only the answer.
#
# PHP does the parts the shell can't: HTML entities, transliteration (the intl
# extension), JSON, and the edit of config.php. Each snippet gets its text from
# an environment variable or from argv after "--", never by pasting it into the
# code, so a name like O'Brien or $HOME stays data. PHP runs with
# display_errors=stderr because this image's default writes PHP errors and
# startup warnings to stdout, where a caller that captures stdout would take
# them for the result. The edit of config.php runs with display_errors=0
# instead: a PHP message about config.php can quote what is in it.
#
# tests/nextcloud-image.test.sh covers each function.

# nc_log MSG...: "[nextcloud] MSG" on stdout.
nc_log() {
    local IFS=' '
    printf '[nextcloud] %s\n' "$*"
}

# nc_warn MSG...: "[nextcloud] WARNING: MSG" on stderr.
nc_warn() {
    local IFS=' '
    printf '[nextcloud] WARNING: %s\n' "$*" >&2
}

# _nc_php CODE [ARG...]: runs the PHP program CODE with ARG... in $argv. The "--"
# keeps php from reading an argument such as --version as one of its own options.
_nc_php() {
    local code=$1
    shift
    php -d display_errors=stderr -r "$code" -- "$@"
}

# _nc_is_mb VALUE: succeeds when VALUE is a plain number of MB. That means digits
# only, and few enough of them that the shell's arithmetic can't wrap around
# (it does so silently from 19 digits, and it would run code in a value like
# a[$(cmd)]).
_nc_is_mb() {
    case $1 in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 15 ]
}

# nc_decode_entities STRING: html_entity_decode(STRING, ENT_QUOTES | ENT_HTML5, 'UTF-8').
# The platform delivers O'Brien as O&apos;Brien. If php fails, the string comes
# back as it was, with a warning, so a decoding problem never stops a boot.
nc_decode_entities() {
    local in=${1-} out
    case $in in
        *'&'*) ;;                                   # only an & can start an entity
        *) printf '%s\n' "$in"; return 0 ;;
    esac
    local -x NC_PHP_IN=$in
    if out=$(_nc_php 'echo html_entity_decode((string) getenv("NC_PHP_IN"), ENT_QUOTES | ENT_HTML5, "UTF-8");'); then
        printf '%s\n' "$out"
    else
        nc_warn 'could not decode HTML entities, so the text is used as it is'
        printf '%s\n' "$in"
    fi
}

# nc_clean_admin_user RAW: a login Nextcloud accepts and occ takes as the value
# of --admin-user. The first install must never fail on the name, so whatever
# goes wrong, the answer is a valid login ("admin" at worst), and the function
# returns 0.
#
#   1. {user. or [user. in RAW means the platform left the template unfilled: admin.
#   2. Decode HTML entities (nc_decode_entities).
#   3. Transliterate with Any-Latin; Latin-ASCII.
#   4. Replace each character outside [A-Za-z0-9 _.@'-] with _.
#   5. Collapse each run of spaces and underscores that has an underscore in it
#      into one _, and trim spaces and _ at both ends.
#   6. Remove a leading null_ or undefined_ and a trailing _null or _undefined
#      (any case), and treat a whole null or undefined as empty.
#   7. Cut to 64 characters and trim the end again.
#   8. Empty, ".", ".." and the names Nextcloud refuses (its verifyUid list)
#      become admin.
#
# The trims in steps 5 to 7 also remove hyphens at the start of the name. The
# official entrypoint runs `occ maintenance:install --admin-user "$NAME"`, and
# occ reads a value that starts with a hyphen as the next option and stops with
# "The --admin-user option requires a value", though Nextcloud accepts such a
# login.
nc_clean_admin_user() {
    local raw=${1-} decoded cleaned code
    local allowed="A-Za-z0-9 _.@'-"

    case $raw in
        *'{user.'* | *'[user.'*) printf 'admin\n'; return 0 ;;
    esac

    decoded=$(nc_decode_entities "$raw")

    IFS= read -r -d '' code <<'PHP' || :
$s = (string) getenv('NC_PHP_IN');

// 3. Transliterate to ASCII. What ICU can't convert (symbols, emoji, bytes that
//    aren't UTF-8) stays as it is, and step 4 replaces it.
if (class_exists('Transliterator')) {
    $t = Transliterator::create('Any-Latin; Latin-ASCII');
    $r = $t === null ? false : $t->transliterate($s);
    if ($r !== false) {
        $s = $r;
    }
}

// preg_replace gives null when it fails; that becomes an empty name, not a warning.
$sub = fn (string $re, string $to, string $v): string => (string) preg_replace($re, $to, $v);
// No space or underscore at either end, and no hyphen at the start.
$trim = fn (string $v): string => rtrim(ltrim($v, ' _-'), ' _');

// 4. Anything Nextcloud doesn't allow in a login becomes an underscore.
$s = $sub('/[^A-Za-z0-9 _.@\x27-]/', '_', $s);
// 5. A run of spaces and underscores that has an underscore in it becomes one.
$s = $trim($sub('/[ _]*_[ _]*/', '_', $s));
// 6. The null or undefined that an empty first or last name leaves behind.
$s = $trim($sub('/^(?:null|undefined)_|_(?:null|undefined)$/i', '', $s));
if (preg_match('/^(?:null|undefined)$/i', $s) === 1) {
    $s = '';
}
// 7. At most 64 characters, which is Nextcloud's limit.
$s = $trim(substr($s, 0, 64));
// 8. Nothing at all, or a name Nextcloud refuses, becomes admin.
$refused = ['.', '..', '.htaccess', 'files_external', '__groupfolders', '.ncdata',
            'owncloud.log', 'nextcloud.log', 'updater.log', 'audit.log'];
echo ($s === '' || in_array($s, $refused, true)) ? 'admin' : $s;
PHP

    local -x NC_PHP_IN=$decoded
    if cleaned=$(_nc_php "$code"); then
        # php has to have printed a login. Anything else means it failed, and the login is admin.
        # shellcheck disable=SC2254  # $allowed is a bracket expression, not a literal
        case $cleaned in
            '' | *[!$allowed]*) ;;
            *)
                if [ "${#cleaned}" -le 64 ]; then
                    printf '%s\n' "$cleaned"
                    return 0
                fi
                ;;
        esac
    fi
    nc_warn 'could not clean the admin name, so the login is admin'
    printf 'admin\n'
}

# nc_url_scheme URL: https or http in lower case, nothing for any other URL.
nc_url_scheme() {
    local url=${1-}
    case ${url,,} in
        https://*) printf 'https\n' ;;
        http://*) printf 'http\n' ;;
    esac
}

# nc_url_host URL: the host of a scheme://... URL in lower case, without user
# name, password, port, path, query or fragment. An IPv6 address keeps its
# brackets, the way a Host header (and trusted_domains) has it. Nothing when
# the URL has no scheme:// or no host.
nc_url_host() {
    local url=${1-} rest
    case $url in
        [A-Za-z]*://*) ;;
        *) return 0 ;;
    esac
    rest=${url#*://}
    rest=${rest%%[/?#]*}                             # the authority: what comes before any path, query or fragment
    rest=${rest##*@}                                 # without user:password@
    case $rest in
        '['*']'*) rest=${rest%%]*}']' ;;             # [::1]:8080 -> [::1]
        *) rest=${rest%%:*} ;;                       # host:8080 -> host
    esac
    rest=${rest,,}
    if [ -n "$rest" ]; then
        printf '%s\n' "$rest"
    fi
}

# nc_memory_limit_mb: the container's memory limit in MB (rounded down), or
# nothing when it has none. cgroup v2 keeps the limit in memory.max, where "max"
# means none. cgroup v1 keeps it in memory/memory.limit_in_bytes, where 2^60 or
# more means none (the kernel reports 9223372036854771712). The v1 file is read
# only when the v2 file doesn't exist. A file that holds anything but digits (a
# negative number, junk, nothing), a number too big for the shell, and a file
# that can't be read all mean no limit, and none of them stops the caller.
#
# This is the same reading as the database image's entrypoint wrapper.
# NC_CGROUP_ROOT is for tests/nextcloud-image.test.sh, which points it at
# made-up cgroup trees. Nothing sets it in a deployment.
nc_memory_limit_mb() {
    local root=${NC_CGROUP_ROOT:-/sys/fs/cgroup} file value unlimited=1152921504606846976    # 2^60
    if [ -r "$root/memory.max" ]; then
        file=$root/memory.max
    elif [ -r "$root/memory/memory.limit_in_bytes" ]; then
        file=$root/memory/memory.limit_in_bytes
    else
        return 0
    fi
    value=$(cat "$file" 2>/dev/null) || return 0
    case $value in
        '' | *[!0-9]*) return 0 ;;                   # "max", or anything else that isn't a number
    esac
    # [ also fails on a number too big for the shell's integers, and that is no limit too.
    if ! [ "$value" -lt "$unlimited" ] 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$((10#$value / 1048576))"
}

# nc_apache_workers MEM_MB: MaxRequestWorkers for the memory limit, 50 MB each,
# at least 10 and at most 150. No limit (empty) gives 150. A value that isn't a
# plain number of MB gives 150 as well, with a warning.
nc_apache_workers() {
    local mem=${1-} workers
    if [ -z "$mem" ]; then
        printf '150\n'
        return 0
    fi
    if ! _nc_is_mb "$mem"; then
        nc_warn "memory size '$mem' is not a number of MB, so Apache gets the no-limit default of 150 workers"
        printf '150\n'
        return 0
    fi
    workers=$((10#$mem / 50))
    if [ "$workers" -lt 10 ]; then workers=10; fi
    if [ "$workers" -gt 150 ]; then workers=150; fi
    printf '%s\n' "$workers"
}

# nc_preview_concurrency MEM_MB: "NEW ALL", the values for preview_concurrency_new
# and preview_concurrency_all. Below 1536 MB it is "1 2", below 3584 MB "2 4",
# and from there up "4 8". No limit (empty) gives "4 8". A value that isn't a
# plain number of MB gives "4 8" as well, with a warning.
nc_preview_concurrency() {
    local mem=${1-}
    if [ -z "$mem" ]; then
        printf '4 8\n'
        return 0
    fi
    if ! _nc_is_mb "$mem"; then
        nc_warn "memory size '$mem' is not a number of MB, so previews get the no-limit default of 4 8"
        printf '4 8\n'
        return 0
    fi
    mem=$((10#$mem))
    if [ "$mem" -lt 1536 ]; then
        printf '1 2\n'
    elif [ "$mem" -lt 3584 ]; then
        printf '2 4\n'
    else
        printf '4 8\n'
    fi
}

# nc_missing_trusted_domains JSON HOST...: each HOST that is not among the values
# of JSON, one per line, in the order given and each once. JSON is what
# `occ config:system:get trusted_domains --output=json` prints: an array, or an
# object when the indexes have gaps. Empty JSON means no entries. Names are
# compared without regard to case, and a HOST is printed as it was given. Only
# string entries count, which is how Nextcloud reads the list. An empty HOST is
# skipped. When JSON can't be read (or php fails) nothing is printed and the
# return status is 1, so a caller that adds the hosts it is given never writes
# over entries it couldn't see.
nc_missing_trusted_domains() {
    local json=${1-} code out rc=0
    if [ "$#" -gt 0 ]; then shift; fi
    local -x NC_PHP_JSON=$json

    IFS= read -r -d '' code <<'PHP' || :
$have = [];
$json = (string) getenv('NC_PHP_JSON');
if (trim($json) !== '') {
    $list = json_decode($json, true);
    if (json_last_error() !== JSON_ERROR_NONE) {
        exit(1);
    }
    foreach ((array) $list as $entry) {
        if (is_string($entry)) {
            $have[strtolower($entry)] = true;
        }
    }
}
$printed = [];
foreach (array_slice($argv, 1) as $host) {
    $key = strtolower($host);
    if ($host === '' || isset($have[$key]) || isset($printed[$key])) {
        continue;
    }
    $printed[$key] = true;
    echo $host, "\n";
}
PHP

    out=$(_nc_php "$code" "$@") || rc=$?
    if [ "$rc" -ne 0 ]; then
        nc_warn 'could not read trusted_domains as JSON, so it is left as it is'
        return 1
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
    fi
}

# nc_first_lines TEXT: the first two non-blank lines of TEXT, joined by " / " and
# each cut to 300 characters. For quoting what occ printed, which can be a whole
# stack trace. It prints nothing when TEXT has no such line.
nc_first_lines() {
    local line n=0 out=''
    while [ "$n" -lt 2 ] && IFS= read -r line; do
        case $line in
            *[![:space:]]*)
                out=${out:+$out / }${line:0:300}
                n=$((n + 1))
                ;;
        esac
    done <<<"${1-}"
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
    fi
}

# nc_occ ARGS...: runs occ with ARGS. The command is $OCC, or "php
# /var/www/html/occ" when that is empty or unset, split at white space. What occ
# prints and its exit status come back as they are. Two callers set OCC: the
# tests, to a fake occ, and the root entrypoint, which runs as root, to
# "runuser -u www-data -- php /var/www/html/occ" for its step 7 only. The hooks
# and nextcloud-config.sh run as www-data and never get it.
nc_occ() {
    local IFS=$' \t\n'
    local -a cmd
    read -r -a cmd <<<"${OCC:-php /var/www/html/occ}"
    "${cmd[@]}" "$@"
}

# nc_try_occ ARGS...: runs occ with ARGS and goes on whatever happens. occ's output
# and errors come through as they are. A failure adds one warning that names the
# command and its first argument (an app, a key, a user name) and nothing after
# that, so no value reaches it. The status is always 0.
nc_try_occ() {
    local rc=0 label=${1-}
    nc_occ "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        case ${2-} in '' | -*) ;; *) label="$label $2" ;; esac
        nc_warn "occ $label failed (exit status $rc)"
    fi
    return 0
}

# nc_json_line TEXT: the last line of TEXT that starts with "{", which is where
# occ puts its answer to --output=json. PHP notices can come before it and after
# it. It prints nothing when there is no such line.
nc_json_line() {
    local line json=''
    while IFS= read -r line; do
        case $line in '{'*) json=$line ;; esac
    done <<<"${1-}"
    if [ -n "$json" ]; then
        printf '%s\n' "$json"
    fi
}

# nc_status_json: runs `occ status --output=json --no-warnings` and prints its
# JSON line. Status 1, with nothing printed, when occ fails or prints no JSON.
# occ's stderr comes through.
nc_status_json() {
    local out json rc=0
    out=$(nc_occ status --output=json --no-warnings) || rc=$?
    json=$(nc_json_line "$out")
    if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
        return 1
    fi
    printf '%s\n' "$json"
}

# nc_status_version JSON: the version in a line of status JSON (its "version",
# such as 35.0.2.2). occ reads it from the code, so once no upgrade is pending
# it is the installed version as well. Status 1, with nothing printed, when JSON
# has no version made of digits and dots.
nc_status_version() {
    local v
    case ${1-} in
        *'"version":"'*) ;;
        *) return 1 ;;
    esac
    v=${1#*'"version":"'}
    v=${v%%'"'*}
    case $v in
        '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
    esac
    printf '%s\n' "$v"
}

# _nc_status_maintenance JSON: on or off, as a line of status JSON says, and
# unknown when it says neither.
_nc_status_maintenance() {
    case ${1-} in
        *'"maintenance":true'*) printf 'on\n' ;;
        *'"maintenance":false'*) printf 'off\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# nc_clouve_marker KEY: the value of the app config marker clouve KEY
# (first_install_done or post_upgrade_done). Status 0 with the value printed when
# it is set, 1 with nothing printed when it is not, and 2 when occ failed.
#
# It reads with an empty --default-value, so a marker that is not set is an
# answer: exit 0 and an empty line. Without one, occ exits 1 and prints nothing,
# and a read that failed can look the same. occ that can't start prints its
# error on stdout and exits 1, and a command that fails on the way prints its
# error on stderr and exits with the exception's code, which can be 1 as well.
# The value is the last line of stdout, since PHP notices can come before it.
# stderr is dropped: in maintenance mode occ writes a notice there at every call.
nc_clouve_marker() {
    local out line value='' rc=0
    out=$(nc_occ config:app:get clouve "${1-}" --default-value= --no-warnings 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
        return 2
    fi
    while IFS= read -r line; do
        value=$line
    done <<<"$out"
    if [ -z "$value" ]; then
        return 1
    fi
    printf '%s\n' "$value"
}

# _nc_repair_step BEFORE: occ maintenance:repair --include-expensive, as a step:
# its output comes through, and a failure is a warning. BEFORE is maintenance
# mode as the repair begins: on, off or unknown.
#
# occ turns maintenance mode on for the whole repair and puts back the value it
# found only when it gets to the end (core/Command/Maintenance/Repair.php). A
# repair that dies on the way leaves maintenance mode on, with nothing pending
# that a later start would finish: an app's repair step that throws an Error,
# which occ doesn't catch, does that. (A kill does it too, and the next start
# finds that through the markers.) So when BEFORE is off and a failed repair has
# left maintenance mode on, it goes off again, with a warning. A repair that
# reached its end and failed there, because one of its steps reported an error,
# has put the value back already.
#
# Status 1 when maintenance mode is still on after that, or can't be read: the
# caller then writes no marker, so the next start runs the steps again.
# Otherwise 0.
_nc_repair_step() {
    local before=${1-} rc=0 now
    nc_occ maintenance:repair --include-expensive || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    nc_warn "occ maintenance:repair failed (exit status $rc)"
    if [ "$before" != off ]; then
        return 0
    fi
    if ! now=$(nc_occ config:system:get maintenance --default-value=false --no-warnings 2>/dev/null); then
        nc_warn 'maintenance mode could not be read after the repair failed, so the steps are not recorded as done, and the next start runs them again'
        return 1
    fi
    case $now in
        *true) ;;
        *) return 0 ;;
    esac
    if nc_occ maintenance:mode --off; then
        nc_warn 'occ maintenance:repair stopped before its end and left maintenance mode on, so it was turned off again'
        return 0
    fi
    nc_warn 'occ maintenance:repair stopped before its end and left maintenance mode on, and it could not be turned off, so the steps are not recorded as done, and the next start tries again'
    return 1
}

# _nc_write_post_upgrade_marker VERSION: sets the marker clouve post_upgrade_done
# to VERSION (lazy, since only the start reads it). Status 0 when it did.
# Otherwise a warning says that the next start runs the post-upgrade steps
# again, and the status is 1.
_nc_write_post_upgrade_marker() {
    local version=${1-} rc=0
    if [ -z "$version" ]; then
        nc_warn 'occ status gave no version, so the post-upgrade steps are not recorded as done, and the next start runs them again'
        return 1
    fi
    nc_occ config:app:set clouve post_upgrade_done --lazy --value="$version" || rc=$?
    if [ "$rc" -ne 0 ]; then
        nc_warn "could not record that the post-upgrade steps are done (occ config:app:set clouve post_upgrade_done, exit status $rc), so the next start runs them again"
        return 1
    fi
    return 0
}

# nc_post_upgrade_steps: what Nextcloud needs after an upgrade and `occ upgrade`
# leaves for later: the indexes, columns and primary keys the new version expects,
# then the repairs that are too slow for `occ upgrade` itself. Each step goes
# through nc_try_occ (the repair through _nc_repair_step), so a failure is a
# warning and the next step still runs. The status is always 0. The official
# entrypoint runs these through the post-upgrade hook after an upgrade of its own,
# and the before-starting hook runs them after the upgrade it finishes, and again
# at a later start when a start was cut off during them.
#
# The marker clouve post_upgrade_done holds the version whose post-upgrade steps
# last ran to the end. The steps delete it first and write it last, whatever
# each step did, so a run that was cut off always leaves it missing. When it
# can't be deleted, the steps don't run at all: a run cut off after that would
# leave the old version behind, which says "never began", not "cut off". The
# before-starting hook runs them again when the marker is missing (a cut-off
# run) or names another version (they never began for this one). The repair
# turns maintenance mode on while it runs, so a run cut off there leaves
# maintenance mode on as well.
#
# When maintenance mode is on as the steps begin and the marker is missing, the
# start before was cut off during these steps (or during the first install's)
# and left maintenance mode on. That happens here when the official entrypoint
# upgrades at the next start: occ upgrade keeps a maintenance mode that it finds
# on, and these steps would end with it still on and the marker written. So it
# goes off first, unless a restore was cut off. If it can't be turned off, the
# steps run but write no marker, so a later start tries again. A marker that is
# there, for any version, means that maintenance mode was turned on some other
# way, maybe on purpose, so it stays on.
nc_post_upgrade_steps() {
    local json version='' before=unknown st=0 write=yes
    if json=$(nc_status_json); then
        version=$(nc_status_version "$json") || version=''
        before=$(_nc_status_maintenance "$json")
    fi
    if [ "$before" = on ] && ! nc_restore_cut_off; then
        nc_clouve_marker post_upgrade_done >/dev/null || st=$?
        if [ "$st" -eq 1 ]; then
            nc_log "Maintenance mode is on, and the marker clouve post_upgrade_done is missing: an earlier start was cut off during these steps or the first install's, and occ maintenance:repair leaves maintenance mode on when it is cut off. Turning it off first."
            if nc_occ maintenance:mode --off; then
                before=off
            else
                write=no
                nc_warn 'could not turn maintenance mode off before the steps after the upgrade, so they run but write no marker, and a later start tries again'
            fi
        fi
    fi
    if ! nc_occ config:app:delete clouve post_upgrade_done >/dev/null; then
        nc_warn 'could not delete the marker clouve post_upgrade_done, so the steps after the upgrade do not run (a run cut off now would leave the old version behind), and the next start tries again'
        return 0
    fi
    nc_try_occ db:add-missing-indices
    nc_try_occ db:add-missing-columns
    nc_try_occ db:add-missing-primary-keys
    if _nc_repair_step "$before" && [ "$write" = yes ] && _nc_write_post_upgrade_marker "$version"; then
        nc_log "post-upgrade steps done for $version (the app config value clouve post_upgrade_done records the version)"
    fi
    return 0
}

# _nc_app_occ SECONDS COMMAND APP: occ COMMAND APP (app:install or app:enable) within SECONDS, and killed 10 s later if
# it is still running. Run from occ, Nextcloud gives an app's release download no time limit (lib/private/Installer.php
# passes timeout 0 on the command line), so a download host that stalls would hold the start, the init lock and the
# ingress's 502 window open for good. occ downloads to a temporary file and checks the signature before it moves the app
# into place, so stopping it during the download leaves no half-copied app behind. nc_occ splits $OCC at white space,
# so timeout in front of it runs occ itself. Like nc_try_occ, it passes occ's output through, warns when occ fails, and
# returns 0. timeout exits 124 when its SIGTERM ended occ and 137 when its SIGKILL did. An occ killed for another reason,
# such as the memory limit, can also give 137, so the time taken tells them apart.
_nc_app_occ() {
    local limit=$1 rc=0 start=$SECONDS
    OCC="timeout -k 10 $limit ${OCC:-php /var/www/html/occ}" nc_occ "$2" "$3" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; } && [ $((SECONDS - start)) -ge "$limit" ]; then
        nc_warn "occ $2 $3 did not finish within $limit s and was stopped. The start goes on without $3, and the AI Assistant can add it later."
    else
        nc_warn "occ $2 $3 failed (exit status $rc)"
    fi
    return 0
}

# nc_first_install_steps: the settings a fresh install needs once nextcloud-config.sh has run, then the markers that say
# they are done. The post-installation hook runs them once, inside the official entrypoint's init lock. The
# before-starting hook runs them again, under the same lock, when an installed Nextcloud has no first-install marker: a
# container killed during the post-installation hook never gets that hook again, because the next start finds
# Nextcloud installed. A kill during the repair in step 2 also leaves maintenance mode on, so that hook turns it off
# before it runs them. Every step is safe to run twice. It reads occ status first, for the version that goes in a
# marker and for maintenance mode as the repair begins.
#
#   1. The admin's email (NEXTCLOUD_ADMIN_EMAIL, when it has an @, for NEXTCLOUD_ADMIN_USER), so email sign-in works.
#   2. Background jobs by cron, the nightly window for heavy jobs (01:00 to 06:00 UTC) and the expensive repairs.
#   3. Trash kept at most 30 days and file versions at most 365.
#   4. AppAPI off (Clouve can't run external apps), no new local external storage, shares of disabled users hidden,
#      the update checker off (the version comes from the image) and serverid 1.
#   5. Calendar, Contacts and Team folders from the app store, each within NC_APP_INSTALL_TIMEOUT seconds (300 when it
#      is not a positive whole number; it is for tests/nextcloud-image.test.sh, and nothing sets it in a deployment).
#      app:install says "already installed" for an app that an earlier install left in custom_apps/, and leaves it
#      disabled, so app:enable follows. It runs only for an app that app:getpath finds (the same lookup as
#      app:install's "already installed" check). For any other app it would download the app again: a second warning
#      for the same app, and after a failed release download a second try of it. Nextcloud keeps a failed fetch of
#      the store's app list for 5 minutes, but no record of a failed release download.
#   6. The markers. First clouve post_upgrade_done, set to the version (a fresh install needs none of the steps after
#      an upgrade, and the repair in step 2 is theirs too). Then clouve first_install_done, set to the UTC time. Both are
#      lazy app config values, since only the start reads them. They go in once the steps have run to the end, whatever
#      each of them did. A step that failed has warned, and an app store that can't be reached must not make every later
#      start try the downloads again. The one exception is a repair that stopped on the way and left maintenance mode
#      on where it could not be turned off (_nc_repair_step): then neither marker goes in, and the next start turns
#      maintenance mode off and runs the steps again.
#
# Each step goes through nc_try_occ or _nc_app_occ (the repair through _nc_repair_step), so a failure is a warning and
# the next step runs. The status is always 0. No step puts a password on a command line.
nc_first_install_steps() {
    local app app_timeout=${NC_APP_INSTALL_TIMEOUT:-300} rc=0 now json version='' before=unknown repaired=yes
    case $app_timeout in
        '' | *[!0-9]* | 0*) app_timeout=300 ;;
    esac

    if json=$(nc_status_json); then
        version=$(nc_status_version "$json") || version=''
        before=$(_nc_status_maintenance "$json")
    fi

    case ${NEXTCLOUD_ADMIN_EMAIL-} in
        *@*)
            if [ -n "${NEXTCLOUD_ADMIN_USER-}" ]; then
                nc_try_occ user:setting "$NEXTCLOUD_ADMIN_USER" settings email "$NEXTCLOUD_ADMIN_EMAIL"
            fi
            ;;
    esac

    nc_try_occ background:cron
    nc_try_occ config:system:set maintenance_window_start --type=integer --value=1
    _nc_repair_step "$before" || repaired=no
    nc_try_occ config:system:set trashbin_retention_obligation --value="auto, 30"
    nc_try_occ config:system:set versions_retention_obligation --value="auto, 365"
    nc_try_occ app:disable app_api
    nc_try_occ config:system:set files_external_allow_create_new_local --type=boolean --value=false
    nc_try_occ config:app:set files_sharing hide_disabled_user_shares --value=yes
    nc_try_occ config:system:set updatechecker --type=boolean --value=false
    nc_try_occ config:system:set serverid --type=integer --value=1

    for app in calendar contacts groupfolders; do
        _nc_app_occ "$app_timeout" app:install "$app"
        if nc_occ app:getpath "$app" >/dev/null 2>&1; then
            _nc_app_occ "$app_timeout" app:enable "$app"
        fi
    done

    if [ "$repaired" = no ]; then
        nc_warn 'the first-install settings are not recorded as done, because maintenance mode is still on after the repair, so the next start runs them again'
        return 0
    fi
    _nc_write_post_upgrade_marker "$version" || :
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    nc_occ config:app:set clouve first_install_done --lazy --value="$now" || rc=$?
    if [ "$rc" -eq 0 ]; then
        nc_log 'first-install settings done (the app config value clouve first_install_done records when)'
    else
        nc_warn "could not record that the first-install settings are done (occ config:app:set clouve first_install_done, exit status $rc), so the next start runs them again"
    fi
    return 0
}

# nc_marker_path NAME: where a marker file is. The paths are written here and nowhere else.
#   restore       data/clouve-backups/RESTORE-IN-PROGRESS in Nextcloud's data folder. The AI Assistant's restore.sh writes
#                 it, with the backup's name, before it changes anything, and removes it once it has finished. So it is
#                 only there when a restore was cut off or failed half way, and then the start must not open Nextcloud
#                 up: no upgrade (not even to a newer image, nc_hold_upgrade_for_restore), and maintenance mode stays
#                 as it is. The start itself goes on, so the AI Assistant can reach the container.
#   backup        data/clouve-backups/BACKUP-IN-PROGRESS. The AI Assistant's backup.sh writes it, with the backup's name
#                 on its first line, just before it turns maintenance mode on, and removes it just after it turns
#                 maintenance mode off again. It holds an exclusive flock on the file for that whole time. When it
#                 leaves maintenance mode alone (--no-maintenance, or maintenance mode already on), it writes none. So
#                 at a start, a marker that nobody holds a lock on means that a backup died with the old container and
#                 left maintenance mode on. One that is locked belongs to a backup that is still running.
#   restore-note  /run/clouve/restore-cut-off. The root entrypoint writes it at every start when the restore marker is
#                 there and removes it when it is not. The skill's scripts keep clouve-backups root's alone (mode 700),
#                 so www-data, which runs the hooks, can't see the restore marker itself.
nc_marker_path() {
    case ${1-} in
        restore) printf '%s\n' /var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS ;;
        backup) printf '%s\n' /var/www/html/data/clouve-backups/BACKUP-IN-PROGRESS ;;
        restore-note) printf '%s\n' /run/clouve/restore-cut-off ;;
    esac
}

# nc_marker_trusted FILE: succeeds when FILE can be a marker that the AI Assistant's scripts made: a plain file (not a
# symlink) that root owns, in a folder (not a symlink) that root owns and that neither its group nor others can write
# to. The scripts make exactly that (clouve-backups mode 700, the markers mode 600, both root's). www-data owns the data
# folder, so it can make a clouve-backups of its own before any backup has, or put a symlink there. A marker that fails
# this test may be www-data's, and nothing trusts it: not to stop the start's upgrade and maintenance handling, and not
# to be read by root.
nc_marker_trusted() {
    local file=${1-} dir mode
    dir=${file%/*}
    [ -f "$file" ] && [ ! -L "$file" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(stat -c %u -- "$file" 2>/dev/null)" = 0 ] && [ "$(stat -c %u -- "$dir" 2>/dev/null)" = 0 ] || return 1
    mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 1
    case $mode in
        '' | *[!0-7]*) return 1 ;;
    esac
    [ $((8#$mode & 8#022)) -eq 0 ]
}

# nc_restore_cut_off: succeeds when a restore was cut off: its marker is there and trusted (nc_marker_trusted), or the
# root entrypoint's note says that it was when the container started. www-data, which runs the hooks, can't see into
# the root-only folder, so for the hooks the note is what counts.
nc_restore_cut_off() {
    nc_marker_trusted "$(nc_marker_path restore)" || [ -e "$(nc_marker_path restore-note)" ]
}

# nc_note_restore_marker: for the root entrypoint, as root, at every start. When the restore marker is there and trusted
# (nc_marker_trusted) it writes the restore note and warns once, since every part of the start that would open
# Nextcloud up then waits. A marker that is there but not trusted is ignored, with a warning. Otherwise it removes any
# note (Docker keeps /run when it restarts a container). A note it can't write or remove gives a warning. The status is
# always 0.
nc_note_restore_marker() {
    local note marker
    note=$(nc_marker_path restore-note)
    marker=$(nc_marker_path restore)
    if nc_marker_trusted "$marker"; then
        if mkdir -p -- "${note%/*}" 2>/dev/null && (umask 022 && : >"$note") 2>/dev/null; then
            nc_warn "A restore was cut off: $marker is there. Until the AI Assistant finishes or undoes it, the start leaves maintenance mode and any pending upgrade alone, and runs none of the steps that a cut-off start left undone."
        else
            nc_warn "A restore was cut off, and $note could not be written, so the hooks, which can't see the restore marker, may not know"
        fi
        return 0
    fi
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        nc_warn "$marker is there, but it is not a file of root's in a folder that only root can write to, so the AI Assistant's restore did not make it. It is ignored."
    fi
    if [ -e "$note" ] || [ -L "$note" ]; then
        rm -f -- "$note" 2>/dev/null || nc_warn "could not remove $note, which says that a restore was cut off"
    fi
    return 0
}

# nc_hold_upgrade_for_restore: for the root entrypoint's last step, as root. Succeeds when a restore was cut off (its
# marker is there and trusted, nc_marker_trusted) and the code on the volume is not this image's (the volume's
# version.php differs from /usr/src/nextcloud/version.php). The official entrypoint would then copy the new code over
# the old and run occ upgrade on a half-restored database, and a failure there stops the container at every start. So
# the caller starts Apache on the volume's code without the official entrypoint, and the upgrade waits until the AI
# Assistant has finished or undone the restore. Fails before the first install (no version.php on the volume) and
# whenever the volume already has this image's code.
nc_hold_upgrade_for_restore() {
    nc_marker_trusted "$(nc_marker_path restore)" || return 1
    [ -f /var/www/html/version.php ] || return 1
    ! cmp -s -- /var/www/html/version.php /usr/src/nextcloud/version.php
}

# nc_claim_new_volume [DIR]: for the root entrypoint, as root, before anything else writes to the volume. When DIR (by
# default /var/www/html, the volume's top folder) is a folder of root's, it gets the owner and the mode the image gives
# that folder, www-data:root and 1777, and one line says so. A new Kubernetes disk (on GKE, a persistent disk's empty
# ext4) has a top folder of root's, mode 755, with lost+found in it, while Docker fills a new named volume from the
# image, owner and mode included. In root's folder www-data can make nothing, so not the init lock (nc_make_init_lock),
# and the official entrypoint's read-only open of the lock would then stop every start. Only the folder itself
# changes, never anything in it: lost+found stays root's until the official entrypoint's first copy removes it. A link,
# a folder of anyone else's and anything that is not a folder are left as they are. Nothing that runs as www-data has
# started yet, and the folder is the volume's mount point, which nobody can swap for a link. Status 0, or 1 with a
# warning when the folder could not be changed.
nc_claim_new_volume() {
    local dir=${1:-/var/www/html}
    if [ -L "$dir" ] || [ ! -d "$dir" ] || [ "$(stat -c %u -- "$dir" 2>/dev/null)" != 0 ]; then
        return 0
    fi
    if chown -h www-data:root -- "$dir" && chmod 1777 -- "$dir"; then
        nc_log "$dir was root's, as on a new disk, so it is now www-data's (1777, as in the image)"
        return 0
    fi
    nc_warn "could not give $dir to www-data, so www-data cannot make the init lock there"
    return 1
}

# nc_make_init_lock [FILE]: for the root entrypoint, as root. Makes FILE (the init lock, by default
# /var/www/html/nextcloud-init-sync.lock) a plain file of www-data's, and lets www-data do it. The official entrypoint
# opens the file as root, read-only (patch-official-entrypoint.sh), and the before-starting hook locks it as www-data.
# Its folder is www-data's (on a new disk, nc_claim_new_volume makes it so first), so root must not create anything
# there (the official entrypoint only reads it): a link that a www-data process puts at FILE between a test and a
# touch would make root create the link's target, such as a restore marker in root's clouve-backups. As www-data, a
# link leads only to files www-data could make anyway. Anything at FILE that is not a plain file of www-data's goes
# first: a link, a folder, a named pipe, or a file of another user's, which the hook could not open on a host with
# fs.protected_regular (the folder is sticky and world-writable in this image). Status 0 when FILE is a plain file
# afterwards, 1 with a warning when not.
nc_make_init_lock() {
    local file=${1:-/var/www/html/nextcloud-init-sync.lock}
    # shellcheck disable=SC2016  # $1 is for the inner sh, which gets the path as its first argument
    if runuser -u www-data -- sh -c '
        if [ -L "$1" ] || { [ -e "$1" ] && { [ ! -f "$1" ] || [ ! -O "$1" ]; }; }; then
            rm -rf -- "$1" || exit 1
        fi
        [ -e "$1" ] || : >>"$1" || exit 1
        [ -f "$1" ] && [ ! -L "$1" ]' _ "$file"; then
        return 0
    fi
    nc_warn "could not make $file a plain file of www-data's, so the official entrypoint and the hooks may not get the init lock"
    return 1
}

# nc_marker_name FILE: the backup's name from the first line of a marker FILE, for a log line. It is never used as a
# path. Root reads it, so it reads only a marker that nc_marker_trusted accepts. Anything else could have been put
# there by www-data to point root at a file that www-data must not see, such as /proc/1/environ. Every character but
# letters, digits, dot, hyphen and underscore becomes _, and the name is cut to 64 characters. It prints "unnamed" for a
# file it doesn't read or that holds no name.
nc_marker_name() {
    local file=${1-} line='' name
    if nc_marker_trusted "$file"; then
        IFS= read -r -n 200 line <"$file" 2>/dev/null || :
    fi
    name=${line//[!A-Za-z0-9._-]/_}
    name=${name:0:64}
    printf '%s\n' "${name:-unnamed}"
}

# _nc_backup_lock FILE: whether a backup that is still running holds its flock on the marker FILE. Status 0 when nobody
# holds a lock on it, 1 when a process does, and 2 when that can't be told. Only a plain file (not a symlink) can be a
# running backup's lock, so for anything else the status is 0. bash opens the file read-only, so, unlike flock FILE,
# nothing can be created through it, and the try is bounded, so a file swapped for a named pipe can't hold up the start.
_nc_backup_lock() {
    local file=${1-} rc=0
    if [ ! -f "$file" ] || [ -L "$file" ]; then
        return 0
    fi
    # shellcheck disable=SC2016  # $1 is for the inner bash, which gets the file as its first argument.
    timeout 5 bash -c 'exec 9<"$1" && flock -n -E 75 9' _ "$file" 2>/dev/null || rc=$?
    case $rc in
        0) return 0 ;;
        75) return 1 ;;
        *) return 2 ;;
    esac
}

# nc_clear_cut_off_backup: for the root entrypoint, as root, once the database answers and before the official
# entrypoint runs. occ runs through $OCC, which the root entrypoint points at www-data's occ. The status is always 0.
#
# A backup marker that nobody holds a lock on means that a backup was still running when the old container stopped,
# and the maintenance mode it turned on stayed on. Unless a restore was cut off too or an upgrade is pending,
# maintenance mode goes off, then the marker goes, and one line names the backup. The order matters: a start cut off in
# between still finds the marker. Root does this, not a hook, because the hooks run as www-data, which can neither see
# nor remove a file in clouve-backups.
#
#   - The marker is locked: the AI Assistant started a backup in this container (its sshd is up before this step), so
#     the backup owns maintenance mode and the marker, and both are left to it, with a line that says so. When the lock
#     can't be checked, both are left alone too, with a warning.
#   - A restore cut off as well: nothing is touched, because the AI Assistant has to finish or undo the restore.
#   - An upgrade pending (a killed occ upgrade): the before-starting hook turns maintenance mode off before it finishes
#     the upgrade, and the marker waits for a later start.
#   - A failure (occ can't report the status, or can't turn maintenance mode off): a warning, and the marker stays for
#     the next start.
nc_clear_cut_off_backup() {
    local marker name json off=no lock=0
    marker=$(nc_marker_path backup)
    if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
        return 0
    fi
    name=$(nc_marker_name "$marker")
    _nc_backup_lock "$marker" || lock=$?
    case $lock in
        1)
            nc_log "A backup ($name) is still running: it holds the lock on its marker, $marker. Maintenance mode and the marker are left to it."
            return 0
            ;;
        2)
            nc_warn "could not tell whether a backup ($name) still holds the lock on its marker, $marker, so maintenance mode and the marker are left as they are"
            return 0
            ;;
    esac
    if nc_restore_cut_off; then
        nc_warn "A backup ($name) and a restore were both cut off, so maintenance mode and both markers are left as they are"
        return 0
    fi
    if ! json=$(nc_status_json); then
        nc_warn "A backup ($name) was cut off, and occ did not report the status, so maintenance mode and the backup's marker wait for a later start"
        return 0
    fi
    case $json in
        *'"installed":true'*) ;;
        *)
            nc_warn "A backup ($name) was cut off, but Nextcloud is not installed, so its marker is left as it is"
            return 0
            ;;
    esac
    case $json in
        *'"needsDbUpgrade":true'*)
            nc_log "A backup ($name) was cut off, and an upgrade is pending. The before-starting hook turns maintenance mode off for the upgrade, and the backup's marker waits for a later start."
            return 0
            ;;
    esac
    if [ "$(_nc_status_maintenance "$json")" = on ]; then
        if ! nc_occ maintenance:mode --off; then
            nc_warn "A backup ($name) was cut off and left maintenance mode on, and occ could not turn it off. The backup's marker stays, so the next start tries again."
            return 0
        fi
        off=yes
    fi
    if ! rm -f -- "$marker"; then
        nc_warn "A backup ($name) was cut off, and its marker $marker could not be removed"
        return 0
    fi
    if [ "$off" = yes ]; then
        nc_log "A backup ($name) was cut off when the container stopped. Maintenance mode, which it had turned on, is off again, and its marker is gone. The backup in data/clouve-backups may be incomplete."
    else
        nc_log "A backup ($name) was cut off when the container stopped. Maintenance mode was already off, and its marker is gone. The backup in data/clouve-backups may be incomplete."
    fi
    return 0
}

# nc_sweep_leftovers [CONFIG_FILE]: removes what a run that was killed leaves
# behind. There are two kinds. The private file of the database settings,
# $NC_TMP_DIR/db.XXXXXX (/run/clouve/tmp when NC_TMP_DIR is not set), comes from
# nextcloud-config.sh. The half-written copy of config.php, .config.php.<12 hex
# digits> next to CONFIG_FILE, comes from nc_repair_db_config. CONFIG_FILE is
# $NC_CONFIG_FILE, or /var/www/html/config/config.php, when not given.
#
# The EXIT traps that delete these files do not run when the container is
# stopped, because PID 1 ignores SIGTERM and the container is then killed, and a
# PHP fatal error in the middle of the write leaves the copy as well. So the next
# run clears them. Only plain files with exactly those names go, never a symlink,
# and nothing else is using them, because the scripts run one after another. It
# prints nothing and returns 0.
nc_sweep_leftovers() {
    local conf=${1:-${NC_CONFIG_FILE:-/var/www/html/config/config.php}} tmp=${NC_TMP_DIR:-/run/clouve/tmp} f dir base suffix
    case $conf in
        */*) dir=${conf%/*} ;;
        *) dir=. ;;
    esac
    base=${conf##*/}
    for f in "$tmp"/db.??????; do
        if [ -f "$f" ] && [ ! -h "$f" ]; then
            rm -f -- "$f"
        fi
    done
    for f in "$dir"/."$base".*; do
        suffix=${f##*/}
        suffix=${suffix#."$base".}
        case $suffix in
            '' | *[!0-9a-f]*) continue ;;
        esac
        if [ "${#suffix}" -eq 12 ] && [ -f "$f" ] && [ ! -h "$f" ]; then
            rm -f -- "$f"
        fi
    done
    return 0
}

# nc_repair_db_config [CONFIG_FILE]: makes dbhost, dbname, dbuser and dbpassword
# in config.php equal to NEXTCLOUD_DB_HOST, NEXTCLOUD_DB_NAME, NEXTCLOUD_DB_USER
# and NEXTCLOUD_DB_PASSWORD, without starting occ. CONFIG_FILE is $NC_CONFIG_FILE,
# or /var/www/html/config/config.php, when not given.
#
# occ cannot start while config.php names a database it cannot reach, not even for
# config:system:set, and a clone's config.php names the database of the deployment
# it was copied from. So nextcloud-config.sh calls this, as www-data, when occ
# status fails. The root entrypoint calls it too, as www-data through runuser (not
# as root: config.php is code that www-data can change), before it hands over to the
# official entrypoint, whose own occ upgrade would otherwise fail on a clone whose
# image is newer than its volume. Either way config.php keeps its owner and mode.
#
# The status is 0 when it changed config.php (it logs that, with no value), 1 when
# config.php was already right, and 2 when it could not (a warning says why). It
# writes nothing unless all four variables are set and not empty, and nothing at
# all unless the new file has been written whole: the new file replaces config.php
# by rename, so a failure leaves config.php as it was.
#
# The new file is made in config/, next to config.php, on purpose: a rename is
# atomic only inside one filesystem. That makes it the one exception to the rule
# that a file carrying a secret goes in /run/clouve/tmp. It is mode 600 until it
# gets config.php's mode and owner, and nc_sweep_leftovers (called first) removes
# one that a kill or a PHP fatal error left behind.
#
# The password reaches PHP through the environment of the PHP process, so it is on
# no command line, and PHP's display_errors is off so that nothing PHP says can
# quote it. config.php is code, and what it prints while PHP includes it (text
# outside <?php ?>, an echo, a warning that quotes a string) can hold a secret, so
# that output is thrown away.
nc_repair_db_config() {
    local file=${1:-${NC_CONFIG_FILE:-/var/www/html/config/config.php}} code reason rc=0
    nc_sweep_leftovers "$file"

    IFS= read -r -d '' code <<'PHP' || :
$file = $argv[1];
$want = ['dbhost' => 'NEXTCLOUD_DB_HOST', 'dbname' => 'NEXTCLOUD_DB_NAME',
         'dbuser' => 'NEXTCLOUD_DB_USER', 'dbpassword' => 'NEXTCLOUD_DB_PASSWORD'];
$new = [];
foreach ($want as $key => $var) {
    $value = getenv($var);
    if (!is_string($value) || $value === '') {
        echo "$var is not set";
        exit(2);
    }
    $new[$key] = $value;
}
if (!is_file($file) || !is_readable($file)) {
    echo "cannot read $file";
    exit(2);
}
$CONFIG = null;
ob_start(static fn (string $buffer): string => '');
try {
    include $file;
} catch (Throwable $e) {
    ob_end_clean();
    echo "cannot read $file";
    exit(2);
}
ob_end_clean();
if (!is_array($CONFIG)) {
    echo "$file does not define \$CONFIG";
    exit(2);
}
$changed = false;
foreach ($new as $key => $value) {
    if (($CONFIG[$key] ?? null) !== $value) {
        $CONFIG[$key] = $value;
        $changed = true;
    }
}
if (!$changed) {
    exit(3);
}
$content = "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n";
umask(0077);
$tmp = dirname($file) . '/.' . basename($file) . '.' . bin2hex(random_bytes(6));
$fh = @fopen($tmp, 'xb');
if ($fh === false) {
    echo "cannot write next to $file";
    exit(2);
}
$ok = fwrite($fh, $content) === strlen($content) && fflush($fh) && fclose($fh)
    && chmod($tmp, fileperms($file) & 0777);
if ($ok && function_exists('posix_geteuid') && posix_geteuid() === 0) {
    $ok = chown($tmp, fileowner($file)) && chgrp($tmp, filegroup($file));
}
if (!$ok || !rename($tmp, $file)) {
    @unlink($tmp);
    echo "cannot replace $file";
    exit(2);
}
PHP

    reason=$(NEXTCLOUD_DB_HOST=${NEXTCLOUD_DB_HOST-} NEXTCLOUD_DB_NAME=${NEXTCLOUD_DB_NAME-} \
             NEXTCLOUD_DB_USER=${NEXTCLOUD_DB_USER-} NEXTCLOUD_DB_PASSWORD=${NEXTCLOUD_DB_PASSWORD-} \
             php -d display_errors=0 -d log_errors=0 -r "$code" -- "$file" 2>&1) || rc=$?
    case $rc in
        0) nc_log 'database settings in config.php updated to match the environment'; return 0 ;;
        3) return 1 ;;
        *) nc_warn "could not check the database settings in config.php: ${reason:-php failed with status $rc}"; return 2 ;;
    esac
}
