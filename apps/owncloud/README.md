# ownCloud Application Bundle

This directory contains the production-ready ownCloud application bundle for the Clouve platform.

## Overview

ownCloud is a powerful, open-source file sync and share platform that enables businesses to securely store, access, and collaborate on files from anywhere. This bundle includes:

- **ownCloud Server**: The main application container based on the official `owncloud/server` image
- **MariaDB**: Database container for persistent data storage
- **Redis**: Caching layer for improved performance

## Architecture

The bundle follows the established Clouve patterns:

- Custom Dockerfile extending the official ownCloud image
- Non-invasive entrypoint wrapper at `/clouve/app/installer/entrypoint.sh`
- Automatic initialization on first run
- Production-ready configuration with health checks
- Persistent volumes for data and database

## Container Structure

### Main Application Container (`owncloud`)
- **Base Image**: `owncloud/server:latest`
- **Port**: 8080 (HTTP)
- **Purpose**: Frontend application server
- **Data Volume**: `/mnt/data` - stores all ownCloud files and configuration

### Database Container (`owncloud-mariadb`)
- **Base Image**: `mariadb:latest`
- **Port**: 3306
- **Purpose**: Database server
- **Data Volume**: `/var/lib/mysql` - stores database files

### Cache Container (`owncloud-redis`)
- **Base Image**: `redis:6`
- **Port**: 6379
- **Purpose**: Caching layer
- **Data Volume**: `/data` - stores Redis cache data

## Environment Variables

### ownCloud Application
- `OWNCLOUD_DOMAIN`: The domain where ownCloud is accessible (e.g., `http://localhost:8080`)
- `OWNCLOUD_TRUSTED_DOMAINS`: Comma-separated list of trusted domains
- `OWNCLOUD_ADMIN_USERNAME`: Admin username for initial setup
- `OWNCLOUD_ADMIN_PASSWORD`: Admin password for initial setup
- `OWNCLOUD_DB_TYPE`: Database type (mysql)
- `OWNCLOUD_DB_HOST`: Database host (container reference)
- `OWNCLOUD_DB_NAME`: Database name
- `OWNCLOUD_DB_USERNAME`: Database username
- `OWNCLOUD_DB_PASSWORD`: Database password
- `OWNCLOUD_MYSQL_UTF8MB4`: Enable UTF8MB4 support (true)
- `OWNCLOUD_REDIS_ENABLED`: Enable Redis caching (true)
- `OWNCLOUD_REDIS_HOST`: Redis host (container reference)

### MariaDB Database
- `MYSQL_DATABASE`: Database name
- `MYSQL_USER`: Database user
- `MYSQL_PASSWORD`: Database password
- `MYSQL_ROOT_PASSWORD`: Root password
- `MARIADB_AUTO_UPGRADE`: Enable automatic upgrades (1)

## Files

```
owncloud/
├── README.md                          # This file
├── logo.png                           # ownCloud logo
├── docker-compose.yml                 # Local development/testing compose file
├── clv-docker-compose.yml            # Production compose file with Clouve metadata
└── image/
    ├── Dockerfile                     # Main application Dockerfile
    ├── build.config                   # Build configuration
    ├── db/
    │   └── Dockerfile                 # MariaDB Dockerfile
    └── installer/
        └── entrypoint.sh              # Custom entrypoint wrapper
```

## Building Images

To build the Docker images:

```bash
cd magneto/dkr
./build.sh owncloud
```

This will build both the application and database images.

## Running Locally

For local development and testing:

```bash
cd magneto/dkr/apps/owncloud
docker compose up -d
```

Access ownCloud at: http://localhost:8080

Default credentials:
- Username: `admin`
- Password: `Admin@123`

## Deployment

The `clv-docker-compose.yml` file contains the production configuration with all Clouve-specific metadata including:

- Health check configurations
- Volume specifications
- Environment variable types
- Resource allocations
- Public/private access flags

## Features

- **Automatic Installation**: First-time setup is handled automatically
- **Database Persistence**: All data persists across container restarts
- **Health Checks**: Built-in health monitoring for all containers
- **Redis Caching**: Improved performance with Redis integration
- **UTF8MB4 Support**: Full Unicode support for international characters
- **Secure Configuration**: Production-ready security settings

## Initialization Flow

1. Container starts and runs custom entrypoint wrapper
2. Wrapper waits for database to be ready
3. Checks if ownCloud is already installed
4. Calls original ownCloud entrypoint for setup
5. ownCloud automatically installs if needed
6. Server starts and is ready for use

## Volumes

- `ownclouddata`: Stores all ownCloud files, uploads, and configuration
- `dbdata`: Stores MariaDB database files
- `redisdata`: Stores Redis cache data

## Health Checks

- **ownCloud**: HTTP check on `/status.php` endpoint
- **MariaDB**: MySQL ping check
- **Redis**: Redis CLI ping check

## Notes

- The custom entrypoint is non-invasive and calls the original ownCloud entrypoint
- All ownCloud-specific initialization is handled by the official image
- Database credentials should be changed for production use
- The bundle supports both HTTP and HTTPS (configure via `OWNCLOUD_DOMAIN`)

## Version

- ownCloud Server: 10.16 (latest)
- MariaDB: Latest (10.11+)
- Redis: 6

## Support

For issues or questions, refer to:
- [ownCloud Documentation](https://doc.owncloud.com/)
- [ownCloud Docker Hub](https://hub.docker.com/r/owncloud/server)

