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
        'actionGetTransformRules'
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
            'help' => 'OAuth2 client ID (auto-generated if empty)',
            'readonly' => true
        ),
        'oauth_client_secret' => array(
            'type' => 'string',
            'default' => '',
            'label' => 'OAuth2 Client Secret',
            'help' => 'OAuth2 client secret (auto-generated if empty)',
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
     * Handle plugin activation
     */
    public function beforeActivate()
    {
        // Initialize OAuth2 client if not already set
        if (empty($this->get('oauth_client_id'))) {
            $this->initializeOAuth2Client();
        }

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
     */
    protected function getApiClient(): SuiteCRMApiClient
    {
        if ($this->apiClient === null) {
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
     * Initialize OAuth2 client in SuiteCRM database
     */
    protected function initializeOAuth2Client()
    {
        try {
            $clientId = 'limesurvey-' . uniqid();
            $clientSecret = bin2hex(random_bytes(32));
            $secretHash = hash('sha256', $clientSecret);

            // Connect to SuiteCRM database
            $pdo = $this->getSuiteCRMDatabaseConnection();

            // Check if client already exists
            $stmt = $pdo->prepare("SELECT id FROM oauth2clients WHERE name = ?");
            $stmt->execute(['LimeSurvey Integration']);

            if ($stmt->fetch()) {
                $this->log("OAuth2 client already exists", 'info');
                return;
            }

            // Insert OAuth2 client
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

            $this->log("OAuth2 client created successfully: {$clientId}", 'info');

        } catch (Exception $e) {
            $this->log("Error initializing OAuth2 client: " . $e->getMessage(), 'error');
            throw $e;
        }
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
     */
    public function log($message, $level = 'info')
    {
        // Only log if debug mode is enabled or level is error
        $debugMode = $this->get('debug_mode', null, null, '0');
        if (($debugMode !== '1' && $debugMode !== 1) && $level !== 'error') {
            return;
        }

        $prefix = '[SuiteCRM Integration] ';

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
            // Fallback to error_log
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
