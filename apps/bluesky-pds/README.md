# Bluesky PDS Docker Application

Bluesky PDS (Personal Data Server) deployment for Clouve marketplace with automatic secret generation. The PDS is a self-hosted server that stores your data and federates with the wider Bluesky social network using the AT Protocol.

## Features

- ✅ **Automatic Secret Generation**: All required secrets and keys are automatically generated on first deployment
- ✅ **Persistent Secrets**: Generated secrets are saved to `/pds/.secrets` for persistence across restarts
- ✅ **Secure by Default**: Uses cryptographically secure random generation for all secrets
- ✅ **K256 Key Generation**: Automatically generates secp256k1 private keys for PLC rotation
- ✅ **No Manual Configuration**: Zero-touch deployment with secure defaults

## Quick Start

```bash
# Build and start container
docker-compose up -d

# View logs to see generated credentials
docker-compose logs bluesky-pds

# Stop container
docker-compose down
```

## Access Bluesky PDS

- **URL**: http://localhost:3000
- **Health Check**: http://localhost:3000/xrpc/_health
- **Admin Password**: Check container logs or `/pds/.secrets` file for auto-generated password

## Configuration

Edit `docker-compose.yml` to customize environment variables:

```yaml
environment:
  # PDS Configuration
  PDS_HOSTNAME: localhost
  PDS_DATA_DIRECTORY: /pds
  PDS_BLOBSTORE_DISK_LOCATION: /pds/blocks
  
  # Admin Configuration
  PDS_ADMIN_PASSWORD: bluesky_admin_password
  PDS_JWT_SECRET: bluesky_jwt_secret_change_me
  PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX: bluesky_plc_rotation_key_change_me
  
  # Email Configuration (optional)
  PDS_EMAIL_SMTP_URL: ""
  PDS_EMAIL_FROM_ADDRESS: ""
  
  # Feature Flags
  PDS_INVITE_REQUIRED: "0"
  LOG_ENABLED: "1"
```

## Environment Variables

