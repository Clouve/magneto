<?php

/**
 * Data Transformer for SuiteCRM Integration
 *
 * Transforms LimeSurvey response data to SuiteCRM-compatible format.
 * Handles field type compatibility, validation, one-to-many field mappings,
 * and auto-generation of values for required fields.
 *
 * @author Clouve
 * @version 2.2.0
 */
class SuiteCRMDataTransformer
{
    /**
     * Available transformation rules for one-to-many mappings
     * These allow a single question value to be transformed differently for each target field
     */
    public const TRANSFORM_RULES = [
        'none' => 'No transformation (use value as-is)',
        'split_first' => 'Split by space/comma, take first part (e.g., "John Doe" → "John")',
        'split_last' => 'Split by space/comma, take last part (e.g., "John Doe" → "Doe")',
        'split_middle' => 'Split by space, take middle parts (e.g., "John A. Doe" → "A.")',
        'uppercase' => 'Convert to uppercase',
        'lowercase' => 'Convert to lowercase',
        'trim' => 'Trim whitespace',
        'email_domain' => 'Extract domain from email (e.g., "user@example.com" → "example.com")',
        'email_local' => 'Extract local part from email (e.g., "user@example.com" → "user")',
        // Auto-generation rules - generate values at CRM record creation time
        'auto_uuid' => '⚡ Auto-generate: Unique ID (UUID format)',
        'auto_number' => '⚡ Auto-generate: Sequential number (timestamp-based)',
        'auto_date' => '⚡ Auto-generate: Current date',
        'auto_datetime' => '⚡ Auto-generate: Current date and time',
        'auto_timestamp' => '⚡ Auto-generate: Unix timestamp',
        'auto_survey_ref' => '⚡ Auto-generate: Survey reference (SurveyID-ResponseID)',
    ];

    /**
     * Rules that generate values regardless of input (auto-generation rules)
     */
    private const AUTO_GENERATE_RULES = [
        'auto_uuid',
        'auto_number',
        'auto_date',
        'auto_datetime',
        'auto_timestamp',
        'auto_survey_ref',
    ];

    /**
     * LimeSurvey question type to SuiteCRM field type compatibility matrix
     */
    private const TYPE_COMPATIBILITY = [
        // Text question types
        'S' => ['varchar', 'text', 'email', 'phone', 'url', 'name'],     // Short text
        'T' => ['text', 'varchar'],                                       // Long text
        'U' => ['text', 'varchar'],                                       // Huge text
        
        // Choice question types
        'L' => ['varchar', 'enum'],                                       // List (Radio)
        '!' => ['varchar', 'enum'],                                       // List (Dropdown)
        'O' => ['varchar', 'enum', 'text'],                               // List with comment
        'M' => ['multienum', 'text', 'varchar'],                          // Multiple choice
        'P' => ['multienum', 'text', 'varchar'],                          // Multiple choice with comments
        
        // Array question types
        'A' => ['varchar', 'enum', 'int'],                                // Array (5 point choice)
        'B' => ['varchar', 'enum', 'int'],                                // Array (10 point choice)
        'C' => ['varchar', 'enum'],                                       // Array (Yes/No/Uncertain)
        'E' => ['varchar', 'enum'],                                       // Array (Increase/Same/Decrease)
        'F' => ['varchar', 'enum', 'text'],                               // Array (Flexible)
        'H' => ['varchar', 'enum', 'text'],                               // Array (Column)
        
        // Date/Time types
        'D' => ['date', 'datetime', 'varchar'],                           // Date
        
        // Numeric types
        'N' => ['int', 'float', 'decimal', 'currency', 'varchar'],        // Numerical
        'K' => ['int', 'float', 'decimal', 'varchar'],                    // Multiple numerical
        
        // Special types
        'Q' => ['text', 'varchar'],                                       // Multiple short text
        ';' => ['text', 'varchar'],                                       // Array (Texts)
        ':' => ['text', 'varchar'],                                       // Array (Numbers)
        'R' => ['varchar', 'text'],                                       // Ranking
        
        // Other types
        'G' => ['enum', 'varchar'],                                       // Gender
        'Y' => ['bool', 'varchar', 'enum'],                               // Yes/No
        'I' => ['varchar', 'text'],                                       // Language
        '*' => ['varchar', 'text'],                                       // Equation
        'X' => [],                                                         // Boilerplate (no mapping)
        '|' => ['varchar', 'text'],                                       // File upload
    ];

