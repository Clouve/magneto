# Odoo Docker Application

Odoo deployment for Clouve marketplace using custom Docker images. Odoo is a comprehensive, open-source enterprise resource planning (ERP) platform that streamlines business operations across sales, CRM, project management, inventory, accounting, and more.

## Overview

This bundle includes:
- **Odoo 19.0**: Latest stable version with modern features
- **PostgreSQL 16**: Reliable and performant database backend
- **Custom Docker Images**: Production-ready images with automatic initialization
- **Security Configuration**: A master password, and Odoo's database manager locked at every start
- **Persistent Storage**: Data persists across container restarts

## Quick Start

```bash
# Start containers (will pull images automatically)
docker-compose up -d

# Stop containers
docker-compose down
```

## Access Odoo

- **URL**: http://localhost:8069
- **Initial Setup**: The first start creates the database (`ODOO_DB_NAME`, default `odoo`) and its admin account by
  itself; sign in with `ODOO_ADMIN_EMAIL` and `ODOO_ADMIN_PASSWORD`
- **Database Manager**: Locked at every start (see Security Configuration below)

## Configuration

### Environment Variables

Edit `docker-compose.yml` to customize environment variables:

#### Database Connection
- `POSTGRES_DB_HOST`: PostgreSQL hostname (default: odoo-postgres)
- `POSTGRES_DB_USER`: PostgreSQL username (default: odoo)
- `POSTGRES_DB_PASSWORD`: PostgreSQL password (default: odoo_password)

#### Security Configuration
- `ODOO_MASTER_PASSWORD`: Master password for database manager (default: odoo_master_password)

**Important**: The master password protects database management operations (create, delete, backup, restore). This is different from the admin password for individual Odoo databases. The image also locks the database manager at every start (see "Verifying Configuration" below).

### Configuration File

The custom Docker image automatically creates `/etc/odoo/odoo.conf` with:
- Database connection settings
- Data directory configuration
- Addons path configuration
- Master password protection

For advanced configuration, you can mount a custom `odoo.conf` file:

```yaml
volumes:
  - ./odoo.conf:/etc/odoo/odoo.conf:ro
  - odoo_data:/var/lib/odoo
  - odoo_addons:/mnt/extra-addons
```

## Features

### Core Features
- **Odoo 19.0**: Latest stable version with modern features
- **PostgreSQL 16**: Reliable and performant database backend
- **Modular Architecture**: Install only the apps you need
- **Automated Installation**: Easy setup on first run
- **Persistent Storage**: Data persists across container restarts
- **Health Checks**: Built-in health monitoring
- **Custom Addons**: Support for custom modules via volume mount

### Custom Docker Image Features
- **Bundled Scripts**: All initialization scripts bundled in the image (no host mounts required)
- **Automatic Initialization**: Database setup on first run with retry logic
- **Idempotent Operations**: Safe to restart containers without re-initialization
- **Multi-Platform Support**: Compatible with amd64 and arm64 architectures
- **Production-Ready Security**: Pre-configured master password protection
- **State Detection**: Skips re-initialization on restart using marker files
- **Color-Coded Output**: User-friendly logs with clear status messages

## System Requirements

- Docker Engine 20.10+
- Docker Compose 1.29+
- 2GB RAM minimum (4GB recommended)
- 10GB disk space minimum

## Volumes

The application uses three Docker volumes:

- `postgres_data`: PostgreSQL database files
- `odoo_data`: Odoo data directory (filestore, sessions, etc.)
- `odoo_addons`: Custom Odoo addons/modules

## Installing Custom Addons

Custom modules go in `/mnt/extra-addons`, which has its own volume (`odoo_addons` here, `odoo-addons` in the
Clouve listing). The entrypoint lists the folder in `addons_path` as the pattern `/mnt/extra-addons*`. Odoo
expands the pattern each time it starts: while no module is in the folder it skips it without a warning, and
once a module folder (with `__init__.py` and `__manifest__.py`) is there, Odoo loads it. So restart Odoo after
adding the first module, before you look for it in Apps.

To install custom Odoo addons:

1. Place your addon directories in a local folder (e.g., `./addons`)
2. Update the docker-compose.yml to mount this folder:

```yaml
volumes:
  - odoo_data:/var/lib/odoo
  - ./addons:/mnt/extra-addons
```

3. Restart the container:

