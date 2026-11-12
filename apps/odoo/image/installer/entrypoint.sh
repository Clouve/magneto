#!/bin/bash

# Odoo Docker Entrypoint Script
# tini, PID 1, runs this script as root. It:
# 1. Waits for PostgreSQL to be ready
# 2. Writes /etc/odoo/odoo.conf, which holds the passwords: it is odoo's, and
#    no other user can read it. It also locks Odoo's database manager
# 3. Gives the volumes to the odoo user (a new disk, or files of root's that
#    an older image left)
# 4. Initializes the Odoo database if not already initialized
# 5. Updates the URL and starts the clouve-ops sshd
# 6. Starts Odoo as the odoo user, never as root

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set error handling
set -e

# What this script and install.sh share: the rule for a secret's name,
# odoo_unset_secrets and odoo_dbfilter.
# shellcheck source=apps/odoo/image/installer/lib.sh
. /clouve/odoo/installer/lib.sh

# Odoo configuration
ODOO_DATA_DIR="/var/lib/odoo"
ODOO_ADDONS_DIR="/mnt/extra-addons"
ODOO_CONF="/etc/odoo/odoo.conf"
INSTALLED_MARKER="$ODOO_DATA_DIR/.odoo_initialized"
OWNER_PASS_MARKER="$ODOO_DATA_DIR/.odoo_owner_pass"

echo -e "${YELLOW}[INFO]${NC} Starting Odoo initialization..."
echo -e "${YELLOW}[INFO]${NC} Odoo version: 19.0"

# ============================================================================
# STEP 1: Wait for PostgreSQL to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for PostgreSQL to be ready..."

# Extract database connection details from environment variables
DB_HOST="${ODOO_DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${ODOO_DB_USER:-odoo}"
DB_PASSWORD="${ODOO_DB_PASSWORD:-odoo}"

max_attempts=60
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" > /dev/null 2>&1; then
        echo -e "${GREEN}[SUCCESS]${NC} PostgreSQL is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo -e "${YELLOW}[WAIT]${NC} PostgreSQL not ready yet... (attempt $attempt/$max_attempts)"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}[ERROR]${NC} PostgreSQL failed to become ready after $max_attempts attempts"
    exit 1
fi

# Wait a bit more to ensure PostgreSQL is fully initialized
sleep 3

# ============================================================================
# STEP 2: Create Odoo configuration file (always)
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Configuring Odoo..."

# Ensure configuration directory exists
mkdir -p "$(dirname "$ODOO_CONF")"

# Master password for database manager
ODOO_MASTER_PASSWORD="${ODOO_MASTER_PASSWORD:-}"

# The database a browser reaches: the deployment's own, through dbfilter.
DB_NAME="${ODOO_DB_NAME:-odoo}"
if ! ODOO_DBFILTER="$(odoo_dbfilter "$DB_NAME")"; then
    echo -e "${RED}[ERROR]${NC} ODOO_DB_NAME isn't a database name Odoo accepts: 2 or more letters, digits, '_', '.' or '-', starting with a letter or a digit"
    exit 1
fi

# Create Odoo configuration file
echo -e "${YELLOW}[INFO]${NC} Creating Odoo configuration file at $ODOO_CONF..."

# The file holds the database and master passwords. It starts out empty, as
# odoo's with mode 600, so no other user can read it at any moment, even
# before a password goes in. Odoo reads it as odoo.
install -m 600 -o odoo -g odoo /dev/null "$ODOO_CONF"
cat > "$ODOO_CONF" <<EOF
[options]
; Database configuration
db_host = $DB_HOST
db_port = $DB_PORT
db_user = $DB_USER
db_password = $DB_PASSWORD

; Data directory
data_dir = $ODOO_DATA_DIR

; Addons path. /mnt/extra-addons (its own volume, for custom modules) is
; written as a pattern: Odoo expands it at every start and skips it without a
; warning while no module is in it, then loads it once one is.
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons*

; The database manager stays locked: with list_db = False, Odoo refuses every
; /web/database action and the database list, and dbfilter lets a browser
; reach this deployment's database only. dbfilter, not db_name: Odoo 19
; creates a missing db_name database at every start, with the admin
; password "admin". odoo db (dump, load) turns the lock off for itself. The
; AI Assistant can open the manager for one task (the odoo skill's
; harden-db-manager playbook), and the next start locks it again.
list_db = False
dbfilter = $ODOO_DBFILTER

; Master password for database manager
; This password protects database management operations (create, delete, backup, restore)
EOF

# Set master password if provided
if [ -n "$ODOO_MASTER_PASSWORD" ]; then
    echo "admin_passwd = $ODOO_MASTER_PASSWORD" >> "$ODOO_CONF"
    echo -e "${GREEN}[SUCCESS]${NC} Master password configured from environment variable"
