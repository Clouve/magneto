<?php

// Load helper classes
require_once __DIR__ . '/classes/SuiteCRMApiClient.php';
require_once __DIR__ . '/classes/FieldCacheManager.php';
require_once __DIR__ . '/classes/DatabaseSchema.php';
require_once __DIR__ . '/classes/DataTransformer.php';

// Debug: Log when this file is loaded
file_put_contents('/tmp/suitecrm_integration.log', "[" . date('Y-m-d H:i:s') . "] SuiteCRMIntegration.php file loaded (v2.0)\n", FILE_APPEND);

/**
 * SuiteCRM Integration Plugin for LimeSurvey
 *
 * This plugin enables LimeSurvey to automatically create leads and cases in SuiteCRM
 * based on survey responses with dynamic field mapping.
 *
 * @author Clouve
 * @version 2.0.0
 */
class SuiteCRMIntegration extends PluginBase
{
    protected $storage = 'DbStorage';
    protected static $description = 'Integrate LimeSurvey with SuiteCRM to automatically create leads and cases from survey responses with dynamic field mapping';
    protected static $name = 'SuiteCRM Integration';

    /** @var array Allowed public methods for AJAX */
    public $allowedPublicMethods = [
        'actionGetModules',
        'actionGetFields',
        'actionGetAllFields',
        'actionTestConnection',
        'actionRefreshCache',
        'actionGetSyncLogs',
        'actionSaveMappings',
        'actionGetMappings',
        'actionGetTransformRules',
        'actionCheckStatus',
        'actionInitializeOAuth2'
    ];

    /** @var SuiteCRMApiClient */
    private $apiClient = null;

    /** @var FieldCacheManager */
    private $cacheManager = null;

    /** @var SuiteCRMDatabaseSchema */
    private $dbSchema = null;

    /** @var SuiteCRMDataTransformer */
    private $dataTransformer = null;

    /** @var array Supported CRM modules */
    private const SUPPORTED_MODULES = ['Leads', 'Cases'];

    /**
     * Encrypted settings for secure storage
     */
    protected $encryptedSettings = array('suitecrm_admin_password', 'oauth_client_secret');

    /**
     * Plugin settings
     */
    protected $settings = array(
        'connection_status' => array(
            'type' => 'info',
            'label' => 'SuiteCRM Connection Status',
            'content' => '' // Will be populated dynamically in getPluginSettings()
        ),
        'enabled' => array(
            'type' => 'select',
            'options' => array(
                '0' => 'Disabled',
                '1' => 'Enabled'
            ),
            'default' => '0',
            'label' => 'Enable SuiteCRM Integration',
            'help' => 'Enable or disable the SuiteCRM integration globally'
        ),
        'suitecrm_url' => array(
            'type' => 'string',
            'default' => '',
            'label' => 'SuiteCRM URL',
            'help' => 'The base URL of your SuiteCRM instance (e.g., http://suitecrm:80)'
        ),
        'suitecrm_admin_user' => array(
            'type' => 'string',
            'default' => '',
            'label' => 'SuiteCRM Admin Username',
            'help' => 'Admin username for SuiteCRM authentication'
        ),
        'suitecrm_admin_password' => array(
            'type' => 'password',
            'default' => '',
            'label' => 'SuiteCRM Admin Password',
            'help' => 'Admin password for SuiteCRM authentication'
        ),
        'suitecrm_db_host' => array(
            'type' => 'string',
            'default' => '',
            'label' => 'SuiteCRM Database Host',
            'help' => 'Database host for SuiteCRM (e.g., suitecrm-mariadb)'
        ),
        'suitecrm_db_port' => array(
            'type' => 'string',
            'default' => '3306',
            'label' => 'SuiteCRM Database Port',
            'help' => 'Database port for SuiteCRM'
        ),
        'suitecrm_db_name' => array(
            'type' => 'string',
            'default' => 'suitecrm',
            'label' => 'SuiteCRM Database Name',
            'help' => 'Database name for SuiteCRM'
        ),
        'suitecrm_db_user' => array(
            'type' => 'string',
            'default' => 'suitecrm',
            'label' => 'SuiteCRM Database User',
            'help' => 'Database username for SuiteCRM'
        ),
        'suitecrm_db_password' => array(
            'type' => 'password',
            'default' => '',
            'label' => 'SuiteCRM Database Password',
            'help' => 'Database password for SuiteCRM'
        ),
        'oauth_client_id' => array(
            'type' => 'string',
            'default' => '',
            'label' => 'OAuth2 Client ID',
            'help' => 'OAuth2 client ID (auto-generated when SuiteCRM is first accessed)',
            'readonly' => true
        ),
        'oauth_client_secret' => array(
            'type' => 'string',
            'default' => '',
            'label' => 'OAuth2 Client Secret',
            'help' => 'OAuth2 client secret (auto-generated when SuiteCRM is first accessed)',
            'readonly' => true
        ),
        'oauth_initialized' => array(
            'type' => 'select',
            'options' => array(
                '0' => 'Not Initialized',
                '1' => 'Initialized'
            ),
            'default' => '0',
            'label' => 'OAuth2 Status',
            'help' => 'Indicates whether OAuth2 client has been created in SuiteCRM',
            'readonly' => true
        ),
        'oauth_init_error' => array(
            'type' => 'string',
            'default' => '',
            'label' => 'Last OAuth2 Error',
            'help' => 'Last error message from OAuth2 initialization attempt',
            'readonly' => true
        ),
        'debug_mode' => array(
            'type' => 'select',
            'options' => array(
                '0' => 'Disabled',
                '1' => 'Enabled'
            ),
            'default' => '0',
            'label' => 'Debug Mode',
            'help' => 'Enable debug logging for troubleshooting'
        ),
        'cache_ttl_hours' => array(
            'type' => 'int',
            'default' => 24,
            'label' => 'Field Cache TTL (hours)',
            'help' => 'How long to cache CRM field metadata (default: 24 hours)'
        )
    );

    /**
     * Initialize plugin and subscribe to events
     */
    public function init()
    {
        // Log to verify plugin is being initialized
        $logFile = '/tmp/suitecrm_integration.log';
        file_put_contents($logFile, "[" . date('Y-m-d H:i:s') . "] init() called - Plugin is being loaded (v2.1)\n", FILE_APPEND);

        // Subscribe to survey completion event
        $this->subscribe('afterSurveyComplete', 'handleSurveyComplete');

        // Subscribe to settings events
        $this->subscribe('beforeSurveySettings');
        $this->subscribe('newSurveySettings');

        // Subscribe to plugin activation
        $this->subscribe('beforeActivate');

        // Subscribe to question attributes for field mapping UI
        $this->subscribe('newQuestionAttributes');

        // Subscribe to question save to sync JSON mappings to database
        $this->subscribe('afterQuestionSave', 'syncMappingsFromQuestionAttribute');

        // Subscribe to direct requests for AJAX endpoints
        $this->subscribe('newDirectRequest');

        file_put_contents($logFile, "[" . date('Y-m-d H:i:s') . "] init() completed - Event subscriptions registered (v2.1)\n", FILE_APPEND);
    }

    /**
     * Override getPluginSettings to add dynamic status panel content
     *
     * @param bool $getValues Whether to get current values
     * @return array Plugin settings with dynamic content
     */
    public function getPluginSettings($getValues = true)
    {
        // Get the base settings
        $settings = parent::getPluginSettings($getValues);

        // Generate the dynamic status panel HTML
        $statusPanelHtml = $this->generateStatusPanelHtml();

        // Update the connection_status setting with the dynamic HTML
        if (isset($settings['connection_status'])) {
            $settings['connection_status']['content'] = $statusPanelHtml;
        }

        return $settings;
    }