### PDS Configuration
- `PDS_HOSTNAME` - Public hostname for your PDS (e.g., pds.example.com)
- `PDS_DATA_DIRECTORY` - Directory for PDS data storage (default: /pds)
- `PDS_BLOBSTORE_DISK_LOCATION` - Directory for blob storage (default: /pds/blocks)
- `PDS_DID_PLC_URL` - PLC directory URL (default: https://plc.directory)
- `PDS_BSKY_APP_VIEW_URL` - Bluesky app view URL (default: https://api.bsky.app)
- `PDS_BSKY_APP_VIEW_DID` - Bluesky app view DID (default: did:web:api.bsky.app)
- `PDS_REPORT_SERVICE_URL` - Moderation service URL (default: https://mod.bsky.app)
- `PDS_REPORT_SERVICE_DID` - Moderation service DID
- `PDS_CRAWLERS` - Crawler URLs (default: https://bsky.network)

### Admin Configuration (Auto-Generated)
- `PDS_ADMIN_PASSWORD` - Admin password for PDS management (auto-generated on first run)
- `PDS_JWT_SECRET` - JWT secret for authentication (auto-generated on first run)
- `PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX` - PLC rotation key in hex format (auto-generated on first run)
- `PDS_DPOP_SECRET` - DPoP secret for OAuth (auto-generated on first run)

**Note**: All these secrets are automatically generated using cryptographically secure methods:
- Passwords and secrets use OpenSSL random generation (base64 encoded)
- PLC rotation key is a proper secp256k1 (K256) private key in hexadecimal format
- Generated values are saved to `/pds/.secrets` for persistence

### Email Configuration (Optional)
- `PDS_EMAIL_SMTP_URL` - SMTP URL for sending emails (e.g., smtps://username:password@smtp.example.com/)
- `PDS_EMAIL_FROM_ADDRESS` - From address for emails (e.g., admin@example.com)

### Feature Flags
- `PDS_INVITE_REQUIRED` - Require invite codes for new accounts (0 = disabled, 1 = enabled)
- `LOG_ENABLED` - Enable logging (0 = disabled, 1 = enabled)

## Verification

```bash
# Check container status
docker-compose ps

# View logs (including generated credentials)
docker-compose logs -f bluesky-pds

# View generated secrets
docker-compose exec bluesky-pds cat /pds/.secrets

# Test PDS health
curl http://localhost:3000/xrpc/_health

# Test WebSocket connection (requires wsdump)
wsdump "ws://localhost:3000/xrpc/com.atproto.sync.subscribeRepos?cursor=0"
```

## Creating Accounts

### Using pdsadmin (inside container)

```bash
# Create an account directly
docker-compose exec bluesky-pds pdsadmin account create

# Create an invite code
docker-compose exec bluesky-pds pdsadmin create-invite-code
```

### Using the Bluesky App

1. Get the Bluesky app:
   - [Bluesky for Web](https://bsky.app)
   - [Bluesky for iPhone](https://apps.apple.com/us/app/bluesky-social/id6444370199)
   - [Bluesky for Android](https://play.google.com/store/apps/details?id=xyz.blueskyweb.app)

2. During signup, enter your PDS URL (e.g., http://localhost:3000)

3. If `PDS_INVITE_REQUIRED` is set to "1", you'll need an invite code

## Features

- ✅ Official Bluesky PDS Docker image
- ✅ Full AT Protocol federation support
- ✅ Self-hosted data storage
- ✅ Custom domain handles
- ✅ Email verification support (with SMTP)
- ✅ Invite code system
- ✅ WebSocket support for real-time updates
- ✅ Health check endpoint
- ✅ Data persistence across container restarts

## Files

- `docker-compose.yml` - Container orchestration for local development
- `clv-docker-compose.yml` - Clouve marketplace deployment configuration
- `image/Dockerfile` - Custom Bluesky PDS Docker image definition (if needed)
- `image/build.config` - Build configuration for the centralized build script
- `logo.png` - Bluesky logo
- `README.md` - This documentation

## Troubleshooting

### Container won't start
```bash
docker-compose logs bluesky-pds
```

### Health check fails
```bash
# Check if the service is responding
curl -v http://localhost:3000/xrpc/_health

# Check container logs
docker-compose logs bluesky-pds
```

### WebSocket connection issues
Ensure your reverse proxy (if using one) is configured to support WebSocket connections. The PDS requires WebSocket support for federation.

### Email not sending
1. Verify SMTP configuration in `PDS_EMAIL_SMTP_URL`
2. Ensure special characters in username/password are URL-encoded
3. Check that your server allows outbound connections on SMTP ports
4. Test SMTP connection manually

### Account creation fails
1. Check that `PDS_HOSTNAME` matches your actual domain
2. Verify DNS is configured correctly (if using a custom domain)
3. Ensure TLS certificates are valid (if using HTTPS)

## Setting up SMTP

To enable email verification and notifications, configure an SMTP service:

### Using Resend
```bash
PDS_EMAIL_SMTP_URL=smtps://resend:<your-api-key>@smtp.resend.com:465/
PDS_EMAIL_FROM_ADDRESS=admin@your.domain
```

### Using SendGrid
```bash
PDS_EMAIL_SMTP_URL=smtps://apikey:<your-api-key>@smtp.sendgrid.net:465/
PDS_EMAIL_FROM_ADDRESS=admin@your.domain
```

### Using Standard SMTP
```bash
PDS_EMAIL_SMTP_URL=smtps://username:password@smtp.example.com/
PDS_EMAIL_FROM_ADDRESS=admin@your.domain
```

### Using Local Sendmail
```bash
PDS_EMAIL_SMTP_URL=smtp:///?sendmail=true
PDS_EMAIL_FROM_ADDRESS=admin@your.domain
```

**Note**: Special characters in username/password must be URL-encoded (e.g., @ becomes %40, & becomes %26)

## Production Deployment

Before deploying to production:

1. **Update all credentials**:
   - Change `PDS_ADMIN_PASSWORD` to a strong password
   - Generate secure values for `PDS_JWT_SECRET` and `PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX`

2. **Configure your domain**:
   - Set `PDS_HOSTNAME` to your actual domain (e.g., pds.example.com)
   - Configure DNS A records for your domain and wildcard subdomain
   - Ensure ports 80 and 443 are open in your firewall

3. **Set up TLS/SSL**:
   - Use a reverse proxy (Caddy, nginx, or Traefik) for automatic HTTPS
   - The official PDS installer includes Caddy for automatic TLS

4. **Configure email** (recommended):
   - Set up SMTP for email verification
   - Configure `PDS_EMAIL_SMTP_URL` and `PDS_EMAIL_FROM_ADDRESS`

5. **Adjust feature flags**:
   - Set `PDS_INVITE_REQUIRED` to "1" if you want to control account creation
   - Set `LOG_ENABLED` to "0" in production if you don't need verbose logging

6. **Start and verify**:
   ```bash
   docker-compose up -d
   curl https://your-domain.com/xrpc/_health
   ```

## Building and Pushing Images

This deployment uses the official Bluesky PDS Docker image. If you need to build a custom image:

```bash
# Build images locally (amd64 only)
cd ..
./build.sh bluesky-pds

# Build and push multi-platform images to registry (amd64 + arm64)
cd ..
./build.sh bluesky-pds --push
```

For more information about the build system, see the [Build Script Documentation](../README.md).

## Clouve Marketplace Deployment

The `clv-docker-compose.yml` file contains Clouve-specific extensions for marketplace deployment:
- `x-clouve-metadata` - Container metadata (purpose, resources, visibility)
- `x-clouve-environment-types` - Environment variable types for UI generation
- `x-clouve-healthcheck` - Health check configuration
- `x-clouve-volumes` - Volume configuration and sizing

## About Bluesky PDS

The Bluesky Personal Data Server (PDS) is a self-hosted server that stores your social media data and federates with the wider Bluesky network using the AT Protocol. By running your own PDS, you have full control over your data while still being able to interact with the entire Bluesky social network.

### Key Features
- **Self-hosted data**: Your posts, likes, and follows are stored on your server
- **Federation**: Seamlessly interact with the entire Bluesky network
- **Custom handles**: Use your own domain as your handle (e.g., @username.yourdomain.com)
- **Data portability**: Easily migrate your data between PDS instances
- **Open protocol**: Built on the open AT Protocol standard

### AT Protocol
The Authenticated Transfer Protocol (atproto) is a federated protocol for large-scale distributed social applications. It provides:
- Account portability
- Algorithmic choice
- Interoperation between services
- Performance at scale

For more information:
- Bluesky: https://bsky.app
- AT Protocol: https://atproto.com
- PDS Documentation: https://github.com/bluesky-social/pds
- PDS Admins Discord: https://discord.gg/e7hpHxRfBP


