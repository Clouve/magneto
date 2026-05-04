#!/bin/bash

# SuiteCRM Integration Plugin Setup Script
# This script helps configure the plugin for Docker environments

set -e

echo "=========================================="
echo "SuiteCRM Integration Plugin Setup"
echo "=========================================="
echo ""

# Check if running in Docker
if [ -f /.dockerenv ]; then
    echo "✓ Running in Docker environment"
else
    echo "⚠ Not running in Docker - manual configuration may be needed"
fi

echo ""
echo "This script will help you configure the SuiteCRM Integration plugin."
echo ""

# Default values for Docker environment
SUITECRM_URL="${SUITECRM_URL:-http://suitecrm:80}"
SUITECRM_DB_HOST="${SUITECRM_DB_HOST:-suitecrm-mariadb}"
SUITECRM_DB_PORT="${SUITECRM_DB_PORT:-3306}"
SUITECRM_DB_NAME="${SUITECRM_DB_NAME:-suitecrm}"
SUITECRM_DB_USER="${SUITECRM_DB_USER:-suitecrm}"
SUITECRM_DB_PASSWORD="${SUITECRM_DB_PASSWORD:-}"
SUITECRM_ADMIN_USER="${SUITECRM_ADMIN_USER:-admin}"
SUITECRM_ADMIN_PASSWORD="${SUITECRM_ADMIN_PASSWORD:-}"

echo "Configuration Summary:"
echo "----------------------"
echo "SuiteCRM URL: $SUITECRM_URL"
echo "Database Host: $SUITECRM_DB_HOST"
echo "Database Port: $SUITECRM_DB_PORT"
echo "Database Name: $SUITECRM_DB_NAME"
echo "Database User: $SUITECRM_DB_USER"
echo "Admin User: $SUITECRM_ADMIN_USER"
echo ""

# Check if plugin directory exists
PLUGIN_DIR="/var/www/html/plugins/SuiteCRMIntegration"
if [ -d "$PLUGIN_DIR" ]; then
    echo "✓ Plugin directory found at $PLUGIN_DIR"
else
    echo "✗ Plugin directory not found at $PLUGIN_DIR"
    echo "  Please ensure the plugin is installed correctly"
    exit 1
fi

# Check if LimeSurvey is accessible
if [ -f "/var/www/html/application/config/config.php" ]; then
    echo "✓ LimeSurvey installation found"
else
    echo "✗ LimeSurvey installation not found"
    echo "  Please ensure LimeSurvey is installed"
    exit 1
fi

echo ""
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo ""
echo "1. Log in to LimeSurvey as administrator"
echo "   URL: http://localhost:8080/admin"
echo ""
echo "2. Navigate to: Configuration → Plugin Manager"
echo ""
echo "3. Find 'SuiteCRM Integration' and click 'Activate'"
echo ""
echo "4. Click 'Settings' and configure:"
echo "   - Enable SuiteCRM Integration: Enabled"
echo "   - SuiteCRM URL: $SUITECRM_URL"
echo "   - SuiteCRM Admin Username: $SUITECRM_ADMIN_USER"
echo "   - SuiteCRM Admin Password: <your-password>"
echo "   - SuiteCRM Database Host: $SUITECRM_DB_HOST"
echo "   - SuiteCRM Database Port: $SUITECRM_DB_PORT"
echo "   - SuiteCRM Database Name: $SUITECRM_DB_NAME"
echo "   - SuiteCRM Database User: $SUITECRM_DB_USER"
echo "   - SuiteCRM Database Password: <your-db-password>"
echo ""
echo "5. For each survey, go to: Survey Settings → Plugin Settings"
echo "   - Enable SuiteCRM Integration for this survey: Enabled"
echo "   - What to create in SuiteCRM: Create Lead (or Case)"
echo "   - Field Mapping (JSON): Configure your field mappings"
echo ""
echo "Example field mapping for leads:"
echo '{"Q1":"first_name","Q2":"last_name","Q3":"email1"}'
echo ""
echo "=========================================="
echo "Setup script completed!"
echo "=========================================="