    /**
     * Check if a LimeSurvey question type is compatible with a SuiteCRM field type
     * 
     * @param string $questionType LimeSurvey question type code
     * @param string $crmFieldType SuiteCRM field type
     * @return bool True if compatible
     */
    public function isTypeCompatible(string $questionType, string $crmFieldType): bool
    {
        $compatible = self::TYPE_COMPATIBILITY[$questionType] ?? ['varchar', 'text'];
        return in_array($crmFieldType, $compatible, true);
    }

    /**
     * Get compatible CRM field types for a question type
     * 
     * @param string $questionType LimeSurvey question type code
     * @return array List of compatible CRM field types
     */
    public function getCompatibleFieldTypes(string $questionType): array
    {
        return self::TYPE_COMPATIBILITY[$questionType] ?? ['varchar', 'text'];
    }

    /**
     * Get compatibility warning message
     * 
     * @param string $questionType LimeSurvey question type
     * @param string $crmFieldType SuiteCRM field type
     * @return string|null Warning message or null if compatible
     */
    public function getCompatibilityWarning(string $questionType, string $crmFieldType): ?string
    {
        if ($this->isTypeCompatible($questionType, $crmFieldType)) {
            return null;
        }
        
        $questionTypeName = $this->getQuestionTypeName($questionType);
        $compatible = implode(', ', $this->getCompatibleFieldTypes($questionType));
        
        return "Question type '{$questionTypeName}' may not be compatible with CRM field type '{$crmFieldType}'. " .
               "Recommended types: {$compatible}";
    }

    /**
     * Get human-readable question type name
     * 
     * @param string $typeCode Question type code
     * @return string
     */
    private function getQuestionTypeName(string $typeCode): string
    {
        $names = [
            'S' => 'Short Text',
            'T' => 'Long Text',
            'U' => 'Huge Text',
            'L' => 'List (Radio)',
            '!' => 'List (Dropdown)',
            'O' => 'List with Comment',
            'M' => 'Multiple Choice',
            'P' => 'Multiple Choice with Comments',
            'D' => 'Date',
            'N' => 'Numerical',
            'K' => 'Multiple Numerical',
            'Q' => 'Multiple Short Text',
            'Y' => 'Yes/No',
            'G' => 'Gender',
        ];
        
        return $names[$typeCode] ?? "Type {$typeCode}";
    }

    /**
     * Transform a LimeSurvey response value to SuiteCRM format
     * 
     * @param mixed $value Raw response value
     * @param string $questionType LimeSurvey question type
     * @param array $crmFieldDef SuiteCRM field definition
     * @return mixed Transformed value
     */
    public function transformValue($value, string $questionType, array $crmFieldDef)
    {
        $crmType = $crmFieldDef['type'] ?? 'varchar';
        
        // Handle empty values
        if ($value === null || $value === '') {
            return $crmFieldDef['default'] ?? null;
        }
        
        // Type-specific transformations
        switch ($crmType) {
            case 'bool':
                return $this->transformToBoolean($value);

            case 'int':
            case 'integer':
                return $this->transformToInteger($value);

            case 'float':
            case 'decimal':
            case 'currency':
                return $this->transformToFloat($value);

            case 'date':
                return $this->transformToDate($value);

            case 'datetime':
                return $this->transformToDateTime($value);

            case 'multienum':
                return $this->transformToMultienum($value);

            case 'email':
                return $this->transformToEmail($value);

            case 'varchar':
            case 'text':
            default:
                return $this->transformToString($value, $crmFieldDef);
        }
    }

