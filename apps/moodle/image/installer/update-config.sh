#!/bin/bash
set -e

# ============================================================================
# UPDATE MOODLE CONFIG.PHP WITH CURRENT ENVIRONMENT VARIABLES
# ============================================================================
# This script updates Moodle's config.php file with current environment variable
# values for database credentials and wwwroot on every container startup.
# This allows dynamic configuration changes without manual file edits.
#
# It also updates the mdl_config table in the database to ensure Moodle's
# internal cache reflects the current wwwroot value.
# ============================================================================

CONFIG_FILE="${MOODLE_INSTALL_PATH}/config.php"

# ============================================================================
# config.php, read and changed without following a link
# ============================================================================
# This script runs as root, and config.php is on the site's volume, which www-data owns: PHP code of the site can put
# a link, a folder or a pipe there at any time, and a process it left running can do it while this script works. So:
#   - config.php is read only as a regular file: perl opens it without following a link (O_NOFOLLOW) and without
#     waiting on a pipe (O_NONBLOCK), and checks on the open file that it is a regular file, the one checked just
#     before, before it reads a byte;
#   - a change goes into a new file in the same folder, which perl creates only if nothing is at its name (O_EXCL, so a
#     link there makes it fail) and gives config.php's owner, group and mode through the open file (fchown, fchmod);
#     mv -fT then renames it over config.php, which replaces whatever is there without following it;
#   - a config.php that is a link or not a regular file is left as it is: one warning names it, nothing of it or of
#     what it points to is read, copied or shown, and the start goes on. (Moodle then reads it as www-data, as it
#     would anyway; the AI Assistant or staff can put a regular file back.)
# The work runs from inside the site's folder (cd -P), by plain names. That folder is the volume's mount point in
# root's /var/www, which www-data can't rename or replace.
# The entrypoint and upgrade.sh change config.php the same way, through this script:
#   update-config.sh --read FILE                         prints FILE's text
#   update-config.sh --edit [--php-lint] FILE COMMAND... FILE's text goes through COMMAND (stdin to stdout), and what
#                                                        COMMAND prints takes FILE's place; --php-lint: only if php -l
#                                                        passes it
# Both exit 2, with the warning, when FILE is a link or not a regular file (or missing), and 1, with an error, when the
# change can't be made; --php-lint exits 3 when the new text fails php -l, and FILE is then unchanged.
# (tests/moodle-root-paths.test.sh)

