<?php
// Gives SuiteCRM's installer its options without a command line. The stock command, bin/console
// suitecrm:app:install, takes the admin's and the database's passwords as options, and a command line can be
// read by every process in the container. install.sh runs
//
//     php -d auto_prepend_file=/clouve/suitecrm/installer/install-args.php bin/console
//
// so PHP loads this file first, and it builds the argument list from the environment, inside the PHP process.
// bin/console then reads the list as if it had been typed. It does nothing in any other use.

if (PHP_SAPI !== 'cli' || basename((string) ($_SERVER['argv'][0] ?? '')) !== 'console'
    || count($_SERVER['argv']) !== 1) {
    return;
}
$options = [
    '-u' => 'SUITECRM_ADMIN_USER',
    '-p' => 'SUITECRM_ADMIN_PASSWORD',
    '-U' => 'DATABASE_USER',
    '-P' => 'DATABASE_PASSWORD',
    '-H' => 'DATABASE_HOST',
    '-Z' => 'DATABASE_PORT',
    '-N' => 'DATABASE_NAME',
    '-S' => 'SUITECRM_URL',
    '-d' => 'CLV_SC_DEMO_DATA',
];
$args = [$_SERVER['argv'][0], 'suitecrm:app:install', '-n', '-W', 'true'];
foreach ($options as $option => $name) {
    $value = getenv($name);
    if (!is_string($value) || $value === '') {
        fwrite(STDERR, "[suitecrm] ERROR: $name is not set, so the installer cannot run\n");
        exit(64);
    }
    $args[] = $option;
    $args[] = $value;
}
$_SERVER['argv'] = $GLOBALS['argv'] = $args;
$_SERVER['argc'] = $GLOBALS['argc'] = count($args);
