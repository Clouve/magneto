<?php
// Makes www-data an allowed cron user, through SuiteCRM's own Configurator, which writes one line to
// public/legacy/config_override.php. SuiteCRM refuses to run its scheduled jobs for a user that is not on that
// list. An install made by the earlier image has only a placeholder there, because its installer ran as root,
// so no scheduled job ever ran on it.
//
// The entrypoint runs it as www-data, only when settings.php cron says "no". It loads SuiteCRM's own code, so
// it never runs as root. It needs the database. It prints nothing when it works. Exit status: 0 when www-data
// is on the list afterwards, 1 when not.

if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() === 0) {
    fwrite(STDERR, "[suitecrm] ERROR: cron-user.php loads SuiteCRM's code, so it runs as www-data, never as root\n");
    exit(1);
}
$root = rtrim($argv[1] ?? '/var/www/html', '/');
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
    $configurator->config['cron']['allowed_cron_users'] = ['www-data'];
    $configurator->handleOverride();
} catch (Throwable $e) {
    ob_end_clean();
    fwrite(STDERR, '[suitecrm] WARNING: could not make www-data an allowed cron user: ' . get_class($e) . "\n");
    exit(1);
}
ob_end_clean();
exit(0);
