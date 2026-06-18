# n8n Docker Application

n8n deployment for Clouve marketplace using custom Docker images. n8n is a powerful, self-hosted workflow automation platform that connects over 400 apps and services to automate repetitive tasks using a visual editor.

## Overview

This bundle includes:
- **n8n 2.12.3**: Latest stable workflow automation platform
- **PostgreSQL 18**: Reliable and performant database backend
- **Custom Docker Images**: Production-ready images with automatic initialization
- **Security Configuration**: Pre-configured encryption key management
- **Persistent Storage**: Data persists across container restarts

## Quick Start

```bash
# Start containers (will pull images automatically)
docker-compose up -d

# Stop containers
docker-compose down
```

## Access n8n

- **URL**: http://localhost:5678
- **Initial Setup**: On first access, you'll be prompted to create an owner account
- **Email**: Your admin email address
- **Password**: Choose a strong password

## Configuration

### Environment Variables

Edit `docker-compose.yml` to customize environment variables:

#### Database Connection
- `DB_POSTGRESDB_HOST`: PostgreSQL hostname (default: n8n-postgres)
- `DB_POSTGRESDB_PORT`: PostgreSQL port (default: 5432)
- `DB_POSTGRESDB_DATABASE`: Database name (default: n8n)
- `DB_POSTGRESDB_USER`: PostgreSQL username (default: n8n)
- `DB_POSTGRESDB_PASSWORD`: PostgreSQL password (default: n8n_password)

#### Security Configuration
- `N8N_ENCRYPTION_KEY`: Encryption key for stored credentials (auto-generated if not set)

**Important**: The encryption key is used to encrypt credentials stored in the database. If you lose this key, you will lose access to all stored credentials and will need to re-enter them.