```bash
docker-compose down
docker-compose up -d
```

   If the modules are already in the volume, restarting Odoo inside its container is enough. tini, the
   container's PID 1, passes `SIGHUP` on to Odoo, which re-executes itself:

```bash
docker-compose exec odoo kill -HUP 1
```

4. In Odoo, go to Apps → Update Apps List → Install your custom addon

## Odoo Apps/Modules

Odoo comes with a wide range of built-in applications:

- **Sales**: CRM, Sales, Point of Sale
- **Finance**: Accounting, Invoicing, Expenses
- **Inventory**: Warehouse Management, Manufacturing, Purchase
- **HR**: Employees, Recruitment, Timesheets, Payroll
- **Marketing**: Email Marketing, Marketing Automation, Events
- **Project**: Project Management, Timesheets, Planning
- **Website**: Website Builder, eCommerce, Blog, Forum
- **Productivity**: Discuss (Chat), Calendar, Contacts, Documents

## Troubleshooting

### Security Warning Still Appears

**Symptom**: "Warning, your Odoo database manager is not protected"

**Cause**: Configuration file not being loaded or master password not set

**Solution**:
1. Check if `ODOO_MASTER_PASSWORD` is set in docker-compose.yml
2. Verify configuration file exists (without printing its passwords):
   ```bash
   docker exec odoo_app grep -vE '^[[:space:]]*(db_password|admin_passwd)[[:space:]]*=' /etc/odoo/odoo.conf   # passwords left out
   ```
3. Check that `admin_passwd` is present in the configuration
4. Restart containers with clean volumes:
   ```bash
   docker-compose down -v
   docker-compose up -d
   ```

### Cannot Access Database Manager

**Symptom**: The database manager says it has been disabled, or refuses every action

**Cause**: The image locks it at every start (`list_db = False`). Open it for one task as "Verifying Configuration"
below shows.

**Symptom**: Incorrect password when accessing database manager

**Cause**: Using wrong master password

**Solution**:
1. Check the `ODOO_MASTER_PASSWORD` environment variable in docker-compose.yml
2. If auto-generated, read it from the configuration file (the logs never show it):
   ```bash
   docker exec odoo_app grep '^admin_passwd' /etc/odoo/odoo.conf
   ```
3. Recreate containers to generate a new password:
   ```bash
   docker-compose down -v
   docker-compose up -d
   ```

### Container Won't Start

**Symptom**: Container exits immediately or fails to start

**Solution**:
```bash
docker-compose logs odoo
docker-compose logs odoo-postgres
```

Look for error messages in the logs and address the specific issue.

### Database Connection Errors

**Symptom**: Odoo cannot connect to PostgreSQL

**Solution**:
1. Verify database credentials:
   ```bash
   docker-compose exec odoo env | grep -E 'HOST|USER|PASSWORD'
   ```
2. Check if PostgreSQL is ready:
   ```bash
   docker-compose exec odoo-postgres pg_isready -U odoo
   ```
3. Verify network connectivity:
   ```bash
   docker-compose exec odoo ping odoo-postgres
   ```

### Permission Issues

**Symptom**: Permission denied errors in logs

**Cause**: Odoo runs as the `odoo` user, never as root, so it can't write to a file of root's in `/var/lib/odoo`. The
entrypoint gives every such file to `odoo` at each container start (an older image ran Odoo as root and left some),
but a restart with `kill -HUP 1` doesn't run the entrypoint. The `odoo` command drops to the `odoo` user by itself
when root runs it (`docker-compose exec odoo odoo ...`, `sudo odoo ...`). Give files that you copy in as root to
`odoo`.

**Solution**:
Reset permissions:
```bash
docker-compose exec odoo chown -R odoo:odoo /var/lib/odoo
```

### Reset Installation

**Symptom**: Need to start fresh with clean state

**Solution**:
To completely reset and start over:
```bash
docker-compose down -v
docker-compose up -d
```

**Warning**: This will delete all data including databases, configurations, and custom addons.

### Odoo Won't Load / Shows Error

**Symptom**: Odoo web interface not accessible

**Solution**:
1. Check if containers are running:
   ```bash
   docker-compose ps
   ```
2. Check Odoo logs for errors:
   ```bash
   docker-compose logs -f odoo
   ```
