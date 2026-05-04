# Docker Marketplace - Management Scripts

This directory contains shared management scripts for Docker Compose applications and bundles.

## Directory Structure

```
marketplace/dkr/
├── apps/              # Individual applications (Gibbon, Moodle, WordPress, etc.)
├── bundles/           # Application bundles (Education Kit, etc.)
├── start.sh           # Shared start script
├── stop.sh            # Shared stop script
├── logs.sh            # Shared logs script
├── status.sh          # Shared status script
├── test.sh            # URL update testing script
├── README.md          # Marketplace packaging guide
└── DEVELOPER_GUIDE.md # This file
```

## Shared Management Scripts

These scripts work with any Docker Compose application or bundle in the `apps/` or `bundles/` directories.

All scripts support three modes of operation:
1. **Simple name mode**: Use just the app/bundle name (searches in apps/ and bundles/)
2. **Relative path mode**: Use a relative path like `apps/wordpress` or `bundles/education-kit`
3. **Local mode**: Run from within an app/bundle directory without arguments

### start.sh - Start Applications/Bundles

Start any application or bundle with optional clean mode.

**Usage:**
```bash
# From marketplace/dkr directory (simple name)
./start.sh <app-or-bundle-name> [--cleanup]

# From marketplace/dkr directory (relative path)
./start.sh <relative-path> [--cleanup]

# From within an app/bundle directory
../../start.sh [--cleanup]
```

**Examples:**
```bash
# Start WordPress (simple name - searches apps/ and bundles/)
./start.sh wordpress

# Start WordPress (relative path - direct)
./start.sh apps/wordpress

# Start Education Kit with clean state (simple name)
./start.sh education-kit --cleanup

# Start Education Kit with clean state (relative path)
./start.sh bundles/education-kit --cleanup

# Start from within app directory
cd apps/gibbon
../../start.sh

# Clean start from within bundle directory
cd bundles/education-kit
../../start.sh --cleanup
```

**Options:**
- `--cleanup` - Remove all existing data and start fresh (prompts for confirmation)

### stop.sh - Stop Applications/Bundles

Stop any application or bundle with optional volume removal.

**Usage:**
```bash
# From marketplace/dkr directory (simple name)
./stop.sh <app-or-bundle-name> [--cleanup]

# From marketplace/dkr directory (relative path)
./stop.sh <relative-path> [--cleanup]

# From within an app/bundle directory
../../stop.sh [--cleanup]
```

**Examples:**
```bash
# Stop WordPress (preserves data, simple name)
./stop.sh wordpress

# Stop WordPress (relative path)
./stop.sh apps/wordpress

# Stop Education Kit and remove all data (simple name)
./stop.sh education-kit --cleanup

# Stop Education Kit and remove all data (relative path)
./stop.sh bundles/education-kit -v

# Stop from within app directory
cd apps/moodle
../../stop.sh

# Stop and remove volumes from within bundle directory
cd bundles/education-kit
../../stop.sh -v
```

**Options:**
- `--cleanup`, `-v` - Remove volumes and delete all data (prompts for confirmation)

### logs.sh - View Logs

Display logs from any application or bundle.

**Usage:**
```bash
# From marketplace/dkr directory (simple name)
./logs.sh <app-or-bundle-name> [service] [options]

# From marketplace/dkr directory (relative path)
./logs.sh <relative-path> [service] [options]

# From within an app/bundle directory
../../logs.sh [service] [options]
```

**Examples:**
```bash
# Show last 100 lines of WordPress logs (simple name)
./logs.sh wordpress

# Show last 100 lines of WordPress logs (relative path)
./logs.sh apps/wordpress

# Follow Education Kit logs in real-time (simple name)
./logs.sh education-kit -f

# Follow Education Kit logs in real-time (relative path)
./logs.sh bundles/education-kit -f

# Show only Moodle service logs from Education Kit (simple name)
./logs.sh education-kit moodle

# Show only Moodle service logs from Education Kit (relative path)
./logs.sh bundles/education-kit moodle

# Show last 50 lines
./logs.sh wordpress -n 50

# Follow specific service from within directory
cd bundles/education-kit
../../logs.sh gibbon -f
```

