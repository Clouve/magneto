#!/bin/bash
# Keeps the Nextcloud settings that depend on the container's environment in step with it. The hooks run this as
# www-data with the container's environment: post-installation once, after the first install, and before-starting at
# every start. It writes only what differs, and Nextcloud writes config.php only when a value changes, so a restart
# that changes nothing leaves config.php alone.
#
# First it removes what a run that was killed left behind (nc_sweep_leftovers), and makes sure occ starts. If occ does not
# start, nc_repair_db_config fixes the database settings in config.php without occ, and occ is asked again.
#
# The steps, in order:
#   1. dbhost, dbname, dbuser and dbpassword from NEXTCLOUD_DB_*. A clone gets a new database host in its
#      environment and keeps the old one in config.php.
#   2. overwrite.cli.url from NEXTCLOUD_URL. A change is logged as "Nextcloud URL has changed: OLD -> NEW".
#   3. overwriteprotocol: https for an https URL, removed for an http one.
#   4. trusted_domains: localhost and the URL's host, each added when it is missing. Nothing is ever removed, so
#      a custom domain leaves the Clouve host working, and going back to the Clouve host adds nothing.
#   5. trusted_proxies, indexes 0 to 2: the private ranges the image's Apache already trusts for X-Real-IP.
#   6. The Valkey socket, then memcache.distributed and memcache.locking on Valkey.
#   7. preview_concurrency_new and preview_concurrency_all, from CLV_PREVIEW_CONCURRENCY_NEW and
#      CLV_PREVIEW_CONCURRENCY_ALL (the root entrypoint sizes them from the container's memory).
#   8. files.chunked_upload.max_size, the chunk size of browser uploads: 40 MiB when it is not set, is 0 or less
#      (chunking off) or is above the ingress's 50 MiB limit on one request. A value from 1 byte to 50 MiB stays. A
#      change is logged with the value it replaced.
#
# It reads NEXTCLOUD_URL, NEXTCLOUD_DB_HOST, NEXTCLOUD_DB_NAME, NEXTCLOUD_DB_USER and NEXTCLOUD_DB_PASSWORD, and
# optionally CLV_PREVIEW_CONCURRENCY_NEW and CLV_PREVIEW_CONCURRENCY_ALL. Three more variables exist for the tests.
# Nothing sets them in a deployment:
#   OCC             the occ command, "php /var/www/html/occ" by default
#   NC_TMP_DIR      the private folder for the file that carries the password, /run/clouve/tmp by default
#   NC_CONFIG_FILE  config.php, /var/www/html/config/config.php by default. The sweep and the repair read it.
#
# It exits 1 only when occ will not start. Every other failure is a warning on stderr, and the script goes on with
# the next setting. A read that fails leaves trusted_domains, overwrite.cli.url, the chunk size and the database
# settings alone. The cache keys and trusted_proxies are different: the cache keys are set without a read, and
# trusted_proxies is set when its read fails. That is harmless, because setting a value that is already right changes
# nothing. An unset variable never empties a setting.
#
# The database password never reaches a log, stdout or a command line. The script compares it inside the shell. The
# only way it reaches occ is a mode 600 file in the private folder, which config:import reads and the script deletes
# right after.
#
# This script never takes the init lock (nextcloud-init-sync.lock). The post-installation hook runs it while the
# official entrypoint holds that lock, and a second flock from this process would wait for the first one forever.

set -u

installer=/clouve/nextcloud/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || { printf '[nextcloud] ERROR: cannot read %s\n' "$installer/lib.sh" >&2; exit 1; }

# www-data's home. su -p keeps root's HOME, which www-data cannot write to, and PHP then logs "Fontconfig error: No
# writable cache directories".
export HOME=/var/www

NC_TMP_DIR=${NC_TMP_DIR:-/run/clouve/tmp}
NC_CONFIG_FILE=${NC_CONFIG_FILE:-/var/www/html/config/config.php}

# The file with the password in it, while it exists. If a signal stops the script first, bash runs this trap on the
# way out and the file goes. Do not add traps for the signals themselves: with one, bash waits for the running command
# to end before it reacts.
db_file=''
trap 'if [ -n "$db_file" ]; then rm -f -- "$db_file"; fi' EXIT

