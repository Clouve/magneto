# Odoo Custom Docker Images

This directory contains the custom Docker images for the Odoo application bundle. These images extend the official Odoo and PostgreSQL images with automatic initialization, bundled scripts, and Clouve-specific optimizations.

## Directory Structure

```
image/
├── Dockerfile                    # Custom Odoo image
├── build.config                  # Build configuration
├── installer/
│   ├── entrypoint.sh            # Main entrypoint script
│   └── install.sh               # Installation/initialization script
└── db/
    └── Dockerfile               # Custom PostgreSQL image
```

## Images

### 1. Odoo Application Image (`r.clv.zone/e2eorg/odoo:latest`)

**Base Image:** `odoo:19.0`

**Enhancements:**
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

**Entrypoint Flow:**
1. Wait for PostgreSQL to be ready (with retry logic)
2. Check if Odoo is already initialized (marker file)
3. Run installation script if first-time setup
4. Start Odoo server

### 2. PostgreSQL Database Image (`r.clv.zone/e2eorg/odoo-postgres:latest`)

**Base Image:** `postgres:18`

**Purpose:**
- Re-packaged official PostgreSQL image
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
cd magneto/dkr/apps/odoo/image
docker buildx build --platform linux/amd64,linux/arm64 \
  -t r.clv.zone/e2eorg/odoo:latest \
  -t r.clv.zone/e2eorg/odoo:19.0 \
  --push .
```

**Build PostgreSQL image:**
```bash
cd magneto/dkr/apps/odoo/image/db
docker buildx build --platform linux/amd64,linux/arm64 \
  -t r.clv.zone/e2eorg/odoo-postgres:latest \
  -t r.clv.zone/e2eorg/odoo-postgres:18 \
  --push .
```

### Using build.config

The `build.config` file defines:
- `APP_IMAGE="odoo"` - Application image name
- `DB_IMAGE="odoo-postgres"` - Database image name
- `DB_NAME="PostgreSQL"` - Human-readable database name

This configuration is used by build scripts to automate the image building process.

## Environment Variables

### Odoo Container

| Variable | Description | Default |
|----------|-------------|---------|
| `POSTGRES_DB_HOST` | PostgreSQL hostname | `db` |
| `POSTGRES_DB_USER` | PostgreSQL username | `odoo` |
| `POSTGRES_DB_PASSWORD` | PostgreSQL password | `odoo` |
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
   - Creates necessary directories with proper permissions
   - Sets up Odoo data directory (`/var/lib/odoo`)
   - Sets up addons directory (`/mnt/extra-addons`)

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
cd magneto/dkr/apps/odoo
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
docker exec odoo_app env | grep -E "POSTGRES_DB_HOST|POSTGRES_DB_USER|POSTGRES_DB_PASSWORD"
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
docker push r.clv.zone/e2eorg/odoo:latest
docker push r.clv.zone/e2eorg/odoo:19.0

# Push PostgreSQL image
docker push r.clv.zone/e2eorg/odoo-postgres:latest
docker push r.clv.zone/e2eorg/odoo-postgres:18
```

### Pulling Images

```bash
# Pull latest versions
docker pull r.clv.zone/e2eorg/odoo:latest
docker pull r.clv.zone/e2eorg/odoo-postgres:latest

# Pull specific versions
docker pull r.clv.zone/e2eorg/odoo:19.0
docker pull r.clv.zone/e2eorg/odoo-postgres:18
```

## License

These custom images are based on:
- Official Odoo image (LGPL-3.0)
- Official PostgreSQL image (PostgreSQL License)

Custom scripts and modifications are maintained by the Clouve Platform team.