else
    # Generate a random master password. It goes into the config file only:
    # the log says where it is, never what it is.
    GENERATED_PASSWD=$(python3 -c 'import base64, os; print(base64.b64encode(os.urandom(24)).decode())')
    echo "admin_passwd = $GENERATED_PASSWD" >> "$ODOO_CONF"
    echo -e "${YELLOW}[WARNING]${NC} No ODOO_MASTER_PASSWORD provided. Generated a random master password for this start."
    echo -e "${YELLOW}[WARNING]${NC} It is admin_passwd in $ODOO_CONF (root and odoo can read it). It isn't shown here."
fi

# Set proper permissions on configuration file: odoo's, read and written by
# odoo only. Odoo writes to it when someone sets a new master password in its
# database manager, which is locked unless opened for one task, and the next
# start writes ODOO_MASTER_PASSWORD back.
chmod 600 "$ODOO_CONF"
chown odoo:odoo "$ODOO_CONF"

echo -e "${GREEN}[SUCCESS]${NC} Odoo configuration file created successfully"

# ============================================================================
# STEP 3: Give the volumes to the odoo user
# ============================================================================
# Odoo runs as odoo, so its data folder has to be odoo's. Root sees to that
# here, before anything runs as odoo:
#   - A new cluster disk has a top folder of root's (mode 755) with lost+found
#     in it. While the top folder is root's, it goes to odoo. Its mode stays.
#   - An older image ran Odoo as root, and it left files of root's in
#     /var/lib/odoo: filestore folders, sessions, backups, the marker file.
#     Every file there that isn't odoo's goes to odoo. That pass reads the
#     whole folder, the filestore included, so it runs once per volume: it
#     then writes $OWNER_PASS_MARKER, and later starts skip it (the start
#     has 360 s before the health check gives up). Removing the marker runs
#     it again at the next start.
#   - /mnt/extra-addons holds module code, which Odoo has to read. A module
#     copied in as root can be unreadable to odoo, so every file there that
#     isn't odoo's goes to odoo, at every start: modules come and go between
#     starts, and the folder is small.
# lost+found belongs to the disk and stays as it is in both.

# claim_top_folder DIR: gives DIR to odoo while it is root's.
claim_top_folder() {
    mkdir -p "$1"
    if [ "$(stat -c %u "$1")" = 0 ]; then
        chown odoo:odoo "$1"
        echo -e "${YELLOW}[INFO]${NC} $1 was root's (a new disk). It is odoo's now."
    fi
}
claim_top_folder "$ODOO_DATA_DIR"
claim_top_folder "$ODOO_ADDONS_DIR"

# give_to_odoo DIR WHY: gives every file under DIR that isn't odoo's to odoo,
# lost+found aside. find looks for one first, so a folder with nothing to fix
# costs one pass. -h: a symbolic link is given to odoo itself, and what it
# points to is left alone (find never follows one).
give_to_odoo() {
    if [ -n "$(find "$1" -mindepth 1 -path "$1/lost+found" -prune -o ! -user odoo -print -quit)" ]; then
        echo -e "${YELLOW}[INFO]${NC} Giving the files in $1 that aren't odoo's to odoo ($2)..."
        find "$1" -mindepth 1 -path "$1/lost+found" -prune -o ! -user odoo -exec chown -h odoo:odoo {} +
    fi
}

# write_as_odoo FILE: writes the date into FILE as odoo, with no environment
# but PATH. FILE is in odoo's folder, so code that ran as odoo can have left
# a link at that path: root removes whatever is there (rm never follows a
# link), and odoo writes the file, so no link can make root write anywhere
# else.
write_as_odoo() {
    rm -rf -- "$1"
    # shellcheck disable=SC2016  # the script is for the sh that runs as odoo
    env -i PATH="$PATH" setpriv --reuid=odoo --regid=odoo --init-groups --no-new-privs -- sh -c 'date > "$1"' sh "$1"
}

if [ -f "$OWNER_PASS_MARKER" ] && [ ! -L "$OWNER_PASS_MARKER" ]; then
    echo -e "${GREEN}[INFO]${NC} The ownership pass over $ODOO_DATA_DIR ran at an earlier start ($OWNER_PASS_MARKER). Skipping it."
else
    give_to_odoo "$ODOO_DATA_DIR" "an older image ran Odoo as root"
    write_as_odoo "$OWNER_PASS_MARKER"
fi
give_to_odoo "$ODOO_ADDONS_DIR" "modules Odoo has to read"