# The perl steps, on a NAME in the current folder. stat: prints "dev inode uid gid mode" for a regular file (status 1
# when nothing is there, 2 for anything else, a link included). read NAME META: prints the text, only if NAME opens
# without following a link as a regular file with META's dev and inode (status 2 otherwise). write NAME META: makes
# NAME from stdin, only if nothing is at NAME, with META's uid, gid and mode, and prints its own "dev inode uid gid
# mode" (status 3 when it can't).
# shellcheck disable=SC2016  # perl code, for perl
CLV_CONFIG_PERL='
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK S_ISREG);
my ($op, $name, $meta) = @ARGV;
sub copy_all {
    my ($in, $out) = @_;
    my $buf;
    while (1) {
        my $n = sysread($in, $buf, 65536);
        return 0 unless defined $n;
        return 1 if $n == 0;
        my $off = 0;
        while ($off < $n) {
            my $w = syswrite($out, $buf, $n - $off, $off);
            return 0 unless defined $w;
            $off += $w;
        }
    }
}
if ($op eq "stat") {
    my @s = lstat($name) or exit 1;
    S_ISREG($s[2]) or exit 2;
    print join(" ", $s[0], $s[1], $s[4], $s[5], $s[2] & 07777), "\n";
    exit 0;
}
my ($dev, $ino, $uid, $gid, $mode) = split(/ /, $meta // "");
defined($mode) or exit 4;
if ($op eq "read") {
    sysopen(my $fh, $name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 2;
    my @s = stat($fh) or exit 2;
    (S_ISREG($s[2]) && $s[0] == $dev && $s[1] == $ino) or exit 2;
    binmode($fh);
    binmode(STDOUT);
    copy_all($fh, \*STDOUT) or exit 3;
    exit 0;
}
if ($op eq "write") {
    sysopen(my $fh, $name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or exit 3;
    binmode($fh);
    binmode(STDIN);
    copy_all(\*STDIN, $fh) or exit 3;
    my @s = stat($fh) or exit 3;
    ($s[4] == $uid && $s[5] == $gid) or chown($uid, $gid, $fh) or exit 3;
    chmod($mode, $fh) or exit 3;
    close($fh) or exit 3;
    print join(" ", $s[0], $s[1], $uid, $gid, $mode), "\n";
    exit 0;
}
exit 4;
'
config_perl() { perl -e "$CLV_CONFIG_PERL" -- "$@"; }

# _config_read_here NAME: config_read's work, in NAME's folder.
_config_read_here() {
  local meta
  meta="$(config_perl stat "$1")" || return 2
  config_perl read "$1" "$meta" || return "$(( $? == 2 ? 2 : 1 ))"
}

# _config_edit_here NAME LINT COMMAND...: config_edit's work, in NAME's folder. Status 2 when NAME isn't a regular file
# (or stops being one), 3 when LINT is lint and php -l fails the new text, 4 when something replaced the new file
# before the rename, 1 for any other failure.
_config_edit_here() {
  local name="$1" lint="$2" meta rand tmp new
  shift 2
  meta="$(config_perl stat "$name")" || return 2
  rand="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$rand" =~ ^[0-9a-f]{16}$ ]] || return 1
  tmp=".$name.clouve-$rand"
  if ! new="$(set -o pipefail; config_perl read "$name" "$meta" | "$@" | config_perl write "$tmp" "$meta")"; then
    rm -rf -- "$tmp" 2>/dev/null || :   # whatever is at that name in this folder; a link goes as a link
    config_perl stat "$name" > /dev/null || return 2
    return 1
  fi
  # php -l only parses the text it gets on stdin; it runs none of it. The text is read back from the new file the same
  # checked way.
  if [[ "$lint" == lint ]] && ! config_perl read "$tmp" "$new" | php -l > /dev/null 2>&1; then
    rm -rf -- "$tmp" 2>/dev/null || :
    return 3
  fi
  if ! mv -fT -- "$tmp" "$name" 2>/dev/null; then
    rm -rf -- "$tmp" 2>/dev/null || :
    return 1
  fi
  [[ -f "$name" && ! -L "$name" ]] || return 4
}

# config_warn FILE: the one line a config.php that is left as it is gets. It names the file and shows nothing of it.
config_warn() {
  echo "⚠ Warning: $1 is a link or not a regular file, so it is left as it is" >&2
}

# config_read FILE: prints FILE's text when FILE is a regular file and not a link. Status 2, with the warning, otherwise.
config_read() {
  local rc=0
  (cd -P -- "$(dirname -- "$1")" 2>/dev/null || exit 1; _config_read_here "${1##*/}") || rc=$?
  case $rc in
    0) return 0 ;;
    2) config_warn "$1"; return 2 ;;
    *) echo "✗ Error: can't read $1" >&2; return 1 ;;
  esac
}

# config_edit [--php-lint] FILE COMMAND...: FILE's text goes through COMMAND, and what COMMAND prints takes FILE's
# place, with FILE's owner, group and mode. Status 2, with the warning, when FILE is a link or not a regular file; 3
# when --php-lint is given and the new text fails php -l (FILE unchanged); 1, with an error, when it can't be changed.
config_edit() {
  local lint=- file rc=0
  if [[ "$1" == --php-lint ]]; then lint=lint; shift; fi
  file="$1"
  shift
  (cd -P -- "$(dirname -- "$file")" 2>/dev/null || exit 1; _config_edit_here "${file##*/}" "$lint" "$@") || rc=$?
  case $rc in
    0) return 0 ;;
    2) config_warn "$file"; return 2 ;;
    3) return 3 ;;
    4) echo "✗ Error: can't write $file: something replaced the new file before it was renamed" >&2; return 1 ;;
    *) echo "✗ Error: can't write $file" >&2; return 1 ;;
  esac
}

# clv_password_filter REGEX PREFIX: stdin to stdout, with the line that matches REGEX (an awk regex) replaced by PREFIX
# followed by CLV_DB_PASSWORD as a PHP single-quoted string (each \ and ' after a \) and ";". awk reads the value from
# its environment, so it is never on a command line, and any character in it reads back the same
# (tests/installer-db-password.test.sh).
clv_password_filter() {
    awk -v re="$1" -v prefix="$2" '
        function phpq(s,   i, c, out) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "\\" || c == "\047") out = out "\\"
                out = out c
            }
            return "\047" out "\047"
        }
        $0 ~ re { print prefix phpq(ENVIRON["CLV_DB_PASSWORD"]) ";"; next }
        { print }
    '
}

case "${1:-}" in
  --read)
    [ $# -eq 2 ] || { echo "Usage: update-config.sh --read FILE" >&2; exit 64; }
    config_read "$2"
    exit
    ;;
  --edit)
    shift
    if [ $# -lt 2 ] || { [ "$1" = --php-lint ] && [ $# -lt 3 ]; }; then
      echo "Usage: update-config.sh --edit [--php-lint] FILE COMMAND..." >&2
      exit 64
    fi
    config_edit "$@"
    exit
    ;;
esac

# config_set FILE COMMAND...: one of the changes below. A config.php that stops being a regular file meanwhile is left
# as it is (the warning names it) and the start goes on; any other failure ends the script, as a failed sed -i did.
config_set() {
  local rc=0
  [ "$CONFIG_OK" = true ] || return 1
  config_edit "$@" || rc=$?
  case $rc in
    0) return 0 ;;
    2) CONFIG_OK=false; return 1 ;;
    *) exit 1 ;;
  esac
}

