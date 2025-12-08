# Gibbon Docker Application

Gibbon deployment for Clouve marketplace using a custom Docker image based on PHP 8.3 with Apache. Gibbon is an open-source school management platform designed for educational institutions.

## Table of Contents

- [Quick Start](#quick-start)
- [Access Gibbon](#access-gibbon)
- [Dynamic Configuration Updates](#dynamic-configuration-updates)
- [Environment Variables](#environment-variables)
- [Common Configuration Scenarios](#common-configuration-scenarios)
- [Moodle Integration](#moodle-integration)
- [Features](#features)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Building and Deployment](#building-and-deployment)
- [About Gibbon](#about-gibbon)

## Quick Start

```bash
# Start containers (will pull images automatically)
docker-compose up -d

# Stop containers
docker-compose down
```

## Access Gibbon

- **URL**: http://localhost:8080
- **Admin Username**: admin
- **Admin Password**: admin_password
- **Admin Email**: admin@example.com

## Dynamic Configuration Updates

🎯 **Key Feature**: This Gibbon Docker image automatically updates configuration from environment variables on every container restart. No manual config editing needed!

### What's Automatic?

#### ✅ Database Credentials
The `config.php` file is automatically updated with current database credentials from environment variables on every container startup:
- `DB_HOST` → `$databaseServer`
- `DB_NAME` → `$databaseName`
- `DB_USER` → `$databaseUsername`
- `DB_PASSWORD` → `$databasePassword`

**Benefits**:
- Rotate database credentials by updating environment variables and restarting
- No manual editing of `config.php` required
- Configuration stays synchronized with Docker Compose or Kubernetes environment

#### ✅ Application URL
The `GIBBON_URL` environment variable is automatically synchronized with the `absoluteURL` setting in the Gibbon database on every container startup.

**Benefits**:
- Change application URL by updating environment variable and restarting
- Database automatically reflects the new URL
- No manual database updates or SQL commands required
- Perfect for environments where URLs change (dev, staging, production)

### How It Works

**Startup Sequence**:
```
Container Start → Wait for MySQL → Install/Upgrade (if needed)
→ Clear uploads cache → Update Configuration → Start Apache
```

The `update-config.sh` script runs automatically on every startup:
1. Updates `config.php` with database credentials from environment variables
2. Waits for database to be ready
3. Updates `absoluteURL` in the database with current `GIBBON_URL` value
4. Verifies all updates were successful

### Verification

**Check container logs**:
```bash
docker logs gibbon_app | grep -A 20 "UPDATING CONFIGURATION"
```

You should see:
```
##################################################################
UPDATING CONFIGURATION FROM ENVIRONMENT VARIABLES
##################################################################
Found config.php at /var/www/html/config.php
Updating database credentials in config.php...
  ✓ Updated $databaseServer to: gibbon-mysql
  ✓ Updated $databaseName to: gibbon
  ✓ Updated $databaseUsername to: gibbon
  ✓ Updated $databasePassword
Database credentials in config.php updated successfully!

Updating absoluteURL in database...
  ✓ absoluteURL updated successfully in database!
  Current absoluteURL in database: http://localhost:8080
============================================================================
Configuration update complete!
============================================================================
```

**Check config.php**:
```bash
docker exec gibbon_app grep '^\$database' /var/www/html/config.php
```

**Check database URL**:
```bash
docker exec gibbon_mysql mysql -u gibbon -pgibbon_password gibbon -sN -e \
  "SELECT value FROM gibbonSetting WHERE name='absoluteURL';"
```

## Environment Variables

### Database Configuration (Auto-Updated)
- `DB_HOST` - Database host (default: gibbon-mysql)
- `DB_NAME` - Database name (default: gibbon)
- `DB_USER` - Database user (default: gibbon)
- `DB_PASSWORD` - Database password

### Application Configuration (Auto-Updated)
- `GIBBON_URL` - External URL for Gibbon (e.g., `http://localhost:8080` or `https://gibbon.example.com`)

### Initial Installation Configuration (Used Once)
- `GIBBON_AUTOINSTALL` - Enable automatic installation (1 = enabled, 0 = disabled)
- `GIBBON_TITLE` - Site title
- `GIBBON_FIRSTNAME` - Admin first name
- `GIBBON_LASTNAME` - Admin last name
- `GIBBON_EMAIL` - Admin email address
- `GIBBON_USERNAME` - Admin username
- `GIBBON_PASSWORD` - Admin password
- `GIBBON_SYSTEM_NAME` - System name
- `GIBBON_ORGANISATION_NAME` - Organization name
- `GIBBON_ORGANISATION_INITIALS` - Organization initials
- `DEMO_DATA` - Include demo data (Y/N)
- `GIBBON_LOG_LEVEL` - Apache log level (debug, info, warn, error)

### Example Configuration

Edit `docker-compose.yml`:

```yaml
environment:
  # Database Configuration (auto-updated on restart)
  DB_HOST: gibbon-mysql
  DB_NAME: gibbon
  DB_USER: gibbon
  DB_PASSWORD: gibbon_password

  # Application URL (auto-updated on restart)
  GIBBON_URL: http://localhost:8080

  # Initial Installation Configuration
  GIBBON_AUTOINSTALL: "1"
  GIBBON_TITLE: My School
  GIBBON_FIRSTNAME: Admin
  GIBBON_LASTNAME: User
  GIBBON_EMAIL: admin@example.com
  GIBBON_USERNAME: admin
  GIBBON_PASSWORD: admin_password
  GIBBON_SYSTEM_NAME: My School
  GIBBON_ORGANISATION_NAME: My School
  GIBBON_ORGANISATION_INITIALS: MS
  DEMO_DATA: "N"
  GIBBON_LOG_LEVEL: info
```

## Common Configuration Scenarios

### Scenario 1: Change Application URL

Moving from development to production:

```bash
# 1. Edit docker-compose.yml
environment:
  GIBBON_URL: https://gibbon.school.edu  # Changed from http://localhost:8080

# 2. Restart container
docker-compose restart gibbon

# 3. Done! URL is updated in database automatically.
```

### Scenario 2: Rotate Database Password

Security policy requires quarterly password rotation:

```bash
# 1. Update password in MySQL
docker-compose exec gibbon-mysql mysql -u root -proot_password -e \
  "ALTER USER 'gibbon'@'%' IDENTIFIED BY 'new_password_q2';"

# 2. Edit docker-compose.yml
environment:
  DB_PASSWORD: new_password_q2  # Changed from old_password_q1

# 3. Restart container
docker-compose restart gibbon

# 4. Done! config.php is updated automatically.
```

### Scenario 3: Migrate to Different Database

Moving from local MySQL to managed database service:

```bash
# 1. Migrate data to new database server
# 2. Edit docker-compose.yml
environment:
  DB_HOST: mysql.cloud-provider.com  # Changed from gibbon-mysql
  DB_NAME: gibbon_prod               # Changed from gibbon
  DB_USER: gibbon_prod_user          # Changed from gibbon
  DB_PASSWORD: secure_cloud_password # Changed from gibbon_password

# 3. Restart container
docker-compose restart gibbon

# 4. Done! config.php is updated automatically.
```

## Moodle Integration

The Gibbon image supports integration with Moodle through multi-part environment variables. This approach is **Clouve marketplace-compatible** and does not require volume mounts.

### Integration Environment Variables

- `ENABLE_MOODLE_INTEGRATION` - Enable Moodle integration (set to `"true"` to enable)
- `GIBBON_INTEGRATION_SQL_1` - First SQL part (typically moodleUser view)
- `GIBBON_INTEGRATION_SQL_2` - Second SQL part (typically moodleCourse view)
- `GIBBON_INTEGRATION_SQL_3` - Third SQL part (typically moodleEnrolment view)
- `GIBBON_INTEGRATION_SQL_N` - Additional SQL parts (automatically detected)

### How It Works

1. **Multi-Part SQL Collection**: The entrypoint script automatically detects and concatenates all `GIBBON_INTEGRATION_SQL_*` environment variables in sequential order (1, 2, 3, ...).

2. **Idempotency**: Integration setup runs only once. A marker file is created at `$INSTALLED_VERSIONS_PATH/.moodle-integration-setup` to prevent re-execution on container restarts.

3. **Database Views Created**:
   - `moodleUser` - Exposes Gibbon users (students and staff) for Moodle SSO authentication
   - `moodleCourse` - Exposes Gibbon courses for the current school year
   - `moodleEnrolment` - Exposes course enrollments (students and teachers)

4. **Verification**: After creating views, the script verifies each view is accessible and logs the results.

### Example Configuration

```yaml
environment:
  # Enable Moodle integration
  ENABLE_MOODLE_INTEGRATION: "true"

  # Part 1: Create moodleUser view for SSO authentication
  GIBBON_INTEGRATION_SQL_1: |
    CREATE OR REPLACE VIEW moodleUser AS
      SELECT
        username,
        preferredName,
        surname,
        email,
        website
      FROM gibbonPerson
      JOIN gibbonRole ON (gibbonRole.gibbonRoleID = gibbonPerson.gibbonRoleIDPrimary)
      WHERE (category = 'Student' OR category = 'Staff')
        AND status = 'Full';

  # Part 2: Create moodleCourse view for course synchronization
  GIBBON_INTEGRATION_SQL_2: |
    CREATE OR REPLACE VIEW moodleCourse AS
      SELECT *
      FROM gibbonCourse
      WHERE gibbonSchoolYearID = (
        SELECT gibbonSchoolYearID
        FROM gibbonSchoolYear
        WHERE status = 'Current'
      );

  # Part 3: Create moodleEnrolment view for enrollment synchronization
  GIBBON_INTEGRATION_SQL_3: |
    CREATE OR REPLACE VIEW moodleEnrolment AS
      SELECT
        gibbonCourseClass.gibbonCourseID,
        gibbonPerson.username,
        'student' AS role
      FROM gibbonCourseClassPerson
      JOIN gibbonPerson ON (gibbonCourseClassPerson.gibbonPersonID = gibbonPerson.gibbonPersonID)
      JOIN gibbonCourseClass ON (gibbonCourseClassPerson.gibbonCourseClassID = gibbonCourseClass.gibbonCourseClassID)
      WHERE gibbonCourseClassPerson.role = 'Student'
        AND gibbonPerson.status = 'Full'
      UNION
      SELECT
        gibbonCourseClass.gibbonCourseID,
        gibbonPerson.username,
        'editingteacher' AS role
      FROM gibbonCourseClassPerson
      JOIN gibbonPerson ON (gibbonCourseClassPerson.gibbonPersonID = gibbonPerson.gibbonPersonID)
      JOIN gibbonCourseClass ON (gibbonCourseClassPerson.gibbonCourseClassID = gibbonCourseClass.gibbonCourseClassID)
      WHERE gibbonCourseClassPerson.role = 'Teacher'
        AND gibbonPerson.status = 'Full';
```

### Benefits

- ✅ **Improved Readability**: Each SQL part is clearly separated and can be documented independently
- ✅ **Better Maintainability**: Easier to edit individual parts without affecting others
- ✅ **Modular Design**: Can add/remove/modify parts independently
- ✅ **Marketplace Compatible**: No volume mounts required - works with Clouve marketplace constraints
- ✅ **Automatic Concatenation**: Parts are automatically detected and concatenated in order

### Verification Logs

When integration is enabled, you'll see output like:

```
##################################################################
GIBBON INTEGRATION SQL FROM ENVIRONMENT VARIABLES
##################################################################
Creating Moodle integration views...
Collecting SQL parts...
  Found part 1
  Found part 2
  Found part 3
✓ Collected 3 SQL part(s)
Executing SQL to create integration views...
✓ Integration views created successfully
Verifying integration views...
✓ moodleUser view is accessible
✓ moodleCourse view is accessible
✓ moodleEnrolment view is accessible
✓ Gibbon-to-Moodle integration setup completed successfully!
##################################################################
```

**Note**: The old POST-INSTALL HOOK approach (mounting scripts at `/clouve/hooks/post-install.sh`) has been removed. Use the multi-part environment variable approach documented above instead.

## Features

- ✅ **Dynamic Configuration Updates**: Automatic synchronization of database credentials and application URL
- ✅ **Custom Docker Image**: Built from Dockerfile (Gibbon v29.0.00)
- ✅ **Multi-Platform Support**: amd64 and arm64 architectures
- ✅ **Automatic Installation**: Zero-touch Gibbon installation
- ✅ **MySQL 8.0 Database**: With health checks and retry logic
- ✅ **Installation State Detection**: Skips re-installation on restart
- ✅ **Data Persistence**: Across container restarts
- ✅ **PHP 8.3 with Apache**: All required PHP extensions pre-installed
- ✅ **Moodle Integration**: Optional database views for SSO and course synchronization

## Verification

### Check Container Status
```bash
docker-compose ps
```

### View Logs
```bash
# All logs
docker-compose logs -f gibbon

# Configuration update logs
docker logs gibbon_app | grep -A 20 "UPDATING CONFIGURATION"
```

### Test Gibbon
```bash
curl http://localhost:8080
```

### Check Database Connection
```bash
docker-compose exec gibbon mysql -h gibbon-mysql -u gibbon -pgibbon_password -e "SELECT 1;"
```

### Verify Configuration Updates
```bash
# Check config.php
docker exec gibbon_app grep '^\$database' /var/www/html/config.php

# Check database URL
docker exec gibbon_mysql mysql -u gibbon -pgibbon_password gibbon -sN -e \
  "SELECT value FROM gibbonSetting WHERE name='absoluteURL';"
```

## Troubleshooting

### Configuration Not Updating

**Symptom**: Changes to environment variables don't reflect in config.php or database

**Solutions**:
```bash
# 1. Ensure container is restarted after environment variable change
docker-compose restart gibbon

# 2. Check script permissions
docker exec gibbon_app ls -la /clouve/gibbon/installer/update-config.sh

# 3. Check container logs for errors
docker logs gibbon_app | grep "UPDATING CONFIGURATION"

# 4. Verify database connectivity
docker exec gibbon_app mysqladmin ping -h"$DB_HOST" -u"$DB_USER" -p"$DB_PASSWORD"
```

### Container Won't Start
```bash
# Check Gibbon logs
docker-compose logs gibbon

# Check MySQL logs
docker-compose logs gibbon-mysql
```

### Gibbon Shows Installation Screen
Check if auto-installation is enabled:
```bash
docker-compose exec gibbon env | grep GIBBON_AUTOINSTALL
```

### Database Connection Fails
```bash
# Check container status
docker-compose ps

# Test database connectivity
docker-compose exec gibbon-mysql mysqladmin ping -h localhost -u root -proot_password
```

### Special Characters in Password

**Symptom**: Database connection fails after password update with special characters

**Solution**: Use environment variable file instead of inline values:
```bash
# Create .env file:
DB_PASSWORD='p@$$w0rd!#'

# Reference in docker-compose.yml:
env_file:
  - .env
```

### URL Not Updating in Database

**Symptom**: config.php updates but database URL stays old

**Solutions**:
```bash
# 1. Check if Gibbon is fully installed
docker exec gibbon_mysql mysql -u gibbon -pgibbon_password gibbon -e \
  "SHOW TABLES LIKE 'gibbonSetting';"

# 2. Manually update if needed
docker exec gibbon_mysql mysql -u gibbon -pgibbon_password gibbon -e \
  "UPDATE gibbonSetting SET value='https://new-url.com' WHERE name='absoluteURL';"

# 3. Restart container to trigger automatic update
docker-compose restart gibbon
```

### Check Gibbon Version
```bash
docker-compose exec gibbon cat /clouve/gibbon/installer/version.txt
```

## Building and Deployment

### Building Images

This deployment uses a custom Gibbon Docker image built from the Dockerfile in the `image/` directory.

To build and push images, use the centralized build script:

```bash
# Build images locally (amd64 only)
cd ..
./build.sh gibbon

# Build and push multi-platform images to registry (amd64 + arm64)
cd ..
./build.sh gibbon --push
```

For more information about the build system, see the [Build Script Documentation](../README.md).

### Production Deployment

Before deploying to production:

1. **Update Credentials**: Change all default passwords in `docker-compose.yml`
   - `GIBBON_PASSWORD` - Admin password
   - `DB_PASSWORD` - Database password
   - `MYSQL_ROOT_PASSWORD` - MySQL root password

2. **Configure Application**:
   - `GIBBON_URL` - Set to your production domain (e.g., `https://gibbon.school.edu`)
   - `GIBBON_LOG_LEVEL` - Set to `warn` or `error`
   - `GIBBON_ORGANISATION_NAME` - Your organization name
   - `GIBBON_ORGANISATION_INITIALS` - Your organization initials

3. **Deploy and Verify**:
   ```bash
   docker-compose up -d
   docker-compose ps
   docker logs gibbon_app
   curl https://your-domain.com
   ```

### Clouve Marketplace Deployment

The `clv-docker-compose.yml` file contains Clouve-specific extensions for marketplace deployment:
- `x-clouve-metadata` - Container metadata (purpose, resources, visibility)
- `x-clouve-environment-types` - Environment variable types for UI generation
- `x-clouve-healthcheck` - Health check configuration
- `x-clouve-volumes` - Volume configuration and sizing

### Files

- `docker-compose.yml` - Container orchestration for local development
- `clv-docker-compose.yml` - Clouve marketplace deployment configuration
- `image/Dockerfile` - Custom Gibbon Docker image definition
- `image/installer/entrypoint.sh` - Container entrypoint script
- `image/installer/update-config.sh` - Configuration update script
- `image/build.config` - Build configuration for the centralized build script
- `test-config-updates.sh` - Automated test script for configuration updates
- `start.sh` - Start containers
- `stop.sh` - Stop containers
- `logo.png` - Gibbon logo

## About Gibbon

Gibbon is an intuitive, open-source school management platform designed to revolutionize the way educational institutions operate. It offers a comprehensive suite of tools for managing administrative tasks, tracking student progress, and facilitating effective communication among teachers, students, and parents.

### Key Features
- Timetabling and scheduling
- Attendance tracking
- Grade reporting and assessment
- Student information management
- Parent and student portals
- Communication tools
- Customizable modules
- Multi-language support

### Compatibility

- **Gibbon Version**: 29.0.00
- **PHP Version**: 8.3
- **MySQL Version**: 8.0
- **Docker Compose**: 3.8+
- **Kubernetes**: Compatible with ConfigMaps and Secrets

For more information, visit: https://gibbonedu.org/

---

## Summary

This Gibbon Docker deployment provides:

✅ **Zero-Touch Configuration**: Automatic updates of database credentials and application URL
✅ **Environment Parity**: Easy configuration management across dev/staging/prod
✅ **Security**: Support for credential rotation without manual file editing
✅ **Cloud-Native**: Works seamlessly with Kubernetes ConfigMaps and Secrets
✅ **Automation-Friendly**: Configuration updates happen automatically on container restart
✅ **Production-Ready**: Comprehensive error handling, validation, and logging

