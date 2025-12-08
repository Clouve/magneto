<?php

/**
 * SuiteCRM REST API v8 Client
 * 
 * Handles OAuth2 authentication and API communication with SuiteCRM.
 * 
 * @author Clouve
 * @version 2.0.0
 */
class SuiteCRMApiClient
{
    /** @var string SuiteCRM base URL */
    private $baseUrl;
    
    /** @var string OAuth2 client ID */
    private $clientId;
    
    /** @var string OAuth2 client secret */
    private $clientSecret;
    
    /** @var string Admin username */
    private $username;
    
    /** @var string Admin password */
    private $password;
    
    /** @var string|null Cached access token */
    private $accessToken = null;
    
    /** @var int Token expiration timestamp */
    private $tokenExpires = 0;
    
    /** @var bool Debug mode */
    private $debugMode = false;
    
    /** @var string Log file path */
    private $logFile = '/tmp/suitecrm_api.log';

    /**
     * Constructor
     * 
     * @param array $config Configuration array with keys: baseUrl, clientId, clientSecret, username, password
     */
    public function __construct(array $config)
    {
        $this->baseUrl = rtrim($config['baseUrl'] ?? '', '/');
        $this->clientId = $config['clientId'] ?? '';
        $this->clientSecret = $config['clientSecret'] ?? '';
        $this->username = $config['username'] ?? '';
        $this->password = $config['password'] ?? '';
        $this->debugMode = $config['debugMode'] ?? false;
    }

    /**
     * Set debug mode
     * 
     * @param bool $enabled
     * @return self
     */
    public function setDebugMode(bool $enabled): self
    {
        $this->debugMode = $enabled;
        return $this;
    }

    /**
     * Log debug message
     * 
     * @param string $message
     */
    private function log(string $message): void
    {
        if ($this->debugMode) {
            $timestamp = date('Y-m-d H:i:s');
            file_put_contents($this->logFile, "[{$timestamp}] [API] {$message}\n", FILE_APPEND);
        }
    }

    /**
     * Get OAuth2 access token
     * 
     * @return string Access token
     * @throws Exception If authentication fails
     */
    public function getAccessToken(): string
    {
        // Return cached token if still valid
        if ($this->accessToken && time() < $this->tokenExpires - 60) {
            return $this->accessToken;
        }

        $url = $this->baseUrl . '/Api/access_token';
        $this->log("Requesting access token from: {$url}");

        $data = [
            'grant_type' => 'password',
            'client_id' => $this->clientId,
            'client_secret' => $this->clientSecret,
            'username' => $this->username,
            'password' => $this->password
        ];

        $response = $this->httpRequest($url, 'POST', $data, [
            'Content-Type: application/x-www-form-urlencoded'
        ], false);

        if (!isset($response['access_token'])) {
            $this->log("Authentication failed: " . json_encode($response));
            throw new Exception("OAuth2 authentication failed: " . ($response['error_description'] ?? 'Unknown error'));
        }

        $this->accessToken = $response['access_token'];
        $this->tokenExpires = time() + ($response['expires_in'] ?? 3600);
        
        $this->log("Access token obtained, expires in {$response['expires_in']} seconds");

        return $this->accessToken;
    }

    /**
     * Test connection to SuiteCRM
     * 
     * @return array Connection status with details
     */
    public function testConnection(): array
    {
        try {
            $token = $this->getAccessToken();
            $modules = $this->getAvailableModules();
            
            return [
                'success' => true,
                'message' => 'Successfully connected to SuiteCRM',
                'modules_count' => count($modules),
                'modules' => $modules
            ];
        } catch (Exception $e) {
            return [
                'success' => false,
                'message' => $e->getMessage()
            ];
        }
    }

    /**
     * Get available modules list
     * 
     * @return array List of module names
     * @throws Exception
     */
    public function getAvailableModules(): array
    {
        $response = $this->apiRequest('GET', '/V8/meta/modules');
        return $response['data']['attributes'] ?? [];
    }

    /**
     * Get field metadata for a module
     *
     * @param string $moduleName Module name (e.g., 'Leads', 'Cases')
     * @return array Field definitions
     * @throws Exception
     */
    public function getModuleFields(string $moduleName): array
    {
        $this->log("Fetching fields for module: {$moduleName}");
        $response = $this->apiRequest('GET', "/V8/meta/fields/{$moduleName}");

        $fields = $response['data']['attributes'] ?? [];
        $this->log("Retrieved " . count($fields) . " fields for {$moduleName}");

        return $this->normalizeFieldMetadata($fields, $moduleName);
    }