# occ_get KEY...: prints a system config value. Status 0 means the key is set (the value may be empty). Status 1 means
# it is not: occ exits 1 and prints nothing. Status 2 means occ failed. config:system:get reads only config.php, which
# occ loads as it starts, so with these arguments it fails only when occ can't start, and occ that can't start prints
# its error on stdout (a command that fails on the way would print it on stderr). So a failed read can't pass for a key
# that is not set.
occ_get() {
    local out rc=0
    out=$(nc_occ config:system:get "$@" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out"
    elif [ "$rc" -eq 1 ] && [ -z "$out" ]; then
        return 1
    else
        return 2
    fi
}

# occ_set ARGS...: runs occ config:system:set. It keeps none of occ's output: not the "set to" line, and not the notice
# occ prints on every call while an upgrade is pending or maintenance mode is on. A failure becomes a warning that names
# the key and its index, never the value, and quotes the first lines of what occ said.
occ_set() {
    local rc=0 out label=$*
    out=$(nc_occ config:system:set "$@" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        nc_warn "occ config:system:set ${label%%--*}failed (exit status $rc): $(nc_first_lines "$out")"
    fi
    return "$rc"
}

# occ_delete KEY: runs occ config:system:delete, which succeeds when the key is not set. Output is handled as in occ_set.
occ_delete() {
    local rc=0 out
    out=$(nc_occ config:system:delete "$@" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        nc_warn "occ config:system:delete $* failed (exit status $rc): $(nc_first_lines "$out")"
    fi
    return "$rc"
}

# --- occ has to start -----------------------------------------------------------------

# occ_starts: succeeds when `occ status` runs. What it printed is kept in $status_out.
occ_starts() {
    status_out=$(nc_occ status --output=json 2>&1)
}

# check_occ: no setting can be applied until occ starts. The one cause it can fix is a stale database setting. occ
# cannot start without a working database, not even for config:system:set, and a clone's config.php still names the
# database of the deployment it was copied from. config:import (step 1) can't help there, so the repair edits
# config.php directly and then asks occ again.
check_occ() {
    if occ_starts; then
        return 0
    fi
    if nc_repair_db_config "$NC_CONFIG_FILE" && occ_starts; then
        return 0
    fi
    printf '[nextcloud] ERROR: occ does not start, so the settings were not applied. occ said: %s\n' "$(nc_first_lines "$status_out")" >&2
    exit 1
}

# --- 1. the database ------------------------------------------------------------------

# write_database_file FILE: the four settings from the environment as JSON in FILE, for config:import. PHP reads them
# itself, so they are not on its command line.
write_database_file() {
    local code
    IFS= read -r -d '' code <<'PHP' || :
try {
    $settings = [];
    foreach (['dbhost' => 'NEXTCLOUD_DB_HOST', 'dbname' => 'NEXTCLOUD_DB_NAME',
              'dbuser' => 'NEXTCLOUD_DB_USER', 'dbpassword' => 'NEXTCLOUD_DB_PASSWORD'] as $key => $var) {
        $settings[$key] = (string) getenv($var);
    }
    $json = json_encode(['system' => $settings], JSON_THROW_ON_ERROR);
    if (file_put_contents($argv[1], $json) !== strlen($json)) {
        throw new RuntimeException('short write');
    }
} catch (Throwable $e) {
    fwrite(STDERR, "could not write the database settings file\n");
    exit(1);
}
PHP
    php -d display_errors=stderr -r "$code" -- "$1"
}

# import_database_settings: writes the four settings through a private file and config:import.
import_database_settings() {
    local out
    if ! db_file=$(umask 077 && mktemp "$NC_TMP_DIR/db.XXXXXX" 2>/dev/null); then
        db_file=''
        nc_warn "cannot make a private file in $NC_TMP_DIR, so the database settings are not updated"
        return 0
    fi
    if write_database_file "$db_file" && out=$(nc_occ config:import "$db_file" 2>&1); then
        nc_log 'database settings updated'
    else
        nc_warn "could not update the database settings: $(nc_first_lines "${out:-the settings file was not written}")"
    fi
    rm -f -- "$db_file"
    db_file=''
}

set_database() {
    local pair key var cur st differs=0
    local -a pairs=(dbhost:NEXTCLOUD_DB_HOST dbname:NEXTCLOUD_DB_NAME dbuser:NEXTCLOUD_DB_USER dbpassword:NEXTCLOUD_DB_PASSWORD)
    for pair in "${pairs[@]}"; do
        var=${pair#*:}
        if [ -z "${!var-}" ]; then
            nc_warn "$var is not set, so the database settings in config.php are left as they are"
            return 0
        fi
    done
    for pair in "${pairs[@]}"; do
        key=${pair%%:*}
        var=${pair#*:}
        cur=$(occ_get "$key")
        st=$?
        if [ "$st" -eq 2 ]; then
            nc_warn "could not read $key, so the database settings are left as they are"
            return 0
        fi
        if [ "$cur" != "${!var}" ]; then
            differs=1
        fi
    done
    if [ "$differs" -eq 1 ]; then
        import_database_settings
    fi
}

# --- 2 and 3. the URL and the scheme --------------------------------------------------

set_url() {
    local old st scheme
    if [ -z "${NEXTCLOUD_URL-}" ]; then
        nc_warn 'NEXTCLOUD_URL is not set, so overwrite.cli.url and overwriteprotocol are left as they are'
        return 0
    fi
    scheme=$(nc_url_scheme "$NEXTCLOUD_URL")
    if [ -z "$scheme" ] || [ -z "$(nc_url_host "$NEXTCLOUD_URL")" ]; then
        nc_warn 'NEXTCLOUD_URL is not an http or https URL with a host, so overwrite.cli.url and overwriteprotocol are left as they are'
        return 0
    fi
    old=$(occ_get overwrite.cli.url)
    st=$?
    if [ "$st" -eq 2 ]; then
        nc_warn 'could not read overwrite.cli.url, so it is left as it is'
    elif [ "$old" != "$NEXTCLOUD_URL" ]; then
        nc_log "Nextcloud URL has changed: $old -> $NEXTCLOUD_URL"
        occ_set overwrite.cli.url --value="$NEXTCLOUD_URL"
    fi
    case $scheme in
        https) occ_set overwriteprotocol --value=https ;;
        http) occ_delete overwriteprotocol ;;
    esac
}

# --- 4. trusted_domains -----------------------------------------------------------------

# next_index JSON: one more than the highest numeric index in the list JSON, or 0 for an empty list. Once its indexes
# have gaps, trusted_domains comes back as an object, and its keys need not be in order.
next_index() {
    local code
    IFS= read -r -d '' code <<'PHP' || :
$list = json_decode((string) getenv('NC_PHP_JSON'), true);
$next = 0;
if (is_array($list)) {
    foreach (array_keys($list) as $key) {
        if (is_int($key) && $key >= $next) {
            $next = $key + 1;
        }
    }
}
echo $next;
PHP
    NC_PHP_JSON=$1 php -d display_errors=stderr -r "$code"
}

set_trusted_domains() {
    local json st missing next host
    json=$(occ_get trusted_domains --output=json)
    st=$?
    case $st in
        0) ;;
        1) json='' ;;
        *) nc_warn 'could not read trusted_domains, so it is left as it is'; return 0 ;;
    esac
    missing=$(nc_missing_trusted_domains "$json" localhost "$(nc_url_host "${NEXTCLOUD_URL-}")") || return 0
    if [ -z "$missing" ]; then
        return 0
    fi
    if ! next=$(next_index "$json"); then
        nc_warn 'could not work out the next index of trusted_domains, so it is left as it is'
        return 0
    fi
    while IFS= read -r host; do
        if occ_set trusted_domains "$next" --value="$host"; then
            nc_log "trusted_domains: added $host at index $next"
            next=$((next + 1))
        fi
    done <<<"$missing"
}

