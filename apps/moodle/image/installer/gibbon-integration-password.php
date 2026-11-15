<?php
// The Education Kit's Moodle settings that hold Gibbon's database password (release 4.5.6, #109): auth_db/pass and
// enrol_database/dbpass. gibbon-integration-password.sh runs this as www-data with the deployment's password on
// stdin. Each setting that is there and holds another value gets the deployment's, through set_config, which also
// clears Moodle's settings cache. A setting that isn't there isn't made. It prints "changed" when it changed one, and
// nothing else, ever: never a value.
//
// Usage: php gibbon-integration-password.php <Moodle's folder> < password
define('CLI_SCRIPT', true);
ini_set('display_errors', '0');

$password = rtrim((string) fgets(STDIN), "\r\n");
if ($password === '') {
    exit(2);
}
$root = rtrim($argv[1] ?? '/var/www/html', '/');
ob_start();
require($root . '/config.php');
ob_end_clean();

$changed = false;
foreach ([['auth_db', 'pass'], ['enrol_database', 'dbpass']] as [$plugin, $name]) {
    $stored = get_config($plugin, $name);
    if ($stored === false || $stored === $password) {
        continue;
    }
    set_config($name, $password, $plugin);
    $changed = true;
}
if ($changed) {
    echo "changed";
}