    /**
     * Normalize field metadata for consistent format
     *
     * @param array $fields Raw field data from API
     * @param string $moduleName Module name
     * @return array Normalized field metadata
     */
    private function normalizeFieldMetadata(array $fields, string $moduleName): array
    {
        $normalized = [];

        foreach ($fields as $fieldName => $fieldDef) {
            // Skip system/internal fields
            if ($this->isSystemField($fieldName)) {
                continue;
            }

            $normalized[$fieldName] = [
                'name' => $fieldName,
                'module' => $moduleName,
                'type' => $fieldDef['type'] ?? 'varchar',
                'dbType' => $fieldDef['dbType'] ?? $fieldDef['type'] ?? 'varchar',
                'label' => $this->getFieldLabel($fieldDef, $fieldName),
                'required' => $fieldDef['required'] ?? false,
                'maxLength' => $fieldDef['len'] ?? null,
                'options' => $fieldDef['options'] ?? null,
                'default' => $fieldDef['default'] ?? null,
                'comment' => $fieldDef['comment'] ?? ''
            ];
        }

        return $normalized;
    }

    /**
     * Get human-readable field label
     *
     * @param array $fieldDef Field definition
     * @param string $fieldName Field name as fallback
     * @return string
     */
    private function getFieldLabel(array $fieldDef, string $fieldName): string
    {
        if (!empty($fieldDef['vname'])) {
            // vname is typically a language label key like "LBL_FIRST_NAME"
            // Convert to readable format
            $label = str_replace(['LBL_', '_'], ['', ' '], $fieldDef['vname']);
            return ucwords(strtolower($label));
        }

        return ucwords(str_replace('_', ' ', $fieldName));
    }

    /**
     * Check if field is a system field that should be hidden
     *
     * @param string $fieldName
     * @return bool
     */
    private function isSystemField(string $fieldName): bool
    {
        $systemFields = [
            'id', 'deleted', 'date_entered', 'date_modified',
            'modified_user_id', 'created_by', 'assigned_user_id',
            'modified_by_name', 'created_by_name', 'assigned_user_name',
            'team_id', 'team_set_id', 'team_count', 'team_name',
            'acl_team_set_id', 'update_date_entered'
        ];

        return in_array($fieldName, $systemFields);
    }

    /**
     * Create a record in a SuiteCRM module
     *
     * @param string $moduleName Module name (e.g., 'Leads', 'Cases')
     * @param array $attributes Record attributes
     * @return array Created record data with ID
     * @throws Exception
     */
    public function createRecord(string $moduleName, array $attributes): array
    {
        $this->log("Creating record in {$moduleName}: " . json_encode($attributes));

        $payload = [
            'data' => [
                'type' => $moduleName,
                'attributes' => $attributes
            ]
        ];

        $response = $this->apiRequest('POST', '/V8/module', $payload);

        $recordId = $response['data']['id'] ?? null;
        $this->log("Record created in {$moduleName} with ID: {$recordId}");

        return [
            'success' => true,
            'id' => $recordId,
            'type' => $moduleName,
            'attributes' => $response['data']['attributes'] ?? $attributes
        ];
    }

    /**
     * Make an authenticated API request
     *
     * @param string $method HTTP method
     * @param string $endpoint API endpoint
     * @param array|null $data Request body data
     * @return array Response data
     * @throws Exception
     */
    private function apiRequest(string $method, string $endpoint, ?array $data = null): array
    {
        $url = $this->baseUrl . '/Api' . $endpoint;
        $token = $this->getAccessToken();

        $headers = [
            'Content-Type: application/vnd.api+json',
            'Accept: application/vnd.api+json',
            'Authorization: Bearer ' . $token
        ];

        return $this->httpRequest($url, $method, $data, $headers, true);
    }

    /**
     * Make HTTP request
     *
     * @param string $url Request URL
     * @param string $method HTTP method
     * @param array|null $data Request body
     * @param array $headers HTTP headers
     * @param bool $jsonBody Whether to encode body as JSON
     * @return array Response data
     * @throws Exception
     */
    private function httpRequest(string $url, string $method, ?array $data, array $headers, bool $jsonBody): array
    {
        $ch = curl_init($url);

        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_TIMEOUT => 30,
            CURLOPT_FOLLOWLOCATION => true
        ]);

        if ($method === 'POST') {
            curl_setopt($ch, CURLOPT_POST, true);
            if ($data !== null) {
                $body = $jsonBody ? json_encode($data) : http_build_query($data);
                curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
            }
        } elseif ($method === 'PATCH') {
            curl_setopt($ch, CURLOPT_CUSTOMREQUEST, 'PATCH');
            if ($data !== null) {
                curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
            }
        }

        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error = curl_error($ch);
        curl_close($ch);

        if ($error) {
            $this->log("CURL error: {$error}");
            throw new Exception("API request failed: {$error}");
        }

        $this->log("HTTP {$method} {$url} - Response code: {$httpCode}");

        $decoded = json_decode($response, true);

        if ($httpCode >= 400) {
            $errorMsg = $decoded['errors'][0]['detail'] ?? $decoded['error_description'] ?? "HTTP {$httpCode}";
            $this->log("API error: {$errorMsg}");
            throw new Exception("SuiteCRM API error: {$errorMsg}");
        }

        return $decoded ?? [];
    }
}