    /**
     * Generate HTML for the SuiteCRM connection status panel
     *
     * This panel shows the current connection status and provides buttons
     * for testing connectivity and initializing OAuth2.
     *
     * @return string HTML content for the status panel
     */
    protected function generateStatusPanelHtml(): string
    {
        $oauthInitialized = $this->get('oauth_initialized') === '1';
        $oauthClientId = $this->get('oauth_client_id');
        $oauthError = $this->get('oauth_init_error');
        $suitecrmUrl = $this->get('suitecrm_url');

        // Determine initial status display
        $initialStatus = 'pending';
        $statusMessage = 'Click "Check Status" to test the connection.';
        $statusClass = 'alert-info';

        if ($oauthInitialized && !empty($oauthClientId)) {
            $initialStatus = 'configured';
            $statusMessage = "OAuth2 client configured: {$oauthClientId}";
            $statusClass = 'alert-success';
        } elseif (!empty($oauthError)) {
            $initialStatus = 'error';
            $statusMessage = "Last error: {$oauthError}";
            $statusClass = 'alert-warning';
        } elseif (empty($suitecrmUrl)) {
            $initialStatus = 'unconfigured';
            $statusMessage = 'SuiteCRM URL not configured. Please configure the settings below.';
            $statusClass = 'alert-secondary';
        }

        $html = <<<HTML
<div id="suitecrm-status-panel" class="card mb-3">
    <div class="card-header bg-primary text-white">
        <i class="ri-link"></i> SuiteCRM Connection Status
    </div>
    <div class="card-body">
        <div id="suitecrm-status-message" class="alert {$statusClass}">
            <span id="suitecrm-status-text">{$statusMessage}</span>
        </div>

        <div id="suitecrm-status-details" class="mb-3" style="display: none;">
            <table class="table table-sm table-bordered">
                <tbody>
                    <tr>
                        <td><strong>SuiteCRM HTTP</strong></td>
                        <td id="status-http">-</td>
                    </tr>
                    <tr>
                        <td><strong>SuiteCRM Database</strong></td>
                        <td id="status-database">-</td>
                    </tr>
                    <tr>
                        <td><strong>OAuth2 Table</strong></td>
                        <td id="status-oauth-table">-</td>
                    </tr>
                    <tr>
                        <td><strong>OAuth2 Client</strong></td>
                        <td id="status-oauth-client">-</td>
                    </tr>
                </tbody>
            </table>
        </div>

        <div class="btn-group" role="group">
            <button type="button" id="btn-check-status" class="btn btn-primary" onclick="SuiteCRMStatus.checkStatus()">
                <i class="ri-refresh-line"></i> Check Status
            </button>
            <button type="button" id="btn-init-oauth" class="btn btn-success" onclick="SuiteCRMStatus.initializeOAuth2()">
                <i class="ri-key-line"></i> Initialize OAuth2
            </button>
            <button type="button" id="btn-test-connection" class="btn btn-info" onclick="SuiteCRMStatus.testConnection()">
                <i class="ri-flashlight-line"></i> Test API Connection
            </button>
        </div>

        <div id="suitecrm-status-loading" class="mt-2" style="display: none;">
            <span class="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span>
            <span id="loading-text">Checking...</span>
        </div>
    </div>
</div>

<script>
var SuiteCRMStatus = {
    // Use the correct LimeSurvey plugin direct URL format
    ajaxUrl: (function() {
        // Get base URL from meta tag or use relative path
        var baseUrl = $('meta[name="baseUrl"]').attr('content') || '';
        return baseUrl + '/index.php/plugins/direct?plugin=SuiteCRMIntegration&function=';
    })(),

    showLoading: function(text) {
        $('#suitecrm-status-loading').show();
        $('#loading-text').text(text || 'Processing...');
        $('.btn-group button').prop('disabled', true);
    },

    hideLoading: function() {
        $('#suitecrm-status-loading').hide();
        $('.btn-group button').prop('disabled', false);
    },

    updateStatus: function(type, message) {
        var alertClass = 'alert-info';
        if (type === 'success' || type === 'ready') alertClass = 'alert-success';
        else if (type === 'error') alertClass = 'alert-danger';
        else if (type === 'warning' || type === 'pending') alertClass = 'alert-warning';

        $('#suitecrm-status-message').removeClass('alert-info alert-success alert-warning alert-danger alert-secondary').addClass(alertClass);
        $('#suitecrm-status-text').text(message);
    },

    updateDetailRow: function(id, status, message) {
        var badgeClass = 'badge bg-secondary';
        if (status === 'ok') badgeClass = 'badge bg-success';
        else if (status === 'error') badgeClass = 'badge bg-danger';
        else if (status === 'warning' || status === 'pending') badgeClass = 'badge bg-warning text-dark';

        $('#' + id).html('<span class="' + badgeClass + '">' + status.toUpperCase() + '</span> ' + message);
    },

    checkStatus: function() {
        var self = this;
        this.showLoading('Checking SuiteCRM status...');

        $.ajax({
            url: this.ajaxUrl + 'actionCheckStatus',
            method: 'GET',
            dataType: 'json',
            success: function(data) {
                self.hideLoading();
                $('#suitecrm-status-details').show();

                self.updateDetailRow('status-http', data.suitecrm_http.status, data.suitecrm_http.message);
                self.updateDetailRow('status-database', data.suitecrm_database.status, data.suitecrm_database.message);
                self.updateDetailRow('status-oauth-table', data.oauth2_table.status, data.oauth2_table.message);
                self.updateDetailRow('status-oauth-client', data.oauth2_client.status, data.oauth2_client.message);

                if (data.overall === 'ready') {
                    self.updateStatus('success', 'All checks passed - SuiteCRM integration is ready!');
                } else if (data.overall === 'error') {
                    self.updateStatus('error', 'Some checks failed - see details above');
                } else {
                    self.updateStatus('warning', 'Some checks pending - SuiteCRM may still be initializing');
                }
            },
            error: function(xhr, status, error) {
                self.hideLoading();
                self.updateStatus('error', 'Failed to check status: ' + error);
            }
        });
    },

    initializeOAuth2: function() {
        var self = this;
        this.showLoading('Initializing OAuth2 client...');

        $.ajax({
            url: this.ajaxUrl + 'actionInitializeOAuth2',
            method: 'GET',
            dataType: 'json',
            success: function(data) {
                self.hideLoading();
                if (data.success) {
                    self.updateStatus('success', 'OAuth2 initialized: ' + (data.client_id || 'Success'));
                    // Refresh the status details
                    setTimeout(function() { self.checkStatus(); }, 500);
                } else {
                    self.updateStatus('error', 'OAuth2 initialization failed: ' + (data.error || 'Unknown error'));
                }
            },
            error: function(xhr, status, error) {
                self.hideLoading();
                var errMsg = 'Failed to initialize OAuth2: ' + error;
                try {
                    var resp = JSON.parse(xhr.responseText);
                    if (resp.error) errMsg = resp.error;
                } catch(e) {}
                self.updateStatus('error', errMsg);
            }
        });
    },

    testConnection: function() {
        var self = this;
        this.showLoading('Testing API connection...');

        $.ajax({
            url: this.ajaxUrl + 'actionTestConnection',
            method: 'GET',
            dataType: 'json',
            success: function(data) {
                self.hideLoading();
                if (data.success) {
                    self.updateStatus('success', 'API connection successful! Found ' + (data.modules_count || 0) + ' modules.');
                } else {
                    self.updateStatus('error', 'API connection failed: ' + (data.message || 'Unknown error'));
                }
            },
            error: function(xhr, status, error) {
                self.hideLoading();
                var errMsg = 'API connection test failed: ' + error;
                try {
                    var resp = JSON.parse(xhr.responseText);
                    if (resp.error) errMsg = resp.error;
                } catch(e) {}
                self.updateStatus('error', errMsg);
            }
        });
    }
};
</script>
HTML;

        return $html;
    }

