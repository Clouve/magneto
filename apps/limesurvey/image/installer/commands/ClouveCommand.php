<?php
/**
 * Console commands of the Clouve LimeSurvey image.
 *
 * configure-suitecrm-plugin.sh runs them as www-data through LimeSurvey's own console.php, which loads every command
 * class in the folder that YII_CONSOLE_COMMANDS names:
 *
 *   YII_CONSOLE_COMMANDS=/clouve/limesurvey/installer/commands php application/commands/console.php clouve schema
 *   YII_CONSOLE_COMMANDS=/clouve/limesurvey/installer/commands php application/commands/console.php clouve suitecrm
 *
 * The file is in the image, outside the web root, and nothing is added to the volume. Values come from the
 * environment, never from the command line, and none is printed.
 */
class ClouveCommand extends CConsoleCommand
{
    /** The SuiteCRM settings that follow the environment at every start: setting => [variable, default]. */
    private const SUITECRM_SETTINGS = [
        'suitecrm_url' => ['SUITECRM_URL', null],
        'suitecrm_admin_user' => ['SUITECRM_ADMIN_USER', 'admin'],
        'suitecrm_admin_password' => ['SUITECRM_ADMIN_PASSWORD', null],
        'suitecrm_db_host' => ['SUITECRM_DB_HOST', 'suitecrm-mariadb'],
        'suitecrm_db_port' => ['SUITECRM_DB_PORT', '3306'],
        'suitecrm_db_name' => ['SUITECRM_DB_NAME', 'suitecrm'],
        'suitecrm_db_user' => ['SUITECRM_DB_USER', 'suitecrm'],
        'suitecrm_db_password' => ['SUITECRM_DB_PASSWORD', null],
    ];

    /**
     * Writes the SuiteCRM plugin's connection settings from the environment, through the plugin's own storage, so
     * the two passwords are stored encrypted with the keys in security.php. It never changes whether the plugin is
     * switched on, and it leaves the settings an admin chose (the plugin's own "enabled" setting and debug mode)
     * as they are, except once: the settings the earlier image wrote had debug mode on and the passwords in clear
     * text, and those are put right the first time this runs.
     *
     * Status 0 when the settings are in place, 1 when the plugin is not registered or cannot be loaded.
     */
    public function actionSuitecrm()
    {
        $row = Plugin::model()->findByAttributes(['name' => 'SuiteCRMIntegration']);
        if ($row === null) {
            echo "the SuiteCRM plugin is not registered\n";
            return 1;
        }
        // The plugin's own class does the storing, whether or not the plugin is switched on.
        $plugin = App()->getPluginManager()->loadPlugin('SuiteCRMIntegration', $row->id);
        if (!$plugin) {
            echo "the SuiteCRM plugin's code could not be loaded\n";
            return 1;
        }

        $changed = [];
        foreach (self::SUITECRM_SETTINGS as $key => [$variable, $default]) {
            $value = getenv($variable);
            if ($value === false || $value === '') {
                $value = $default;
            }
            if ($value === null) {
                continue;
            }
            // getSetting() reads through the plugin, which decrypts. A password the earlier image stored in clear
            // text reads back as itself, so the stored form decides whether it has to be written again.
            $encrypted = in_array($key, ['suitecrm_admin_password', 'suitecrm_db_password'], true);
            if ($plugin->getSetting($key) === $value && (!$encrypted || !$this->storedInClear($row->id, $key, $value))) {
                continue;
            }
            $plugin->setSetting($key, $value);
            $changed[] = $key;
        }

        // Once: what the earlier image's script wrote.
        if ((int) $plugin->getSetting('clouve_settings_version') < 2) {
            if ($plugin->getSetting('enabled') === null) {
                $plugin->setSetting('enabled', '1');
                $changed[] = 'enabled';
            }
            $plugin->setSetting('debug_mode', '0');
            $plugin->setSetting('clouve_settings_version', 2);
            $changed[] = 'debug_mode';
        }

        echo $changed ? 'settings written: ' . implode(' ', $changed) . "\n" : "settings already in step\n";
        return 0;
    }

    /**
     * Makes the SuiteCRM plugin's two tables when they are missing, and brings a table of mappings that an earlier
     * image made to the plugin's current shape, with the plugin's own schema code (classes/DatabaseSchema.php).
     * The earlier script had a copy of the table's definition, and the copy fell behind: its table had no
     * transform_rule column and allowed one CRM field per question, so the plugin could not save a mapping.
     * Rows that are there are kept.
     *
     * Status 0 when both tables are in place and current, 1 when not.
     */
    public function actionSchema()
    {
        $file = dirname(Yii::app()->basePath) . '/plugins/SuiteCRMIntegration/classes/DatabaseSchema.php';
        if (!is_file($file)) {
            echo "the SuiteCRM plugin's schema code is not on the volume\n";
            return 1;
        }
        require_once $file;
        $result = (new SuiteCRMDatabaseSchema())->install();
        if (empty($result['success'])) {
            // The first line of the database's message, which names tables and columns and holds no value.
            $error = strtok((string) ($result['error'] ?? 'no reason given'), "\n");
            echo "the plugin's tables could not be made or brought up to date: " . substr($error, 0, 200) . "\n";
            return 1;
        }
        $migration = (string) ($result['details']['migration'] ?? '');
        echo strpos($migration, 'Migrated') === 0
            ? "the plugin's tables are in place. " . $migration . "\n"
            : "the plugin's tables are in place\n";
        return 0;
    }

    /**
     * Whether a setting's stored value is the clear text itself (as JSON), which is how the earlier image wrote it.
     */
    private function storedInClear(int $pluginId, string $key, string $value): bool
    {
        $setting = PluginSetting::model()->findByAttributes(
            ['plugin_id' => $pluginId, 'model' => null, 'model_id' => null, 'key' => $key]
        );
        return $setting !== null && $setting->value === json_encode($value);
    }
}