    /**
     * Transform value to boolean
     */
    private function transformToBoolean($value): bool
    {
        if (is_bool($value)) {
            return $value;
        }

        $trueValues = ['Y', 'Yes', 'yes', '1', 'true', 'TRUE', 'on'];
        return in_array($value, $trueValues, true);
    }

    /**
     * Transform value to integer
     */
    private function transformToInteger($value): ?int
    {
        if (is_numeric($value)) {
            return (int)$value;
        }
        return null;
    }

    /**
     * Transform value to float
     */
    private function transformToFloat($value): ?float
    {
        if (is_numeric($value)) {
            return (float)$value;
        }
        return null;
    }

    /**
     * Transform value to date format (Y-m-d)
     */
    private function transformToDate($value): ?string
    {
        if (empty($value)) {
            return null;
        }

        $timestamp = strtotime($value);
        if ($timestamp === false) {
            return null;
        }

        return date('Y-m-d', $timestamp);
    }

    /**
     * Transform value to datetime format (Y-m-d H:i:s)
     */
    private function transformToDateTime($value): ?string
    {
        if (empty($value)) {
            return null;
        }

        $timestamp = strtotime($value);
        if ($timestamp === false) {
            return null;
        }

        return date('Y-m-d H:i:s', $timestamp);
    }

    /**
     * Transform value to multienum format (comma-separated)
     */
    private function transformToMultienum($value): string
    {
        if (is_array($value)) {
            return '^' . implode('^,^', $value) . '^';
        }

        // Handle LimeSurvey multiple choice format
        if (is_string($value) && strpos($value, '|') !== false) {
            $parts = explode('|', $value);
            return '^' . implode('^,^', $parts) . '^';
        }

        return '^' . $value . '^';
    }

    /**
     * Transform value to email format
     */
    private function transformToEmail($value): ?string
    {
        $value = trim($value);

        if (filter_var($value, FILTER_VALIDATE_EMAIL)) {
            return $value;
        }

        return null;
    }

    /**
     * Transform value to string with length validation
     */
    private function transformToString($value, array $fieldDef): string
    {
        $value = (string)$value;

        // Trim to max length if specified
        $maxLength = $fieldDef['maxLength'] ?? $fieldDef['len'] ?? null;
        if ($maxLength && strlen($value) > $maxLength) {
            $value = substr($value, 0, $maxLength);
        }

        return $value;
    }

    /**
     * Validate a value against CRM field constraints
     *
     * @param mixed $value Value to validate
     * @param array $crmFieldDef Field definition
     * @return array Validation result with 'valid' and 'errors' keys
     */
    public function validateValue($value, array $crmFieldDef): array
    {
        $errors = [];

        // Check required
        if (($crmFieldDef['required'] ?? false) && ($value === null || $value === '')) {
            $errors[] = "Field '{$crmFieldDef['label']}' is required";
        }

        // Check max length
        $maxLength = $crmFieldDef['maxLength'] ?? $crmFieldDef['len'] ?? null;
        if ($maxLength && is_string($value) && strlen($value) > $maxLength) {
            $errors[] = "Field '{$crmFieldDef['label']}' exceeds maximum length of {$maxLength}";
        }

        // Check email format
        if (($crmFieldDef['type'] ?? '') === 'email' && !empty($value)) {
            if (!filter_var($value, FILTER_VALIDATE_EMAIL)) {
                $errors[] = "Field '{$crmFieldDef['label']}' must be a valid email address";
            }
        }

        return [
            'valid' => empty($errors),
            'errors' => $errors
        ];
    }

