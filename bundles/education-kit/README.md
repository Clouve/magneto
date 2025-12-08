# Education Kit Docker Bundle

A comprehensive education platform combining Gibbon (School Management System) and Moodle (Learning Management System) with **automatic integration** via multi-part environment variables for user authentication and enrollment synchronization.

## Overview

The Education Kit bundle provides a complete solution for educational institutions by combining:

- **Gibbon**: An open-source school management platform for managing student records, timetables, attendance, and staff communication
- **Moodle**: A leading learning management system for creating online courses, managing students, and tracking progress

These applications are **automatically integrated** using a multi-part environment variable approach that is **Clouve marketplace-compatible** (no volume mounts required). Moodle authenticates users and synchronizes course enrollments from Gibbon's database, providing a seamless experience for students and staff.

## 🚀 Quick Start

### One-Command Deployment (Recommended)

```bash
# From marketplace/dkr directory
cd marketplace/dkr
./start.sh education-kit
```

**That's it!** Gibbon and Moodle will start with automatic integration configured.

### Alternative: Using Docker Compose Directly

```bash
# From within the bundle directory
cd marketplace/dkr/bundles/education-kit

# Start all services (will pull images automatically)
docker-compose up -d

# Stop all services
docker-compose down
```

### Using Shared Management Scripts

```bash
# From marketplace/dkr directory
cd marketplace/dkr

# Start with clean state (removes all existing data)
./start.sh education-kit --clean

# Check status
./status.sh education-kit

# View logs
./logs.sh education-kit -f

# Stop (preserves data)
./stop.sh education-kit
```

For more information on the shared management scripts, see [marketplace/dkr/README.md](../../README.md).

## What You Get

