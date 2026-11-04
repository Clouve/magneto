# Odoo Custom Docker Images

This directory contains the custom Docker images for the Odoo application bundle. These images extend the official Odoo and PostgreSQL images with automatic initialization, bundled scripts, and Clouve-specific optimizations.

## Directory Structure

```
image/
├── Dockerfile                    # Custom Odoo image
├── build.config                  # Build configuration
├── installer/
│   ├── entrypoint.sh            # Main entrypoint script (runs as root, starts Odoo as odoo)
│   ├── install.sh               # Installation/initialization script
│   ├── update-config.sh         # Sets web.base.url from ODOO_URL at every start
│   ├── odoo                     # /usr/local/bin/odoo: runs Odoo as the odoo user
│   ├── start-clouve-ops-sshd.sh # The clouve-ops sshd for the AI Assistant
│   └── clouve-ops-sshd.conf     # sshd settings for clouve-ops
└── postgres/
    └── Dockerfile               # Custom PostgreSQL image
```

## Images

### 1. Odoo Application Image (`r.clv.zone/e2eorg/odoo`)

**Base Image:** `odoo:19.0`

**Enhancements:**
- Odoo runs as the `odoo` user, never as root (see "Users and passwords" below)
- Bundled initialization scripts (no host mounts required)
- Automatic database connection with retry logic
- PostgreSQL client tools for database connectivity
- Health check utilities (curl, netcat)
- Idempotent operations (safe to restart)
- Installation state detection

**Added Tools:**
- `postgresql-client` - PostgreSQL command-line tools
- `curl` - HTTP client for health checks
- `netcat-openbsd` - Network connectivity testing
- `tini` - PID 1: it runs the entrypoint, reaps finished processes whose parent has gone (such as what an SSH
  session leaves behind) and passes signals on to Odoo
- `openssh-server` and `sudo` - The clouve-ops channel for the AI Assistant. The image holds no SSH host keys: each
  container makes its own when its sshd starts, and the PostgreSQL image does the same

