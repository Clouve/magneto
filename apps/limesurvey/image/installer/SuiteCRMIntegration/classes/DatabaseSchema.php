<?php

/**
 * Database Schema Manager for SuiteCRM Integration
 * 
 * Handles creation and management of custom database tables for
 * field mappings and sync logging.
 * 
 * @author Clouve
 * @version 2.0.0
 */
class SuiteCRMDatabaseSchema
{
    /** @var string Table prefix (from LimeSurvey config) */
    private $tablePrefix;
    
    /** @var CDbConnection Database connection */
    private $db;

    /**
     * Constructor
     */
    public function __construct()
    {
        $this->db = Yii::app()->db;
        $this->tablePrefix = Yii::app()->db->tablePrefix;
    }

    /**
     * Get full table name with prefix
     * 
     * @param string $tableName Base table name
     * @return string Full table name
     */
    public function getTableName(string $tableName): string
    {
        return $this->tablePrefix . $tableName;
    }

    /**
     * Check if schema is installed
     * 
     * @return bool
     */
    public function isInstalled(): bool
    {
        try {
            $mappingsTable = $this->getTableName('survey_crm_mappings');
            $exists = $this->db->createCommand("SHOW TABLES LIKE '{$mappingsTable}'")->queryScalar();
            return !empty($exists);
        } catch (Exception $e) {
            return false;
        }
    }

    /**
     * Install database schema
     *
     * @return array Installation status
     */
    public function install(): array
    {
        $results = [];

        try {
            // Create mappings table
            $results['mappings_table'] = $this->createMappingsTable();

            // Create sync log table
            $results['sync_log_table'] = $this->createSyncLogTable();

            // Migrate existing schema if needed (v2.0 to v2.1)
            $results['migration'] = $this->migrateSchemaIfNeeded();

            return [
                'success' => true,
                'details' => $results
            ];
        } catch (Exception $e) {
            return [
                'success' => false,
                'error' => $e->getMessage(),
                'details' => $results
            ];
        }
    }

    /**
     * Migrate schema from v2.0 to v2.1 (one-to-many support)
     *
     * Changes:
     * - Changes unique key from (question_id) to (question_id, crm_module, crm_field_name)
     * - Adds transform_rule column
     * - Adds index on question_id
     *
     * @return string Migration status
     */
    private function migrateSchemaIfNeeded(): string
    {
        $tableName = $this->getTableName('survey_crm_mappings');
        $changes = [];

        try {
            // Check if transform_rule column exists
            $columns = $this->db->createCommand("SHOW COLUMNS FROM {$tableName} LIKE 'transform_rule'")->queryScalar();
            if (empty($columns)) {
                // Add transform_rule column
                $this->db->createCommand("ALTER TABLE {$tableName} ADD COLUMN transform_rule VARCHAR(100) NULL COMMENT 'Optional value transformation rule, e.g., split_first, split_last' AFTER crm_field_type")->execute();
                $changes[] = 'Added transform_rule column';
            }

            // Check current unique key structure
            $indexes = $this->db->createCommand("SHOW INDEX FROM {$tableName} WHERE Key_name = 'unique_question_mapping'")->queryAll();

            if (!empty($indexes)) {
                // Old unique key exists (only on question_id), need to change it
                // First drop the old key
                $this->db->createCommand("ALTER TABLE {$tableName} DROP INDEX unique_question_mapping")->execute();
                $changes[] = 'Dropped old unique_question_mapping index';

                // Add new composite unique key
                $this->db->createCommand("ALTER TABLE {$tableName} ADD UNIQUE KEY unique_question_field_mapping (question_id, crm_module, crm_field_name)")->execute();
                $changes[] = 'Added new unique_question_field_mapping index';
            }

            // Check if question_id index exists
            $qidIndex = $this->db->createCommand("SHOW INDEX FROM {$tableName} WHERE Key_name = 'idx_question'")->queryAll();
            if (empty($qidIndex)) {
                $this->db->createCommand("ALTER TABLE {$tableName} ADD INDEX idx_question (question_id)")->execute();
                $changes[] = 'Added idx_question index';
            }

            if (empty($changes)) {
                return 'Schema already up to date';
            }

            return 'Migrated: ' . implode(', ', $changes);

        } catch (Exception $e) {
            // If table doesn't exist or other error, migration not needed
            return 'Migration skipped: ' . $e->getMessage();
        }
    }