# The AI Assistant's backups go in $ODOO_DATA_DIR/backups, and odoo db dump,
# which runs as odoo, can't write into a folder of root's. The odoo skill's
# backup.sh makes a missing folder as odoo's, mode 700, from skill 0.1.5 on;
# older ones made it as root's. So the folder is made here too, as odoo's,
# and set to mode 700 at every start: only odoo and root can read the backups
# in it. Code that ran as odoo can have left something else
# at that path, a file or a link. That goes first, because root never follows
# a link in odoo's folder (chmod would change what the link points to).
BACKUPS_DIR="$ODOO_DATA_DIR/backups"
if [ -L "$BACKUPS_DIR" ] || { [ -e "$BACKUPS_DIR" ] && [ ! -d "$BACKUPS_DIR" ]; }; then
    rm -f -- "$BACKUPS_DIR"
fi
if [ ! -d "$BACKUPS_DIR" ]; then
    install -d -o odoo -g odoo -m 700 "$BACKUPS_DIR"
fi
chmod 700 "$BACKUPS_DIR"

# ============================================================================
# STEP 4: Check if Odoo is already initialized
# ============================================================================

if [ -f "$INSTALLED_MARKER" ]; then
    echo -e "${GREEN}[INFO]${NC} Odoo appears to be already initialized. Skipping database initialization."
    echo -e "${GREEN}[INFO]${NC} Marker file found: $INSTALLED_MARKER"
else
    echo -e "${YELLOW}[INFO]${NC} First-time initialization detected. Running setup..."

    # Run the installation script
    /clouve/odoo/installer/install.sh

    # Create marker file to indicate initialization is complete. A dangling
    # link at that path also lands here, since [ -f ] follows it;
    # write_as_odoo removes it first.
    write_as_odoo "$INSTALLED_MARKER"
    echo -e "${GREEN}[SUCCESS]${NC} Odoo initialization completed!"
fi

# ============================================================================
# STEP 5: Update configuration (runs on every startup)
# ============================================================================

# Run the configuration update script to handle URL changes and other dynamic config
if [ -f /clouve/odoo/installer/update-config.sh ]; then
    echo -e "${YELLOW}[INFO]${NC} Running configuration update script..."
    /clouve/odoo/installer/update-config.sh
fi

# ============================================================================
# CLOUVE-OPS SSHD: shell channel for the Magneto Agent container's Claude Code
# ============================================================================
# Started as root, before Odoo drops to the odoo user. It applies the per-pod
# CLOUVE_OPS_PASSWORD to the clouve-ops user via chpasswd, then execs sshd -D.
# The subshell exits at once, so sshd's parent is tini (PID 1), never Odoo,
# and sshd keeps running when Odoo restarts itself. It stops with the
# container: tini, PID 1, exits when Odoo does.
( /clouve/odoo/installer/start-clouve-ops-sshd.sh & )

# ============================================================================
# STEP 6: Start Odoo, as the odoo user
# ============================================================================

echo -e "${GREEN}[SUCCESS]${NC} Odoo is ready to use!"
echo -e "${GREEN}[INFO]${NC} Access Odoo at: http://localhost:8069"
echo -e "${YELLOW}[INFO]${NC} Starting Odoo server as the odoo user..."

# Odoo reads every setting from odoo.conf, the database password included.
# The official image's /entrypoint.sh isn't used (the Dockerfile removes it):
# it puts --db_host, --db_port, --db_user and --db_password on Odoo's command
# line for each one odoo.conf lacks, and any process in the container can
# read a command line. Step 1 has waited for PostgreSQL already.
#
# No secret in this environment goes on to Odoo: odoo_unset_secrets takes
# out every variable whose name is a secret's, and PGPASSWORD. Odoo doesn't
# need them, and a process of odoo's can read Odoo's environment: with
# CLOUVE_OPS_PASSWORD, that would be root over SSH. A PGPASSWORD would also
# win over odoo.conf's db_password. PID 1 (tini) keeps them, for the AI
# Assistant, which reads its settings from PID 1's environment.
odoo_unset_secrets

# /usr/local/bin/odoo drops to the odoo user and becomes Odoo, exec after
# exec, so Odoo is tini's child. tini passes it SIGHUP (the AI Assistant's
# restart: Odoo re-executes itself, still as odoo) and docker stop's SIGTERM.
# "odoo ARGS" and "-ARGS" start Odoo with ARGS (CMD is "odoo"). Any other
# command runs as given, as root.
[ $# -gt 0 ] || set -- odoo
case "$1" in
    odoo) shift; exec /usr/local/bin/odoo "$@" -c "$ODOO_CONF" ;;
    -*) exec /usr/local/bin/odoo "$@" -c "$ODOO_CONF" ;;
    *) exec "$@" ;;
esac