✅ **Gibbon** - School Management System (http://localhost:8081)
✅ **Moodle** - Learning Management System (http://localhost:8080)
✅ **Automatic Integration** - SSO and enrollment sync configured automatically
✅ **Zero Configuration** - Works out of the box with sensible defaults
✅ **Marketplace Compatible** - No volume mounts required

## Access Applications

### Gibbon (School Management System)
- **URL**: http://localhost:8081
- **Admin Username**: `admin`
- **Admin Password**: `admin_password`
- **Admin Email**: admin@example.com

### Moodle (Learning Management System)
- **URL**: http://localhost:8080
- **Admin Username**: `admin`
- **Admin Password**: `Admin@123`
- **Admin Email**: admin@example.com

## Architecture

The Education Kit consists of four main services:

1. **Gibbon Application** (Port 8081)
   - School management platform
   - Manages student records, timetables, and staff
   - Provides user and course data for Moodle integration

2. **Gibbon MySQL Database** (Port 3307)
   - Stores Gibbon application data
   - Accessed by Moodle for user authentication and enrollment

3. **Moodle Application** (Port 8080)
   - Learning management system
   - Integrates with Gibbon for user authentication
   - Synchronizes course enrollments from Gibbon

4. **Moodle MySQL Database** (Port 3306)
   - Stores Moodle application data
   - Separate from Gibbon database

### Network Architecture

All services run on a shared `education_network` Docker network, allowing:
- Moodle to connect to Gibbon's MySQL database for authentication
- Secure inter-service communication
- Isolated from external networks

## Integration Features

### Automatic Integration via Multi-Part Environment Variables

The Education Kit uses **automatic integration** via multi-part environment variables. This approach is **Clouve marketplace-compatible** and does not require volume mounts.

When you start the bundle, integration happens automatically:

1. **Gibbon container** starts → Executes `GIBBON_INTEGRATION_SQL_*` → Creates database views for Moodle
2. **Moodle container** starts → Waits for Gibbon → Executes `MOODLE_INTEGRATION_SQL_*` → Configures External Database plugins
3. **Integration complete** - SSO and enrollment sync ready

#### Integration Environment Variables

**Gibbon Integration:**
- `ENABLE_MOODLE_INTEGRATION: "true"` - Enables Moodle integration
- `GIBBON_INTEGRATION_SQL_1` - Creates moodleUser view (SSO authentication)
- `GIBBON_INTEGRATION_SQL_2` - Creates moodleCourse view (course synchronization)
- `GIBBON_INTEGRATION_SQL_3` - Creates moodleEnrolment view (enrollment synchronization)

**Moodle Integration:**
- `ENABLE_GIBBON_INTEGRATION: "true"` - Enables Gibbon integration
- `GIBBON_DB_HOST`, `GIBBON_DB_NAME`, `GIBBON_DB_USER`, `GIBBON_DB_PASSWORD` - Gibbon database connection
- `MOODLE_INTEGRATION_SQL_1` - Enables External Database plugins
- `MOODLE_INTEGRATION_SQL_2` - Configures External Database Authentication (auth_db)
- `MOODLE_INTEGRATION_SQL_3` - Configures External Database Enrollment (enrol_database)

#### How Multi-Part Integration Works

1. **Multi-Part SQL Collection**: The entrypoint scripts automatically detect and concatenate all `*_INTEGRATION_SQL_*` environment variables in sequential order (1, 2, 3, ...).

2. **Idempotency**: Integration setup runs only once. Marker files prevent re-execution on container restarts:
   - Gibbon: `$INSTALLED_VERSIONS_PATH/.moodle-integration-setup`
   - Moodle: `$INSTALLED_VERSIONS_PATH/.gibbon-integration-setup`

3. **Dependency Management**: Moodle waits for:
   - Gibbon database to be ready (up to 60 attempts, 2 seconds each)
   - Gibbon integration views to be created (up to 30 attempts, 2 seconds each)

4. **Verification**: After setup, scripts verify views are accessible and test database connections.

#### Database Views Created (Gibbon)

- **moodleUser**: Exposes Gibbon users (students and staff) for Moodle SSO authentication
- **moodleCourse**: Exposes Gibbon courses for the current school year
- **moodleEnrolment**: Maps Gibbon course enrollments to Moodle (students and teachers)

#### Moodle Plugins Configured

- **External Database Authentication (auth_db)**: Authenticates users against Gibbon's moodleUser view
- **External Database Enrollment (enrol_database)**: Synchronizes course enrollments from Gibbon's moodleEnrolment view

#### Data Flow

1. **User Authentication**: User logs into Moodle → Moodle checks Gibbon database → User authenticated
2. **Course Sync**: Sync task runs → Moodle reads Gibbon courses → Courses created in Moodle
3. **Enrollment Sync**: Sync task runs → Moodle reads Gibbon enrollments → Users enrolled in courses

#### Benefits of Multi-Part Approach

- ✅ **Improved Readability**: Each SQL part is clearly separated and documented
- ✅ **Better Maintainability**: Easier to edit individual parts without affecting others
- ✅ **Modular Design**: Can add/remove/modify parts independently
- ✅ **Marketplace Compatible**: No volume mounts required - works with Clouve marketplace constraints
- ✅ **Automatic Concatenation**: Parts are automatically detected and concatenated in order
- ✅ **Dependency Management**: Automatically waits for required services to be ready

#### Example Integration Configuration

Here's how the multi-part SQL integration is configured in the education-kit `docker-compose.yml`:

**Gibbon Service:**
```yaml
gibbon:
  environment:
    # Enable Moodle integration
    ENABLE_MOODLE_INTEGRATION: "true"

    # Part 1: Create moodleUser view for SSO authentication
    GIBBON_INTEGRATION_SQL_1: |
      CREATE OR REPLACE VIEW moodleUser AS
        SELECT username, preferredName, surname, email, website
        FROM gibbonPerson
        JOIN gibbonRole ON (gibbonRole.gibbonRoleID = gibbonPerson.gibbonRoleIDPrimary)
        WHERE (category = 'Student' OR category = 'Staff') AND status = 'Full';

    # Part 2: Create moodleCourse view for course synchronization
    GIBBON_INTEGRATION_SQL_2: |
      CREATE OR REPLACE VIEW moodleCourse AS
        SELECT * FROM gibbonCourse
        WHERE gibbonSchoolYearID = (
          SELECT gibbonSchoolYearID FROM gibbonSchoolYear WHERE status = 'Current'
        );

    # Part 3: Create moodleEnrolment view for enrollment synchronization
    GIBBON_INTEGRATION_SQL_3: |
      CREATE OR REPLACE VIEW moodleEnrolment AS
        SELECT gibbonCourseClass.gibbonCourseID, gibbonPerson.username, 'student' AS role
        FROM gibbonCourseClassPerson
        JOIN gibbonPerson ON (gibbonCourseClassPerson.gibbonPersonID = gibbonPerson.gibbonPersonID)
        JOIN gibbonCourseClass ON (gibbonCourseClassPerson.gibbonCourseClassID = gibbonCourseClass.gibbonCourseClassID)
        WHERE gibbonCourseClassPerson.role = 'Student' AND gibbonPerson.status = 'Full'
        UNION
        SELECT gibbonCourseClass.gibbonCourseID, gibbonPerson.username, 'editingteacher' AS role
        FROM gibbonCourseClassPerson
        JOIN gibbonPerson ON (gibbonCourseClassPerson.gibbonPersonID = gibbonPerson.gibbonPersonID)
        JOIN gibbonCourseClass ON (gibbonCourseClassPerson.gibbonCourseClassID = gibbonCourseClass.gibbonCourseClassID)
        WHERE gibbonCourseClassPerson.role = 'Teacher' AND gibbonPerson.status = 'Full';
```

**Moodle Service:**
```yaml
moodle:
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
      INSERT INTO mdl_config (name, value) VALUES ('auth', 'manual,db')
      ON DUPLICATE KEY UPDATE value = IF(value NOT LIKE '%db%', CONCAT(value,',db'), value);
      INSERT INTO mdl_config (name, value) VALUES ('enrol_plugins_enabled', 'manual,database')
      ON DUPLICATE KEY UPDATE value = IF(value NOT LIKE '%database%', CONCAT(value,',database'), value);

    # Part 2: Configure External Database Authentication (auth_db)
    MOODLE_INTEGRATION_SQL_2: |
      INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'host', 'gibbon-mysql') ON DUPLICATE KEY UPDATE value = 'gibbon-mysql';
      INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'name', 'gibbon') ON DUPLICATE KEY UPDATE value = 'gibbon';
      INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('auth_db', 'table', 'moodleUser') ON DUPLICATE KEY UPDATE value = 'moodleUser';
      -- ... (additional auth_db configuration)

    # Part 3: Configure External Database Enrollment (enrol_database)
    MOODLE_INTEGRATION_SQL_3: |
      INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'dbhost', 'gibbon-mysql') ON DUPLICATE KEY UPDATE value = 'gibbon-mysql';
      INSERT INTO mdl_config_plugins (plugin, name, value) VALUES ('enrol_database', 'remoteenroltable', 'moodleEnrolment') ON DUPLICATE KEY UPDATE value = 'moodleEnrolment';
      -- ... (additional enrol_database configuration)
```

See the full configuration in `docker-compose.yml`.

#### Verification Logs

When integration is enabled, you'll see output like:

**Gibbon Integration Logs:**
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

**Moodle Integration Logs:**
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

#### Migration Note

**The old POST-INSTALL HOOK approach** (mounting scripts at `/clouve/hooks/post-install.sh`) **has been removed**. The education-kit bundle now uses the multi-part environment variable approach documented above.

## Verify Integration

### Check Integration Logs

```bash
cd marketplace/dkr/bundles/education-kit

# View Gibbon integration logs
docker-compose logs gibbon | grep -A 20 "GIBBON INTEGRATION SQL"

# View Moodle integration logs
docker-compose logs moodle | grep -A 20 "MOODLE INTEGRATION SQL"
```

**Expected output**: You should see "✓ Collected 3 SQL part(s)" and successful verification messages.

### Check Database Views

```bash
# Verify Gibbon views exist
docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
  -e "SHOW TABLES LIKE 'moodle%';"
```

**Expected output**:
```
+---------------------------+
| Tables_in_gibbon (moodle%)|
+---------------------------+
| moodleCourse              |
| moodleEnrolment           |
| moodleUser                |
+---------------------------+
```

### Test Database Connection

```bash
# Test Moodle can connect to Gibbon database
docker-compose exec moodle mysql -h gibbon-mysql -u gibbon -pgibbon_password gibbon \
  -e "SELECT COUNT(*) as user_count FROM moodleUser;"
```

**Expected output**: Should return a count of users from Gibbon.

## Configuration

### Environment Variables

#### Gibbon Configuration
```yaml
# Database
DB_HOST: gibbon-mysql
DB_NAME: gibbon
DB_USER: gibbon
DB_PASSWORD: gibbon_password

# Application
GIBBON_AUTOINSTALL: "1"
GIBBON_URL: http://localhost:8081
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

# Integration (see "Example Integration Configuration" above)
ENABLE_MOODLE_INTEGRATION: "true"
GIBBON_INTEGRATION_SQL_1: |
  -- SQL for moodleUser view
GIBBON_INTEGRATION_SQL_2: |
  -- SQL for moodleCourse view
GIBBON_INTEGRATION_SQL_3: |
  -- SQL for moodleEnrolment view
```

#### Moodle Configuration
```yaml
# Database
DB_HOST: moodle-mysql
DB_NAME: moodle
DB_USER: moodle
DB_PASSWORD: moodle_password

# Application
MOODLE_URL: http://localhost:8080
MOODLE_SITE_NAME: My Moodle Site
MOODLE_EMAIL: admin@example.com
MOODLE_USERNAME: admin
MOODLE_PASSWORD: Admin@123
MOODLE_FULLNAME: Administrator
MOODLE_SHORTNAME: Admin
MOODLE_LOG_LEVEL: info

# Gibbon Integration
GIBBON_DB_HOST: gibbon-mysql
GIBBON_DB_NAME: gibbon
GIBBON_DB_USER: gibbon
GIBBON_DB_PASSWORD: gibbon_password
ENABLE_GIBBON_INTEGRATION: "true"
MOODLE_INTEGRATION_SQL_1: |
  -- SQL to enable plugins
MOODLE_INTEGRATION_SQL_2: |
  -- SQL to configure auth_db
MOODLE_INTEGRATION_SQL_3: |
  -- SQL to configure enrol_database
```

### Customize Configuration

Edit `docker-compose.yml` to customize environment variables for your institution:

```bash
cd marketplace/dkr/bundles/education-kit
nano docker-compose.yml  # or use your preferred editor
```

After making changes, restart the bundle:
```bash
docker-compose down
docker-compose up -d
```

### Disable Auto-Integration

To disable automatic integration, edit `docker-compose.yml`:

```yaml
services:
  gibbon:
    environment:
      ENABLE_MOODLE_INTEGRATION: "false"  # or remove this line

  moodle:
    environment:
      ENABLE_GIBBON_INTEGRATION: "false"  # or remove this line
```

## Volumes

The bundle uses five persistent volumes:

- `gibbon_db_data`: Gibbon MySQL database files
- `gibbon_data`: Gibbon application files
- `moodle_db_data`: Moodle MySQL database files
- `moodle_data`: Moodle application files
- `moodledata`: Moodle user uploads and course files

## Common Tasks

### View Logs

```bash
cd marketplace/dkr/bundles/education-kit

# All services
docker-compose logs -f

# Specific service
docker-compose logs -f gibbon
docker-compose logs -f moodle
docker-compose logs -f gibbon-mysql
docker-compose logs -f moodle-mysql

# Filter for errors
docker-compose logs gibbon | grep -i "error\|fail\|warning"
docker-compose logs moodle | grep -i "error\|fail\|warning"
```

### Restart Services

```bash
# Restart all
docker-compose restart

# Restart specific service
docker-compose restart gibbon
docker-compose restart moodle
```

### Access Container Shell

```bash
# Gibbon
docker-compose exec gibbon bash

# Moodle
docker-compose exec moodle bash
```

### Access Database

```bash
# Gibbon database
docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon

# Moodle database
docker-compose exec moodle-mysql mysql -u moodle -pmoodle_password moodle
```

### Check Container Status

```bash
docker-compose ps
```

All services should show "Up" status.

### Check Database Connectivity

```bash
# From Gibbon to Gibbon database
docker-compose exec gibbon mysql -h gibbon-mysql -u gibbon -pgibbon_password gibbon -e "SELECT 1;"

# From Moodle to Moodle database
docker-compose exec moodle mysql -h moodle-mysql -u moodle -pmoodle_password moodle -e "SELECT 1;"

# From Moodle to Gibbon database (for integration)
docker-compose exec moodle mysql -h gibbon-mysql -u gibbon -pgibbon_password gibbon -e "SELECT 1;"
```

All should return `1`.

## Testing Integration

### Step 1: Create Test User in Gibbon

1. Log in to Gibbon (http://localhost:8081)
2. Go to **People** → **Manage Users**
3. Add a new student or staff member
4. Set status to "Full"
5. Note the username and password

### Step 2: Verify User in moodleUser View

```bash
# Check if user appears in moodleUser view
docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
  -e "SELECT * FROM moodleUser WHERE username='testuser';"
```

**Expected output**: User should appear with username, preferredName, surname, email.

### Step 3: Test SSO Login in Moodle

1. Go to Moodle (http://localhost:8080)
2. Log in with the Gibbon username and password
3. User should be authenticated via Gibbon! ✅

**Troubleshooting**: If login fails, check:
- User exists in Gibbon with status "Full"
- User appears in moodleUser view
- External Database Authentication is enabled in Moodle

### Step 4: Create Test Course in Gibbon

1. Log in to Gibbon
2. Go to **Learn** → **Courses & Classes**
3. Add a new course for the current school year
4. Enroll students and teachers

### Step 5: Verify Course in moodleCourse View

```bash
# Check if course appears in moodleCourse view
docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
  -e "SELECT * FROM moodleCourse;"
```

**Expected output**: Course should appear for the current school year.

### Step 6: Sync Course to Moodle

1. Log in to Moodle as admin
2. Go to **Site administration** → **Plugins** → **Enrolments** → **External database**
3. Click **"Synchronize now"**
4. Course should appear in Moodle with enrollments! ✅

### Step 7: Verify Enrollments

```bash
# Check enrollments in moodleEnrolment view
docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
  -e "SELECT * FROM moodleEnrolment;"
```

**Expected output**: Students and teachers should appear with their roles.

## Troubleshooting

### Integration Not Working

**Check environment variables:**
```bash
docker-compose exec gibbon env | grep ENABLE_MOODLE_INTEGRATION
docker-compose exec moodle env | grep ENABLE_GIBBON_INTEGRATION
```

Both should show `true`.

**Check integration logs:**
```bash
docker-compose logs gibbon | grep -A 20 "GIBBON INTEGRATION SQL"
docker-compose logs moodle | grep -A 20 "MOODLE INTEGRATION SQL"
```

**Expected output**: You should see "✓ Collected 3 SQL part(s)" and successful verification messages.

**Verify database views:**
```bash
docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
  -e "SHOW TABLES LIKE 'moodle%';"
```

**Expected output**: Should show moodleUser, moodleCourse, moodleEnrolment.

**Common issues:**
- **Integration skipped**: Verify `ENABLE_*_INTEGRATION` environment variables are set to `"true"`
- **SQL execution failed**: Check database connectivity and credentials
- **Views not created**: Check Gibbon logs for SQL errors
- **Moodle can't connect**: Verify `GIBBON_DB_*` environment variables are correct

### User Authentication Issues

**User can't log in to Moodle:**

1. **Verify user exists in Gibbon with status "Full":**
   ```bash
   docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
     -e "SELECT username, status FROM gibbonPerson WHERE username='testuser';"
   ```
   User must have `status = 'Full'`.

2. **Verify user appears in moodleUser view:**
   ```bash
   docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
     -e "SELECT * FROM moodleUser WHERE username='testuser';"
   ```

3. **Check External Database Authentication is enabled in Moodle:**
   - Log in to Moodle as admin
   - Go to **Site administration** → **Plugins** → **Authentication** → **Manage authentication**
   - Verify "External database" is enabled

4. **Test database connection from Moodle admin panel:**
   - Go to **Site administration** → **Plugins** → **Authentication** → **External database**
   - Check connection settings match Gibbon database

5. **Check Moodle logs:**
   - Go to **Site administration** → **Reports** → **Logs**
   - Filter for authentication events

### Course Sync Issues

**Courses not appearing in Moodle:**

1. **Verify course is for current school year:**
   ```bash
   docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
     -e "SELECT name, gibbonSchoolYearID FROM gibbonCourse;"
   ```

2. **Check current school year:**
   ```bash
   docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
     -e "SELECT gibbonSchoolYearID, name, status FROM gibbonSchoolYear WHERE status='Current';"
   ```

3. **Verify course appears in moodleCourse view:**
   ```bash
   docker-compose exec gibbon-mysql mysql -u gibbon -pgibbon_password gibbon \
     -e "SELECT * FROM moodleCourse;"
   ```

4. **Manually trigger Moodle sync:**
   - Log in to Moodle as admin
   - Go to **Site administration** → **Plugins** → **Enrolments** → **External database**
   - Click **"Synchronize now"**

### Containers Won't Start

**Check logs:**
```bash
docker-compose logs gibbon
docker-compose logs moodle
docker-compose logs gibbon-mysql
docker-compose logs moodle-mysql
```

**Common issues:**
- Port conflicts (8080, 8081, 3306, 3307 already in use)
- Insufficient disk space
- Database initialization errors

### Reset Installation

To completely reset and start over:

```bash
cd marketplace/dkr/bundles/education-kit

# WARNING: This deletes all data!
docker-compose down -v

# Start fresh - integration runs automatically
docker-compose up -d
```

## Production Deployment

Before deploying to production:

1. **Update all credentials** in `docker-compose.yml`:
   - Change all database passwords
   - Change admin passwords for both applications
   - Update email addresses

2. **Configure URLs**:
   - Set `GIBBON_URL` to your Gibbon domain
   - Set `MOODLE_URL` to your Moodle domain

3. **Security**:
   - Use strong passwords (minimum 16 characters)
   - Configure SSL/TLS certificates
   - Set up proper firewall rules
   - Regularly update to latest versions

4. **Backup Strategy**:
   - Regular database backups
   - Volume snapshots
   - Configuration backups

## Files

- `docker-compose.yml` - Local development and production configuration
- `clv-docker-compose.yml` - Clouve marketplace deployment configuration
- `README.md` - This comprehensive documentation
- `logo.png` - Education Kit logo
- `gibbon.png` - Gibbon logo
- `moodle.png` - Moodle logo

## Next Steps

After deploying the Education Kit:

1. ✅ **Deploy the bundle** - `cd marketplace/dkr && ./start.sh education-kit`
2. ✅ **Verify integration** - Check logs and database views (see "Verify Integration" section)
3. 📚 **Configure Gibbon** - Set up school details, academic year, users, courses
4. 📚 **Configure Moodle** - Customize site settings, themes, plugins
5. 👥 **Test SSO** - Create users in Gibbon, log in to Moodle (see "Testing Integration" section)
6. 📖 **Test enrollment sync** - Create courses in Gibbon, sync to Moodle
7. 🎓 **Go live** - Start using the integrated platform!

## Summary

The Education Kit provides a **complete, integrated educational platform** with:

✅ **Zero-configuration deployment** - One command to start
✅ **Automatic integration** - SSO and enrollment sync configured automatically via multi-part environment variables
✅ **Marketplace compatible** - No volume mounts required - works with Clouve marketplace constraints
✅ **Production ready** - Fully tested and documented
✅ **Easy to use** - Simple commands for common tasks
✅ **Well documented** - Comprehensive guides with practical examples
✅ **Modular design** - Easy to customize and extend
✅ **Idempotent** - Safe to restart - integration runs only once

**Get started now**: `cd marketplace/dkr && ./start.sh education-kit`

## Support

For application-specific issues:

### Gibbon
- [Gibbon Documentation](https://docs.gibbonedu.org/)
- [Gibbon Support](https://gibbonedu.org/support/)
- [Gibbon Community](https://ask.gibbonedu.org/)

### Moodle
- [Moodle Documentation](https://docs.moodle.org/)
- [Moodle Community Forums](https://moodle.org/forums/)
- [Moodle Tracker](https://tracker.moodle.org/)

### Integration Issues

For issues specific to the Gibbon-Moodle integration:
1. Check the "Troubleshooting" section above
2. Review integration logs: `docker-compose logs gibbon | grep -i integration`
3. Verify database views exist and contain data
4. Test database connectivity between services

## Additional Documentation

For more detailed information about the base images:
- **Gibbon**: See [marketplace/dkr/apps/gibbon/README.md](../../apps/gibbon/README.md)
- **Moodle**: See [marketplace/dkr/apps/moodle/README.md](../../apps/moodle/README.md)

## License

- Gibbon: GNU General Public License v3.0
- Moodle: GNU General Public License v3.0