    /**
     * Create the survey_crm_mappings table
     *
     * Note: In v2.1+, a single question can map to multiple CRM fields (one-to-many mapping).
     * The unique constraint is on (question_id, crm_module, crm_field_name) to allow
     * a question to populate multiple fields but prevent duplicate mappings.
     *
     * @return string Status message
     */
    private function createMappingsTable(): string
    {
        $tableName = $this->getTableName('survey_crm_mappings');

        $sql = "CREATE TABLE IF NOT EXISTS {$tableName} (
            id INT AUTO_INCREMENT PRIMARY KEY,
            survey_id INT NOT NULL,
            question_id INT NOT NULL,
            crm_module VARCHAR(100) NOT NULL COMMENT 'e.g., Leads, Cases',
            crm_field_name VARCHAR(100) NOT NULL COMMENT 'API field name, e.g., first_name',
            crm_field_label VARCHAR(255) NULL COMMENT 'Display label for reference',
            crm_field_type VARCHAR(50) NULL COMMENT 'Field type, e.g., varchar, email',
            transform_rule VARCHAR(100) NULL COMMENT 'Optional value transformation rule, e.g., split_first, split_last',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY unique_question_field_mapping (question_id, crm_module, crm_field_name),
            INDEX idx_survey (survey_id),
            INDEX idx_module (crm_module),
            INDEX idx_question (question_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci";

        $this->db->createCommand($sql)->execute();

        return "Created table: {$tableName}";
    }

    /**
     * Create the survey_crm_sync_log table
     * 
     * @return string Status message
     */
    private function createSyncLogTable(): string
    {
        $tableName = $this->getTableName('survey_crm_sync_log');
        
        $sql = "CREATE TABLE IF NOT EXISTS {$tableName} (
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
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci";
        
        $this->db->createCommand($sql)->execute();
        
        return "Created table: {$tableName}";
    }

    /**
     * Uninstall database schema (drop tables)
     *
     * @return array Uninstall status
     */
    public function uninstall(): array
    {
        $results = [];

        try {
            $tables = ['survey_crm_mappings', 'survey_crm_sync_log'];

            foreach ($tables as $table) {
                $tableName = $this->getTableName($table);
                $this->db->createCommand("DROP TABLE IF EXISTS {$tableName}")->execute();
                $results[$table] = "Dropped table: {$tableName}";
            }

            return [
                'success' => true,
                'details' => $results
            ];
        } catch (Exception $e) {
            return [
                'success' => false,
                'error' => $e->getMessage(),
                'details' => $results
            ];
        }
    }

    /**
     * Save a field mapping (one-to-many: a question can map to multiple fields)
     *
     * @param int $surveyId Survey ID
     * @param int $questionId Question ID
     * @param string $crmModule CRM module name
     * @param string $fieldName CRM field name
     * @param string $fieldLabel CRM field label
     * @param string $fieldType CRM field type
     * @param string $transformRule Optional transformation rule (e.g., 'split_first', 'split_last')
     * @return bool Success status
     */
    public function saveMapping(int $surveyId, int $questionId, string $crmModule, string $fieldName, string $fieldLabel = '', string $fieldType = '', string $transformRule = ''): bool
    {
        $tableName = $this->getTableName('survey_crm_mappings');

        // Use INSERT ... ON DUPLICATE KEY UPDATE for upsert
        // The unique key is (question_id, crm_module, crm_field_name) allowing one question to map to multiple fields
        $sql = "INSERT INTO {$tableName}
                (survey_id, question_id, crm_module, crm_field_name, crm_field_label, crm_field_type, transform_rule)
                VALUES (:survey_id, :question_id, :crm_module, :crm_field_name, :crm_field_label, :crm_field_type, :transform_rule)
                ON DUPLICATE KEY UPDATE
                survey_id = VALUES(survey_id),
                crm_field_label = VALUES(crm_field_label),
                crm_field_type = VALUES(crm_field_type),
                transform_rule = VALUES(transform_rule),
                updated_at = CURRENT_TIMESTAMP";

        return $this->db->createCommand($sql)->execute([
            ':survey_id' => $surveyId,
            ':question_id' => $questionId,
            ':crm_module' => $crmModule,
            ':crm_field_name' => $fieldName,
            ':crm_field_label' => $fieldLabel,
            ':crm_field_type' => $fieldType,
            ':transform_rule' => $transformRule ?: null
        ]) !== false;
    }

    /**
     * Save multiple field mappings for a single question (one-to-many mapping)
     * This replaces all existing mappings for the question with the new set.
     *
     * @param int $surveyId Survey ID
     * @param int $questionId Question ID
     * @param array $mappings Array of mapping data, each containing: module, field, label, type, transformRule
     * @return bool Success status
     */
    public function saveMappings(int $surveyId, int $questionId, array $mappings): bool
    {
        if (empty($mappings)) {
            // Delete all mappings for this question
            return $this->deleteMapping($questionId);
        }

        try {
            // Start transaction
            $transaction = $this->db->beginTransaction();

            // Delete existing mappings for this question
            $this->deleteMapping($questionId);

            // Insert new mappings
            foreach ($mappings as $mapping) {
                $result = $this->saveMapping(
                    $surveyId,
                    $questionId,
                    $mapping['module'] ?? $mapping['crm_module'] ?? '',
                    $mapping['field'] ?? $mapping['crm_field_name'] ?? '',
                    $mapping['label'] ?? $mapping['crm_field_label'] ?? '',
                    $mapping['type'] ?? $mapping['crm_field_type'] ?? '',
                    $mapping['transformRule'] ?? $mapping['transform_rule'] ?? ''
                );

                if (!$result) {
                    $transaction->rollback();
                    return false;
                }
            }

            $transaction->commit();
            return true;
        } catch (Exception $e) {
            if (isset($transaction)) {
                $transaction->rollback();
            }
            throw $e;
        }
    }

    /**
     * Delete all field mappings for a question
     *
     * @param int $questionId Question ID
     * @return bool Success status
     */
    public function deleteMapping(int $questionId): bool
    {
        $tableName = $this->getTableName('survey_crm_mappings');

        return $this->db->createCommand()
            ->delete($tableName, 'question_id = :question_id', [':question_id' => $questionId]) !== false;
    }

    /**
     * Delete a specific field mapping for a question
     *
     * @param int $questionId Question ID
     * @param string $crmModule CRM module
     * @param string $fieldName Field name
     * @return bool Success status
     */
    public function deleteSingleMapping(int $questionId, string $crmModule, string $fieldName): bool
    {
        $tableName = $this->getTableName('survey_crm_mappings');

        return $this->db->createCommand()
            ->delete($tableName,
                'question_id = :question_id AND crm_module = :crm_module AND crm_field_name = :crm_field_name',
                [
                    ':question_id' => $questionId,
                    ':crm_module' => $crmModule,
                    ':crm_field_name' => $fieldName
                ]
            ) !== false;
    }

    /**
     * Get all mappings for a question (returns array for one-to-many support)
     *
     * @param int $questionId Question ID
     * @return array Array of mappings (empty if none)
     */
    public function getMappings(int $questionId): array
    {
        $tableName = $this->getTableName('survey_crm_mappings');

        return $this->db->createCommand("SELECT * FROM {$tableName} WHERE question_id = :question_id ORDER BY id ASC")
            ->queryAll(true, [':question_id' => $questionId]);
    }

    /**
     * Get first mapping for a question (backward compatibility)
     *
     * @deprecated Use getMappings() instead for one-to-many support
     * @param int $questionId Question ID
     * @return array|null Mapping data or null
     */
    public function getMapping(int $questionId): ?array
    {
        $mappings = $this->getMappings($questionId);
        return !empty($mappings) ? $mappings[0] : null;
    }

    /**
     * Get all mappings for a survey (one-to-many: returns array of mappings per question)
     *
     * @param int $surveyId Survey ID
     * @return array Mappings grouped by question ID (each question can have multiple mappings)
     */
    public function getMappingsForSurvey(int $surveyId): array
    {
        $tableName = $this->getTableName('survey_crm_mappings');

        $results = $this->db->createCommand("SELECT * FROM {$tableName} WHERE survey_id = :survey_id ORDER BY question_id, id")
            ->queryAll(true, [':survey_id' => $surveyId]);

        // Group by question_id, each question can have multiple mappings
        $mappings = [];
        foreach ($results as $row) {
            $questionId = $row['question_id'];
            if (!isset($mappings[$questionId])) {
                $mappings[$questionId] = [];
            }
            $mappings[$questionId][] = $row;
        }

        return $mappings;
    }

    /**
     * Get all mappings for a survey as a flat list (for backward compatibility)
     * When a question has multiple mappings, each mapping is a separate entry.
     *
     * @param int $surveyId Survey ID
     * @return array Flat array of all mappings
     */
    public function getMappingsForSurveyFlat(int $surveyId): array
    {
        $tableName = $this->getTableName('survey_crm_mappings');

        return $this->db->createCommand("SELECT * FROM {$tableName} WHERE survey_id = :survey_id ORDER BY question_id, id")
            ->queryAll(true, [':survey_id' => $surveyId]);
    }

    /**
     * Get mappings grouped by module for a survey (updated for one-to-many)
     * Each module contains all mappings for that module, with question_id as first grouping.
     *
     * @param int $surveyId Survey ID
     * @return array Mappings grouped by CRM module, then by question_id
     */
    public function getMappingsGroupedByModule(int $surveyId): array
    {
        $allMappings = $this->getMappingsForSurveyFlat($surveyId);
        $grouped = [];

        foreach ($allMappings as $mapping) {
            $module = $mapping['crm_module'];
            $questionId = $mapping['question_id'];

            if (!isset($grouped[$module])) {
                $grouped[$module] = [];
            }
            if (!isset($grouped[$module][$questionId])) {
                $grouped[$module][$questionId] = [];
            }

            // Store as array of mappings per question (supports one-to-many)
            $grouped[$module][$questionId][] = $mapping;
        }

        return $grouped;
    }

    /**
     * Get mappings directly from question attributes (suitecrm_mappings_json)
     *
     * This reads the JSON mappings stored in question attributes, which is the
     * source of truth for field mappings. This is useful when mappings haven't
     * been synced to the survey_crm_mappings table (e.g., after CLI import).
     *
     * @param int $surveyId Survey ID
     * @return array Mappings grouped by CRM module, then by question_id
     */
    public function getMappingsFromQuestionAttributes(int $surveyId): array
    {
        $tablePrefix = \Yii::app()->db->tablePrefix;

        $sql = "
            SELECT q.qid, qa.value as mappings_json
            FROM {$tablePrefix}questions q
            INNER JOIN {$tablePrefix}question_attributes qa ON q.qid = qa.qid
            WHERE q.sid = :survey_id
              AND q.parent_qid = 0
              AND qa.attribute = 'suitecrm_mappings_json'
              AND qa.value IS NOT NULL
              AND qa.value != ''
              AND qa.value != '[]'
        ";

        $rows = $this->db->createCommand($sql)
            ->queryAll(true, [':survey_id' => $surveyId]);

        $grouped = [];

        foreach ($rows as $row) {
            $questionId = (int)$row['qid'];
            $mappings = json_decode($row['mappings_json'], true);

            if (json_last_error() !== JSON_ERROR_NONE || !is_array($mappings)) {
                continue;
            }

            foreach ($mappings as $mapping) {
                if (!isset($mapping['module']) || !isset($mapping['field'])) {
                    continue;
                }

                $module = $mapping['module'];

                if (!isset($grouped[$module])) {
                    $grouped[$module] = [];
                }
                if (!isset($grouped[$module][$questionId])) {
                    $grouped[$module][$questionId] = [];
                }

                // Convert to the same format as getMappingsGroupedByModule
                $grouped[$module][$questionId][] = [
                    'question_id' => $questionId,
                    'crm_module' => $module,
                    'crm_field_name' => $mapping['field'],
                    'crm_field_label' => $mapping['label'] ?? ucwords(str_replace('_', ' ', $mapping['field'])),
                    'crm_field_type' => $mapping['type'] ?? 'varchar',
                    'transform_rule' => $mapping['transformRule'] ?? ''
                ];
            }
        }

        return $grouped;
    }

    /**
     * Log a sync attempt
     *
     * @param int $responseId Response ID
     * @param int $surveyId Survey ID
     * @param string $crmModule CRM module
     * @param string $status Sync status (success, failed, partial)
     * @param string|null $crmRecordId Created CRM record ID
     * @param array|null $requestPayload Request payload
     * @param array|null $responseData Response data
     * @param string|null $errorMessage Error message
     * @param array|null $fieldMappings Field mappings used
     * @return int Inserted log ID
     */
    public function logSync(
        int $responseId,
        int $surveyId,
        string $crmModule,
        string $status,
        ?string $crmRecordId = null,
        ?array $requestPayload = null,
        ?array $responseData = null,
        ?string $errorMessage = null,
        ?array $fieldMappings = null
    ): int {
        $tableName = $this->getTableName('survey_crm_sync_log');

        $this->db->createCommand()->insert($tableName, [
            'response_id' => $responseId,
            'survey_id' => $surveyId,
            'crm_module' => $crmModule,
            'sync_status' => $status,
            'crm_record_id' => $crmRecordId,
            'request_payload' => $requestPayload ? json_encode($requestPayload) : null,
            'response_data' => $responseData ? json_encode($responseData) : null,
            'error_message' => $errorMessage,
            'field_mappings_used' => $fieldMappings ? json_encode($fieldMappings) : null
        ]);

        return $this->db->getLastInsertID();
    }

    /**
     * Get sync logs for a survey
     *
     * @param int $surveyId Survey ID
     * @param int $limit Max results
     * @param int $offset Offset for pagination
     * @param string|null $statusFilter Filter by status
     * @return array Sync logs
     */
    public function getSyncLogs(int $surveyId, int $limit = 50, int $offset = 0, ?string $statusFilter = null): array
    {
        $tableName = $this->getTableName('survey_crm_sync_log');

        $where = 'survey_id = :survey_id';
        $params = [':survey_id' => $surveyId];

        if ($statusFilter) {
            $where .= ' AND sync_status = :status';
            $params[':status'] = $statusFilter;
        }

        $sql = "SELECT * FROM {$tableName} WHERE {$where} ORDER BY synced_at DESC LIMIT {$limit} OFFSET {$offset}";

        return $this->db->createCommand($sql)->queryAll(true, $params);
    }

    /**
     * Get sync log statistics for a survey
     *
     * @param int $surveyId Survey ID
     * @return array Statistics
     */
    public function getSyncStats(int $surveyId): array
    {
        $tableName = $this->getTableName('survey_crm_sync_log');

        $sql = "SELECT
                    sync_status,
                    COUNT(*) as count,
                    MAX(synced_at) as last_sync
                FROM {$tableName}
                WHERE survey_id = :survey_id
                GROUP BY sync_status";

        $results = $this->db->createCommand($sql)->queryAll(true, [':survey_id' => $surveyId]);

        $stats = [
            'total' => 0,
            'success' => 0,
            'failed' => 0,
            'partial' => 0,
            'last_sync' => null
        ];

        foreach ($results as $row) {
            $stats[$row['sync_status']] = (int)$row['count'];
            $stats['total'] += (int)$row['count'];

            if (!$stats['last_sync'] || $row['last_sync'] > $stats['last_sync']) {
                $stats['last_sync'] = $row['last_sync'];
            }
        }

        return $stats;
    }
}