**Options:**
- `-f`, `--follow` - Follow log output in real-time (like `tail -f`)
- `-n`, `--lines N` - Show last N lines (default: 100)
- `[service]` - Optional service name to filter logs

### status.sh - Check Status

Display status and resource usage for any application or bundle.

**Usage:**
```bash
# From marketplace/dkr directory (simple name)
./status.sh <app-or-bundle-name>

# From marketplace/dkr directory (relative path)
./status.sh <relative-path>

# From within an app/bundle directory
../../status.sh
```

**Examples:**
```bash
# Check WordPress status (simple name)
./status.sh wordpress

# Check WordPress status (relative path)
./status.sh apps/wordpress

# Check Education Kit status (simple name)
./status.sh education-kit

# Check Education Kit status (relative path)
./status.sh bundles/education-kit

# Check status from within directory
cd apps/gibbon
../../status.sh
```

### test.sh - Test Dynamic URL Updates

Test the dynamic URL update functionality for Docker applications. This script verifies that changing a URL environment variable and restarting the container properly updates the application's internal configuration.

The test script uses environment variable substitution in docker-compose.yml files instead of modifying the files directly, making it cleaner and safer.

**Usage:**
```bash
./test.sh <app-path> [domain1] [domain2] [port]
```

**Arguments:**
- `app-path` - Required. Relative path to app/bundle directory (e.g., `apps/limesurvey`)
- `domain1` - Optional. First test domain (default: `t1.test.clv`)
- `domain2` - Optional. Second test domain (default: `t2.test.clv`)
- `port` - Optional. Port number to use (default: `8080`)

**Examples:**
```bash
# Test LimeSurvey with default domains and port
./test.sh apps/limesurvey

# Test WordPress with default domains and port
./test.sh apps/wordpress

# Test with custom domains (default port: 8080)
./test.sh apps/limesurvey test1.example.com test2.example.com

# Test with custom domains and custom port
./test.sh apps/limesurvey custom1.mysite.com custom2.mysite.com 9090
```

**How It Works:**

The test script performs the following steps:
1. Validates the app directory and docker-compose.yml
2. Starts the application with the first test domain
3. Stops the application
4. Restarts with the second test domain (changed URL)
5. Verifies URL change detection in container logs
6. Tests reverse URL change (back to first domain)
7. Cleans up (stops containers, unsets environment variables)

**Environment Variable Substitution:**

Applications that support dynamic URL testing use environment variable substitution in their docker-compose.yml files:

```yaml
environment:
  # Uses environment variable substitution for testing flexibility
  # Default: http://t1.test.clv:8080
  # Override with: TEST_DOMAIN and TEST_PORT environment variables
  PUBLIC_URL: http://${TEST_DOMAIN:-t1.test.clv}:${TEST_PORT:-8080}
```

This approach:
- ✅ Doesn't modify docker-compose.yml files during testing
- ✅ No temporary backup files needed
- ✅ No risk of corrupted configuration files
- ✅ Version-control friendly
- ✅ Works with default values when environment variables are not set

**Supported Applications:**
- WordPress (`WORDPRESS_SITE_URL`)
- LimeSurvey (`PUBLIC_URL`)

**Test Output:**

The script provides color-coded output showing:
- Test configuration (domains, port)
- Step-by-step progress
- Container logs verification
- URL change detection confirmation
- Pass/fail summary

**Example Output:**
```
[INFO] Test URL 1 (initial): http://t1.test.clv:8080
[INFO] Test URL 2 (changed): http://t2.test.clv:8080
[SUCCESS] Found URL change detection in logs
[SUCCESS] ✓ TEST PASSED: URL change detection is working correctly
```

## Applications

Individual applications in the `apps/` directory:

- **gibbon** - Gibbon Education Platform with MySQL 8.0
- **moodle** - Moodle Learning Management System with MySQL 8.0
- **wordpress** - WordPress CMS with MariaDB (supports dynamic URL updates)
- **limesurvey** - LimeSurvey Survey Platform with MariaDB (supports dynamic URL updates)
- **bluesky-pds** - Bluesky Personal Data Server