#### URL Configuration
- `WEBHOOK_URL`: External URL for webhook endpoints (e.g., https://n8n.example.com)
- `N8N_HOST`: Host n8n listens on (default: 0.0.0.0)
- `N8N_PORT`: Port n8n listens on (default: 5678)
- `N8N_PROTOCOL`: Protocol for the editor UI (http or https)

#### Timezone
- `GENERIC_TIMEZONE`: Timezone for cron-based triggers (default: UTC)
- `TZ`: System timezone (default: UTC)

## Features

### Core Features
- **Visual Workflow Editor**: Drag-and-drop interface for building automations
- **400+ Integrations**: Native connectors for popular apps and services
- **Webhook Support**: Trigger workflows from external events
- **Cron Scheduling**: Schedule workflows on any interval
- **Error Handling**: Built-in retry logic and error workflows
- **Version Control**: Import/export workflows as JSON
- **Credential Management**: Encrypted storage for API keys and tokens
- **Execution Logging**: Full history of workflow executions

### Custom Docker Image Features
- **Bundled Scripts**: All initialization scripts bundled in the image (no host mounts required)
- **Automatic Initialization**: Database setup on first run with retry logic
- **Idempotent Operations**: Safe to restart containers without re-initialization
- **Multi-Platform Support**: Compatible with amd64 and arm64 architectures
- **Encryption Key Management**: Auto-generated and persisted encryption key
- **State Detection**: Skips re-initialization on restart using marker files
- **Color-Coded Output**: User-friendly logs with clear status messages

## System Requirements

- Docker Engine 20.10+
- Docker Compose 1.29+
- 1GB RAM minimum (2GB recommended)
- 10GB disk space minimum

## Volumes

The application uses two Docker volumes:

- `n8n_data`: n8n data directory (workflows, credentials, execution data)
- `postgres_data`: PostgreSQL database files

## Troubleshooting

### Container Won't Start

**Symptom**: Container exits immediately or fails to start

**Solution**:
```bash
docker-compose logs n8n
docker-compose logs n8n-postgres
```

Look for error messages in the logs and address the specific issue.

### Database Connection Errors

**Symptom**: n8n cannot connect to PostgreSQL

**Solution**:
1. Verify database credentials:
   ```bash
   docker-compose exec n8n env | grep -E 'DB_POSTGRESDB'
   ```
2. Check if PostgreSQL is ready:
   ```bash
   docker-compose exec n8n-postgres pg_isready -U n8n
   ```
3. Verify network connectivity:
   ```bash
   docker-compose exec n8n ping n8n-postgres
   ```

### Webhook URLs Not Working

**Symptom**: External services can't reach n8n webhooks

**Solution**:
1. Verify `WEBHOOK_URL` is set correctly in `docker-compose.yml`
2. Ensure the URL is publicly accessible
3. Check firewall rules allow traffic to the n8n port
4. Verify reverse proxy configuration if using one

### Lost Credentials After Restart

**Symptom**: Stored credentials become invalid after container restart

**Cause**: Encryption key changed between restarts

**Solution**:
1. Check if `N8N_ENCRYPTION_KEY` is set consistently:
   ```bash
   docker-compose exec n8n env | grep N8N_ENCRYPTION_KEY
   ```
2. If using auto-generated key, verify the key file persists:
   ```bash
   docker-compose exec n8n cat /home/node/.n8n/.encryption_key
   ```
3. Set a fixed `N8N_ENCRYPTION_KEY` in `docker-compose.yml` to prevent rotation

### Permission Issues

**Symptom**: Permission denied errors in logs

**Solution**:
Reset permissions:
```bash
docker-compose exec n8n chown -R node:node /home/node/.n8n
```

### Reset Installation

**Symptom**: Need to start fresh with clean state

**Solution**:
To completely reset and start over:
```bash
docker-compose down -v
docker-compose up -d
```

**Warning**: This will delete all data including workflows, credentials, and execution history.

## Naming Conventions

This bundle follows the Clouve multi-app naming conventions:

- **Main container**: `n8n` (isPublic: true) - Receives ingress exposure
- **Database container**: `n8n-postgres` (isPublic: false) - Prefixed with main app name

This pattern ensures:
- Clear relationship between containers
- Proper ingress routing to public-facing services
- Compatibility with Clouve deployment scripts

## Production Deployment

### Pre-Deployment Checklist

Before deploying to production:

1. **Set a fixed encryption key** via `N8N_ENCRYPTION_KEY` environment variable
2. **Use strong passwords** for database accounts (minimum 16 characters)
3. **Configure SSL/TLS** using a reverse proxy (nginx, traefik, etc.)
4. **Set `WEBHOOK_URL`** to your public HTTPS URL
5. **Set up regular backups** of the PostgreSQL database
6. **Configure timezone** via `GENERIC_TIMEZONE` for accurate scheduling
7. **Set resource limits** for containers
8. **Enable monitoring** and logging
9. **Test disaster recovery** procedures
10. **Secure the editor** behind authentication and network controls

### Clouve Marketplace Deployment

The `clv-docker-compose.yml` file is ready for deployment to the Clouve marketplace with:
- Proper bundle metadata for marketplace listing
- Environment variable type mappings for UI generation
- Volume size specifications for resource allocation
- Health check configuration for monitoring
- Container metadata for deployment orchestration

## Building Custom Docker Images

The n8n bundle uses custom Docker images hosted in the Clouve registry. To build the images:

### Using the Build Script

```bash
# Local build (single platform - current architecture)
cd magneto/dkr
./build.sh n8n

# Build and push to registry (multi-platform: amd64 + arm64)
cd magneto/dkr
./build.sh n8n --push
```

### Image Details

**n8n Application Image:**
- **Registry**: `r.clv.zone/e2eorg/n8n`
- **Base Image**: `n8nio/n8n:2.12.3`
- **Enhancements**: Custom entrypoint, bundled scripts, automatic initialization
- **Platforms**: linux/amd64, linux/arm64

**PostgreSQL Database Image:**
- **Registry**: `r.clv.zone/e2eorg/n8n-postgres`
- **Base Image**: `postgres:18`
- **Purpose**: Hosted in Clouve registry to avoid Docker Hub rate limits
- **Platforms**: linux/amd64, linux/arm64

### Image Structure

```
magneto/dkr/apps/n8n/image/
├── Dockerfile                    # Custom n8n image
├── build.config                  # Build configuration
├── installer/
│   ├── entrypoint.sh            # Main entrypoint script
│   ├── install.sh               # Installation script
│   └── update-config.sh         # Configuration update script
└── postgres/
    └── Dockerfile               # Custom PostgreSQL image
```

## Support

For n8n-specific issues, consult:
- [n8n Documentation](https://docs.n8n.io)
- [n8n Community Forums](https://community.n8n.io)
- [n8n GitHub Repository](https://github.com/n8n-io/n8n)

For Docker image or deployment issues:
- Check container logs: `docker-compose logs n8n`
- Review this README's Troubleshooting section

## License

n8n is licensed under the Sustainable Use License.
