#!/bin/bash

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Starting SuiteCRM Integration plugin configuration..."

# Check if both required plugin tables exist
echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Checking if required plugin tables exist..."

# Check plugins table
if ! mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
    -e "SELECT 1 FROM ${DB_TABLE_PREFIX}plugins LIMIT 1;" 2>&1 | tee /tmp/plugins_check.log >/dev/null; then
    echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Plugins table not ready yet"
    echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Error details:"
    cat /tmp/plugins_check.log
    echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Skipping auto-configuration"
    exit 1
fi

# Check plugin_settings table
if ! mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
    -e "SELECT 1 FROM ${DB_TABLE_PREFIX}plugin_settings LIMIT 1;" 2>&1 | tee /tmp/plugin_settings_check.log >/dev/null; then
    echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Plugin settings table not ready yet"
    echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Error details:"
    cat /tmp/plugin_settings_check.log
    echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Skipping auto-configuration"
    exit 1
fi

echo -e "${GREEN}[PLUGIN-CONFIG]${NC} Both plugin tables exist and are accessible"

# ============================================================================
# Create required plugin database tables (normally done by beforeActivate())
# Since we register the plugin via SQL, we need to create these tables manually
# ============================================================================

echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Creating plugin database tables..."

# Create survey_crm_mappings table
if mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" << SQL_EOF
CREATE TABLE IF NOT EXISTS ${DB_TABLE_PREFIX}survey_crm_mappings (
    id INT AUTO_INCREMENT PRIMARY KEY,
    survey_id INT NOT NULL,
    question_id INT NOT NULL,
    crm_module VARCHAR(100) NOT NULL COMMENT 'e.g., Leads, Cases',
    crm_field_name VARCHAR(100) NOT NULL COMMENT 'API field name, e.g., first_name',
    crm_field_label VARCHAR(255) NULL COMMENT 'Display label for reference',
    crm_field_type VARCHAR(50) NULL COMMENT 'Field type, e.g., varchar, email',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY unique_question_mapping (question_id),
    INDEX idx_survey (survey_id),
    INDEX idx_module (crm_module)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL_EOF
then
    echo -e "${GREEN}[PLUGIN-CONFIG]${NC} Created table: ${DB_TABLE_PREFIX}survey_crm_mappings"
else
    echo -e "${YELLOW}[PLUGIN-CONFIG WARNING]${NC} Could not create survey_crm_mappings table (may already exist)"
fi

# Create survey_crm_sync_log table
if mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" << SQL_EOF
CREATE TABLE IF NOT EXISTS ${DB_TABLE_PREFIX}survey_crm_sync_log (
    id INT AUTO_INCREMENT PRIMARY KEY,
    response_id INT NOT NULL,
    survey_id INT NOT NULL,
    crm_module VARCHAR(100) NOT NULL,
    crm_record_id VARCHAR(100) NULL COMMENT 'SuiteCRM record ID (UUID)',
    sync_status ENUM('success', 'failed', 'partial') NOT NULL,
    request_payload LONGTEXT NULL COMMENT 'JSON payload sent to CRM',
    response_data LONGTEXT NULL COMMENT 'JSON response from CRM',
    error_message TEXT NULL,
    field_mappings_used TEXT NULL COMMENT 'JSON of question->field mappings used',
    synced_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_response (response_id),
    INDEX idx_survey (survey_id),
    INDEX idx_status (sync_status),
    INDEX idx_synced_at (synced_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
SQL_EOF
then
    echo -e "${GREEN}[PLUGIN-CONFIG]${NC} Created table: ${DB_TABLE_PREFIX}survey_crm_sync_log"
else
    echo -e "${YELLOW}[PLUGIN-CONFIG WARNING]${NC} Could not create survey_crm_sync_log table (may already exist)"
fi

# Check if plugin is already registered
PLUGIN_ID=$(mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
    -sN -e "SELECT id FROM ${DB_TABLE_PREFIX}plugins WHERE name='SuiteCRMIntegration';" 2>/dev/null || echo "")

if [ -z "$PLUGIN_ID" ]; then
    echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Registering SuiteCRM Integration plugin..."

    # Register the plugin in the plugins table
    if mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" << SQL_EOF
INSERT INTO ${DB_TABLE_PREFIX}plugins (name, active, version, load_error, plugin_type)
VALUES ('SuiteCRMIntegration', 1, '2.0.0', 0, 'user');
SQL_EOF
    then
        # Get the newly created plugin ID
        PLUGIN_ID=$(mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
            -sN -e "SELECT id FROM ${DB_TABLE_PREFIX}plugins WHERE name='SuiteCRMIntegration';" 2>/dev/null || echo "")

        echo -e "${GREEN}[PLUGIN-CONFIG]${NC} Plugin registered with ID: $PLUGIN_ID"
    else
        echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Failed to register plugin"
        exit 1
    fi
else
    echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Plugin already registered with ID: $PLUGIN_ID"
fi

# Check if plugin is already configured
PLUGIN_CONFIGURED=$(mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
    -sN -e "SELECT COUNT(*) FROM ${DB_TABLE_PREFIX}plugin_settings WHERE plugin_id='$PLUGIN_ID' AND \`key\`='suitecrm_url';" 2>/dev/null || echo "0")

if [ "$PLUGIN_CONFIGURED" -gt 0 ]; then
    echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} SuiteCRM Integration plugin already configured, skipping"
    exit 0
fi

# Configure plugin settings via database
# NOTE: LimeSurvey's DbStorage expects JSON-encoded values (uses json_decode on retrieval)
# Strings must be wrapped in double quotes to be valid JSON
if [ -n "$SUITECRM_URL" ] && [ -n "$PLUGIN_ID" ]; then
    echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} Auto-configuring SuiteCRM Integration plugin..."

    # Insert plugin settings with plugin_id (values are JSON-encoded)
    if mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" << SQL_EOF
-- Global enable setting (CRITICAL: required for plugin to work)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'enabled', '1');

