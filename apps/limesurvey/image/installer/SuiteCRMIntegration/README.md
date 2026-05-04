# SuiteCRM Integration Plugin for LimeSurvey (v2.0)

## Overview

This plugin enables LimeSurvey to automatically create leads and cases in SuiteCRM based on survey responses.

**Key Features:**
- Automatic Lead/Case creation on survey completion
- Per-question field mapping via dropdown selector
- Dynamic field discovery from SuiteCRM API
- OAuth2 authentication (auto-configured)
- Sync logging for audit trail

## Quick Start (CRM Kit Bundle)

If using the CRM Kit bundle with `ENABLE_SUITECRM_INTEGRATION=true`, the plugin is **automatically installed and configured**. Skip to [Configure Field Mappings](#configure-field-mappings).

## Installation

### Option 1: Docker (CRM Kit Bundle)

Add to your `docker-compose.yml`:

```yaml
limesurvey:
  environment:
    ENABLE_SUITECRM_INTEGRATION: "true"
    SUITECRM_URL: http://suitecrm:80
    SUITECRM_ADMIN_USER: admin
    SUITECRM_ADMIN_PASSWORD: Admin@123
    SUITECRM_DB_HOST: suitecrm-mariadb
    SUITECRM_DB_NAME: suitecrm
    SUITECRM_DB_USER: suitecrm
    SUITECRM_DB_PASSWORD: suitecrm_password
```

### Option 2: Manual Installation

1. Copy plugin to LimeSurvey: `cp -r SuiteCRMIntegration /path/to/limesurvey/plugins/`
2. Set permissions: `chown -R www-data:www-data /path/to/limesurvey/plugins/SuiteCRMIntegration`
3. Activate in **Configuration** → **Plugin Manager**
4. Configure global settings (see below)

## Configuration

### Global Settings (Manual Installation Only)

Go to **Configuration** → **Plugin Manager** → **Settings**:

| Setting | Example Value |
|---------|---------------|
| SuiteCRM URL | `http://suitecrm:80` |
| Admin Username | `admin` |
| Admin Password | `Admin@123` |
| Database Host | `suitecrm-mariadb` |
| Database Name | `suitecrm` |
| Database User/Password | Your DB credentials |

OAuth2 credentials are auto-generated on activation.

### Enable for a Survey

1. Go to **Survey Settings** → **Plugin Settings**
2. Enable **SuiteCRM Integration for this survey**
3. Save

## Configure Field Mappings

For each question you want to sync to SuiteCRM:

1. **Edit the question**
2. Scroll to **"SuiteCRM Integration"** section
3. **Select the CRM field** from dropdown (e.g., `Leads: first_name`)
4. **Save**

### Example Mapping

| Question | CRM Field |
|----------|-----------|
| firstName | Leads: first_name |
| lastName | Leads: last_name |
| email | Leads: email1 |
| phone | Leads: phone_work |
| company | Leads: account_name |
| message | Leads: description |

**Required fields:** `last_name` for Leads, `name` for Cases

**Auto-set values:** `lead_source=Survey`, `status=New`

See [FIELD_MAPPING_GUIDE.md](FIELD_MAPPING_GUIDE.md) for complete field reference.

## Troubleshooting

### Enable Debug Mode

1. Go to plugin global settings → Set **Debug Mode** to "Enabled"
2. Check logs: `/tmp/suitecrm_integration.log`
3. Check sync history:
   ```sql
   SELECT * FROM lime_survey_crm_sync_log ORDER BY id DESC LIMIT 10;
   ```

### Common Issues

| Issue | Solution |
|-------|----------|
| "OAuth2 client not initialized" | Check database connection settings |
| "OAuth2 authentication failed" | Verify SuiteCRM admin credentials and URL |
| No records created | Check field mappings; ensure `last_name` (Leads) or `name` (Cases) is mapped |
| Records created with empty fields | Check question codes match and survey responses are filled |

### Verify OAuth2 Client

```sql
SELECT id, name, allowed_grant_type FROM oauth2clients WHERE name = 'LimeSurvey Integration';
```

## Version Information

- **Version**: 2.0.0
- **Compatibility**: LimeSurvey 4.0+, 5.0+, 6.0+
- **API**: SuiteCRM V8 (OAuth2)

## License

MIT License