echo "============================================================================"
echo "UPDATING MOODLE CONFIGURATION"
echo "============================================================================"

# Check if config.php exists
if [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
    echo "ℹ config.php not found at $CONFIG_FILE"
    echo "  Moodle has not been installed yet. Skipping configuration update."
    echo "============================================================================"
    exit 0
fi

# New files that an earlier start made and didn't rename, because it was cut off. They are removed by name from inside
# the site's folder; rm doesn't follow a link.
(cd -P -- "$MOODLE_INSTALL_PATH" 2>/dev/null && rm -f -- .config.php.clouve-???????????????? 2>/dev/null) || :

# A link, a folder or a pipe at config.php is left as it is: nothing below reads or changes it. The database's wwwroot
# is still updated.
CONFIG_OK=true
if config_perl stat "$CONFIG_FILE" > /dev/null; then
    echo "Found config.php at: $CONFIG_FILE"
else
    config_warn "$CONFIG_FILE"
    echo "  Its database settings and wwwroot are not updated."
    CONFIG_OK=false
fi

# ============================================================================
# PART 1: UPDATE DATABASE CREDENTIALS IN CONFIG.PHP
# ============================================================================

# Check if environment variables are set
if [ "$CONFIG_OK" != true ]; then
    :
elif [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
    echo "⚠ WARNING: Database environment variables not fully set. Skipping database config update."
    echo "  DB_HOST: ${DB_HOST:-(not set)}"
    echo "  DB_NAME: ${DB_NAME:-(not set)}"
    echo "  DB_USER: ${DB_USER:-(not set)}"
    # Only whether the password is set: its value never goes to the log.
    if [ -n "$DB_PASSWORD" ]; then echo "  DB_PASSWORD: (set)"; else echo "  DB_PASSWORD: (not set)"; fi
else
    echo "Updating database credentials in config.php..."
    
    # Escape special characters in password for sed
    # This handles passwords with special characters like $, &, /, \, etc.
    DB_HOST_ESCAPED=$(printf '%s\n' "$DB_HOST" | sed -e 's/[\/&]/\\&/g')
    DB_NAME_ESCAPED=$(printf '%s\n' "$DB_NAME" | sed -e 's/[\/&]/\\&/g')
    DB_USER_ESCAPED=$(printf '%s\n' "$DB_USER" | sed -e 's/[\/&]/\\&/g')
    
    # Update database configuration values in config.php
    # These sed commands will replace the hardcoded values with environment variable values
    
    # Update database host
    config_set "$CONFIG_FILE" sed "s/^\$CFG->dbhost[[:space:]]*=.*$/\$CFG->dbhost    = '${DB_HOST_ESCAPED}';/" &&
    echo "  ✓ Updated \$CFG->dbhost to: $DB_HOST"
    
    # Update database name
    config_set "$CONFIG_FILE" sed "s/^\$CFG->dbname[[:space:]]*=.*$/\$CFG->dbname    = '${DB_NAME_ESCAPED}';/" &&
    echo "  ✓ Updated \$CFG->dbname to: $DB_NAME"
    
    # Update database user
    config_set "$CONFIG_FILE" sed "s/^\$CFG->dbuser[[:space:]]*=.*$/\$CFG->dbuser    = '${DB_USER_ESCAPED}';/" &&
    echo "  ✓ Updated \$CFG->dbuser to: $DB_USER"
    
    # Update database password, off every command line (clv_password_filter).
    CLV_DB_PASSWORD="$DB_PASSWORD" config_set "$CONFIG_FILE" clv_password_filter '^\\$CFG->dbpass[ \t]*=' '$CFG->dbpass    = ' &&
    echo "  ✓ Updated \$CFG->dbpass to: [REDACTED]"
    
    [ "$CONFIG_OK" = true ] && echo "✓ Database credentials updated successfully in config.php"
fi

# ============================================================================
# PART 2: UPDATE WWWROOT IN CONFIG.PHP AND DATABASE
# ============================================================================

# moodle_db ARGS...: the mysql client on Moodle's database. The password goes in MYSQL_PWD, in this one command's
# environment: a command line can be read by every process in the container.
moodle_db() {
    MYSQL_PWD="$DB_PASSWORD" mysql --skip-ssl -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" "$@"
}

if [ -z "$MOODLE_URL" ]; then
    echo "⚠ WARNING: MOODLE_URL environment variable not set. Skipping wwwroot update."
else
    # ============================================================================
    # DETECT URL CHANGES
    # ============================================================================
    # First, check if the URL has actually changed by comparing with the database value
    # This allows us to log URL changes explicitly (required for test scripts)

    echo "Checking if MOODLE_URL has changed..."

    PREVIOUS_WWWROOT=""
    URL_HAS_CHANGED=false

    # Check if we can connect to the database to get the previous URL
    if moodle_db \
       -e "SELECT 1;" >/dev/null 2>&1; then

        # Get the current wwwroot value from the database
        PREVIOUS_WWWROOT=$(moodle_db \
          -sN -e "SELECT value FROM mdl_config WHERE name = 'wwwroot';" 2>/dev/null || echo "")

        if [ -n "$PREVIOUS_WWWROOT" ]; then
            echo "  Previous URL from database: $PREVIOUS_WWWROOT"
            echo "  Current MOODLE_URL: $MOODLE_URL"

            # Check if URL has changed
            if [ "$PREVIOUS_WWWROOT" != "$MOODLE_URL" ]; then
                URL_HAS_CHANGED=true
                echo "  ✓ URL has changed!"
                echo "    Old URL: $PREVIOUS_WWWROOT"
                echo "    New URL: $MOODLE_URL"
            else
                echo "  ℹ URL unchanged: $MOODLE_URL"
            fi
        else
            echo "  ℹ No previous URL found in database (first run after installation)"
        fi
    else
        echo "  ⚠ WARNING: Could not connect to database to check previous URL"
        echo "    Will proceed with updating config.php"
    fi

    # ============================================================================
    # UPDATE CONFIG.PHP
    # ============================================================================

    if [ "$CONFIG_OK" = true ]; then
        echo "Updating wwwroot in config.php..."

        # Escape special characters in URL for sed
        MOODLE_URL_ESCAPED=$(printf '%s\n' "$MOODLE_URL" | sed -e 's/[\/&]/\\&/g')

        # Update wwwroot in config.php
        config_set "$CONFIG_FILE" sed "s/^\$CFG->wwwroot[[:space:]]*=.*$/\$CFG->wwwroot   = '${MOODLE_URL_ESCAPED}';/" &&
        echo "  ✓ Updated \$CFG->wwwroot to: $MOODLE_URL"
    fi

    # ============================================================================
    # UPDATE WWWROOT IN DATABASE
    # ============================================================================
    # Moodle caches the wwwroot value in the mdl_config table
    # We need to update it there as well to ensure consistency

    echo "Updating wwwroot in database (mdl_config table)..."

    # Check if we can connect to the database
    if moodle_db \
       -e "SELECT 1;" >/dev/null 2>&1; then

        # Update the wwwroot value in mdl_config table
        # The wwwroot is stored with name='wwwroot' in the mdl_config table
        # Use INSERT ... ON DUPLICATE KEY UPDATE to handle both new and existing entries
        moodle_db \
          -e "INSERT INTO mdl_config (name, value) VALUES ('wwwroot', '$MOODLE_URL') ON DUPLICATE KEY UPDATE value = '$MOODLE_URL';" 2>&1

        # Verify the update
        CURRENT_WWWROOT=$(moodle_db \
          -sN -e "SELECT value FROM mdl_config WHERE name = 'wwwroot';" 2>/dev/null || echo "")

        if [ "$CURRENT_WWWROOT" = "$MOODLE_URL" ]; then
            echo "  ✓ Updated wwwroot in database to: $MOODLE_URL"
        else
            echo "  ⚠ WARNING: Database wwwroot value does not match expected value"
            echo "    Expected: $MOODLE_URL"
            echo "    Current:  $CURRENT_WWWROOT"
        fi

        # If URL has changed, clear Moodle's cache to ensure changes take effect immediately
        if [ "$URL_HAS_CHANGED" = true ]; then
            echo "URL change detected - invalidating Moodle cache..."
            # We do this by updating the allversionshash which forces cache invalidation
            moodle_db \
              -e "UPDATE mdl_config SET value = CONCAT(value, '1') WHERE name = 'allversionshash';" 2>&1 || true
            echo "  ✓ Cache invalidation triggered"
        fi

    else
        echo "  ⚠ WARNING: Could not connect to database to update wwwroot"
        echo "    The config.php file has been updated, but the database value may be stale"
        echo "    This may cause issues until the database is accessible"
    fi

    echo "✓ wwwroot updated successfully"
fi

echo "============================================================================"
echo "✓ MOODLE CONFIGURATION UPDATE COMPLETED"
echo "============================================================================"

