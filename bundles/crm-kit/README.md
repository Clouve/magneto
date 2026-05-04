# CRM Kit Docker Bundle

A comprehensive customer relationship management platform combining LimeSurvey (Survey Platform) and SuiteCRM (Customer Relationship Management) in a single integrated bundle.

## Overview

The CRM Kit bundle provides a complete solution for organizations by combining:

- **LimeSurvey**: A powerful open-source survey platform for creating, distributing, and analyzing professional surveys
- **SuiteCRM**: A comprehensive open-source CRM solution for managing customer interactions, sales processes, and marketing campaigns

These applications work together to provide a comprehensive platform for customer engagement, from gathering feedback through surveys to managing customer relationships and sales pipelines.

## 🚀 Quick Start

### One-Command Deployment (Recommended)

```bash
# From magneto/dkr directory
cd magneto/dkr
./start.sh crm-kit
```

**That's it!** LimeSurvey and SuiteCRM will start and be ready to use.

### Alternative: Using Docker Compose Directly

```bash
# From within the bundle directory
cd magneto/dkr/bundles/crm-kit

# Start all services (will pull images automatically)
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f
```

## What's Included

✅ **LimeSurvey** - Survey Platform (http://localhost:8080)
✅ **SuiteCRM** - Customer Relationship Management (http://localhost:8081)
✨ **SuiteCRM Integration Plugin** - Automatically creates leads/cases from survey responses
✅ **Zero Configuration** - Works out of the box with sensible defaults
✅ **Marketplace Compatible** - No volume mounts required

## 🔗 Automatic Integration

The CRM Kit bundle includes **automatic integration** between LimeSurvey and SuiteCRM:

- **Automatic Lead Creation**: Survey responses automatically create leads in SuiteCRM
- **Automatic Case Creation**: Support surveys can create cases in SuiteCRM
- **OAuth2 Authentication**: Secure, industry-standard authentication
- **Pre-Configured**: Integration is enabled and configured automatically
- **Flexible Field Mapping**: Map survey questions to CRM fields via JSON

### How It Works

1. User completes a survey in LimeSurvey
2. Plugin authenticates with SuiteCRM via OAuth2
3. Survey data is mapped to CRM fields
4. Lead or Case is created in SuiteCRM automatically
5. Sales team can follow up immediately

See [Integration Documentation](#suitecrm-integration) below for details.

## Access Applications

### LimeSurvey (Survey Platform)
- **URL**: http://localhost:8080
- **Admin Username**: `admin`
- **Admin Password**: `Admin@123`
- **Admin Email**: admin@example.com

### SuiteCRM (Customer Relationship Management)
- **URL**: http://localhost:8081
- **Admin Username**: `admin`
- **Admin Password**: `Admin@123`

## Architecture

### Container Structure

The CRM Kit bundle consists of 4 containers organized into 2 application groups:

#### LimeSurvey (Survey Platform)
- `limesurvey` - LimeSurvey application (port 8080)
- `limesurvey-mariadb` - MariaDB database for LimeSurvey

#### SuiteCRM (Customer Relationship Management)
- `suitecrm` - SuiteCRM application (port 8081)
- `suitecrm-mariadb` - MariaDB database for SuiteCRM

### Container Naming Convention

Following Clouve's multi-app bundle conventions:
- Each main application container uses its own name as the base (`limesurvey`, `suitecrm`)
- Dependency containers are prefixed with the main app they serve:
  - LimeSurvey: `limesurvey`, `limesurvey-mariadb`
  - SuiteCRM: `suitecrm`, `suitecrm-mariadb`

This naming convention ensures compatibility with Clouve Strato scripts and proper ingress routing.

### Public Containers (Ingress Exposure)

The following containers have `isPublic: true` and receive ingress exposure:
- `limesurvey` - Survey creation and management interface
- `suitecrm` - CRM and customer management interface

Database containers are internal only (`isPublic: false`).

## Use Cases

### For Sales Teams
- **LimeSurvey**: Customer satisfaction surveys, product feedback, market research
- **SuiteCRM**: Lead management, sales pipeline tracking, customer relationship management

### For Marketing Teams
- **LimeSurvey**: Campaign effectiveness surveys, customer insights, brand awareness studies
- **SuiteCRM**: Marketing automation, campaign management, lead nurturing

### For Customer Success
- **LimeSurvey**: NPS surveys, customer feedback, support satisfaction
- **SuiteCRM**: Customer support ticketing, account management, customer lifecycle tracking

### For Research Organizations
- **LimeSurvey**: Academic research, data collection, participant management
- **SuiteCRM**: Participant relationship management, research project tracking

## Management

### Stop the Bundle

```bash
cd magneto/dkr/bundles/crm-kit
docker-compose down
```

### Stop and Remove All Data

```bash
cd magneto/dkr/bundles/crm-kit
docker-compose down -v
```

⚠️ **Warning**: This will delete all data including databases, uploaded files, and configurations.

### View Logs

```bash
# All services
docker-compose logs -f

# Specific service
docker-compose logs -f limesurvey
docker-compose logs -f suitecrm
```

### Restart a Service

```bash
docker-compose restart limesurvey
docker-compose restart suitecrm
```

## Customization

### Customize Configuration

Edit `docker-compose.yml` to customize environment variables for your organization:

```bash
cd magneto/dkr/bundles/crm-kit
nano docker-compose.yml  # or use your preferred editor
```

After making changes, restart the bundle:
```bash
docker-compose down
docker-compose up -d
```

### Change Ports

If the default ports conflict with other services, edit `docker-compose.yml`:

```yaml
services:
  limesurvey:
    ports:
      - "9080:8080"  # Change from 8080 to 9080

  suitecrm:
    ports:
      - "9081:80"  # Change from 8081 to 9081
```

## Troubleshooting

### Containers Won't Start

Check if ports are already in use:
```bash
lsof -i :8080
lsof -i :8081
```

### Database Connection Errors

Ensure database containers are healthy:
```bash
docker-compose ps
```

Wait for health checks to pass (may take 30-60 seconds on first start).

### Reset Everything

```bash
docker-compose down -v
docker-compose up -d
```

### Check Container Health

```bash
docker-compose ps
docker inspect crm_kit_limesurvey_app
docker inspect crm_kit_suitecrm_app
```

## Data Persistence

All application data is stored in Docker volumes:

- `limesurvey_db_data` - LimeSurvey database
- `limesurvey_data` - LimeSurvey application files
- `limesurvey_upload` - LimeSurvey uploaded files and surveys
- `suitecrm_db_data` - SuiteCRM database
- `suitecrm_data` - SuiteCRM application files

Data persists across container restarts and updates.

## Health Checks

All application containers include health checks:

- **LimeSurvey**: HTTP check on `/` (30s initial delay)
- **SuiteCRM**: HTTP check on `/` (120s initial delay)
- **Databases**: MariaDB health check commands

## Resource Requirements

### Minimum Requirements
- **CPU**: 2 cores
- **RAM**: 4 GB
- **Disk**: 30 GB

### Recommended for Production
- **CPU**: 4 cores
- **RAM**: 8 GB
- **Disk**: 50 GB

## Files

- `docker-compose.yml` - Local development and production configuration
- `clv-docker-compose.yml` - Clouve marketplace deployment configuration
- `README.md` - This comprehensive documentation
- `description.txt` - Bundle description for marketplace
- `logo.png` - CRM Kit logo
- `limesurvey.png` - LimeSurvey logo
- `suitecrm.png` - SuiteCRM logo

## SuiteCRM Integration

The CRM Kit bundle includes a pre-configured integration plugin that automatically creates leads and cases in SuiteCRM from LimeSurvey survey responses.

### Integration Features

- ✅ **Automatic Installation**: Plugin is installed automatically when `ENABLE_SUITECRM_INTEGRATION=true`
- ✅ **Auto-Configuration**: All settings configured from environment variables
- ✅ **OAuth2 Authentication**: Secure API authentication
- ✅ **Lead Creation**: Create leads from customer feedback surveys
- ✅ **Case Creation**: Create support cases from issue reports
- ✅ **Field Mapping**: Map survey questions to CRM fields via JSON

### How to Use the Integration

#### Step 1: Verify Integration is Enabled

The integration is enabled by default in the CRM Kit bundle. Check the logs:

```bash
docker-compose logs limesurvey | grep SuiteCRM
```

You should see:
```
[INFO] SuiteCRM Integration is enabled
[SUCCESS] SuiteCRM Integration plugin installed!
```

#### Step 2: Create a Survey

1. Log in to LimeSurvey (http://localhost:8080)
2. Create a new survey with questions like:
   - Q1: First Name
   - Q2: Last Name
   - Q3: Email
   - Q4: Phone
   - Q5: How can we help?

#### Step 3: Configure Survey Integration

1. In your survey, go to **Survey Settings** → **Plugin Settings**
2. Find "SuiteCRM Integration" section
3. Configure:
   - **Enable**: `Enabled`
   - **Create Type**: `Create Lead`
   - **Field Mapping**:
     ```json
     {
       "Q1": "first_name",
       "Q2": "last_name",
       "Q3": "email1",
       "Q4": "phone_work",
       "Q5": "description"
     }
     ```
4. Save settings

#### Step 4: Test the Integration

1. Complete the survey as a test user
2. Log in to SuiteCRM (http://localhost:8081)
3. Go to **Leads**
4. You should see a new lead with:
   - Name: [First Name] [Last Name]
   - Email: [Email]
   - Phone: [Phone]
   - Description: [How can we help?]
   - Lead Source: Survey
   - Status: New

### Integration Documentation

For detailed documentation, see:
- **Plugin Documentation**: `magneto/dkr/apps/limesurvey/SuiteCRMIntegration/README.md`
- **Installation Guide**: `magneto/dkr/apps/limesurvey/SuiteCRMIntegration/INSTALLATION.md`
- **Field Mapping Guide**: `magneto/dkr/apps/limesurvey/SuiteCRMIntegration/FIELD_MAPPING_GUIDE.md`
- **Quick Start**: `magneto/dkr/apps/limesurvey/SuiteCRMIntegration/QUICKSTART.md`

### Disable Integration

To disable the integration, edit `docker-compose.yml`:

```yaml
environment:
  ENABLE_SUITECRM_INTEGRATION: "false"
```

Then restart:
```bash
docker-compose up -d
```

## Next Steps

After deploying the CRM Kit:

1. **Configure LimeSurvey**: Set up your first survey, customize themes, configure email settings
2. **Set up SuiteCRM**: Configure company details, add users, customize modules
3. **Enable Integration**: Configure survey-specific integration settings (see above)
4. **Create Surveys**: Design customer feedback surveys in LimeSurvey
5. **Import Contacts**: Add customer contacts to SuiteCRM
6. **Test Integration**: Complete a test survey and verify lead creation
7. **Backup Strategy**: Implement regular backups of volumes and databases

## Support

For issues or questions:
- Check the troubleshooting section above
- Review container logs: `docker-compose logs -f`
- Consult individual application documentation:
  - LimeSurvey: https://manual.limesurvey.org/
  - SuiteCRM: https://docs.suitecrm.com/

## Version Information

- **LimeSurvey**: 6.16.1
- **SuiteCRM**: 8.9.1
- **Bundle Version**: 1.0.0