3. Verify PostgreSQL is ready:
   ```bash
   docker-compose exec odoo-postgres pg_isready -U odoo
   ```

### Custom Addons Not Appearing

**Symptom**: Custom modules not visible in Odoo Apps

**Solution**:
1. Verify the addons are in the correct directory structure: each module is its own folder directly inside
   `/mnt/extra-addons`, holding `__init__.py` and `__manifest__.py`
2. Update the apps list in Odoo (Apps → Update Apps List)
3. Check file permissions on the addons directory:
   ```bash
   docker-compose exec odoo ls -la /mnt/extra-addons
   ```
4. Restart Odoo container. Odoo checks the `/mnt/extra-addons*` entry in `addons_path` only when it starts,
   so the first module in the folder stays invisible until then:
   ```bash
   docker-compose restart odoo
   ```

### Configuration Not Persisting

**Symptom**: Configuration changes lost after container restart

**Cause**: Container is being recreated instead of restarted

**Solution**:
Use `docker-compose restart` instead of `docker-compose up --force-recreate`:
```bash
docker-compose restart odoo
```

## Upgrading Odoo

To upgrade to a new version of Odoo:

1. Backup your database:
```bash
docker-compose exec odoo-postgres pg_dump -U odoo postgres > backup.sql
```

2. Update the image version in `docker-compose.yml`:
```yaml
odoo:
  image: odoo:19.0  # or desired version
```

3. Restart the containers:
```bash
docker-compose down
docker-compose up -d
```

4. Odoo will automatically run database migrations on startup

## Naming Conventions

This bundle follows the Clouve multi-app naming conventions:

- **Main container**: `odoo` (isPublic: true) - Receives ingress exposure
- **Database container**: `odoo-postgres` (isPublic: false) - Prefixed with main app name

This pattern ensures:
- Clear relationship between containers
- Proper ingress routing to public-facing services
- Compatibility with Clouve deployment scripts

## Production Deployment

### Pre-Deployment Checklist

Before deploying to production:

1. **Update all credentials** in `docker-compose.yml`
2. **Use strong passwords** for database and admin accounts (minimum 16 characters)
3. **Set a secure master password** via `ODOO_MASTER_PASSWORD` environment variable
4. **Configure SSL/TLS** using a reverse proxy (nginx, traefik, etc.)
5. **Set up regular backups** of the PostgreSQL database
6. **Configure email** for notifications and password resets
7. **Review security settings** in Odoo configuration
8. **Set resource limits** for containers
9. **Enable monitoring** and logging
10. **Test disaster recovery** procedures

### Example Production Configuration

Create an `odoo.conf` file:

```ini
[options]
admin_passwd = strong_master_password
db_host = odoo-postgres
db_port = 5432
db_user = odoo
db_password = strong_db_password
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons*
data_dir = /var/lib/odoo
logfile = /var/log/odoo/odoo.log
log_level = info
workers = 4
max_cron_threads = 2
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
```

Mount this file in docker-compose.yml:

```yaml
volumes:
  - ./odoo.conf:/etc/odoo/odoo.conf:ro
  - odoo_data:/var/lib/odoo
  - odoo_addons:/mnt/extra-addons
```

### Clouve Marketplace Deployment

The `clv-docker-compose.yml` file is ready for deployment to the Clouve marketplace with:
- Proper bundle metadata for marketplace listing
- Environment variable type mappings for UI generation
- Volume size specifications for resource allocation
- Health check configuration for monitoring
- Container metadata for deployment orchestration

## Security Configuration

### Master Password Protection

The custom Docker image includes production-ready security configuration for the Odoo database manager:

#### What is the Master Password?

The master password protects database management operations:
- Create new databases
- Delete existing databases
- Backup databases
- Restore databases from backup
- Duplicate databases

**Important**: This password is different from the admin password for individual Odoo databases.

#### Setting the Master Password

**Method 1: Environment Variable (Recommended)**

Set the `ODOO_MASTER_PASSWORD` environment variable in `docker-compose.yml`:

```yaml
environment:
  ODOO_MASTER_PASSWORD: your_secure_master_password
```

**Method 2: Auto-Generated (Development Only)**

If `ODOO_MASTER_PASSWORD` is not provided, the entrypoint makes up a random 32-character password at every container
start. It writes the password to `/etc/odoo/odoo.conf` (`admin_passwd`) only, a file that only the `odoo` user and
root can read. The logs say where it is, never what it is. Read it there:

```bash
docker exec odoo_app grep '^admin_passwd' /etc/odoo/odoo.conf
```

#### Verifying Configuration

1. Check the configuration file (without printing its passwords):
```bash
docker exec odoo_app grep -vE '^[[:space:]]*(db_password|admin_passwd)[[:space:]]*=' /etc/odoo/odoo.conf   # passwords left out
```

2. Check that the database manager is locked: the database list answers an error.
```bash
curl -s -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"call","params":{}}' \
  http://localhost:8069/web/database/list
```

The image locks Odoo's database manager at every start: `odoo.conf` gets `list_db = False` and
`dbfilter = ^<ODOO_DB_NAME>\Z`, so `/web/database/*` refuses every action and a browser reaches that one database.
`odoo db` (dump, load, duplicate) works with the lock on. To use the manager page on a local container for one task,
open it, restart Odoo in place, and close it the same way afterwards (a new container locks it again):

```bash
docker exec odoo_app sed -i 's/^list_db = False$/list_db = True/' /etc/odoo/odoo.conf
docker exec odoo_app kill -HUP 1      # tini passes it on; Odoo re-reads odoo.conf
# ... the task at http://localhost:8069/web/database/manager, with ODOO_MASTER_PASSWORD ...
docker exec odoo_app sed -i 's/^list_db = True$/list_db = False/' /etc/odoo/odoo.conf
docker exec odoo_app kill -HUP 1
```

### Security Best Practices

#### Password Requirements
- **Minimum length**: 16 characters recommended
- **Complexity**: Use a mix of uppercase, lowercase, numbers, and special characters
- **Uniqueness**: Never reuse passwords across different systems

#### Environment-Specific Passwords
- **Development**: Use a simple password for local testing (e.g., `odoo_master_password`)
- **Staging**: Use a unique password different from production
- **Production**: Use a strong, randomly generated password stored in a secrets manager

#### General Security
- Change default passwords in production
- Use strong passwords for database and admin accounts
- Configure SSL/TLS for production deployments
- Regularly update to the latest Odoo version
- Review and configure Odoo security settings
- Implement proper backup strategies
- Use firewall rules to restrict database access
- Enable two-factor authentication for admin users
- Regularly audit user permissions and access logs
- Never commit passwords to version control
- Rotate passwords regularly as part of security maintenance

## Building Custom Docker Images

The Odoo bundle uses custom Docker images hosted in the Clouve registry. To build the images:

### Using the Build Script

```bash
# Local build (single platform - current architecture)
cd magneto
./build.sh odoo

# Build and push to registry (multi-platform: amd64 + arm64)
cd magneto
./build.sh odoo --push
```

### Image Details

**Odoo Application Image:**
- **Registry**: `r.clv.zone/e2eorg/odoo`
- **Base Image**: `odoo:19.0`
- **Enhancements**: Custom entrypoint, bundled scripts, automatic initialization
- **Platforms**: linux/amd64, linux/arm64

**PostgreSQL Database Image:**
- **Registry**: `r.clv.zone/e2eorg/odoo-postgres`
- **Base Image**: `postgres:16`
- **Purpose**: Hosted in Clouve registry to avoid Docker Hub rate limits
- **Platforms**: linux/amd64, linux/arm64

### Image Structure

```
magneto/apps/odoo/image/
├── Dockerfile                    # Custom Odoo image
├── build.config                  # Build configuration
├── installer/
│   ├── entrypoint.sh            # Main entrypoint script
│   └── install.sh               # Installation script
└── postgres/
    └── Dockerfile               # Custom PostgreSQL image
```

## Support

For Odoo-specific issues, consult:
- [Odoo Documentation](https://www.odoo.com/documentation/19.0/)
- [Odoo Community Forums](https://www.odoo.com/forum)
- [Odoo GitHub Repository](https://github.com/odoo/odoo)

For Docker image or deployment issues:
- Check container logs: `docker-compose logs odoo`
- Review this README's Troubleshooting section
- Inspect configuration, passwords left out: `docker exec odoo_app grep -vE '^[[:space:]]*(db_password|admin_passwd)[[:space:]]*=' /etc/odoo/odoo.conf`

## License

Odoo is licensed under the GNU Lesser General Public License v3.0 (LGPL-3.0).