    /**
     * Apply a transformation rule to a value
     *
     * @param mixed $value The original value
     * @param string $rule The transformation rule to apply
     * @param array $context Optional context (surveyId, responseId) for auto-generation
     * @return mixed The transformed value
     */
    public function applyTransformRule($value, string $rule, array $context = [])
    {
        // Handle auto-generation rules first (they generate values regardless of input)
        if ($this->isAutoGenerateRule($rule)) {
            return $this->generateAutoValue($rule, $context);
        }

        // For regular rules, return early if no value or rule
        if (empty($rule) || $rule === 'none' || $value === null || $value === '') {
            return $value;
        }

        $value = (string)$value;

        switch ($rule) {
            case 'split_first':
                // Split by space or comma, return first part
                $parts = preg_split('/[\s,]+/', trim($value), -1, PREG_SPLIT_NO_EMPTY);
                return !empty($parts) ? $parts[0] : $value;

            case 'split_last':
                // Split by space or comma, return last part
                $parts = preg_split('/[\s,]+/', trim($value), -1, PREG_SPLIT_NO_EMPTY);
                return !empty($parts) ? end($parts) : $value;

            case 'split_middle':
                // Split by space, return middle parts (everything except first and last)
                $parts = preg_split('/\s+/', trim($value), -1, PREG_SPLIT_NO_EMPTY);
                if (count($parts) <= 2) {
                    return '';
                }
                array_shift($parts); // Remove first
                array_pop($parts);   // Remove last
                return implode(' ', $parts);

            case 'uppercase':
                return mb_strtoupper($value, 'UTF-8');

            case 'lowercase':
                return mb_strtolower($value, 'UTF-8');

            case 'trim':
                return trim($value);

            case 'email_domain':
                // Extract domain from email
                if (strpos($value, '@') !== false) {
                    $parts = explode('@', $value);
                    return end($parts);
                }
                return $value;

            case 'email_local':
                // Extract local part from email
                if (strpos($value, '@') !== false) {
                    $parts = explode('@', $value);
                    return $parts[0];
                }
                return $value;

            default:
                return $value;
        }
    }

    /**
     * Check if a rule is an auto-generation rule
     *
     * @param string $rule The rule to check
     * @return bool True if it's an auto-generation rule
     */
    public function isAutoGenerateRule(string $rule): bool
    {
        return in_array($rule, self::AUTO_GENERATE_RULES, true);
    }

    /**
     * Generate an auto-value based on the rule type
     *
     * @param string $rule The auto-generation rule
     * @param array $context Optional context (surveyId, responseId)
     * @return mixed The generated value
     */
    private function generateAutoValue(string $rule, array $context = [])
    {
        switch ($rule) {
            case 'auto_uuid':
                return $this->generateUuid();

            case 'auto_number':
                return $this->generateSequentialNumber();

            case 'auto_date':
                return date('Y-m-d');

            case 'auto_datetime':
                return date('Y-m-d H:i:s');

            case 'auto_timestamp':
                return time();

            case 'auto_survey_ref':
                return $this->generateSurveyReference($context);

            default:
                return null;
        }
    }

