# Moodle Docker Application

Moodle deployment for Clouve marketplace using a custom Docker image based on PHP 8.3 with Apache. Moodle is a free and open-source learning management system (LMS) written in PHP and distributed under the GNU General Public License.

## Quick Start

```bash
# Start containers (will pull images automatically)
docker-compose up -d

# Stop containers
docker-compose down
```

## Access Moodle

- **URL**: http://localhost:8080
- **Admin Username**: admin
- **Admin Password**: Admin@123
- **Admin Email**: admin@example.com

## Configuration

Edit `docker-compose.yml` to customize environment variables:

### Database Configuration
- `DB_HOST`: Database hostname (default: moodle-mysql)
- `DB_NAME`: Database name (default: moodle)
- `DB_USER`: Database username (default: moodle)
- `DB_PASSWORD`: Database password (default: moodle_password)

### Moodle Application Configuration
- `MOODLE_URL`: Full URL where Moodle will be accessible (default: http://localhost:8080)
  - **Important**: Use the final user-facing URL (e.g., `https://moodle.example.com` for production)
  - SSL proxy mode is **automatically enabled** if the URL starts with `https://`
  - When HTTPS is detected, `$CFG->sslproxy = true;` is added to config.php for proper reverse proxy support
  - **For reverse proxy/SSL termination setups**: Set this to `https://your-domain.com` even if the container runs on HTTP internally
  - This ensures Moodle generates correct HTTPS URLs and doesn't show "Site not HTTPS" warnings
- `MOODLE_SITE_NAME`: Name of your Moodle site (default: My Moodle Site)
- `MOODLE_EMAIL`: Administrator email address (default: admin@example.com)
- `MOODLE_USERNAME`: Administrator username (default: admin)
- `MOODLE_PASSWORD`: Administrator password (default: Admin@123)
- `MOODLE_FULLNAME`: Administrator full name (default: Administrator)
- `MOODLE_SHORTNAME`: Administrator short name (default: Admin)
- `MOODLE_LOG_LEVEL`: Apache log level (default: info)

### Gibbon Integration (Multi-Part SQL Injection)

The Moodle image supports integration with Gibbon through multi-part environment variables. This approach is **Clouve marketplace-compatible** and does not require volume mounts.

#### Integration Environment Variables

**Enable Integration:**
- `ENABLE_GIBBON_INTEGRATION` - Enable Gibbon integration (set to `"true"` to enable)

**Gibbon Database Connection:**
- `GIBBON_DB_HOST` - Gibbon database hostname (required)
- `GIBBON_DB_NAME` - Gibbon database name (required)
- `GIBBON_DB_USER` - Gibbon database username (required)
- `GIBBON_DB_PASSWORD` - Gibbon database password (required)

**SQL Parts:**
- `MOODLE_INTEGRATION_SQL_1` - First SQL part (typically plugin enablement)
- `MOODLE_INTEGRATION_SQL_2` - Second SQL part (typically auth_db configuration)
- `MOODLE_INTEGRATION_SQL_3` - Third SQL part (typically enrol_database configuration)
- `MOODLE_INTEGRATION_SQL_N` - Additional SQL parts (automatically detected)

#### How It Works

1. **Multi-Part SQL Collection**: The entrypoint script automatically detects and concatenates all `MOODLE_INTEGRATION_SQL_*` environment variables in sequential order (1, 2, 3, ...).

2. **Dependency Waiting**: Before executing SQL, the script:
   - Waits for Gibbon database to be ready (up to 60 attempts, 2 seconds each)
   - Waits for Gibbon integration views to be created (up to 30 attempts, 2 seconds each)
   - Validates required Gibbon database environment variables

3. **Idempotency**: Integration setup runs only once. A marker file is created at `$INSTALLED_VERSIONS_PATH/.gibbon-integration-setup` to prevent re-execution on container restarts.

4. **Plugins Configured**:
   - **External Database Authentication (auth_db)** - Authenticates users against Gibbon's moodleUser view
   - **External Database Enrollment (enrol_database)** - Synchronizes course enrollments from Gibbon's moodleEnrolment view

5. **Verification**: After configuration, the script tests the connection to Gibbon database and logs the results.

#### Example Configuration

```yaml
environment:
  # Enable Gibbon integration
  ENABLE_GIBBON_INTEGRATION: "true"

  # Gibbon database connection
  GIBBON_DB_HOST: gibbon-mysql
  GIBBON_DB_NAME: gibbon
  GIBBON_DB_USER: gibbon
  GIBBON_DB_PASSWORD: gibbon_password

  # Part 1: Enable External Database plugins
  MOODLE_INTEGRATION_SQL_1: |
    -- Enable External Database Authentication plugin
    INSERT INTO mdl_config (name, value)
    VALUES ('auth', 'manual,db')
    ON DUPLICATE KEY UPDATE value = IF(value NOT LIKE '%db%', CONCAT(value,',db'), value);
    -- Enable External Database Enrollment plugin
    INSERT INTO mdl_config (name, value)
    VALUES ('enrol_plugins_enabled', 'manual,database')
    ON DUPLICATE KEY UPDATE value = IF(value NOT LIKE '%database%', CONCAT(value,',database'), value);

  # Part 2: Configure External Database Authentication
  MOODLE_INTEGRATION_SQL_2: |
    -- Database connection settings
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'host', 'gibbon-mysql') ON DUPLICATE KEY UPDATE value = 'gibbon-mysql';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'name', 'gibbon') ON DUPLICATE KEY UPDATE value = 'gibbon';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'user', 'gibbon') ON DUPLICATE KEY UPDATE value = 'gibbon';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'pass', 'gibbon_password') ON DUPLICATE KEY UPDATE value = 'gibbon_password';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'type', 'mysql') ON DUPLICATE KEY UPDATE value = 'mysql';
    -- User table and field mappings
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'table', 'moodleUser') ON DUPLICATE KEY UPDATE value = 'moodleUser';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'fielduser', 'username') ON DUPLICATE KEY UPDATE value = 'username';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'passtype', 'internal') ON DUPLICATE KEY UPDATE value = 'internal';
    -- User synchronization settings
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'removeuser', '2') ON DUPLICATE KEY UPDATE value = '2';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'updateusers', '1') ON DUPLICATE KEY UPDATE value = '1';
    -- Field mappings (firstname, lastname, email)
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'field_map_firstname', 'preferredName') ON DUPLICATE KEY UPDATE value = 'preferredName';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'field_updatelocal_firstname', 'onlogin') ON DUPLICATE KEY UPDATE value = 'onlogin';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'field_map_lastname', 'surname') ON DUPLICATE KEY UPDATE value = 'surname';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'field_updatelocal_lastname', 'onlogin') ON DUPLICATE KEY UPDATE value = 'onlogin';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'field_map_email', 'email') ON DUPLICATE KEY UPDATE value = 'email';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'field_updatelocal_email', 'oncreate') ON DUPLICATE KEY UPDATE value = 'oncreate';

  # Part 3: Configure External Database Enrollment
  MOODLE_INTEGRATION_SQL_3: |
    -- Database connection settings
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'dbhost', 'gibbon-mysql') ON DUPLICATE KEY UPDATE value = 'gibbon-mysql';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'dbname', 'gibbon') ON DUPLICATE KEY UPDATE value = 'gibbon';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'dbuser', 'gibbon') ON DUPLICATE KEY UPDATE value = 'gibbon';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'dbpass', 'gibbon_password') ON DUPLICATE KEY UPDATE value = 'gibbon_password';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'dbtype', 'mysqli') ON DUPLICATE KEY UPDATE value = 'mysqli';
    -- Local field mappings (Moodle side)
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'localcoursefield', 'idnumber') ON DUPLICATE KEY UPDATE value = 'idnumber';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'localuserfield', 'username') ON DUPLICATE KEY UPDATE value = 'username';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'localrolefield', 'shortname') ON DUPLICATE KEY UPDATE value = 'shortname';
    -- Remote enrollment table settings (Gibbon side)
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'remoteenroltable', 'moodleEnrolment') ON DUPLICATE KEY UPDATE value = 'moodleEnrolment';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'remotecoursefield', 'gibbonCourseID') ON DUPLICATE KEY UPDATE value = 'gibbonCourseID';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'remoteuserfield', 'username') ON DUPLICATE KEY UPDATE value = 'username';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'remoterolefield', 'role') ON DUPLICATE KEY UPDATE value = 'role';
    -- Remote course table settings (Gibbon side)
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'newcoursetable', 'moodleCourse') ON DUPLICATE KEY UPDATE value = 'moodleCourse';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'newcoursefullname', 'name') ON DUPLICATE KEY UPDATE value = 'name';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'newcourseshortname', 'nameShort') ON DUPLICATE KEY UPDATE value = 'nameShort';
    INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'newcourseidnumber', 'gibbonCourseID') ON DUPLICATE KEY UPDATE value = 'gibbonCourseID';
```

#### Benefits of Multi-Part Approach

- ✅ **Improved Readability**: Each SQL part is clearly separated and can be documented independently
- ✅ **Better Maintainability**: Easier to edit individual parts without affecting others
- ✅ **Modular Design**: Can add/remove/modify parts independently
- ✅ **Marketplace Compatible**: No volume mounts required - works with Clouve marketplace constraints
- ✅ **Automatic Concatenation**: Parts are automatically detected and concatenated in order
- ✅ **Dependency Management**: Automatically waits for Gibbon database and views to be ready

#### Verification Logs

When integration is enabled, you'll see output like:

```
##################################################################
MOODLE INTEGRATION SQL FROM ENVIRONMENT VARIABLES
##################################################################
Waiting for Gibbon database to be ready...
✓ Gibbon database is ready
Waiting for Gibbon integration views to be created...
✓ Gibbon integration views are ready
Configuring Moodle External Database plugins...
Collecting SQL parts...
  Found part 1
  Found part 2
  Found part 3
✓ Collected 3 SQL part(s)
Executing SQL to configure Moodle plugins...
✓ Moodle integration configured successfully
Testing connection to Gibbon database...
✓ Moodle can successfully connect to Gibbon database
✓ Moodle-to-Gibbon integration setup completed successfully!
##################################################################
```

#### Integration Requirements

For successful integration, ensure:

1. **Gibbon container** has `ENABLE_MOODLE_INTEGRATION="true"` set
2. **Gibbon database** is accessible from Moodle container
3. **Gibbon integration views** (moodleUser, moodleCourse, moodleEnrolment) are created
4. **Database credentials** match between Gibbon and Moodle configuration
5. **Network connectivity** exists between Moodle and Gibbon database

#### Migration Note

**The old POST-INSTALL HOOK approach** (mounting scripts at `/clouve/hooks/post-install.sh`) **has been removed**. Use the multi-part environment variable approach documented above instead.

## Features

- **Moodle 4.5.1 LTS**: Latest long-term support version
- **PHP 8.3**: Modern PHP version with optimal performance
- **Apache Web Server**: Production-ready web server
- **MySQL Database**: Reliable database backend
- **Automated Installation**: Automatic setup on first run
- **Persistent Storage**: Data persists across container restarts
- **Health Checks**: Built-in health monitoring
- **Security Hardening**: Production-ready security configurations

## System Requirements

- Docker Engine 20.10+
- Docker Compose 1.29+
- 2GB RAM minimum (4GB recommended)
- 10GB disk space minimum

## Volumes

The application uses three Docker volumes:

- `db_data`: MySQL database files
- `moodle_data`: Moodle application files
- `moodledata`: Moodle data directory (user uploads, course files, etc.)

## Building the Image

To build the custom Moodle image locally:

```bash
cd image
docker build -t r.clv.zone/e2eorg/moodle:latest .
```

## Architecture

### Directory Structure

```
moodle/
├── image/
│   ├── Dockerfile              # Custom Moodle image definition
│   ├── build.config            # Build configuration
│   └── installer/
│       ├── entrypoint.sh       # Container entrypoint script
│       ├── install.sh          # Initial installation script
│       └── upgrade.sh          # Upgrade script
├── docker-compose.yml          # Local development configuration
├── clv-docker-compose.yml      # Clouve marketplace configuration
├── logo.png                    # Moodle logo
└── README.md                   # This documentation
```

### Components

1. **Moodle Container**: Runs Apache with PHP 8.3 and Moodle application
2. **MySQL Container**: Database backend for Moodle
3. **Volumes**: Persistent storage for database and application data

## Troubleshooting

### Container won't start
```bash
docker-compose logs moodle
docker-compose logs moodle-mysql
```

### Moodle shows installation screen
Check if the installation completed successfully:
```bash
docker-compose exec moodle ls -la /var/www/html/config.php
```

### Database connection errors
Verify database credentials:
```bash
docker-compose exec moodle env | grep DB_
```

### Permission issues
Reset permissions:
```bash
docker-compose exec moodle chown -R www-data:www-data /var/www/html
docker-compose exec moodle chown -R www-data:www-data /var/moodledata
```

### Reset installation
To start fresh:
```bash
docker-compose down -v
docker-compose up -d
```

### Composer vendor directory not found
If you see "Composer vendor directory not found" error:
```bash
# Check if vendor directory exists
docker-compose exec moodle ls -la /var/www/html/vendor

# If missing, rebuild the image (Composer dependencies are installed during build)
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

### Site not HTTPS warning
If you see "Site not HTTPS" warning despite having SSL termination (nginx, etc.):

1. **Update MOODLE_URL to use HTTPS**: Edit `docker-compose.yml` and change:
   ```yaml
   environment:
     MOODLE_URL: https://your-domain.com  # Use HTTPS URL
   ```

2. **Restart the container**:
   ```bash
   docker-compose down
   docker-compose up -d
   ```

3. **Verify SSL proxy configuration**:
   ```bash
   docker-compose exec moodle grep sslproxy /var/www/html/config.php
   # Should show: $CFG->sslproxy = true;
   ```

**Note**: The `$CFG->sslproxy` setting is automatically added when `MOODLE_URL` starts with `https://`. This tells Moodle that SSL termination is handled by a reverse proxy (nginx, etc.) and prevents the "Site not HTTPS" warning.

## Upgrading Moodle

To upgrade to a new version of Moodle:

1. Update the `MOODLE_VERSION` and `MOODLE_RELEASE` in `image/Dockerfile`
2. Rebuild the image
3. Restart the containers

The entrypoint script will automatically detect the new version and run the upgrade process.

## Security Considerations

- Change default passwords in production
- Use strong passwords for database and admin accounts
- Configure SSL/TLS for production deployments
- Regularly update to the latest Moodle version
- Review and configure Moodle security settings
- Implement proper backup strategies

## Support

For Moodle-specific issues, consult:
- [Moodle Documentation](https://docs.moodle.org/)
- [Moodle Community Forums](https://moodle.org/forums/)
- [Moodle Tracker](https://tracker.moodle.org/)

## License

Moodle is licensed under the GNU General Public License v3.0.