    /**
     * Handle plugin activation
     *
     * NOTE: OAuth2 initialization is now LAZY - it happens when the user first
     * enables integration for a survey or manually triggers it via the admin UI.
     * This allows the plugin to activate even if SuiteCRM is not yet available.
     */
    public function beforeActivate()
    {
        // Install database schema if not already installed
        $schema = $this->getDbSchema();
        if (!$schema->isInstalled()) {
            $result = $schema->install();
            if (!$result['success']) {
                $this->debugLog("Failed to install database schema: " . ($result['error'] ?? 'Unknown error'));
            } else {
                $this->debugLog("Database schema installed successfully");
            }
        }

        // NOTE: OAuth2 client initialization is DEFERRED until first use
        // This allows LimeSurvey to start without waiting for SuiteCRM
        $this->debugLog("Plugin activated - OAuth2 will be initialized lazily when first needed");
    }

    /**
     * Debug log helper that writes to a file
     */
    protected function debugLog($message)
    {
        $logFile = '/tmp/suitecrm_integration.log';
        $timestamp = date('Y-m-d H:i:s');
        file_put_contents($logFile, "[{$timestamp}] {$message}\n", FILE_APPEND);
    }

    /**
     * Public wrapper for getting plugin settings
     * Needed because helper classes can't access protected get() method
     *
     * @param string $key Setting key
     * @param string|null $lang Language code
     * @param int|null $surveyId Survey ID
     * @param mixed $default Default value
     * @return mixed Setting value
     */
    public function getSetting(string $key, ?string $lang = null, ?int $surveyId = null, $default = null)
    {
        return $this->get($key, $lang, $surveyId, $default);
    }

    /**
     * Public wrapper for setting plugin settings
     * Needed because helper classes can't access protected set() method
     *
     * @param string $key Setting key
     * @param mixed $value Setting value
     * @param int|null $surveyId Survey ID
     */
    public function setSetting(string $key, $value, ?int $surveyId = null): void
    {
        $this->set($key, $value);
    }

    /**
     * Get API client instance
     *
     * @return SuiteCRMApiClient
     * @throws Exception if OAuth2 initialization fails and SuiteCRM is not available
     */
    protected function getApiClient(): SuiteCRMApiClient
    {
        if ($this->apiClient === null) {
            // Skip lazy initialization in console mode to avoid interfering with imports
            if (!$this->isConsoleMode()) {
                // Ensure OAuth2 is initialized before creating the API client
                $oauthStatus = $this->ensureOAuth2Initialized();
                if (!$oauthStatus['ready']) {
                    $this->debugLog("getApiClient() - OAuth2 not ready: " . ($oauthStatus['error'] ?? 'Unknown'));
                    // Continue anyway - the API client will fail gracefully if credentials are missing
                }
            }

            $this->apiClient = new SuiteCRMApiClient([
                'baseUrl' => $this->get('suitecrm_url'),
                'clientId' => $this->get('oauth_client_id'),
                'clientSecret' => $this->get('oauth_client_secret'),
                'username' => $this->get('suitecrm_admin_user'),
                'password' => $this->get('suitecrm_admin_password'),
                'debugMode' => $this->get('debug_mode', null, null, '0') === '1'
            ]);
        }
        return $this->apiClient;
    }

    /**
     * Check if we're running in console/CLI mode
     *
     * This is important to avoid triggering lazy initialization or logging
     * that could interfere with console command output (e.g., survey imports).
     *
     * @return bool True if running in console mode
     */
    protected function isConsoleMode(): bool
    {
        return php_sapi_name() === 'cli' || defined('STDIN');
    }

    /**
     * Get cache manager instance
     *
     * @return FieldCacheManager
     */
    protected function getCacheManager(): FieldCacheManager
    {
        if ($this->cacheManager === null) {
            $cacheTtl = (int)$this->get('cache_ttl_hours', null, null, 24);
            $this->cacheManager = new FieldCacheManager(
                $this->getApiClient(),
                $this,
                $cacheTtl
            );
        }
        return $this->cacheManager;
    }

    /**
     * Get database schema manager instance
     *
     * @return SuiteCRMDatabaseSchema
     */
    protected function getDbSchema(): SuiteCRMDatabaseSchema
    {
        if ($this->dbSchema === null) {
            $this->dbSchema = new SuiteCRMDatabaseSchema();
        }
        return $this->dbSchema;
    }

    /**
     * Get data transformer instance
     *
     * @return SuiteCRMDataTransformer
     */
    protected function getDataTransformer(): SuiteCRMDataTransformer
    {
        if ($this->dataTransformer === null) {
            $this->dataTransformer = new SuiteCRMDataTransformer();
        }
        return $this->dataTransformer;
    }

    /**
     * Handle survey completion event
     */
    public function handleSurveyComplete()
    {
        $this->debugLog("handleSurveyComplete() called (v2.0)");

        $event = $this->getEvent();
        $surveyId = $event->get('surveyId');
        $responseId = $event->get('responseId');

        $this->debugLog("Survey ID: {$surveyId}, Response ID: {$responseId}");

        // Check if integration is enabled for this survey
        if (!$this->isEnabledForSurvey($surveyId)) {
            $this->debugLog("Integration not enabled for survey {$surveyId}");
            $this->log("Integration not enabled for survey {$surveyId}", 'debug');
            return;
        }

        $this->debugLog("Integration IS enabled for survey {$surveyId}");

        try {
            // Get survey response data
            $this->debugLog("Getting response data...");
            $response = $this->pluginManager->getAPI()->getResponse($surveyId, $responseId);
            $this->debugLog("Response data: " . json_encode($response));

            // Process with dynamic field mapping (v2.0)
            $this->debugLog("Using dynamic field mapping (v2.0)");
            $this->processWithDynamicMapping($surveyId, $responseId, $response);

        } catch (\Exception $e) {
            $this->debugLog("ERROR: " . $e->getMessage());
            $this->debugLog("ERROR trace: " . $e->getTraceAsString());
            $this->log("Error handling survey completion: " . $e->getMessage(), 'error');

            // Log the error to sync log
            try {
                $this->getDbSchema()->logSync(
                    $responseId,
                    $surveyId,
                    'Unknown',
                    'failed',
                    null,
                    null,
                    null,
                    $e->getMessage()
                );
            } catch (\Exception $logError) {
                $this->debugLog("Failed to log sync error: " . $logError->getMessage());
            }
        } catch (\Throwable $t) {
            $this->debugLog("THROWABLE: " . $t->getMessage());
            $this->debugLog("THROWABLE trace: " . $t->getTraceAsString());
        }
    }

