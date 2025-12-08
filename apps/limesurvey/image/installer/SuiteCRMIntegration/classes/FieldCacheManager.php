<?php

/**
 * Field Cache Manager
 * 
 * Manages caching of SuiteCRM field metadata using LimeSurvey's plugin settings storage.
 * Implements time-based expiry and manual refresh capability.
 * 
 * @author Clouve
 * @version 2.0.0
 */
class FieldCacheManager
{
    /** @var SuiteCRMApiClient */
    private $apiClient;
    
    /** @var PluginBase Plugin instance for settings storage */
    private $plugin;
    
    /** @var int Cache TTL in seconds (default 24 hours) */
    private $cacheTtl;
    
    /** @var string Cache key prefix (short to fit in 50 char limit) */
    private const CACHE_PREFIX = 'scf_';

    /** @var string Metadata key for cache timestamps */
    private const CACHE_META_KEY = 'scf_meta';

    /**
     * Constructor
     * 
     * @param SuiteCRMApiClient $apiClient API client instance
     * @param PluginBase $plugin Plugin instance for settings storage
     * @param int $cacheTtlHours Cache TTL in hours (default 24)
     */
    public function __construct(SuiteCRMApiClient $apiClient, $plugin, int $cacheTtlHours = 24)
    {
        $this->apiClient = $apiClient;
        $this->plugin = $plugin;
        $this->cacheTtl = $cacheTtlHours * 3600;
    }

    /**
     * Get fields for a module (from cache or API)
     *
     * @param string $moduleName Module name
     * @param bool $forceRefresh Force refresh from API
     * @return array Field metadata
     * @throws Exception
     */
    public function getFields(string $moduleName, bool $forceRefresh = false): array
    {
        $cacheKey = $this->getCacheKey($moduleName);

        if (!$forceRefresh && $this->isCacheValid($moduleName)) {
            $cached = $this->plugin->getSetting($cacheKey);
            if (is_array($cached) && !empty($cached)) {
                return $cached;
            }
        }
        
        // Fetch from API and cache
        $fields = $this->apiClient->getModuleFields($moduleName);
        $this->cacheFields($moduleName, $fields);
        
        return $fields;
    }

    /**
     * Get fields for multiple modules
     * 
     * @param array $moduleNames Array of module names
     * @param bool $forceRefresh Force refresh from API
     * @return array Associative array of module => fields
     */
    public function getFieldsForModules(array $moduleNames, bool $forceRefresh = false): array
    {
        $result = [];
        
        foreach ($moduleNames as $moduleName) {
            try {
                $result[$moduleName] = $this->getFields($moduleName, $forceRefresh);
            } catch (Exception $e) {
                $result[$moduleName] = [
                    'error' => true,
                    'message' => $e->getMessage()
                ];
            }
        }
        
        return $result;
    }

    /**
     * Get flattened list of all fields for dropdown display
     * 
     * @param array $moduleNames Module names to include
     * @return array Formatted for dropdown: [key => "Module: Field Label"]
     */
    public function getFieldsForDropdown(array $moduleNames): array
    {
        $options = ['' => '-- None (No Mapping) --'];
        
        foreach ($moduleNames as $moduleName) {
            try {
                $fields = $this->getFields($moduleName);
                
                foreach ($fields as $fieldName => $fieldDef) {
                    $key = json_encode([
                        'module' => $moduleName,
                        'field' => $fieldName
                    ]);
                    $label = $fieldDef['label'] ?? ucwords(str_replace('_', ' ', $fieldName));
                    $required = ($fieldDef['required'] ?? false) ? ' *' : '';
                    $options[$key] = "{$moduleName}: {$label}{$required}";
                }
            } catch (Exception $e) {
                // Skip module if error
                continue;
            }
        }
        
        return $options;
    }

