# LimeSurvey Docker Application

Custom LimeSurvey Docker image based on the official `martialblog/limesurvey` image with Clouve-specific initialization and production-ready configuration.

## Quick Start

```bash
# Build the image
docker-compose build

# Start containers
docker-compose up -d

# Stop containers
docker-compose down
```

## Access LimeSurvey

- **URL**: http://localhost:8080
- **Admin Username**: admin
- **Admin Password**: Admin@123
- **Admin Email**: admin@example.com

## Configuration

Edit `docker-compose.yml` to customize environment variables:

```yaml
environment:
  # Database Configuration
  DB_TYPE: mysql
  DB_HOST: limesurvey-mariadb
  DB_NAME: limesurvey
  DB_USERNAME: limesurvey
  DB_PASSWORD: limesurvey_password
  DB_TABLE_PREFIX: lime_
  DB_MYSQL_ENGINE: InnoDB
  
  # Admin Configuration
  ADMIN_USER: admin
  ADMIN_NAME: Administrator
  ADMIN_EMAIL: admin@example.com
  ADMIN_PASSWORD: Admin@123
  
  # URL Configuration
  PUBLIC_URL: http://localhost:8080
  URL_FORMAT: path
  
  # Server Configuration
  LISTEN_PORT: 8080
```

## Verification

```bash
# Check container status
docker-compose ps

# View logs
docker-compose logs -f limesurvey

# Test LimeSurvey
curl http://localhost:8080

# Check database connection
docker-compose exec limesurvey-mariadb mysql -u limesurvey -plimesurvey_password -e "SELECT 1;"
```

## Features

- ✅ Based on official `martialblog/limesurvey:6-apache` Docker image
- ✅ Multi-platform support (amd64 and arm64 architectures)
- ✅ Custom Clouve-specific initialization wrapper
- ✅ Database connectivity with retry logic
- ✅ Installation state detection (skips re-installation on restart)
- ✅ Data persistence across container restarts
- ✅ Production-ready security hardening
- ✅ MariaDB 11 database support
- ✅ Comprehensive PHP extensions (LDAP, IMAP, GD, etc.) from official image

## Files

- `image/Dockerfile` - Custom LimeSurvey image definition
- `image/installer/entrypoint.sh` - Container entrypoint script
- `image/installer/install.sh` - LimeSurvey installation script
- `image/db/Dockerfile` - MariaDB database image
- `image/build.config` - Build configuration for the centralized build script
- `docker-compose.yml` - Container orchestration for local development
- `clv-docker-compose.yml` - Clouve platform deployment configuration

## Troubleshooting

### Container won't start
```bash
docker-compose logs limesurvey
docker-compose logs limesurvey-mariadb
```

### LimeSurvey shows installation screen
```bash
# Check if database is initialized
docker-compose exec limesurvey ls -la /var/www/html/.limesurvey_initialized
docker-compose exec limesurvey-mariadb mysql -u limesurvey -plimesurvey_password -e "SHOW TABLES FROM limesurvey;"
```

### Database connection fails
```bash
docker-compose ps
docker-compose exec limesurvey-mariadb healthcheck.sh --connect --innodb_initialized
```

### Reset installation
```bash
# Stop containers
docker-compose down

# Remove volumes
docker volume rm limesurvey_db_data limesurvey_limesurvey_data limesurvey_limesurvey_upload

# Start fresh
docker-compose up -d
```

## Building and Pushing Images

To build and push images, use the centralized build script located in the parent directory:

```bash
# Build images locally (amd64 only)
cd ..
./build.sh limesurvey

# Build and push multi-platform images to registry (amd64 + arm64)
cd ..
./build.sh limesurvey --push
```

For more information about the build system, see the [Build Script Documentation](../README.md).

## Production Deployment

Before deploying to production:
1. Update all credentials in `docker-compose.yml`
2. Change `PUBLIC_URL` to your domain
3. Update `ADMIN_PASSWORD` to a secure password
4. Update `DB_PASSWORD` to a secure password
5. Update `MYSQL_ROOT_PASSWORD` to a secure password
6. Consider setting encryption keys for enhanced security
7. Build and test: `docker-compose build && docker-compose up -d`
8. Verify LimeSurvey loads and database is connected

## Environment Variables

### Database Configuration
- `DB_TYPE` - Database type (mysql or pgsql, default: mysql)
- `DB_HOST` - Database host (default: limesurvey-mariadb)
- `DB_PORT` - Database port (default: 3306)
- `DB_NAME` - Database name (default: limesurvey)
- `DB_USERNAME` - Database username (default: limesurvey)
- `DB_PASSWORD` - Database password (required)
- `DB_TABLE_PREFIX` - Table prefix (default: lime_)
- `DB_MYSQL_ENGINE` - MySQL engine (default: InnoDB)

### Admin Configuration
- `ADMIN_USER` - Admin username (default: admin)
- `ADMIN_NAME` - Admin display name (default: Administrator)
- `ADMIN_EMAIL` - Admin email (default: admin@example.com)
- `ADMIN_PASSWORD` - Admin password (required)

### URL Configuration
- `PUBLIC_URL` - Public URL for LimeSurvey
- `BASE_URL` - Base URL path
- `URL_FORMAT` - URL format (path or get, default: path)

### Security Configuration (Optional)
- `ENCRYPT_KEYPAIR` - Encryption keypair
- `ENCRYPT_PUBLIC_KEY` - Public encryption key
- `ENCRYPT_SECRET_KEY` - Secret encryption key
- `ENCRYPT_NONCE` - Encryption nonce
- `ENCRYPT_SECRET_BOX_KEY` - Secret box key