    /**
     * Process survey response with dynamic field mapping (v2.1 - one-to-many support)
     *
     * This method now supports one-to-many mappings where a single question can
     * populate multiple CRM fields with optional transformation rules.
     */
    protected function processWithDynamicMapping($surveyId, $responseId, $response)
    {
        $this->debugLog("processWithDynamicMapping() called (v2.1 - one-to-many)");

        $schema = $this->getDbSchema();
        $cacheManager = $this->getCacheManager();
        $transformer = $this->getDataTransformer();
        $apiClient = $this->getApiClient();

        // Get mappings directly from question attributes (source of truth)
        // This ensures mappings work even after CLI import when afterQuestionSave wasn't triggered
        $mappingsByModule = $schema->getMappingsFromQuestionAttributes($surveyId);

        if (empty($mappingsByModule)) {
            $this->debugLog("No field mappings found in question attributes for survey {$surveyId}");
            return;
        }

        // Get question info for the survey
        $questions = $this->getQuestionInfo($surveyId);

        // Get CRM field definitions
        $crmFields = [];
        foreach (array_keys($mappingsByModule) as $module) {
            $crmFields[$module] = $cacheManager->getFields($module);
        }

        // Count total mappings for logging
        $totalMappings = 0;
        foreach ($mappingsByModule as $module => $questionMappings) {
            foreach ($questionMappings as $questionId => $mappingsList) {
                $totalMappings += count($mappingsList);
            }
        }
        $this->debugLog("Processing {$totalMappings} total field mappings across " . count($mappingsByModule) . " modules");

        // Process each module
        foreach ($mappingsByModule as $module => $questionMappings) {
            // Count fields for this module
            $moduleFieldCount = 0;
            foreach ($questionMappings as $mappingsList) {
                $moduleFieldCount += count($mappingsList);
            }
            $this->debugLog("Processing module: {$module} with {$moduleFieldCount} field mappings from " . count($questionMappings) . " questions");

            try {
                // Transform response data for this module
                // The transformer now handles one-to-many mappings natively
                // Context is passed for auto-generation rules (auto_uuid, auto_number, etc.)
                $transformResult = $transformer->transformResponse(
                    $response,
                    $questionMappings,  // This is now: question_id => [array of mappings]
                    $questions,
                    $crmFields,
                    ['surveyId' => $surveyId, 'responseId' => $responseId]
                );

                if (!empty($transformResult['errors'])) {
                    $this->debugLog("Transformation errors: " . json_encode($transformResult['errors']));
                }

                $moduleData = $transformResult['data'][$module] ?? [];

                if (empty($moduleData)) {
                    $this->debugLog("No data to send for module {$module}");
                    continue;
                }

                $this->debugLog("Creating {$module} record with " . count($moduleData) . " fields: " . json_encode($moduleData));

                // Create record in SuiteCRM
                $result = $apiClient->createRecord($module, $moduleData);

                // Flatten mappings for logging
                $flatMappings = [];
                foreach ($questionMappings as $questionId => $mappingsList) {
                    foreach ($mappingsList as $mapping) {
                        $flatMappings[] = $mapping;
                    }
                }

                // Log success
                $schema->logSync(
                    $responseId,
                    $surveyId,
                    $module,
                    'success',
                    $result['id'] ?? null,
                    $moduleData,
                    $result,
                    null,
                    $flatMappings
                );

                $this->debugLog("{$module} record created with ID: " . ($result['id'] ?? 'unknown'));

            } catch (\Exception $e) {
                $this->debugLog("Error creating {$module} record: " . $e->getMessage());

                // Flatten mappings for logging
                $flatMappings = [];
                foreach ($questionMappings as $questionId => $mappingsList) {
                    foreach ($mappingsList as $mapping) {
                        $flatMappings[] = $mapping;
                    }
                }

                // Log failure
                $schema->logSync(
                    $responseId,
                    $surveyId,
                    $module,
                    'failed',
                    null,
                    $moduleData ?? null,
                    null,
                    $e->getMessage(),
                    $flatMappings
                );
            }
        }
    }

    /**
     * Get question information for a survey
     *
     * @param int $surveyId Survey ID
     * @return array Question info indexed by question ID
     */
    protected function getQuestionInfo($surveyId)
    {
        $questions = [];

        try {
            // Use LimeSurvey's Question model
            $questionModels = Question::model()->findAllByAttributes(['sid' => $surveyId]);

            foreach ($questionModels as $question) {
                // In LimeSurvey 6.x, question text is in a separate l10n table
                // We only need title (code) and type for the transformation
                $questionText = '';
                try {
                    // Try to get localized question text if available
                    if (method_exists($question, 'questionl10ns') && $question->questionl10ns) {
                        $l10n = $question->questionl10ns;
                        if (is_array($l10n) && !empty($l10n)) {
                            $firstL10n = reset($l10n);
                            $questionText = $firstL10n->question ?? '';
                        } elseif (is_object($l10n)) {
                            $questionText = $l10n->question ?? '';
                        }
                    }
                } catch (\Exception $e) {
                    // Ignore l10n errors - question text is optional for transformation
                }

                $questions[$question->qid] = [
                    'qid' => $question->qid,
                    'title' => $question->title,
                    'code' => $question->title,
                    'type' => $question->type,
                    'question' => $questionText
                ];
            }

            $this->debugLog("Retrieved " . count($questions) . " questions for survey {$surveyId}");
        } catch (\Exception $e) {
            $this->debugLog("Error getting question info: " . $e->getMessage());
        }

        return $questions;
    }

    /**
     * Provide survey-specific settings
     */
    public function beforeSurveySettings()
    {
        $event = $this->getEvent();
        $surveyId = $event->get('survey');

        // Get sync stats for this survey
        $syncStats = [];
        try {
            $syncStats = $this->getDbSchema()->getSyncStats($surveyId);
        } catch (\Exception $e) {
            // Ignore if table doesn't exist yet
        }

        // Build sync stats info string
        $syncInfo = '';
        if (!empty($syncStats['total'])) {
            $syncInfo = sprintf(
                "Total syncs: %d (Success: %d, Failed: %d). Last sync: %s",
                $syncStats['total'],
                $syncStats['success'] ?? 0,
                $syncStats['failed'] ?? 0,
                $syncStats['last_sync'] ?? 'Never'
            );
        }

        // Get current value, handling case where duplicate records exist (returns array)
        // Use reset() to get the first value, consistent with how findByAttributes works in setGeneric
        $currentValue = $this->get('survey_enabled', 'Survey', $surveyId);
        if (is_array($currentValue)) {
            $currentValue = reset($currentValue);
        }

        $event->set("surveysettings.{$this->id}", array(
            'name' => get_class($this),
            'settings' => array(
                'survey_enabled' => array(
                    'type' => 'select',
                    'options' => array(
                        '0' => 'Disabled',
                        '1' => 'Enabled'
                    ),
                    'default' => '0',
                    'label' => 'Enable SuiteCRM Integration for this survey',
                    'help' => 'When enabled, survey responses will be synced to SuiteCRM based on field mappings configured in each question\'s settings.',
                    'current' => $currentValue
                ),
                'sync_stats_info' => array(
                    'type' => 'info',
                    'content' => '<div class="alert alert-info">' .
                        '<strong>Sync Statistics:</strong> ' .
                        ($syncInfo ?: 'No sync attempts yet.') .
                        '</div>' .
                        '<div class="alert alert-secondary mt-2">' .
                        '<strong>How to map fields:</strong> Edit each question and expand the "SuiteCRM Integration" section to select the corresponding CRM field.' .
                        '</div>',
                    'label' => ''
                )
            )
        ));
    }

    /**
     * Save survey-specific settings
     */
    public function newSurveySettings()
    {
        $event = $this->getEvent();
        foreach ($event->get('settings') as $name => $value) {
            $this->set($name, $value, 'Survey', $event->get('survey'));
        }
    }

