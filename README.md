# Marketplace Application Packaging Guide

This guide explains how to prepare containerized applications for deployment in a Kubernetes-based marketplace system. Whether you're packaging a single application or a multi-application bundle, this document covers the directory structure, configuration patterns, and best practices you need to follow.

## Table of Contents

1. [Overview](#overview)
2. [Directory Structure](#directory-structure)
3. [Single Applications](#single-applications)
4. [Application Bundles](#application-bundles)
5. [Dockerfile Best Practices](#dockerfile-best-practices)
6. [Docker Compose Configuration](#docker-compose-configuration)
7. [Marketplace Manifest Configuration](#marketplace-manifest-configuration)
8. [Environment Variables and Secrets](#environment-variables-and-secrets)
9. [Health Checks and Readiness](#health-checks-and-readiness)
10. [Initialization and Entrypoint Scripts](#initialization-and-entrypoint-scripts)
11. [Volume Management](#volume-management)
12. [Multi-Container Applications](#multi-container-applications)
13. [Build Configuration](#build-configuration)
14. [Testing Your Application](#testing-your-application)

---

## Overview

The marketplace packaging system enables you to:

- **Package single applications** with their dependencies (databases, caches, etc.)
- **Create application bundles** that combine multiple applications with shared integrations
- **Define deployment configurations** that work across development and production environments
- **Provide metadata** for marketplace discovery and user configuration

### Key Concepts

| Concept | Description |
|---------|-------------|
| **Application** | A single deployable unit (e.g., WordPress, Moodle) with its dependencies |
| **Bundle** | Multiple applications packaged together with integrations (e.g., Education Kit) |
| **Development Compose** | `docker-compose.yml` for local testing and development |
| **Marketplace Manifest** | `clv-docker-compose.yml` with metadata for marketplace deployment |
| **Image Directory** | Contains Dockerfiles and build configuration for custom images |

---

## Directory Structure

### Single Application Structure

```
apps/
└── my-application/
    ├── README.md                    # Application documentation
    ├── logo.png                     # Application logo (recommended: 256x256)
    ├── docker-compose.yml           # Development/testing configuration
    ├── clv-docker-compose.yml       # Marketplace manifest with metadata
    └── image/                       # Custom Docker image build files
        ├── Dockerfile               # Main application Dockerfile
        ├── build.config             # Build configuration variables
        ├── installer/               # Initialization scripts
        │   ├── entrypoint.sh        # Custom entrypoint wrapper
        │   ├── install.sh           # Installation logic (optional)
        │   └── ...                  # Additional helper scripts
        └── <database>/              # Database container (mariadb/, mysql/, postgres/)
            └── Dockerfile           # Database Dockerfile
```

### Application Bundle Structure

```
bundles/
└── my-bundle/
    ├── README.md                    # Bundle documentation
    ├── description.txt              # Short bundle description
    ├── logo.png                     # Bundle logo
    ├── app1.png                     # Logo for included app 1
    ├── app2.png                     # Logo for included app 2
    ├── docker-compose.yml           # Development configuration
    └── clv-docker-compose.yml       # Marketplace manifest
```

> **Note:** Bundles typically reuse existing application images and do not include their own `image/` directory.

---

## Single Applications

A single application package includes one primary application container and any required supporting services.

### Container Naming Conventions

- **Main container:** Use the application name (e.g., `wordpress`, `moodle`)
- **Supporting containers:** Prefix with main app name (e.g., `wordpress-mariadb`, `moodle-mysql`)
- This convention is critical for service discovery and orchestration

---

## Application Bundles

Bundles combine multiple applications that work together with shared integrations.

### Bundle Characteristics

- **Reuse existing images:** Bundles reference pre-built application images
- **Shared networks:** All containers communicate on a common network
- **Integration configuration:** Environment variables configure inter-app communication
- **Multiple public endpoints:** Each main application gets its own port/ingress

---

## Dockerfile Best Practices

### Extending Official Images

When extending official Docker images:

1. **Preserve original entrypoints** - Don't rename or modify them
2. **Place custom scripts in separate paths** (e.g., `/clouve/app/installer/`)
3. **Call original entrypoint from your wrapper**

```dockerfile
# Example: Extending an official image
FROM wordpress

# Install additional dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

# Create directory for custom scripts
RUN mkdir -p /clouve/myapp/installer

# Copy custom entrypoint wrapper
COPY installer/entrypoint.sh /clouve/myapp/installer/entrypoint.sh
RUN chmod +x /clouve/myapp/installer/entrypoint.sh

# Set custom entrypoint (calls original at /usr/local/bin/docker-entrypoint.sh)
ENTRYPOINT ["/clouve/myapp/installer/entrypoint.sh"]
CMD []
```

### Building from Scratch

For applications built from base images (e.g., `php:8.3-apache`):

```dockerfile
FROM php:8.3-apache

# Version configuration
ENV APP_VERSION=1.0.0
ENV APP_PATH=myapp/myapp-${APP_VERSION}

# Install system dependencies
RUN apt-get update && apt-get -y upgrade && \
    apt-get install -y \
    gettext-base locales git default-mysql-client \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && locale-gen

# Install PHP extensions
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions && \
    install-php-extensions pdo_mysql gd opcache zip intl

# Clean up
RUN apt-get clean autoclean && apt-get autoremove -y && \
    rm -rfv /var/lib/{apt,dpkg,cache,log}/

# Apache configuration
RUN a2enmod rewrite headers

# Security hardening
RUN sed -i "s/Options Indexes FollowSymLinks/Options FollowSymLinks/g" /etc/apache2/apache2.conf
RUN echo "ServerTokens Prod\nServerSignature Off" >> /etc/apache2/apache2.conf

# PHP configuration
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
RUN printf "upload_max_filesize=100M\npost_max_size=100M\nmemory_limit=512M" >> "$PHP_INI_DIR/php.ini"

# Working directory for custom scripts
WORKDIR /clouve
COPY installer ./myapp/installer
RUN chmod +x ./myapp/installer/*.sh

# Download and extract application
ADD https://example.com/myapp-${APP_VERSION}.tar.gz ./myapp/installer/
RUN tar -xzf ./myapp/installer/myapp-${APP_VERSION}.tar.gz -C ./myapp/

ENTRYPOINT ["/clouve/myapp/installer/entrypoint.sh"]
CMD ["apache2-foreground"]
```

### Database Images

For database containers, you can often use a simple re-packaging Dockerfile:

```dockerfile
# mariadb/Dockerfile
FROM mariadb:latest

LABEL maintainer="Your Team"
LABEL description="MariaDB database for MyApp"
```

This approach is useful when you want to:
- Avoid Docker Hub rate limits in production
- Push to your own private registry
- Maintain consistent image sources

---

## Docker Compose Configuration

### Development Configuration (`docker-compose.yml`)

The development compose file is used for local testing. Key features:

```yaml
services:
  myapp:
    image: registry.example.com/myapp
    container_name: myapp
    restart: unless-stopped
    ports:
      # Support environment variable substitution for flexible testing
      - "${TEST_PORT:-8080}:80"
    environment:
      DB_HOST: myapp-mysql
      DB_NAME: myapp
      DB_USER: myapp
      DB_PASSWORD: myapp_password
      # URL with environment variable substitution
      APP_URL: http://${TEST_DOMAIN:-localhost}:${TEST_PORT:-8080}
    volumes:
      - app_data:/var/www/html
    networks:
      - app_network
    # Dependencies with health check conditions
    depends_on:
      myapp-mysql:
        condition: service_healthy

  myapp-mysql:
    image: registry.example.com/myapp-mysql
    container_name: myapp_db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: myapp
      MYSQL_USER: myapp
      MYSQL_PASSWORD: myapp_password
      MYSQL_ROOT_PASSWORD: root_password
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - app_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  app_data:
    driver: local
  db_data:
    driver: local

networks:
  app_network:
    driver: bridge
```

### Environment Variable Substitution

Use environment variable substitution for testing flexibility:

```yaml
environment:
  # Default: http://localhost:8080
  # Override with: TEST_DOMAIN and TEST_PORT environment variables
  APP_URL: http://${TEST_DOMAIN:-localhost}:${TEST_PORT:-8080}
```

This allows testing URL change detection without modifying files:

```bash
TEST_DOMAIN=newdomain.test TEST_PORT=9090 docker-compose up -d
```

---

## Marketplace Manifest Configuration

The marketplace manifest (`clv-docker-compose.yml`) extends standard Docker Compose with metadata extensions.

### Container Metadata (`x-clouve-metadata`)

```yaml
x-clouve-metadata:
  containerName: myapp           # Unique container identifier
  purpose: Frontend              # Frontend, Backend, Database, Cache, etc.
  protocol: TCP                  # TCP or UDP
  isPublic: true                 # Whether to expose via ingress
  memoryBase: 1                  # Base memory units (GB)
  cpuBase: 1                     # Base CPU units (cores)
```

### Application Metadata (`x-clouve-bundle-metadata`)

```yaml
x-clouve-bundle-metadata:
  appVersion: "1.0.0"            # Application version
  appTitle: "My Application"     # Display name in marketplace
  appDescription: |              # Detailed description
    My Application is a powerful platform that enables...
  appIcon: /path/to/icon.png     # Optional: custom icon path
```

### Environment Variable Types (`x-clouve-environment-types`)

Define how each environment variable should be handled:

```yaml
environment:
  DB_HOST: myapp-mysql
  DB_PASSWORD: myapp-mysql-password
  APP_URL: http://localhost
  ADMIN_EMAIL: '{user.userEmail}'
  ADMIN_PASSWORD: app-password

x-clouve-environment-types:
  DB_HOST: containerReference      # Reference to another container
  DB_PASSWORD: secret              # Auto-generated secret
  APP_URL: applicationUrl          # Replaced with actual deployment URL
  ADMIN_EMAIL: applicationUsername # User-provided value
  ADMIN_PASSWORD: applicationPassword  # User-configurable password
```

**Environment Type Reference:**

| Type | Description |
|------|-------------|
| `static` | Fixed value, not modified during deployment |
| `secret` | Auto-generated secure password/token |
| `containerReference` | Reference to another container name |
| `applicationUrl` | Replaced with deployment URL |
| `applicationUsername` | Primary user identifier |
| `applicationPassword` | Primary user password |
| `userConfigurable` | User can modify during deployment |

### Template Variables

Use template variables for user context:

```yaml
environment:
  ADMIN_EMAIL: '{user.userEmail}'
  ADMIN_USER: '{user.firstName}_{user.lastName}'
  ORG_NAME: '{org.name}'
```

**Available Template Variables:**

| Variable | Description |
|----------|-------------|
| `{user.userEmail}` | User's email address |
| `{user.firstName}` | User's first name |
| `{user.lastName}` | User's last name |
| `{org.name}` | Organization name |

---

## Health Checks and Readiness

Health checks ensure containers are ready to receive traffic before being added to load balancers.

### Docker Compose Health Checks

```yaml
healthcheck:
  test:
    - CMD
    - wget
    - '--spider'
    - '-q'
    - http://localhost:80/
  interval: 15s        # Time between checks
  timeout: 10s         # Maximum time for check to complete
  retries: 5           # Number of retries before marking unhealthy
  start_period: 30s    # Grace period for container startup
```

### Marketplace Health Check Extension (`x-clouve-healthcheck`)

```yaml
x-clouve-healthcheck:
  enabled: true              # Enable/disable health checking
  type: HTTP                 # HTTP, TCP, or Command
  path: /                    # HTTP endpoint path
  port: 80                   # Port to check
  initialDelay: 30           # Seconds to wait before first check
  interval: 15               # Seconds between checks
  timeout: 10                # Seconds to wait for response
  failureThreshold: 5        # Failures before marking unhealthy
  successThreshold: 1        # Successes before marking healthy
```

### Health Check Types

**HTTP Health Check:**
```yaml
x-clouve-healthcheck:
  enabled: true
  type: HTTP
  path: /health
  port: 8080
```

**TCP Health Check (for databases):**
```yaml
x-clouve-healthcheck:
  enabled: true
  type: TCP
  port: 3306
```

**Command Health Check:**
```yaml
x-clouve-healthcheck:
  enabled: true
  type: Command
  path: mysqladmin ping -h localhost
  port: 3306
```

> **Note:** Set `enabled: false` for supporting containers (databases) that don't need external health checking.

---

## Initialization and Entrypoint Scripts

Custom entrypoint scripts handle initialization, configuration, and startup.

### Entrypoint Script Pattern

```bash
#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Path to the original entrypoint (from base image)
ORIGINAL_ENTRYPOINT="/usr/local/bin/docker-entrypoint.sh"

# Application paths
APP_DIR="/var/www/html"
INSTALLED_MARKER="/var/www/html/.app_initialized"

# ============================================================================
# STEP 1: Wait for database to be ready
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Waiting for database to be ready..."
max_attempts=60
attempt=0

while [ $attempt -lt $max_attempts ]; do
    if mysqladmin ping -h"$DB_HOST" --silent 2>/dev/null; then
        echo -e "${GREEN}[SUCCESS]${NC} Database is ready!"
        break
    fi
    attempt=$((attempt + 1))
    echo -e "${YELLOW}[WAIT]${NC} Database not ready... (attempt $attempt/$max_attempts)"
    sleep 2
done

if [ $attempt -eq $max_attempts ]; then
    echo -e "${RED}[ERROR]${NC} Database failed to become ready"
    exit 1
fi

# Wait for database to stabilize
sleep 3

# ============================================================================
# STEP 2: Check if application is already installed
# ============================================================================

if [ -f "$INSTALLED_MARKER" ]; then
    echo -e "${GREEN}[INFO]${NC} Application already initialized"

    # Check if URL has changed and update if needed
    # (Application-specific URL update logic here)
else
    echo -e "${YELLOW}[INFO]${NC} First-time initialization..."

    # Run installation logic
    # ...

    # Create marker file
    echo "$(date)" > "$INSTALLED_MARKER"
fi

# ============================================================================
# STEP 3: Execute original entrypoint or start service
# ============================================================================

if [ -f "$ORIGINAL_ENTRYPOINT" ]; then
    exec "$ORIGINAL_ENTRYPOINT" "$@"
else
    exec "$@"
fi
```

### Key Initialization Patterns

1. **Database readiness polling:** Use `mysqladmin ping` or similar with timeout
2. **Initialization markers:** Track state with marker files in persistent volumes
3. **URL change detection:** Check and update application URLs on restart
4. **File bundling:** Copy application files from bundled location to volume mount
5. **Original entrypoint preservation:** Always call original entrypoint if it exists

### File Bundling for Kubernetes Volumes

When Kubernetes mounts an empty PVC, it overwrites container files. Bundle files during build:

```dockerfile
# Bundle application files during build
RUN cp -a /var/www/html/. /clouve/myapp/package/

# In entrypoint.sh, copy files if missing
if [ ! -f "/var/www/html/index.php" ]; then
    cp -prf /clouve/myapp/package/* /var/www/html/
    chown -R www-data:www-data /var/www/html/
fi
```

---

## Volume Management

### Volume Configuration

```yaml
volumes:
  - app_data:/var/www/html          # Application files
  - upload_data:/var/www/html/upload # User uploads
  - db_data:/var/lib/mysql          # Database files

x-clouve-volumes:
  - name: app-data
    size: 10                        # Size in GB
    description: "Volume for application files"
  - name: upload-data
    size: 20
    description: "Volume for user uploads"
  - name: db-data
    size: 10
    description: "Volume for database files"
```

### Volume Best Practices

1. **Separate volumes by purpose:** Application files, uploads, database data
2. **Size appropriately:** Consider growth patterns
3. **Use descriptive names:** Helps with management and debugging
4. **Handle empty volume mounts:** Bundle files and copy on first start

---

## Multi-Container Applications

### Service Dependencies

Use `depends_on` with health check conditions:

```yaml
services:
  myapp:
    depends_on:
      myapp-mysql:
        condition: service_healthy
      myapp-redis:
        condition: service_started
```

### Shared Networks

All containers in an application should share a network:

```yaml
networks:
  app_network:
    driver: bridge

services:
  myapp:
    networks:
      - app_network
  myapp-mysql:
    networks:
      - app_network
```

### Inter-Container Communication

Use container service names for internal communication:

```yaml
environment:
  DB_HOST: myapp-mysql        # Service name, not container_name
  REDIS_HOST: myapp-redis
  CACHE_URL: redis://myapp-redis:6379
```

---

## Build Configuration

### Build Configuration File (`build.config`)

```bash
# build.config
APP_IMAGE="myapp"
MARIADB_IMAGE="myapp-mariadb"
MARIADB_NAME="MariaDB"
```

### Multi-Platform Builds

Build for multiple architectures using Docker Buildx:

```bash
# Build for local architecture only
docker buildx build --platform linux/amd64 -t myapp:latest .

# Build for multiple architectures and push
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t registry.example.com/myapp:latest \
  --push .
```

### Build Script Pattern

```bash
#!/bin/bash

# Load configuration
source ./image/build.config

# Build main application image
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t "${REGISTRY}/${APP_IMAGE}:latest" \
  --push \
  ./image

# Build database image (if custom)
if [ -d "./image/mariadb" ]; then
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t "${REGISTRY}/${MARIADB_IMAGE}:latest" \
    --push \
    ./image/mariadb
fi
```

---

## Testing Your Application

### Local Testing Workflow

```bash
# 1. Build images locally
docker-compose build

# 2. Start containers
docker-compose up -d

# 3. Check container status
docker-compose ps

# 4. View logs
docker-compose logs -f myapp

# 5. Test application
curl http://localhost:8080

# 6. Stop containers
docker-compose down
```

### Testing URL Changes

Test that your application handles URL changes correctly:

```bash
# Start with default URL
docker-compose up -d

# Verify application works
curl http://localhost:8080

# Stop and restart with new URL
docker-compose down
TEST_DOMAIN=newdomain.test TEST_PORT=9090 docker-compose up -d

# Verify URL was updated
curl http://newdomain.test:9090
```

### Testing Database Persistence

```bash
# Start containers
docker-compose up -d

# Create some data in the application
# ...

# Stop containers (preserves volumes)
docker-compose down

# Restart containers
docker-compose up -d

# Verify data persists
# ...

# Clean up (removes volumes)
docker-compose down -v
```

### Validation Checklist

Before submitting your application to the marketplace:

- [ ] **Container starts successfully** with `docker-compose up -d`
- [ ] **Health checks pass** - verify with `docker-compose ps`
- [ ] **Application is accessible** at configured URL
- [ ] **Database connection works** - application can read/write data
- [ ] **Data persists** across container restarts
- [ ] **URL changes are handled** - application updates internal URLs
- [ ] **Logs are clean** - no errors in `docker-compose logs`
- [ ] **Marketplace manifest is valid** - all required metadata present
- [ ] **Environment types are correct** - secrets, URLs, references properly typed
- [ ] **Health check configuration** - appropriate for your application

---

## Complete Marketplace Manifest Example

Here's a complete example of a marketplace manifest (`clv-docker-compose.yml`):

```yaml
services:
  myapp:
    image: registry.example.com/myapp
    container_name: myapp
    restart: unless-stopped
    ports:
      - "8080:80"
    environment:
      # Database Configuration
      DB_HOST: myapp-mysql
      DB_PORT: 3306
      DB_NAME: myapp
      DB_USER: myapp
      DB_PASSWORD: myapp-db-password
      # Application Configuration
      APP_URL: http://localhost:8080
      ADMIN_USER: '{user.firstName}'
      ADMIN_EMAIL: '{user.userEmail}'
      ADMIN_PASSWORD: myapp-admin-password
      # Feature Flags
      DEBUG_MODE: "false"
    x-clouve-environment-types:
      DB_HOST: containerReference
      DB_PORT: static
      DB_NAME: static
      DB_USER: static
      DB_PASSWORD: secret
      APP_URL: applicationUrl
      ADMIN_USER: applicationUsername
      ADMIN_EMAIL: static
      ADMIN_PASSWORD: applicationPassword
      DEBUG_MODE: userConfigurable
    x-clouve-metadata:
      containerName: myapp
      purpose: Frontend
      protocol: TCP
      isPublic: true
      memoryBase: 1
      cpuBase: 1
    x-clouve-healthcheck:
      enabled: true
      type: HTTP
      path: /
      port: 80
      initialDelay: 30
      interval: 15
      timeout: 10
      failureThreshold: 5
      successThreshold: 1
    x-clouve-bundle-metadata:
      appVersion: "1.0.0"
      appTitle: "My Application"
      appDescription: |
        My Application is a powerful platform that enables teams to collaborate
        effectively. Features include real-time editing, file sharing, and
        integrated communication tools.
    volumes:
      - app_data:/var/www/html
      - upload_data:/var/www/html/upload
    x-clouve-volumes:
      - name: app-data
        size: 10
        description: "Volume for application files"
      - name: upload-data
        size: 20
        description: "Volume for user uploads"
    networks:
      - app_network
    depends_on:
      myapp-mysql:
        condition: service_healthy

  myapp-mysql:
    image: registry.example.com/myapp-mysql
    container_name: myapp_db
    restart: unless-stopped
    environment:
      MYSQL_DATABASE: myapp
      MYSQL_USER: myapp
      MYSQL_PASSWORD: myapp-db-password
      MYSQL_ROOT_PASSWORD: myapp-root-password
    x-clouve-environment-types:
      MYSQL_DATABASE: static
      MYSQL_USER: static
      MYSQL_PASSWORD: secret
      MYSQL_ROOT_PASSWORD: secret
    x-clouve-metadata:
      containerName: myapp-mysql
      purpose: Database
      protocol: TCP
      isPublic: false
      memoryBase: 1
      cpuBase: 1
    x-clouve-healthcheck:
      enabled: false
      type: Command
      path: mysqladmin ping -h localhost
      port: 3306
    volumes:
      - db_data:/var/lib/mysql
    x-clouve-volumes:
      - name: db-data
        size: 10
        description: "Volume for database files"
    networks:
      - app_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  app_data:
    driver: local
  upload_data:
    driver: local
  db_data:
    driver: local

networks:
  app_network:
    driver: bridge
```

---

## Additional Resources

- **DEVELOPER_GUIDE.md** - Management scripts and operational documentation
- **Individual app READMEs** - Application-specific documentation in `apps/<app>/README.md`
- **Bundle READMEs** - Bundle-specific documentation in `bundles/<bundle>/README.md`