    /**
     * Refresh cache for all configured modules
     * 
     * @param array $moduleNames Modules to refresh
     * @return array Refresh status for each module
     */
    public function refreshAllCaches(array $moduleNames): array
    {
        $status = [];
        
        foreach ($moduleNames as $moduleName) {
            try {
                $fields = $this->getFields($moduleName, true);
                $status[$moduleName] = [
                    'success' => true,
                    'field_count' => count($fields),
                    'refreshed_at' => date('Y-m-d H:i:s')
                ];
            } catch (Exception $e) {
                $status[$moduleName] = [
                    'success' => false,
                    'error' => $e->getMessage()
                ];
            }
        }
        
        return $status;
    }

    /**
     * Clear cache for a specific module
     *
     * @param string $moduleName Module name
     */
    public function clearCache(string $moduleName): void
    {
        $cacheKey = $this->getCacheKey($moduleName);
        $this->plugin->setSetting($cacheKey, null);
        $this->updateCacheMetadata($moduleName, null);
    }

    /**
     * Clear all module caches
     *
     * @param array $moduleNames Modules to clear
     */
    public function clearAllCaches(array $moduleNames): void
    {
        foreach ($moduleNames as $moduleName) {
            $this->clearCache($moduleName);
        }
    }

    /**
     * Get cache status for all modules
     *
     * @param array $moduleNames Module names
     * @return array Cache status for each module
     */
    public function getCacheStatus(array $moduleNames): array
    {
        $status = [];
        $metadata = $this->getCacheMetadata();

        foreach ($moduleNames as $moduleName) {
            $cacheKey = $this->getCacheKey($moduleName);
            $cached = $this->plugin->getSetting($cacheKey);
            $cachedAt = $metadata[$moduleName]['cached_at'] ?? null;
            $expiresAt = $cachedAt ? ($cachedAt + $this->cacheTtl) : null;

            $status[$moduleName] = [
                'cached' => is_array($cached) && !empty($cached),
                'field_count' => is_array($cached) ? count($cached) : 0,
                'cached_at' => $cachedAt ? date('Y-m-d H:i:s', $cachedAt) : null,
                'expires_at' => $expiresAt ? date('Y-m-d H:i:s', $expiresAt) : null,
                'is_valid' => $this->isCacheValid($moduleName)
            ];
        }

        return $status;
    }

    /**
     * Generate cache key for a module
     * Key format: scf_<module> (e.g., scf_leads, scf_cases)
     * Must be <= 50 chars to fit in lime_plugin_settings.key column
     *
     * @param string $moduleName Module name
     * @return string Cache key
     */
    private function getCacheKey(string $moduleName): string
    {
        // Keep it simple and short - just prefix + lowercase module name
        return self::CACHE_PREFIX . strtolower($moduleName);
    }

    /**
     * Check if cache is still valid
     *
     * @param string $moduleName Module name
     * @return bool
     */
    private function isCacheValid(string $moduleName): bool
    {
        $metadata = $this->getCacheMetadata();
        $cachedAt = $metadata[$moduleName]['cached_at'] ?? 0;

        return (time() - $cachedAt) < $this->cacheTtl;
    }

    /**
     * Cache field data for a module
     *
     * @param string $moduleName Module name
     * @param array $fields Field data
     */
    private function cacheFields(string $moduleName, array $fields): void
    {
        $cacheKey = $this->getCacheKey($moduleName);
        $this->plugin->setSetting($cacheKey, $fields);
        $this->updateCacheMetadata($moduleName, time());
    }

    /**
     * Get cache metadata
     *
     * @return array
     */
    private function getCacheMetadata(): array
    {
        $metadata = $this->plugin->getSetting(self::CACHE_META_KEY);
        return is_array($metadata) ? $metadata : [];
    }

    /**
     * Update cache metadata
     *
     * @param string $moduleName Module name
     * @param int|null $timestamp Cache timestamp or null to clear
     */
    private function updateCacheMetadata(string $moduleName, ?int $timestamp): void
    {
        $metadata = $this->getCacheMetadata();

        if ($timestamp === null) {
            unset($metadata[$moduleName]);
        } else {
            $metadata[$moduleName] = [
                'cached_at' => $timestamp
            ];
        }

        $this->plugin->setSetting(self::CACHE_META_KEY, $metadata);
    }
}