    /**
     * Check if integration is enabled for a survey
     */
    protected function isEnabledForSurvey($surveyId)
    {
        // Check global setting
        // Note: Use string '0' as default to match the settings definition
        $globalEnabled = $this->get('enabled', null, null, '0');
        $this->debugLog("Global enabled setting: " . var_export($globalEnabled, true));

        // String '0' and integer 0 are both falsy when checked with !
        if (!$globalEnabled || $globalEnabled === '0') {
            $this->debugLog("Global setting is disabled");
            return false;
        }

        // Check survey-specific setting
        $surveyEnabled = $this->get('survey_enabled', 'Survey', $surveyId, '0');
        $this->debugLog("Survey {$surveyId} enabled setting: " . var_export($surveyEnabled, true));

        // Handle case where duplicate records exist (returns array)
        // Use reset() to get the first value, consistent with how findByAttributes works in setGeneric
        if (is_array($surveyEnabled)) {
            $surveyEnabled = reset($surveyEnabled);
            $this->debugLog("Multiple values found, using first: " . var_export($surveyEnabled, true));
        }

        // Return true only if explicitly set to '1' (enabled)
        return $surveyEnabled === '1' || $surveyEnabled === 1;
    }

    /**
     * Initialize OAuth2 client in SuiteCRM database (LAZY INITIALIZATION)
     *
     * This method is called lazily when:
     * 1. User first enables integration for a survey
     * 2. User clicks "Test Connection" in the admin UI
     * 3. User clicks "Initialize OAuth2" button in the status panel
     *
     * @return array Result with 'success', 'message', and optionally 'error' keys
     */
    protected function initializeOAuth2Client(): array
    {
        $this->debugLog("initializeOAuth2Client() called - attempting lazy OAuth2 setup");

        try {
            // First, check if OAuth2 is already initialized
            $existingClientId = $this->get('oauth_client_id');
            if (!empty($existingClientId) && $this->get('oauth_initialized') === '1') {
                $this->debugLog("OAuth2 already initialized with client ID: {$existingClientId}");
                return [
                    'success' => true,
                    'message' => 'OAuth2 client already initialized',
                    'client_id' => $existingClientId
                ];
            }

            // Generate new credentials
            $clientId = 'limesurvey-' . uniqid();
            $clientSecret = bin2hex(random_bytes(32));
            $secretHash = hash('sha256', $clientSecret);

            // Try to connect to SuiteCRM database
            $pdo = $this->getSuiteCRMDatabaseConnection();

            // Check if oauth2clients table exists (SuiteCRM may not be fully initialized)
            try {
                $stmt = $pdo->query("SHOW TABLES LIKE 'oauth2clients'");
                if ($stmt->rowCount() === 0) {
                    $error = "SuiteCRM database not fully initialized - oauth2clients table does not exist";
                    $this->debugLog($error);
                    $this->set('oauth_init_error', $error);
                    return [
                        'success' => false,
                        'message' => 'SuiteCRM not ready',
                        'error' => $error,
                        'retry_suggested' => true
                    ];
                }
            } catch (Exception $e) {
                $error = "Cannot check SuiteCRM database: " . $e->getMessage();
                $this->debugLog($error);
                $this->set('oauth_init_error', $error);
                return [
                    'success' => false,
                    'message' => 'Cannot access SuiteCRM database',
                    'error' => $error,
                    'retry_suggested' => true
                ];
            }

            // Check if client already exists in SuiteCRM
            $stmt = $pdo->prepare("SELECT id, secret FROM oauth2clients WHERE name = ?");
            $stmt->execute(['LimeSurvey Integration']);
            $existing = $stmt->fetch();

            if ($existing) {
                // Client exists - retrieve and use existing credentials
                $this->debugLog("OAuth2 client already exists in SuiteCRM: " . $existing['id']);
                $this->set('oauth_client_id', $existing['id']);
                // Note: We can't retrieve the original secret since only hash is stored
                // User may need to recreate if secret was lost
                $this->set('oauth_initialized', '1');
                $this->set('oauth_init_error', '');

                return [
                    'success' => true,
                    'message' => 'Using existing OAuth2 client from SuiteCRM',
                    'client_id' => $existing['id'],
                    'note' => 'Client secret may need to be regenerated if lost'
                ];
            }

            // Insert new OAuth2 client
            $now = date('Y-m-d H:i:s');
            $stmt = $pdo->prepare("
                INSERT INTO oauth2clients (
                    id, name, date_entered, date_modified,
                    created_by, deleted, secret, is_confidential,
                    allowed_grant_type, duration_value, duration_amount, duration_unit
                ) VALUES (
                    ?, ?, ?, ?,
                    '1', 0, ?, 1,
                    'password', 3600, 1, 'hour'
                )
            ");

            $stmt->execute([
                $clientId,
                'LimeSurvey Integration',
                $now,
                $now,
                $secretHash
            ]);

            // Store credentials in plugin settings
            $this->set('oauth_client_id', $clientId);
            $this->set('oauth_client_secret', $clientSecret);
            $this->set('oauth_initialized', '1');
            $this->set('oauth_init_error', '');

            $this->log("OAuth2 client created successfully: {$clientId}", 'info');
            $this->debugLog("OAuth2 client created successfully: {$clientId}");

            return [
                'success' => true,
                'message' => 'OAuth2 client created successfully',
                'client_id' => $clientId
            ];

        } catch (Exception $e) {
            $error = $e->getMessage();
            $this->log("Error initializing OAuth2 client: " . $error, 'error');
            $this->debugLog("OAuth2 initialization failed: " . $error);
            $this->set('oauth_init_error', $error);

            return [
                'success' => false,
                'message' => 'OAuth2 initialization failed',
                'error' => $error,
                'retry_suggested' => true
            ];
        }
    }

    /**
     * Ensure OAuth2 is initialized before any SuiteCRM operation
     * This is the main entry point for lazy initialization.
     *
     * @return array Status with 'ready' boolean and details
     */
    protected function ensureOAuth2Initialized(): array
    {
        // Check if already initialized
        if ($this->get('oauth_initialized') === '1' && !empty($this->get('oauth_client_id'))) {
            return [
                'ready' => true,
                'message' => 'OAuth2 is initialized'
            ];
        }

        // Attempt lazy initialization
        $result = $this->initializeOAuth2Client();

        return [
            'ready' => $result['success'],
            'message' => $result['message'],
            'error' => $result['error'] ?? null,
            'initialization_result' => $result
        ];
    }

    /**
     * Get SuiteCRM database connection
     */
    protected function getSuiteCRMDatabaseConnection()
    {
        $host = $this->get('suitecrm_db_host');
        $port = $this->get('suitecrm_db_port', null, null, '3306');
        $dbname = $this->get('suitecrm_db_name');
        $user = $this->get('suitecrm_db_user');
        $password = $this->get('suitecrm_db_password');

        if (empty($host) || empty($dbname) || empty($user)) {
            throw new Exception("SuiteCRM database configuration is incomplete");
        }

        $dsn = "mysql:host={$host};port={$port};dbname={$dbname};charset=utf8mb4";

        try {
            $pdo = new PDO($dsn, $user, $password, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC
            ]);
            return $pdo;
        } catch (PDOException $e) {
            $this->log("Database connection error: " . $e->getMessage(), 'error');
            throw $e;
        }
    }