# --- 5, 6 and 7. proxies, cache and previews -------------------------------------------

set_trusted_proxies() {
    local i cur
    local -a ranges=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16)
    for i in 0 1 2; do
        if cur=$(occ_get trusted_proxies "$i") && [ "$cur" = "${ranges[$i]}" ]; then
            continue
        fi
        occ_set trusted_proxies "$i" --value="${ranges[$i]}"
    done
}

# The socket goes in first. Every occ call is a new PHP process that reads config.php as it starts, and one that finds a
# cache class on Redis and no redis host connects to 127.0.0.1:6379. It still runs its command, but it logs
# "Could not boot ...: Connection refused" to nextcloud.log, and the admin overview then warns about errors in the log.
set_cache() {
    occ_set redis host --value=/run/clouve/valkey/valkey.sock
    occ_set redis port --type=integer --value=0
    occ_set memcache.distributed --value='\OC\Memcache\Redis'
    occ_set memcache.locking --value='\OC\Memcache\Redis'
}

set_previews() {
    local new=${CLV_PREVIEW_CONCURRENCY_NEW-} all=${CLV_PREVIEW_CONCURRENCY_ALL-}
    if [ -z "$new" ] || [ -z "$all" ]; then
        return 0
    fi
    case $new$all in
        *[!0-9]*)
            nc_warn 'CLV_PREVIEW_CONCURRENCY_NEW and CLV_PREVIEW_CONCURRENCY_ALL must be numbers, so preview concurrency is left as it is'
            return 0
            ;;
    esac
    occ_set preview_concurrency_new --type=integer --value="$new"
    occ_set preview_concurrency_all --type=integer --value="$all"
}