-- Debug mode (enable for troubleshooting)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'debug_mode', '1');

-- SuiteCRM URL (JSON-encoded string)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'suitecrm_url', '"$SUITECRM_URL"');

-- SuiteCRM Admin User (JSON-encoded string)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'suitecrm_admin_user', '"${SUITECRM_ADMIN_USER:-admin}"');

-- SuiteCRM Admin Password (JSON-encoded string)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'suitecrm_admin_password', '"${SUITECRM_ADMIN_PASSWORD}"');

-- SuiteCRM Database Host (JSON-encoded string)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'suitecrm_db_host', '"${SUITECRM_DB_HOST:-suitecrm-mariadb}"');

-- SuiteCRM Database Port (JSON-encoded string)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'suitecrm_db_port', '"${SUITECRM_DB_PORT:-3306}"');

-- SuiteCRM Database Name (JSON-encoded string)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'suitecrm_db_name', '"${SUITECRM_DB_NAME:-suitecrm}"');

-- SuiteCRM Database User (JSON-encoded string)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'suitecrm_db_user', '"${SUITECRM_DB_USER:-suitecrm}"');

-- SuiteCRM Database Password (JSON-encoded string)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, NULL, NULL, 'suitecrm_db_password', '"${SUITECRM_DB_PASSWORD}"');

SQL_EOF
    then
        echo -e "${GREEN}[PLUGIN-CONFIG]${NC} SuiteCRM Integration plugin configured successfully!"
    else
        echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Failed to configure plugin settings"
        exit 1
    fi
else
    echo -e "${RED}[PLUGIN-CONFIG ERROR]${NC} Missing required environment variables (SUITECRM_URL or PLUGIN_ID)"
    exit 1
fi

# ============================================================================
# OAuth2 Client Setup - LAZY INITIALIZATION
# ============================================================================
# NOTE: OAuth2 client creation in SuiteCRM is now handled LAZILY by the plugin
# at runtime when the user first enables integration for a survey. This approach:
# 1. Avoids startup failures when SuiteCRM is not yet ready
# 2. Allows the plugin to work even if SuiteCRM starts later
# 3. Provides better user feedback through the plugin's admin UI
#
# The plugin will automatically create the OAuth2 client when:
# - User enables "Enable SuiteCRM Integration for this survey" for the first time
# - User clicks "Test Connection" in the plugin settings
# - User clicks "Initialize OAuth2" button in the status panel
# ============================================================================

echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} OAuth2 client setup will be handled lazily by the plugin at runtime"
echo -e "${YELLOW}[PLUGIN-CONFIG]${NC} The plugin will create the OAuth2 client when SuiteCRM is first accessed"

# Field mappings are stored in question attributes (suitecrm_mappings_json)
# and are read directly at response time by the plugin - no sync needed

echo -e "${GREEN}[PLUGIN-CONFIG]${NC} SuiteCRM Integration plugin setup complete!"