    /**
     * Get OAuth2 access token from SuiteCRM
     */
    protected function getAccessToken()
    {
        $url = rtrim($this->get('suitecrm_url'), '/') . '/Api/access_token';
        $clientId = $this->get('oauth_client_id');
        $clientSecret = $this->get('oauth_client_secret');
        $username = $this->get('suitecrm_admin_user');
        $password = $this->get('suitecrm_admin_password');

        if (empty($clientId) || empty($clientSecret)) {
            throw new Exception("OAuth2 client not initialized");
        }

        $data = [
            'grant_type' => 'password',
            'client_id' => $clientId,
            'client_secret' => $clientSecret,
            'username' => $username,
            'password' => $password
        ];

        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, http_build_query($data));
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            'Content-Type: application/x-www-form-urlencoded'
        ]);

        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        if ($httpCode !== 200) {
            $this->log("OAuth2 authentication failed: HTTP {$httpCode} - {$response}", 'error');
            throw new Exception("OAuth2 authentication failed");
        }

        $result = json_decode($response, true);

        if (!isset($result['access_token'])) {
            $this->log("No access token in response: {$response}", 'error');
            throw new Exception("No access token received");
        }

        return $result['access_token'];
    }

    /**
     * Log a message
     *
     * In console mode, logging is done only to debugLog (file) to avoid
     * interfering with console command output (e.g., survey imports).
     */
    public function log($message, $level = 'info')
    {
        // Only log if debug mode is enabled or level is error
        $debugMode = $this->get('debug_mode', null, null, '0');
        if (($debugMode !== '1' && $debugMode !== 1) && $level !== 'error') {
            return;
        }

        $prefix = '[SuiteCRM Integration] ';

        // In console mode, only log to file to avoid corrupting console output
        if ($this->isConsoleMode()) {
            $this->debugLog("[$level] $message");
            return;
        }

        if (function_exists('Yii') && isset(Yii::app()->log)) {
            switch ($level) {
                case 'error':
                    Yii::log($prefix . $message, 'error', 'application.plugins.SuiteCRMIntegration');
                    break;
                case 'warning':
                    Yii::log($prefix . $message, 'warning', 'application.plugins.SuiteCRMIntegration');
                    break;
                case 'debug':
                    Yii::log($prefix . $message, 'trace', 'application.plugins.SuiteCRMIntegration');
                    break;
                default:
                    Yii::log($prefix . $message, 'info', 'application.plugins.SuiteCRMIntegration');
            }
        } else {
            // Fallback to error_log (goes to Apache error log, not stdout)
            error_log($prefix . "[$level] " . $message);
        }
    }

    /**
     * Add custom question attributes for CRM field mapping
     *
     * This adds a multi-mapping interface where each question can be mapped to
     * multiple SuiteCRM fields (one-to-many mapping support).
     *
     * The "SuiteCRM Integration" section is only shown in the question editor
     * when the survey-level setting "Enable SuiteCRM Integration" is enabled.
     */
    public function newQuestionAttributes()
    {
        $this->debugLog("newQuestionAttributes() called");
        $event = $this->getEvent();

        // Get the current survey ID from request parameters
        // This is available when editing a question in the admin interface
        $surveyId = null;
        $request = Yii::app()->getRequest();
        if ($request) {
            $surveyId = (int)$request->getParam('surveyid', 0);
            if ($surveyId <= 0) {
                // Also check 'sid' parameter (used in some contexts)
                $surveyId = (int)$request->getParam('sid', 0);
            }
        }

        $this->debugLog("newQuestionAttributes() surveyId from request: " . var_export($surveyId, true));

        // Only show the SuiteCRM Integration section if the integration is enabled for this survey
        if ($surveyId > 0 && !$this->isEnabledForSurvey($surveyId)) {
            $this->debugLog("SuiteCRM integration not enabled for survey {$surveyId}, hiding question attributes");
            return;
        }

        // Build module options
        $moduleOptions = ['' => '-- Select Module --'];
        foreach (self::SUPPORTED_MODULES as $module) {
            $moduleOptions[$module] = $module;
        }

        // Build field options (will be populated via AJAX based on module selection)
        $fieldOptions = ['' => '-- Select Field --'];

        // Try to get cached fields for all modules
        try {
            $cacheManager = $this->getCacheManager();
            foreach (self::SUPPORTED_MODULES as $module) {
                $fields = $cacheManager->getFields($module, false);
                foreach ($fields as $fieldName => $fieldDef) {
                    $label = $fieldDef['label'] ?? ucwords(str_replace('_', ' ', $fieldName));
                    $required = ($fieldDef['required'] ?? false) ? ' *' : '';
                    $key = json_encode(['module' => $module, 'field' => $fieldName]);
                    $fieldOptions[$key] = "{$module}: {$label}{$required}";
                }
            }
        } catch (Exception $e) {
            $this->debugLog("Error loading fields for question attributes: " . $e->getMessage());
        }

        // Build transform rule options
        $transformer = $this->getDataTransformer();
        $transformOptions = ['' => 'None (use value as-is)'];
        foreach ($transformer->getTransformRules() as $ruleKey => $ruleLabel) {
            if ($ruleKey !== 'none') {
                $transformOptions[$ruleKey] = $ruleLabel;
            }
        }

        // All LimeSurvey question type codes - required because the attribute filter
        // checks for specific question types (can't use null for "all types")
        $allQuestionTypes = '15ABCDEFGHIKLMNOPQRSTUXXY!|*:;';

        $questionAttributes = [
            // Hidden JSON storage for all mappings (managed entirely by JavaScript UI)
            'suitecrm_mappings_json' => [
                'types'     => $allQuestionTypes,
                'category'  => 'SuiteCRM Integration',
                'inputtype' => 'text',
                'default'   => '[]',
                'caption'   => 'CRM Field Mappings',
                'help'      => 'Configure which SuiteCRM fields this question should populate. Click the + button to add mappings.',
                'readonly'  => false,
            ],
        ];

        $this->debugLog("newQuestionAttributes() appending " . count($questionAttributes) . " attributes with types: " . $allQuestionTypes);
        $event->append('questionAttributes', $questionAttributes);

        // Register the question editor JavaScript when in the question editor
        $this->registerQuestionEditorAssets();
    }

    /**
     * Register JavaScript and CSS assets for the question editor
     */
    protected function registerQuestionEditorAssets()
    {
        // Only register if we're in the admin context
        if (!Yii::app()->hasComponent('clientScript')) {
            return;
        }

        try {
            $assetsPath = dirname(__FILE__) . '/assets';
            if (!is_dir($assetsPath)) {
                $this->debugLog("Assets directory not found: " . $assetsPath);
                return;
            }

            $assetsUrl = Yii::app()->assetManager->publish($assetsPath);

            // Register CSS first
            if (file_exists($assetsPath . '/question-editor.css')) {
                Yii::app()->clientScript->registerCssFile($assetsUrl . '/question-editor.css');
            }

            // Register JavaScript
            if (file_exists($assetsPath . '/question-editor.js')) {
                Yii::app()->clientScript->registerScriptFile(
                    $assetsUrl . '/question-editor.js',
                    CClientScript::POS_END
                );
            }

            $this->debugLog("Question editor assets registered from: " . $assetsUrl);
        } catch (Exception $e) {
            $this->debugLog("Failed to register question editor assets: " . $e->getMessage());
        }
    }

    /**
     * Sync field mappings from question attribute JSON to database
     *
     * This is called after a question is saved to extract the JSON mappings
     * from the suitecrm_mappings_json attribute and save them to our mappings table.
     */
    public function syncMappingsFromQuestionAttribute()
    {
        $event = $this->getEvent();
        $question = $event->get('question');

        if (!$question) {
            return;
        }

        $questionId = $question->qid ?? $question['qid'] ?? null;
        $surveyId = $question->sid ?? $question['sid'] ?? null;

        if (!$questionId || !$surveyId) {
            return;
        }

        $this->debugLog("syncMappingsFromQuestionAttribute() for question {$questionId} in survey {$surveyId}");

        try {
            // Get the JSON mappings attribute value
            $mappingsJson = '';

            // Try to get from question attributes
            if (is_object($question) && method_exists($question, 'getAttributes')) {
                $attrs = $question->getAttributes();
                $mappingsJson = $attrs['suitecrm_mappings_json'] ?? '';
            } elseif (is_array($question)) {
                $mappingsJson = $question['suitecrm_mappings_json'] ?? '';
            }

            // Also try QuestionAttribute model
            if (empty($mappingsJson)) {
                $attr = QuestionAttribute::model()->findByAttributes([
                    'qid' => $questionId,
                    'attribute' => 'suitecrm_mappings_json'
                ]);
                if ($attr) {
                    $mappingsJson = $attr->value ?? '';
                }
            }

            if (empty($mappingsJson) || $mappingsJson === '[]') {
                // No mappings, delete any existing
                $schema = $this->getDbSchema();
                $schema->deleteMapping($questionId);
                $this->debugLog("Cleared mappings for question {$questionId}");
                return;
            }

            // Parse the JSON
            $mappings = json_decode($mappingsJson, true);
            if (json_last_error() !== JSON_ERROR_NONE || !is_array($mappings)) {
                $this->debugLog("Invalid JSON in mappings for question {$questionId}: " . json_last_error_msg());
                return;
            }

            // Convert to the format expected by saveMappings
            $mappingsToSave = [];
            foreach ($mappings as $mapping) {
                if (!isset($mapping['module']) || !isset($mapping['field'])) {
                    continue;
                }
                $mappingsToSave[] = [
                    'module' => $mapping['module'],
                    'field' => $mapping['field'],
                    'label' => $mapping['label'] ?? '',
                    'type' => $mapping['type'] ?? 'varchar',
                    'transformRule' => $mapping['transformRule'] ?? ''
                ];
            }

            // Save to database
            $schema = $this->getDbSchema();
            $result = $schema->saveMappings($surveyId, $questionId, $mappingsToSave);

            $this->debugLog("Saved " . count($mappingsToSave) . " mappings for question {$questionId}: " . ($result ? 'success' : 'failed'));

        } catch (Exception $e) {
            $this->debugLog("Error syncing mappings for question {$questionId}: " . $e->getMessage());
        }
    }

    /**
     * Handle direct AJAX requests
     */
    public function newDirectRequest()
    {
        $event = $this->getEvent();

        if ($event->get('target') !== 'SuiteCRMIntegration') {
            return;
        }

        $request = Yii::app()->request;
        $function = $request->getParam('function', '');

        // Verify the function is allowed
        if (!in_array($function, $this->allowedPublicMethods)) {
            $this->sendJsonResponse(['error' => 'Invalid function'], 400);
            return;
        }

        // Call the appropriate method
        $methodName = $function;
        if (method_exists($this, $methodName)) {
            $this->$methodName();
        } else {
            $this->sendJsonResponse(['error' => 'Method not found'], 404);
        }
    }

    /**
     * AJAX: Get available CRM modules
     */
    public function actionGetModules()
    {
        $modules = [];
        foreach (self::SUPPORTED_MODULES as $module) {
            $modules[] = [
                'name' => $module,
                'label' => $module
            ];
        }

        $this->sendJsonResponse(['modules' => $modules]);
    }

    /**
     * AJAX: Get fields for a module
     */
    public function actionGetFields()
    {
        $request = Yii::app()->request;
        $module = $request->getParam('module', '');

        if (empty($module) || !in_array($module, self::SUPPORTED_MODULES)) {
            $this->sendJsonResponse(['error' => 'Invalid module'], 400);
            return;
        }

        try {
            $cacheManager = $this->getCacheManager();
            $fields = $cacheManager->getFields($module);

            $this->sendJsonResponse([
                'module' => $module,
                'fields' => $fields,
                'count' => count($fields)
            ]);
        } catch (Exception $e) {
            $this->sendJsonResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * AJAX: Get all fields for all supported modules (for populating field dropdowns)
     */
    public function actionGetAllFields()
    {
        try {
            $cacheManager = $this->getCacheManager();
            $allFields = [];

            foreach (self::SUPPORTED_MODULES as $module) {
                try {
                    $fields = $cacheManager->getFields($module, false);
                    if (!empty($fields)) {
                        $allFields[$module] = $fields;
                    }
                } catch (Exception $e) {
                    $this->debugLog("Error loading fields for {$module}: " . $e->getMessage());
                }
            }

            $this->sendJsonResponse([
                'fields' => $allFields,
                'modules' => array_keys($allFields)
            ]);
        } catch (Exception $e) {
            $this->sendJsonResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * AJAX: Test connection to SuiteCRM
     */
    public function actionTestConnection()
    {
        try {
            $apiClient = $this->getApiClient();
            $result = $apiClient->testConnection();

            $this->sendJsonResponse($result);
        } catch (Exception $e) {
            $this->sendJsonResponse([
                'success' => false,
                'error' => $e->getMessage()
            ], 500);
        }
    }

    /**
     * AJAX: Refresh field cache
     */
    public function actionRefreshCache()
    {
        try {
            $cacheManager = $this->getCacheManager();
            $status = $cacheManager->refreshAllCaches(self::SUPPORTED_MODULES);

            $this->sendJsonResponse([
                'success' => true,
                'status' => $status
            ]);
        } catch (Exception $e) {
            $this->sendJsonResponse([
                'success' => false,
                'error' => $e->getMessage()
            ], 500);
        }
    }

    /**
     * AJAX: Get sync logs for a survey
     */
    public function actionGetSyncLogs()
    {
        $request = Yii::app()->request;
        $surveyId = (int)$request->getParam('surveyId', 0);
        $limit = (int)$request->getParam('limit', 50);
        $offset = (int)$request->getParam('offset', 0);
        $status = $request->getParam('status', null);

        if ($surveyId <= 0) {
            $this->sendJsonResponse(['error' => 'Invalid survey ID'], 400);
            return;
        }

        try {
            $schema = $this->getDbSchema();
            $logs = $schema->getSyncLogs($surveyId, $limit, $offset, $status);
            $stats = $schema->getSyncStats($surveyId);

            $this->sendJsonResponse([
                'logs' => $logs,
                'stats' => $stats,
                'pagination' => [
                    'limit' => $limit,
                    'offset' => $offset
                ]
            ]);
        } catch (Exception $e) {
            $this->sendJsonResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * AJAX: Save field mappings for a question (supports one-to-many)
     */
    public function actionSaveMappings()
    {
        $request = Yii::app()->request;
        $surveyId = (int)$request->getParam('surveyId', 0);
        $questionId = (int)$request->getParam('questionId', 0);
        $mappingsJson = $request->getParam('mappings', '[]');

        if ($surveyId <= 0 || $questionId <= 0) {
            $this->sendJsonResponse(['error' => 'Invalid survey or question ID'], 400);
            return;
        }

        try {
            $mappings = json_decode($mappingsJson, true);
            if (json_last_error() !== JSON_ERROR_NONE) {
                $this->sendJsonResponse(['error' => 'Invalid JSON in mappings'], 400);
                return;
            }

            $schema = $this->getDbSchema();
            $result = $schema->saveMappings($surveyId, $questionId, $mappings);

            $this->sendJsonResponse([
                'success' => $result,
                'questionId' => $questionId,
                'mappingsCount' => count($mappings)
            ]);
        } catch (Exception $e) {
            $this->sendJsonResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * AJAX: Get field mappings for a question (supports one-to-many)
     */
    public function actionGetMappings()
    {
        $request = Yii::app()->request;
        $questionId = (int)$request->getParam('questionId', 0);

        if ($questionId <= 0) {
            $this->sendJsonResponse(['error' => 'Invalid question ID'], 400);
            return;
        }

        try {
            $schema = $this->getDbSchema();
            $mappings = $schema->getMappings($questionId);

            $this->sendJsonResponse([
                'questionId' => $questionId,
                'mappings' => $mappings,
                'count' => count($mappings)
            ]);
        } catch (Exception $e) {
            $this->sendJsonResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * AJAX: Get available transformation rules
     */
    public function actionGetTransformRules()
    {
        try {
            $transformer = $this->getDataTransformer();
            $rules = $transformer->getTransformRules();

            $this->sendJsonResponse([
                'rules' => $rules
            ]);
        } catch (Exception $e) {
            $this->sendJsonResponse(['error' => $e->getMessage()], 500);
        }
    }

    /**
     * AJAX: Check SuiteCRM connectivity and OAuth2 status
     *
     * This endpoint provides a comprehensive status check including:
     * - SuiteCRM HTTP endpoint availability
     * - SuiteCRM database connectivity
     * - oauth2clients table existence (indicates SuiteCRM is fully initialized)
     * - OAuth2 client status in LimeSurvey
     */
    public function actionCheckStatus()
    {
        $status = [
            'timestamp' => date('Y-m-d H:i:s'),
            'suitecrm_http' => ['status' => 'unknown', 'message' => ''],
            'suitecrm_database' => ['status' => 'unknown', 'message' => ''],
            'oauth2_table' => ['status' => 'unknown', 'message' => ''],
            'oauth2_client' => ['status' => 'unknown', 'message' => ''],
            'overall' => 'unknown'
        ];

        $suitecrmUrl = $this->get('suitecrm_url');

        // Check 1: SuiteCRM HTTP endpoint
        if (!empty($suitecrmUrl)) {
            try {
                $ch = curl_init(rtrim($suitecrmUrl, '/') . '/');
                curl_setopt_array($ch, [
                    CURLOPT_RETURNTRANSFER => true,
                    CURLOPT_TIMEOUT => 10,
                    CURLOPT_FOLLOWLOCATION => true,
                    CURLOPT_NOBODY => true  // HEAD request
                ]);
                curl_exec($ch);
                $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
                $error = curl_error($ch);
                curl_close($ch);

                if ($error) {
                    $status['suitecrm_http'] = [
                        'status' => 'error',
                        'message' => "Connection failed: {$error}"
                    ];
                } elseif ($httpCode >= 200 && $httpCode < 400) {
                    $status['suitecrm_http'] = [
                        'status' => 'ok',
                        'message' => "SuiteCRM is reachable (HTTP {$httpCode})"
                    ];
                } else {
                    $status['suitecrm_http'] = [
                        'status' => 'warning',
                        'message' => "SuiteCRM returned HTTP {$httpCode}"
                    ];
                }
            } catch (Exception $e) {
                $status['suitecrm_http'] = [
                    'status' => 'error',
                    'message' => $e->getMessage()
                ];
            }
        } else {
            $status['suitecrm_http'] = [
                'status' => 'error',
                'message' => 'SuiteCRM URL not configured'
            ];
        }

        // Check 2: SuiteCRM Database connectivity
        try {
            $pdo = $this->getSuiteCRMDatabaseConnection();
            $status['suitecrm_database'] = [
                'status' => 'ok',
                'message' => 'Database connection successful'
            ];

            // Check 3: oauth2clients table exists
            try {
                $stmt = $pdo->query("SHOW TABLES LIKE 'oauth2clients'");
                if ($stmt->rowCount() > 0) {
                    $status['oauth2_table'] = [
                        'status' => 'ok',
                        'message' => 'oauth2clients table exists - SuiteCRM is fully initialized'
                    ];
                } else {
                    $status['oauth2_table'] = [
                        'status' => 'warning',
                        'message' => 'oauth2clients table not found - SuiteCRM may still be initializing'
                    ];
                }
            } catch (Exception $e) {
                $status['oauth2_table'] = [
                    'status' => 'error',
                    'message' => 'Cannot check oauth2clients table: ' . $e->getMessage()
                ];
            }
        } catch (Exception $e) {
            $status['suitecrm_database'] = [
                'status' => 'error',
                'message' => 'Database connection failed: ' . $e->getMessage()
            ];
            $status['oauth2_table'] = [
                'status' => 'unknown',
                'message' => 'Cannot check - database not accessible'
            ];
        }

        // Check 4: OAuth2 client status
        $oauthInitialized = $this->get('oauth_initialized') === '1';
        $oauthClientId = $this->get('oauth_client_id');
        $oauthError = $this->get('oauth_init_error');

        if ($oauthInitialized && !empty($oauthClientId)) {
            $status['oauth2_client'] = [
                'status' => 'ok',
                'message' => "OAuth2 client initialized: {$oauthClientId}",
                'client_id' => $oauthClientId
            ];
        } elseif (!empty($oauthError)) {
            $status['oauth2_client'] = [
                'status' => 'error',
                'message' => "OAuth2 initialization failed: {$oauthError}",
                'last_error' => $oauthError
            ];
        } else {
            $status['oauth2_client'] = [
                'status' => 'pending',
                'message' => 'OAuth2 client not yet initialized (will be created on first use)'
            ];
        }

        // Determine overall status
        $hasErrors = false;
        $allOk = true;
        foreach (['suitecrm_http', 'suitecrm_database', 'oauth2_table', 'oauth2_client'] as $check) {
            if ($status[$check]['status'] === 'error') {
                $hasErrors = true;
                $allOk = false;
            } elseif ($status[$check]['status'] !== 'ok') {
                $allOk = false;
            }
        }

        if ($allOk) {
            $status['overall'] = 'ready';
        } elseif ($hasErrors) {
            $status['overall'] = 'error';
        } else {
            $status['overall'] = 'pending';
        }

        $this->sendJsonResponse($status);
    }

    /**
     * AJAX: Manually initialize OAuth2 client
     *
     * This endpoint allows administrators to manually trigger OAuth2 initialization
     * from the plugin settings page.
     */
    public function actionInitializeOAuth2()
    {
        $this->debugLog("actionInitializeOAuth2() called - manual OAuth2 initialization");

        $result = $this->initializeOAuth2Client();

        if ($result['success']) {
            $this->sendJsonResponse([
                'success' => true,
                'message' => $result['message'],
                'client_id' => $result['client_id'] ?? null
            ]);
        } else {
            $this->sendJsonResponse([
                'success' => false,
                'message' => $result['message'],
                'error' => $result['error'] ?? 'Unknown error',
                'retry_suggested' => $result['retry_suggested'] ?? false
            ], 500);
        }
    }

    /**
     * Send JSON response and exit
     *
     * @param array $data Response data
     * @param int $statusCode HTTP status code
     */
    private function sendJsonResponse(array $data, int $statusCode = 200)
    {
        header('Content-Type: application/json');
        http_response_code($statusCode);
        echo json_encode($data);
        Yii::app()->end();
    }
}