    /**
     * Generate a UUID v4
     *
     * @return string UUID string
     */
    private function generateUuid(): string
    {
        // Generate 16 random bytes
        if (function_exists('random_bytes')) {
            $data = random_bytes(16);
        } else {
            $data = openssl_random_pseudo_bytes(16);
        }

        // Set version (4) and variant bits
        $data[6] = chr(ord($data[6]) & 0x0f | 0x40); // version 4
        $data[8] = chr(ord($data[8]) & 0x3f | 0x80); // variant

        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($data), 4));
    }

    /**
     * Generate a sequential number based on timestamp and random suffix
     * Format: YYYYMMDD-HHMMSS-XXXX (e.g., 20240115-143052-7829)
     *
     * @return string Sequential number
     */
    private function generateSequentialNumber(): string
    {
        $datePart = date('Ymd-His');
        $randomPart = str_pad((string)mt_rand(0, 9999), 4, '0', STR_PAD_LEFT);
        return $datePart . '-' . $randomPart;
    }

    /**
     * Generate a survey reference combining survey and response IDs
     *
     * @param array $context Context with surveyId and responseId
     * @return string Survey reference
     */
    private function generateSurveyReference(array $context): string
    {
        $surveyId = $context['surveyId'] ?? 'S';
        $responseId = $context['responseId'] ?? time();
        return "LS-{$surveyId}-{$responseId}";
    }

    /**
     * Get available transformation rules
     *
     * @return array Associative array of rule_key => description
     */
    public function getTransformRules(): array
    {
        return self::TRANSFORM_RULES;
    }

    /**
     * Transform complete survey response to CRM payload (one-to-many mappings)
     *
     * Each question can map to multiple CRM fields with optional transformation rules.
     * Example: A "Full Name" question can populate both first_name (with split_first)
     * and last_name (with split_last) fields in SuiteCRM.
     *
     * Auto-generation rules (auto_uuid, auto_number, etc.) will generate values
     * regardless of whether a question response exists, making them suitable for
     * required CRM fields that don't need user input.
     *
     * @param array $response LimeSurvey response data (question_code => value)
     * @param array $mappings Field mappings: question_id => [array of mapping_info]
     *                        Each mapping_info contains: crm_module, crm_field_name, transform_rule
     * @param array $questions Questions info (question_id => question_info with type)
     * @param array $crmFields CRM field definitions by module
     * @param array $context Optional context (surveyId, responseId) for auto-generation
     * @return array Transformed data grouped by module with 'data', 'errors', 'valid' keys
     */
    public function transformResponse(
        array $response,
        array $mappings,
        array $questions,
        array $crmFields,
        array $context = []
    ): array {
        $result = [];
        $errors = [];

        foreach ($mappings as $questionId => $mappingsList) {
            $questionCode = $this->findQuestionCode($questionId, $questions);
            $originalValue = null;
            $questionType = 'S'; // Default to short text

            // Get the response value if available
            if ($questionCode && isset($response[$questionCode])) {
                $originalValue = $response[$questionCode];
                $questionType = $questions[$questionId]['type'] ?? 'S';
            }

            // mappingsList is always an array of mappings (one-to-many)
            if (!is_array($mappingsList) || empty($mappingsList)) {
                continue;
            }

            // Process each target field mapping for this question
            foreach ($mappingsList as $mapping) {
                if (!is_array($mapping) || !isset($mapping['crm_module']) || !isset($mapping['crm_field_name'])) {
                    continue;
                }

                $module = $mapping['crm_module'];
                $fieldName = $mapping['crm_field_name'];
                $transformRule = $mapping['transform_rule'] ?? '';
                $fieldDef = $crmFields[$module][$fieldName] ?? ['type' => 'varchar'];

                // For auto-generate rules, we process even if no question response exists
                // For regular rules, skip if no response
                if (!$this->isAutoGenerateRule($transformRule) && ($originalValue === null || $originalValue === '')) {
                    continue;
                }

                // Apply transformation rule (auto-generate rules will create values here)
                $value = $this->applyTransformRule($originalValue, $transformRule, $context);

                // Then apply type transformation
                $transformed = $this->transformValue($value, $questionType, $fieldDef);

                // Validate
                $validation = $this->validateValue($transformed, $fieldDef);
                if (!$validation['valid']) {
                    $errors = array_merge($errors, $validation['errors']);
                }

                // Group by module
                if (!isset($result[$module])) {
                    $result[$module] = [];
                }
                $result[$module][$fieldName] = $transformed;
            }
        }

        return [
            'data' => $result,
            'errors' => $errors,
            'valid' => empty($errors)
        ];
    }

    /**
     * Find question code by question ID
     */
    private function findQuestionCode(int $questionId, array $questions): ?string
    {
        foreach ($questions as $qid => $question) {
            if ((int)$qid === $questionId || (int)($question['qid'] ?? 0) === $questionId) {
                return $question['title'] ?? $question['code'] ?? null;
            }
        }
        return null;
    }
}

