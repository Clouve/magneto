# WordPress Docker Application

Custom WordPress Docker image with pre-installed wp-cli and automatic initialization.

## Quick Start

```bash
# Build the image
docker-compose build

# Start containers
docker-compose up -d

# Stop containers
docker-compose down
```

## Access WordPress

- **URL**: http://localhost:8080
- **Admin Username**: admin
- **Admin Password**: admin_password
- **Admin Email**: admin@example.com

## Configuration

Edit `docker-compose.yml` to customize environment variables:

```yaml
environment:
  WORDPRESS_DB_HOST: wordpress-mariadb
  WORDPRESS_DB_NAME: wordpress
  WORDPRESS_DB_USER: wordpress
  WORDPRESS_DB_PASSWORD: wordpress_password
  WORDPRESS_SITE_TITLE: My WordPress Site
  WORDPRESS_ADMIN_USER: admin
  WORDPRESS_ADMIN_PASSWORD: admin_password
  WORDPRESS_ADMIN_EMAIL: admin@example.com
  WORDPRESS_SITE_URL: http://localhost:8080
  WORDPRESS_TABLE_PREFIX: wp_
  WORDPRESS_DEBUG: "false"
```

## Verification

```bash
# Check container status
docker-compose ps

# View logs
docker-compose logs -f wordpress

# Test WordPress
curl http://localhost:8080

# Check database connection
docker-compose exec wordpress mysql -h wordpress-mariadb -u wordpress -pwordpress_password -e "SELECT 1;"
```

## Features

- ✅ Custom Docker image with pre-installed wp-cli (v2.12.0)
- ✅ Multi-platform support (amd64 and arm64 architectures)
- ✅ Automatic WordPress initialization
- ✅ Database connectivity with retry logic
- ✅ Installation state detection (skips re-installation on restart)
- ✅ Data persistence across container restarts
- ✅ Self-contained Docker image

## Files

- `image/Dockerfile` - Custom WordPress image definition
- `image/docker-entrypoint.sh` - Initialization script
- `image/build.config` - Build configuration for the centralized build script
- `docker-compose.yml` - Container orchestration
- `start.sh` - Start containers
- `stop.sh` - Stop containers

## Troubleshooting

### Container won't start
```bash
docker-compose logs wordpress
docker-compose logs wordpress-mariadb
```

### WordPress shows installation screen
```bash
docker-compose exec wordpress mysql -h wordpress-mariadb -u wordpress -pwordpress_password -e "SELECT 1 FROM wp_options LIMIT 1;"
```

### Database connection fails
```bash
docker-compose ps
docker-compose exec wordpress-mariadb healthcheck.sh --connect --innodb_initialized
```

## Building and Pushing Images

To build and push images, use the centralized build script located in the parent directory:

```bash
# Build images locally (amd64 only)
cd ..
./build.sh wordpress

# Build and push multi-platform images to registry (amd64 + arm64)
cd ..
./build.sh wordpress --push
```

For more information about the build system, see the [Build Script Documentation](../README.md).

## Production Deployment

Before deploying to production:
1. Update all credentials in `docker-compose.yml`
2. Change `WORDPRESS_SITE_URL` to your domain
3. Update `WORDPRESS_ADMIN_PASSWORD` to a secure password
4. Update `WORDPRESS_DB_PASSWORD` to a secure password
5. Build and test: `docker-compose build && docker-compose up -d`
6. Verify WordPress loads and database is connected

