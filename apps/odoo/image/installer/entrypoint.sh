#!/bin/bash

# Odoo Docker Entrypoint Script
# tini, PID 1, runs this script as root. It:
# 1. Waits for PostgreSQL to be ready
# 2. Writes /etc/odoo/odoo.conf, which holds the passwords: it is odoo's, and
#    no other user can read it
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

# Odoo configuration
ODOO_DATA_DIR="/var/lib/odoo"
ODOO_ADDONS_DIR="/mnt/extra-addons"
ODOO_CONF="/etc/odoo/odoo.conf"
INSTALLED_MARKER="$ODOO_DATA_DIR/.odoo_initialized"

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
# odoo only (Odoo saves a new master password set in its database manager here)
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
#     Every file there that isn't odoo's goes to odoo. find looks for one
#     first, so a start with nothing to fix costs one pass over the folder.
# lost+found belongs to the disk and stays as it is. /mnt/extra-addons only
# has to be readable, since Odoo reads the modules in it and never writes
# there. Its top folder goes to odoo on a new disk, as the first install
# always did, and the modules in it keep their owner (the AI Assistant gives
# the ones it adds to odoo).

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

if [ -n "$(find "$ODOO_DATA_DIR" -mindepth 1 -path "$ODOO_DATA_DIR/lost+found" -prune -o ! -user odoo -print -quit)" ]; then
    echo -e "${YELLOW}[INFO]${NC} Giving the files in $ODOO_DATA_DIR that aren't odoo's to odoo (an older image ran Odoo as root)..."
    # -h: a symbolic link is given to odoo itself, and what it points to is left alone.
    find "$ODOO_DATA_DIR" -mindepth 1 -path "$ODOO_DATA_DIR/lost+found" -prune -o ! -user odoo -exec chown -h odoo:odoo {} +
fi

# The AI Assistant's backups go in $ODOO_DATA_DIR/backups. Its backup.sh runs
# as root and makes that folder when it is missing, and odoo db dump, which
# runs as odoo, couldn't write into a folder of root's. So the folder is made
# here, as odoo's, and set to mode 700 at every start: only odoo and root can
# read the backups in it. Code that ran as odoo can have left something else
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

    # Create marker file to indicate initialization is complete. It is in
    # odoo's folder, so code that ran as odoo can have left a link at that
    # path (a dangling one also lands here, since [ -f ] follows it). Root
    # removes whatever is there (rm never follows a link), and the marker is
    # written as odoo, so no link can make root write a file anywhere else.
    rm -rf -- "$INSTALLED_MARKER"
    # shellcheck disable=SC2016  # the script is for the sh that runs as odoo
    setpriv --reuid=odoo --regid=odoo --init-groups --no-new-privs -- sh -c 'date > "$1"' sh "$INSTALLED_MARKER"
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
# None of the passwords in this environment goes on to Odoo. Odoo doesn't
# need them, and a process of odoo's can read Odoo's environment: with
# CLOUVE_OPS_PASSWORD, that would be root over SSH. A PGPASSWORD would also
# win over odoo.conf's db_password. PID 1 (tini) keeps them, for the AI
# Assistant, which reads its settings from PID 1's environment.
unset ODOO_DB_PASSWORD ODOO_MASTER_PASSWORD ODOO_ADMIN_PASSWORD CLOUVE_OPS_PASSWORD PGPASSWORD

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