**Entrypoint Flow:**
0. tini starts as PID 1 and runs the entrypoint, as root
1. Wait for PostgreSQL to be ready (with retry logic)
2. Write `/etc/odoo/odoo.conf`: the `odoo` user's, mode 600
3. Give the volumes to the `odoo` user (a new disk, or files of root's that an older image left)
4. Check if Odoo is already initialized (marker file), and run the installation script if not
5. Update `web.base.url`, and start the clouve-ops sshd (as root, detached, so its parent is tini)
6. Start the Odoo server as the `odoo` user, with `odoo.conf` and no password on its command line or in its
   environment

### 2. PostgreSQL Database Image (`r.clv.zone/e2eorg/odoo-postgres`)

**Base Image:** `postgres:18`

**Purpose:**
- Re-packaged official PostgreSQL image, with the clouve-ops channel for the AI Assistant (`openssh-server` and
  `sudo`) and no SSH host keys: each container makes its own when its sshd starts
- `tini` as PID 1, with PostgreSQL as its child. The entrypoint starts the sshd detached, so its parent is tini too.
  PostgreSQL then never sees a process it didn't start: when one of those ends with an error or a signal, PostgreSQL
  takes it for a crashed server process and ends every connection to restart
- Hosted in Clouve registry to avoid Docker Hub rate limits
- Multi-platform support (amd64, arm64)
- Optimized for Odoo compatibility

## Building Images

### Prerequisites

- Docker with BuildKit enabled
- Multi-platform build support (buildx)
- Access to `r.clv.zone/e2eorg` registry

### Build Commands

**Build Odoo image:**
```bash
cd magneto/apps/odoo/image
docker buildx build --platform linux/amd64,linux/arm64 \
  -t r.clv.zone/e2eorg/odoo \
  -t r.clv.zone/e2eorg/odoo:19.0 \
  --push .
```

**Build PostgreSQL image:**
```bash
cd magneto/apps/odoo/image/postgres
docker buildx build --platform linux/amd64,linux/arm64 \
  -t r.clv.zone/e2eorg/odoo-postgres \
  -t r.clv.zone/e2eorg/odoo-postgres:18 \
  --push .
```

### Using build.config

The `build.config` file defines:
- `APP_IMAGE="odoo"` - Application image name
- `POSTGRES_IMAGE="odoo-postgres"` - Database image name
- `POSTGRES_NAME="PostgreSQL"` - Human-readable database name

This configuration is used by build scripts to automate the image building process.

## Environment Variables

### Odoo Container

| Variable | Description | Default |
|----------|-------------|---------|
| `ODOO_DB_HOST` | PostgreSQL hostname | `db` |
| `ODOO_DB_USER` | PostgreSQL username | `odoo` |
| `ODOO_DB_PASSWORD` | PostgreSQL password | `odoo` |
| `DB_PORT` | PostgreSQL port | `5432` |
| `ODOO_DB_NAME` | Odoo database name | `odoo` |
| `ODOO_ADMIN_EMAIL` | Admin user email (used as login) | `admin@example.com` |
| `ODOO_ADMIN_PASSWORD` | Admin user password | `Admin@123` |
| `ODOO_MASTER_PASSWORD` | Master password for database management | (auto-generated) |

### PostgreSQL Container

| Variable | Description | Default |
|----------|-------------|---------|
| `POSTGRES_DB` | Database name | `postgres` |
| `POSTGRES_USER` | Database username | `odoo` |
| `POSTGRES_PASSWORD` | Database password | `odoo` |

## Users and passwords

The container starts as root: tini, the entrypoint and the clouve-ops sshd run as root. Odoo never runs as root.

- The entrypoint ends with `exec /usr/local/bin/odoo ... -c /etc/odoo/odoo.conf`. That script drops to the `odoo`
  user (its user, group and own groups, through `setpriv`) and execs the real `/usr/bin/odoo`. Every step is an exec,
  so the Odoo server is tini's child, and the restart (`grep -q odoo /proc/1/cmdline && sudo kill -HUP 1`) still
  reaches it. Odoo re-executes itself in place, still as `odoo`. `setpriv` also sets `no_new_privs`, which Odoo and
  everything it starts keep (`wkhtmltopdf` for PDF reports, for one): none of them can gain rights through a setuid
  program such as `sudo` or `su`.
- `/usr/local/bin/odoo` comes before `/usr/bin/odoo` in root's PATH and in sudo's `secure_path`, and the build fails
  if it doesn't. So the Odoo commands that root runs run as `odoo` too: `sudo odoo shell ...`,
  `sudo odoo ... --stop-after-init`, and the `odoo db dump` in the AI Assistant's `backup.sh`. Their arguments,
  stdin, environment and exit status stay the same, and `HOME` becomes `/var/lib/odoo`. A root Odoo would leave files
  of root's in `/var/lib/odoo` (filestore folders, sessions), and the server couldn't write to them after that.
- Before anything runs as `odoo`, the entrypoint gives the top folders of `/var/lib/odoo` and `/mnt/extra-addons` to
  `odoo` while they are root's (a new cluster disk), and keeps their mode. It also gives `odoo` every file in
  `/var/lib/odoo` that isn't `odoo`'s, since older images ran Odoo as root and left such files. `find` looks for one
  first, so a start with nothing to fix costs one pass over the folder. `lost+found` stays as it is. The modules in
  `/mnt/extra-addons` keep their owner, because Odoo only reads them (the AI Assistant gives the ones it adds to
  `odoo`).
- The entrypoint makes `/var/lib/odoo/backups` as `odoo`'s when it is missing, and sets it to mode 700 at every start,
  so only `odoo` and root can read the backups. `backup.sh` runs as root and would make the folder as root's, and the
  dump, which runs as `odoo`, couldn't write into it. If the folder goes missing while the container runs,
  `backup.sh` fails until the next start.
- Root never follows a link in `odoo`'s folders, because code running as `odoo` can leave one there. The ownership
  pass uses `find` (which doesn't follow links) and `chown -h`. A file or a link where the `backups` folder should be
  is removed before the folder is made. The install marker (`/var/lib/odoo/.odoo_initialized`) is written as `odoo`,
  after root removes whatever was at that path.
- Odoo gets the database password from `odoo.conf` only. The file is `odoo`'s, mode 600 from the moment it is made, so
  no other user can read it. Odoo writes to it too, when someone sets a new master password in its database manager.
- No password goes on a command line, where any process in the container can read it. The official image's
  `/entrypoint.sh` put `--db_host`, `--db_port`, `--db_user` and `--db_password` on Odoo's command line for each one
  `odoo.conf` lacks. The Dockerfile removes it, and the entrypoint waits for PostgreSQL itself. The installer hands the
  admin's password to its `odoo shell` step through that command's environment.
- The entrypoint takes `ODOO_DB_PASSWORD`, `ODOO_MASTER_PASSWORD`, `ODOO_ADMIN_PASSWORD`, `CLOUVE_OPS_PASSWORD` and
  `PGPASSWORD` out of the environment it passes to Odoo. Any process of `odoo`'s could read them there, and
  `CLOUVE_OPS_PASSWORD` would give it root over SSH. Odoo would also take a `PGPASSWORD` over `odoo.conf`. PID 1 keeps
  them, because the AI Assistant reads its settings from PID 1's environment.
- Without `ODOO_MASTER_PASSWORD`, the entrypoint makes up a new master password at every start and writes it to
  `odoo.conf` (`admin_passwd`) only. The log says where it is, never what it is.

`bash tests/odoo-non-root.test.sh` checks all of this on a running pair of containers built from the current source,
on new disks and on a disk with files of root's. It takes about a minute when the images are cached.

## Initialization Process

### First-Time Setup

1. **PostgreSQL Readiness Check**
   - Uses `pg_isready` to verify database is accepting connections
   - Retries up to 60 times with 2-second intervals
   - Fails if database doesn't become ready

2. **Installation Detection**
   - Checks for marker file: `/var/lib/odoo/.odoo_initialized`
   - If marker exists, skips initialization
   - If marker doesn't exist, runs installation script

3. **Database Initialization**
   - Verifies PostgreSQL connection using `psql`
   - Creates necessary directories (the entrypoint has already given them to the `odoo` user)
   - Sets up Odoo data directory (`/var/lib/odoo`)
   - Sets up addons directory (`/mnt/extra-addons`), the custom-modules volume. The `odoo.conf` that the
     entrypoint writes on every start lists it in `addons_path` as the pattern `/mnt/extra-addons*`, so Odoo
     skips it without a warning while it holds no module and loads it at the next start once one is there

4. **Marker File Creation**
   - Creates `.odoo_initialized` marker file
   - Contains timestamp of initialization
   - Prevents re-initialization on restart

### Subsequent Restarts

- Detects existing marker file
- Skips initialization steps
- Directly starts Odoo server
- Preserves all data and configuration

## Authentication

### Login Credentials

After automatic initialization, you can log in with:
- **Email/Login**: Value from `ODOO_ADMIN_EMAIL` environment variable (default: `admin@example.com`)
- **Password**: Value from `ODOO_ADMIN_PASSWORD` environment variable (default: `Admin@123`)
- **Database**: Value from `ODOO_DB_NAME` environment variable (default: `odoo`)

### Email-Based Login

This custom Docker image is configured to support **email-based authentication** out of the box. The admin user's login field is automatically set to the email address specified in the `ODOO_ADMIN_EMAIL` environment variable.

**How it works:**
- The `ODOO_ADMIN_EMAIL` environment variable serves dual purpose: it sets both the login field and email field
- During initialization, the admin user's `login` field in the database is set to this email address
- Users can log in using their email address as the username
- This eliminates redundancy and potential configuration errors

**Example:**
- ✅ **Login with email**: `admin@example.com` / `Admin@123`
- ✅ **Login field in database**: `admin@example.com`
- ✅ **Email field in database**: `admin@example.com`

**Configuration:**

In `docker-compose.yml`:
```yaml
environment:
  ODOO_ADMIN_EMAIL: admin@example.com
  ODOO_ADMIN_PASSWORD: Admin@123
```

In `clv-docker-compose.yml` (production template):
```yaml
environment:
  ODOO_ADMIN_EMAIL: applicationEmail
  ODOO_ADMIN_PASSWORD: applicationPassword
```

**Benefits:**
- ✅ **Single source of truth**: One variable for both login and email
- ✅ **No redundancy**: Eliminates potential configuration mismatches
- ✅ **User-friendly**: Login with email address
- ✅ **Modern UX**: Consistent with modern web applications
- ✅ **No custom modules**: Works with Odoo's standard authentication
- ✅ **Simple configuration**: Fewer environment variables to manage

**Note:** While the login field is set to an email address, Odoo still uses its standard username-based authentication internally. The email address simply serves as the username value.

### Password Management

Passwords are hashed using Odoo's built-in password hashing mechanism (pbkdf2_sha512). The automatic initialization script:
1. Creates the admin user during database initialization
2. Sets the password using Odoo's ORM (which automatically hashes it)
3. Stores the hashed password in the `res_users` table

To change the admin password after initialization:
1. Log in to Odoo with the current credentials
2. Navigate to Settings → Users & Companies → Users
3. Select the admin user
4. Click "Change Password"

## Differences from Official Images

### Odoo Image

| Feature | Official Image | Custom Image |
|---------|---------------|--------------|
| Initialization | Manual | Automatic |
| Database Wait | None | Built-in retry logic |
| Scripts | Host-mounted | Bundled in image |
| State Detection | None | Marker file system |
| PostgreSQL Tools | Not included | Included |
| Health Checks | Basic | Enhanced with curl |

### PostgreSQL Image

| Feature | Official Image | Custom Image |
|---------|---------------|--------------|
| Registry | Docker Hub | Clouve Registry |
| Rate Limits | Yes | No |
| Multi-platform | Manual | Automated |

## Comparison with WordPress Bundle

The Odoo custom images follow the same patterns as the WordPress bundle:

**Similarities:**
- Bundled entrypoint scripts (no host mounts)
- Automatic initialization on first run
- Database connection retry logic
- Installation state detection
- Multi-platform support
- Custom registry hosting

**Differences:**
- Odoo uses PostgreSQL instead of MariaDB
- Odoo initialization is simpler (no wp-cli equivalent needed)
- Odoo database creation happens via web UI on first access
- WordPress installs via CLI, Odoo via web interface

## Testing

### Local Build and Test

```bash
# Build images locally
cd magneto/apps/odoo
docker-compose build

# Start containers
docker-compose up -d

# Check logs
docker-compose logs -f odoo

# Access Odoo
open http://localhost:8069
```

### Verify Initialization

```bash
# Run the image's own checks: Odoo as the odoo user, no password on a command line
bash tests/odoo-non-root.test.sh    # from the magneto folder

# Check marker file
docker exec odoo_app ls -la /var/lib/odoo/.odoo_initialized

# Check PostgreSQL connection
docker exec odoo_app pg_isready -h odoo-postgres -U odoo

# Check Odoo process
docker exec odoo_app ps aux | grep odoo
```

## Troubleshooting

### Database Connection Issues

```bash
# Check PostgreSQL is running
docker-compose ps odoo-postgres

# Test connection manually
docker exec odoo_app psql -h odoo-postgres -U odoo -d postgres -c "SELECT 1"

# Check environment variables
docker exec odoo_app env | grep -E "ODOO_DB_HOST|ODOO_DB_USER|ODOO_DB_PASSWORD"
```

### Initialization Problems

```bash
# Remove marker file to force re-initialization
docker exec odoo_app rm /var/lib/odoo/.odoo_initialized

# Restart container
docker-compose restart odoo

# Watch initialization logs
docker-compose logs -f odoo
```

### Build Issues

```bash
# Clean build (no cache)
docker-compose build --no-cache

# Check Dockerfile syntax
docker build --check image/

# Verify base image availability
docker pull odoo:19.0
docker pull postgres:18
```

## Maintenance

### Updating Base Images

When new versions of Odoo or PostgreSQL are released:

1. Update `FROM` line in Dockerfiles
2. Update version tags in build commands
3. Test thoroughly in development
4. Update `clv-docker-compose.yml` with new tags
5. Rebuild and push to registry

### Breaking Changes and Upgrade Notes

#### PostgreSQL 18 Volume Mount Change

**Important:** PostgreSQL 18+ changed the recommended data directory structure. When upgrading from PostgreSQL 16 or earlier:

**Old mount point (PostgreSQL ≤17):**
```yaml
volumes:
  - postgres_data:/var/lib/postgresql/data
```

**New mount point (PostgreSQL 18+):**
```yaml
volumes:
  # PostgreSQL 18+ uses /var/lib/postgresql as the mount point
  # This allows pg_upgrade to work properly with version-specific subdirectories
  - postgres_data:/var/lib/postgresql
```

**Why this change?**
- PostgreSQL 18+ stores data in version-specific subdirectories (e.g., `/var/lib/postgresql/18/data`)
- This enables proper `pg_upgrade --link` functionality for major version upgrades
- The new structure is more flexible for managing multiple PostgreSQL versions

**Migration Path:**
If you have existing data on PostgreSQL 16 or earlier:
1. Backup your database using `pg_dump`
2. Update volume mount to `/var/lib/postgresql`
3. Recreate containers with fresh volumes
4. Restore data using `pg_restore`

Alternatively, use `pg_upgrade` for in-place upgrades (advanced users only).

### Security Updates

- Monitor official image security advisories
- Rebuild images when base images are updated
- Update dependencies in Dockerfile if needed
- Test after rebuilding

## Registry Management

### Pushing Images

```bash
# Login to registry
docker login r.clv.zone

# Push Odoo image
docker push r.clv.zone/e2eorg/odoo
docker push r.clv.zone/e2eorg/odoo:19.0

# Push PostgreSQL image
docker push r.clv.zone/e2eorg/odoo-postgres
docker push r.clv.zone/e2eorg/odoo-postgres:18
```

### Pulling Images

```bash
# Pull latest versions
docker pull r.clv.zone/e2eorg/odoo
docker pull r.clv.zone/e2eorg/odoo-postgres

# Pull specific versions
docker pull r.clv.zone/e2eorg/odoo:19.0
docker pull r.clv.zone/e2eorg/odoo-postgres:18
```

## License

These custom images are based on:
- Official Odoo image (LGPL-3.0)
- Official PostgreSQL image (PostgreSQL License)

Custom scripts and modifications are maintained by the Clouve Platform team.