# --- 8. the upload chunk size -------------------------------------------------------------

# chunk_size_of JSON: the value in JSON (what `occ config:system:get --output=json` printed) as Nextcloud reads it:
# getSystemValueInt() casts it to int, so "104857600" and 1.5e8 count as numbers too. Status 1 when JSON can't be read.
chunk_size_of() {
    local code
    IFS= read -r -d '' code <<'PHP' || :
$value = json_decode((string) getenv('NC_PHP_JSON'), true);
if (json_last_error() !== JSON_ERROR_NONE) {
    exit(1);
}
echo (int) $value;
PHP
    NC_PHP_JSON=$1 php -d display_errors=stderr -r "$code"
}

# set_chunk_size: browser uploads go in chunks of files.chunked_upload.max_size bytes, 100 MiB when the key is not set
# (apps/files/lib/Service/ChunkedUploadConfig.php; the web UI gets it from JSConfigHelper). The ingress refuses a request
# body over 50 MiB, so a chunk that size gets HTTP 413. 0 or less turns chunking off, and then the web UI sends each file
# as one request, so any file over 50 MiB gets 413. The key becomes 40 MiB in all three cases: not set, 0 or less, and
# above 50 MiB. A value from 1 byte to 50 MiB is the admin's choice and stays. Nextcloud 35 reads only this key. The app
# key files max_chunk_size of older versions is read by nothing but a migration that has already run.
set_chunk_size() {
    local key=files.chunked_upload.max_size want=41943040 cap=52428800 json st cur from
    json=$(occ_get "$key" --output=json)
    st=$?
    case $st in
        0)
            cur=$(chunk_size_of "$json") || cur=''
            if ! [[ $cur =~ ^-?[0-9]+$ ]]; then
                nc_warn "could not read $key as a number, so it is left as it is"
                return 0
            fi
            if [ "$cur" -ge 1 ] && [ "$cur" -le "$cap" ]; then
                return 0
            fi
            from=$cur
            if [ "$cur" -le 0 ]; then
                from="$cur (chunking off)"
            fi
            ;;
        1) from="Nextcloud's default of 100 MiB" ;;
        *) nc_warn "could not read $key, so it is left as it is"; return 0 ;;
    esac
    if occ_set "$key" --type=integer --value="$want"; then
        nc_log "$key set to $want (40 MiB), from $from, so that an upload request fits under the ingress's 50 MiB limit"
    fi
}

nc_sweep_leftovers "$NC_CONFIG_FILE"
check_occ
set_database
set_url
set_trusted_domains
set_trusted_proxies
set_cache
set_previews
set_chunk_size
exit 0