Each application has:
- `docker-compose.yml` - Local development configuration with environment variable substitution support
- `clv-docker-compose.yml` - Clouve marketplace configuration
- `README.md` - Application-specific documentation
- `logo.png` - Application logo

**Dynamic URL Configuration:**

Applications marked with "supports dynamic URL updates" use environment variable substitution in their docker-compose.yml files, allowing URL configuration to be changed without modifying the files:

```yaml
# Example from WordPress
WORDPRESS_SITE_URL: http://${TEST_DOMAIN:-t1.test.clv}:${TEST_PORT:-8080}

# Example from LimeSurvey
PUBLIC_URL: http://${TEST_DOMAIN:-t1.test.clv}:${TEST_PORT:-8080}
```

This enables:
- Testing with different domains and ports using the `test.sh` script
- Clean separation between configuration and code
- No file modifications during testing
- Default values when environment variables are not set

## Bundles

Application bundles in the `bundles/` directory combine multiple applications:

- **education-kit** - Gibbon + Moodle with integrated authentication and enrollment

Each bundle has:
- `docker-compose.yml` - Local development configuration
- `clv-docker-compose.yml` - Clouve marketplace configuration
- `README.md` - Bundle-specific documentation
- Additional integration scripts and documentation

## Legacy Scripts

The `apps/` directory contains legacy versions of the management scripts that require an app name parameter. These are maintained for backward compatibility but the shared scripts at this level are recommended for new usage.

## Quick Start Examples

### Start an Application

```bash
# Navigate to marketplace/dkr
cd marketplace/dkr

# Start WordPress
./start.sh wordpress

# Access at http://localhost:8080
```

### Start a Bundle

```bash
# Navigate to marketplace/dkr
cd marketplace/dkr

# Start Education Kit
./start.sh education-kit

# Access Moodle at http://localhost:8080
# Access Gibbon at http://localhost:8081
```

### Work from Within Directory

```bash
# Navigate to app directory
cd marketplace/dkr/apps/gibbon

# Start
../../start.sh

# Check status
../../status.sh

# View logs
../../logs.sh -f

# Stop
../../stop.sh
```

### Clean Restart

```bash
# Stop and remove all data
./stop.sh education-kit --cleanup

# Start fresh
./start.sh education-kit --cleanup
```

## Common Workflows

### Development Workflow

```bash
# Start application
./start.sh wordpress

# Check status
./status.sh wordpress

# Follow logs during development
./logs.sh wordpress -f

# Stop when done (preserves data)
./stop.sh wordpress
```

### Troubleshooting Workflow

```bash
# Check status
./status.sh education-kit

# View recent logs
./logs.sh education-kit

# View specific service logs
./logs.sh education-kit moodle -n 200

# Restart with clean state
./stop.sh education-kit --cleanup
./start.sh education-kit --cleanup
```

### Testing Workflow

```bash
# Start with clean state
./start.sh gibbon --cleanup

# Run tests...

# Clean up completely
./stop.sh gibbon --cleanup
```

### URL Update Testing Workflow

```bash
# Test URL change detection with default settings
./test.sh apps/limesurvey

# Test with custom domains
./test.sh apps/wordpress test1.mysite.com test2.mysite.com

# Test with custom domains and port
./test.sh apps/limesurvey custom1.example.com custom2.example.com 9090

# The test script will:
# 1. Start the app with first domain
# 2. Change to second domain and verify detection
# 3. Change back to first domain and verify
# 4. Clean up automatically
```

## Script Features

### Automatic Detection

The scripts automatically detect:
- Whether you're calling from parent directory or within an app/bundle directory
- Available applications and bundles
- Running containers and their status
- Port mappings and access URLs

### Safety Features

- Confirmation prompts for destructive operations (--cleanup, --cleanup)
- Clear error messages with helpful suggestions
- Validation of docker-compose.yml existence
- Docker and docker-compose availability checks

### Flexible Usage

- Works from any directory level
- Supports both apps and bundles
- Optional service filtering for logs
- Customizable log output (lines, follow mode)

## Requirements

- Docker Engine 20.10+
- Docker Compose 1.29+

## See Also

- Individual app documentation in `apps/*/README.md`
- Bundle documentation in `bundles/*/README.md`
- Build script in `build.sh`

