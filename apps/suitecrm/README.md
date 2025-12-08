# SuiteCRM 8 Application Bundle

This directory contains a production-ready SuiteCRM 8 application bundle for the Clouve platform.

## Overview

SuiteCRM 8 is an open-source Customer Relationship Management (CRM) software solution for SME and Enterprise. This bundle provides a custom-built Docker image with automatic initialization and database setup.

## Version

- **SuiteCRM Version**: 8.9.1 (Latest Stable)
- **PHP Version**: 8.2
- **Web Server**: Apache 2.4
- **Database**: MariaDB (latest)

## Structure

```
suitecrm/
├── image/
│   ├── Dockerfile              # Custom SuiteCRM 8 image
│   ├── db/
│   │   └── Dockerfile          # MariaDB database image
│   └── installer/
│       ├── entrypoint.sh       # Main entrypoint script
│       └── install.sh          # Installation script
├── docker-compose.yml          # Local development compose file
├── clv-docker-compose.yml      # Production compose file with Clouve metadata
└── README.md                   # This file
```

## Features

- **Custom-built image**: Downloads SuiteCRM 8.9.1 from official GitHub releases
- **Automatic initialization**: Handles database setup and SuiteCRM installation automatically
- **Production-ready**: Includes proper security settings, health checks, and resource limits
- **Persistent storage**: Data persists across container restarts
- **Environment-based configuration**: Easy configuration via environment variables

## Quick Start

### Local Development

1. Build and start the containers:
   ```bash
   cd magneto/dkr/apps/suitecrm
   docker-compose up -d
   ```

2. Access SuiteCRM at: http://localhost:8080

3. Default credentials:
   - Username: `admin`
   - Password: `Admin@123`

### Building Images

Build the SuiteCRM image:
```bash
cd image
docker build -t r.clv.zone/e2eorg/suitecrm .
```

Build the MariaDB image:
```bash
cd image/db
docker build -t r.clv.zone/e2eorg/suitecrm-mariadb .
```

## Environment Variables

### SuiteCRM Container

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_HOST` | MariaDB host | `suitecrm-mariadb` |
| `DATABASE_PORT` | MariaDB port | `3306` |
| `DATABASE_NAME` | Database name | `suitecrm` |
| `DATABASE_USER` | Database user | `suitecrm` |
| `DATABASE_PASSWORD` | Database password | `suitecrm_password` |
| `SUITECRM_URL` | SuiteCRM site URL | `http://localhost:8080` |
| `SUITECRM_ADMIN_USER` | Admin username | `admin` |
| `SUITECRM_ADMIN_PASSWORD` | Admin password | `Admin@123` |
| `SUITECRM_INSTALL_DEMO_DATA` | Install demo data (`yes`/`no`, `true`/`false`, `1`/`0`) | `no` |
| `SUITECRM_VERSION` | SuiteCRM version | `8.9.1` |

### MariaDB Container

| Variable | Description | Default |
|----------|-------------|---------|
| `MYSQL_DATABASE` | Database name | `suitecrm` |
| `MYSQL_USER` | Database user | `suitecrm` |
| `MYSQL_PASSWORD` | Database password | `suitecrm_password` |
| `MYSQL_ROOT_PASSWORD` | Root password | `root_password` |

## Architecture

### Dockerfile

The custom Dockerfile:
1. Uses PHP 8.2 with Apache as the base image
2. Installs all required PHP extensions (mysqli, gd, opcache, zip, etc.)
3. Downloads SuiteCRM 8.9.1 from the official GitHub repository
4. Installs Composer dependencies
5. Configures Apache to use `/public` as DocumentRoot (SuiteCRM 8 security best practice)
6. Sets up proper permissions and PHP settings

### Entrypoint Script

The entrypoint script (`installer/entrypoint.sh`):
1. Waits for MariaDB to be ready
2. Copies SuiteCRM files to the web root (if not already done)
3. Checks if SuiteCRM is already initialized
4. Runs the installation script if needed
5. Sets proper permissions
6. Starts Apache

### Installation Script

The installation script (`installer/install.sh`):
1. Verifies MariaDB connection
2. Creates the database if it doesn't exist
3. Checks if SuiteCRM is already installed
4. Creates `.env.local` configuration file
5. Runs SuiteCRM CLI installer
6. Sets proper permissions on writable directories

## Health Checks

- **SuiteCRM**: HTTP check on port 80, path `/`
  - Initial delay: 120s (allows time for installation)
  - Interval: 30s
  - Timeout: 10s
  - Retries: 5

- **MariaDB**: Built-in MariaDB health check
  - Interval: 10s
  - Timeout: 5s
  - Retries: 5

## Volumes

- `suitecrm-data`: SuiteCRM application files and data (10GB)
- `suitecrm-db-data`: MariaDB database files (10GB)

## Demo Data Configuration

SuiteCRM can be installed with or without demo data. Demo data includes sample accounts, contacts, leads, opportunities, and other CRM records that are useful for testing and evaluation.

### Controlling Demo Data Installation

Use the `SUITECRM_INSTALL_DEMO_DATA` environment variable to control whether demo data is installed:

**Clean Installation (No Demo Data)** - Default:
```yaml
environment:
  SUITECRM_INSTALL_DEMO_DATA: "no"  # or "false" or "0"
```

**With Demo Data** - For testing/evaluation:
```yaml
environment:
  SUITECRM_INSTALL_DEMO_DATA: "yes"  # or "true" or "1"
```

### Accepted Values

The `SUITECRM_INSTALL_DEMO_DATA` variable accepts the following values (case-insensitive):

- **For clean installation**: `no`, `false`, `0`
- **For demo data**: `yes`, `true`, `1`

If not set or an invalid value is provided, it defaults to `no` (clean installation).

### When to Use Demo Data

**Use demo data (`yes`) when:**
- Evaluating SuiteCRM features
- Testing the application
- Training users
- Demonstrating CRM capabilities

**Use clean installation (`no`) when:**
- Setting up production environment
- Starting with real customer data
- Deploying for actual business use

### Example: Starting with Demo Data

To start SuiteCRM with demo data for evaluation:

```bash
# Edit docker-compose.yml and set:
SUITECRM_INSTALL_DEMO_DATA: "yes"

# Then start the containers:
docker-compose up -d
```

**Note**: Demo data is only installed during the initial setup. Changing this variable after SuiteCRM is already installed will have no effect.

## Security Considerations

1. **DocumentRoot**: Set to `/var/www/html/public` (SuiteCRM 8 recommended security practice)
2. **File Permissions**: Proper permissions set on writable directories only
3. **Database Passwords**: Use strong passwords in production
4. **Admin Password**: Change default admin password after first login
5. **HTTPS**: Use reverse proxy with SSL/TLS in production

## Troubleshooting

### Check logs

```bash
# SuiteCRM logs
docker logs suitecrm_app

# MariaDB logs
docker logs suitecrm_db
```

### Access container shell

```bash
docker exec -it suitecrm_app bash
```

### Reset installation

```bash
docker-compose down -v
docker-compose up -d
```

## References

- [SuiteCRM Official Website](https://suitecrm.com/)
- [SuiteCRM 8 Documentation](https://docs.suitecrm.com/8.x/)
- [SuiteCRM GitHub Repository](https://github.com/salesagility/SuiteCRM-Core)
- [SuiteCRM 8 Install Guide](https://docs.suitecrm.com/8.x/admin/installation-guide/)

