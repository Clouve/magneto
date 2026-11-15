<?php
// Switches the image's scheduler on or off in SuiteCRM's own settings, through SuiteCRM's Configurator, which
// writes one line to public/legacy/config_override.php:
//
//     $sugar_config['clouve']['scheduler'] = 'on';
//
// The scheduler loop (loops.sh) runs SuiteCRM's scheduled jobs only while that line says 'on'. A new install
// sets it (install.sh), and so does a release (release-scheduler.sh). An install that existed before this image
// has no such line: no scheduled job ever ran on it, and starting them all at once could send queued campaign
// email and run workflows over old records with nobody's yes. The setting lives in SuiteCRM's settings and not
// in the image's state folder, so that nothing done to that folder can release a held scheduler.
//
//     php scheduler-setting.php on|off [ROOT]
//
// It loads SuiteCRM's own code, so it runs as www-data, never as root, and it needs the database. It prints
// nothing when it works. Exit status: 0 when the setting has the value afterwards, 1 when not.

if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() === 0) {
    fwrite(STDERR, "[suitecrm] ERROR: scheduler-setting.php loads SuiteCRM's code, so it runs as www-data, never as root\n");
    exit(1);
}
$value = $argv[1] ?? '';
if ($value !== 'on' && $value !== 'off') {
    fwrite(STDERR, "Usage: php scheduler-setting.php on|off [ROOT]\n");
    exit(1);
}
$root = rtrim($argv[2] ?? '/var/www/html', '/');
if (!@chdir($root . '/public/legacy')) {
    fwrite(STDERR, "[suitecrm] WARNING: no SuiteCRM in $root\n");
    exit(1);
}
ob_start(static fn (string $buffer): string => '');
try {
    if (!defined('sugarEntry')) {
        define('sugarEntry', true);
    }
    require_once 'include/entryPoint.php';
    require_once 'modules/Configurator/Configurator.php';
    $configurator = new Configurator();
    $configurator->config['clouve']['scheduler'] = $value;
    $configurator->handleOverride();
} catch (Throwable $e) {
    ob_end_clean();
    fwrite(STDERR, '[suitecrm] WARNING: could not write the scheduler setting: ' . get_class($e) . "\n");
    exit(1);
}
ob_end_clean();

// Read it back from the file, the way settings.php does.
$sugar_config = [];
ob_start(static fn (string $buffer): string => '');
try {
    include $root . '/public/legacy/config.php';
    if (is_file($root . '/public/legacy/config_override.php')) {
        include $root . '/public/legacy/config_override.php';
    }
} catch (Throwable $e) {
    $sugar_config = [];
}
ob_end_clean();
if ((($sugar_config['clouve']['scheduler'] ?? 'off') === 'on') !== ($value === 'on')) {
    fwrite(STDERR, "[suitecrm] WARNING: the scheduler setting is not '$value' after it was written\n");
    exit(1);
}
exit(0);
