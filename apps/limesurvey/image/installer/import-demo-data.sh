#!/bin/bash

# LimeSurvey Demo Data Import Script
# This script imports demo survey data into LimeSurvey when INSTALL_DEMO_DATA=true
# It follows the same pattern as configure-suitecrm-plugin.sh
#
# Required environment variables:
#   DB_HOST          - Database host
#   DB_USERNAME      - Database username
#   DB_PASSWORD      - Database password
#   DB_NAME          - Database name
#   DB_TABLE_PREFIX  - Table prefix (default: lime_)
#   LIMESURVEY_INSTALL_PATH - LimeSurvey installation path (default: /var/www/html)
#
# Optional environment variables:
#   DEMO_DATA_SOURCE - Path to the .lss file (default: /clouve/limesurvey/installer/demo_data.lss)

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Set defaults
DB_TABLE_PREFIX=${DB_TABLE_PREFIX:-'lime_'}
LIMESURVEY_INSTALL_PATH=${LIMESURVEY_INSTALL_PATH:-'/var/www/html'}
DEMO_DATA_SOURCE=${DEMO_DATA_SOURCE:-'/clouve/limesurvey/installer/demo_data.lss'}
DEMO_DATA_MARKER="${LIMESURVEY_INSTALL_PATH}/.demo_data_installed"

echo -e "${YELLOW}[DEMO-DATA]${NC} Starting demo data import..."

# ============================================================================
# Validate required environment variables
# ============================================================================

if [ -z "$DB_HOST" ] || [ -z "$DB_USERNAME" ] || [ -z "$DB_PASSWORD" ] || [ -z "$DB_NAME" ]; then
    echo -e "${RED}[DEMO-DATA ERROR]${NC} Missing required database environment variables"
    echo -e "${RED}[DEMO-DATA ERROR]${NC} Required: DB_HOST, DB_USERNAME, DB_PASSWORD, DB_NAME"
    exit 1
fi

# ============================================================================
# Check if demo data file exists
# ============================================================================

if [ ! -f "$DEMO_DATA_SOURCE" ]; then
    echo -e "${RED}[DEMO-DATA ERROR]${NC} Demo data file not found at $DEMO_DATA_SOURCE"
    exit 1
fi

echo -e "${GREEN}[DEMO-DATA]${NC} Demo data file found: $DEMO_DATA_SOURCE"

# ============================================================================
# Check if demo data was already imported (marker file exists)
# ============================================================================

if [ -f "$DEMO_DATA_MARKER" ]; then
    echo -e "${YELLOW}[DEMO-DATA]${NC} Demo data already imported (marker file exists)"
    echo -e "${YELLOW}[DEMO-DATA]${NC} Marker contents:"
    cat "$DEMO_DATA_MARKER"
    exit 0
fi

# ============================================================================
# Wait for LimeSurvey to be fully initialized
# ============================================================================

echo -e "${YELLOW}[DEMO-DATA]${NC} Waiting for LimeSurvey to be fully initialized..."

TIMEOUT=180
ELAPSED=0
POLL_INTERVAL=3

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check 1: Verify surveys table exists (LimeSurvey is fully installed)
    if mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
        -e "SELECT 1 FROM ${DB_TABLE_PREFIX}surveys LIMIT 1;" 2>/dev/null >/dev/null; then

        # Check 2: Verify config files exist and are not empty
        if [ -s "$LIMESURVEY_INSTALL_PATH/application/config/config.php" ] && \
           [ -s "$LIMESURVEY_INSTALL_PATH/application/config/security.php" ]; then

            # Check 3: Verify web server is responding
            if curl -s -f http://localhost:8080 >/dev/null 2>&1; then
                echo -e "${GREEN}[DEMO-DATA]${NC} LimeSurvey is fully initialized!"
                break
            fi
        fi
    fi

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo -e "${RED}[DEMO-DATA ERROR]${NC} Timeout waiting for LimeSurvey initialization after ${TIMEOUT}s"
    exit 1
fi

# ============================================================================
# Wait for database to stabilize
# ============================================================================

echo -e "${YELLOW}[DEMO-DATA]${NC} Waiting 5 seconds for database to stabilize..."
sleep 5

# ============================================================================
# Import the demo survey using LimeSurvey CLI
# ============================================================================

# Determine the base language for the survey
# The demo data file is typically in English, but this can be customized
DEMO_DATA_LANG=${DEMO_DATA_LANG:-'en'}

echo -e "${YELLOW}[DEMO-DATA]${NC} Importing demo survey from $DEMO_DATA_SOURCE (language: $DEMO_DATA_LANG)..."

cd "$LIMESURVEY_INSTALL_PATH"
# Note: LimeSurvey's importsurvey command requires the format "filename:language"
# due to a bug in the command that doesn't handle missing language suffix properly
IMPORT_RESULT=$(php application/commands/console.php importsurvey "${DEMO_DATA_SOURCE}:${DEMO_DATA_LANG}" 2>&1)

if [[ "$IMPORT_RESULT" =~ ^[0-9]+$ ]]; then
    SURVEY_ID="$IMPORT_RESULT"
    echo -e "${GREEN}[DEMO-DATA]${NC} Demo survey imported successfully with Survey ID: $SURVEY_ID"

    # ============================================================================
    # Configure SuiteCRM Integration for the demo survey (if enabled)
    # ============================================================================

    if [ "$ENABLE_SUITECRM_INTEGRATION" = "true" ]; then
        echo -e "${YELLOW}[DEMO-DATA]${NC} Configuring SuiteCRM integration for demo survey..."

        # Get the plugin ID
        PLUGIN_ID=$(mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" \
            -sN -e "SELECT id FROM ${DB_TABLE_PREFIX}plugins WHERE name='SuiteCRMIntegration';" 2>/dev/null || echo "")

        if [ -n "$PLUGIN_ID" ]; then
            # Insert survey-specific settings (values are JSON-encoded for LimeSurvey's DbStorage)
            if mariadb -h "$DB_HOST" -u "$DB_USERNAME" -p"$DB_PASSWORD" "$DB_NAME" << SQL_EOF
-- Enable SuiteCRM integration for this survey (1 is valid JSON integer)
INSERT INTO ${DB_TABLE_PREFIX}plugin_settings (plugin_id, model, model_id, \`key\`, \`value\`)
VALUES ($PLUGIN_ID, 'Survey', '$SURVEY_ID', 'survey_enabled', '1')
ON DUPLICATE KEY UPDATE \`value\` = '1';
SQL_EOF
            then
                echo -e "${GREEN}[DEMO-DATA]${NC} SuiteCRM integration enabled for demo survey"
            else
                echo -e "${YELLOW}[DEMO-DATA WARNING]${NC} Failed to enable SuiteCRM integration for demo survey"
            fi

            # Field mappings are stored in question attributes (suitecrm_mappings_json)
            # and are read directly at response time by the plugin
            echo -e "${GREEN}[DEMO-DATA]${NC} CRM field mappings configured via question attributes"
        else
            echo -e "${YELLOW}[DEMO-DATA WARNING]${NC} SuiteCRM plugin not found, skipping survey configuration"
        fi
    fi

    # Create marker file to prevent re-import on container restart
    echo "Survey ID: $SURVEY_ID" > "$DEMO_DATA_MARKER"
    echo "Imported: $(date)" >> "$DEMO_DATA_MARKER"
    echo "Source: $DEMO_DATA_SOURCE" >> "$DEMO_DATA_MARKER"
    chown www-data:www-data "$DEMO_DATA_MARKER"

    echo -e "${GREEN}[DEMO-DATA]${NC} Demo data installation complete!"
    exit 0
else
    echo -e "${RED}[DEMO-DATA ERROR]${NC} Failed to import demo survey"
    echo -e "${RED}[DEMO-DATA ERROR]${NC} Import result: $IMPORT_RESULT"
    exit 1
fi

