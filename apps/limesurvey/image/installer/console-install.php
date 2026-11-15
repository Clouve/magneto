<?php
// Runs LimeSurvey's own `console.php install <admin> <password> <full name> <email>` without putting the admin's
// password on a command line, where every process in the container could read it. The entrypoint runs this file as
// www-data with no arguments. It builds console.php's argument list from the environment (ADMIN_USER, ADMIN_PASSWORD,
// ADMIN_NAME, ADMIN_EMAIL) and then loads console.php in this same process, which reads the list from $_SERVER['argv'].

$root = getenv('LS_ROOT') ?: '/var/www/html';
$password = getenv('ADMIN_PASSWORD');
if ($password === false || $password === '') {
    fwrite(STDERR, "ADMIN_PASSWORD is not set\n");
    exit(1);
}
$argv = [
    $root . '/application/commands/console.php',
    'install',
    getenv('ADMIN_USER') ?: 'admin',
    $password,
    getenv('ADMIN_NAME') ?: 'Administrator',
    getenv('ADMIN_EMAIL') ?: 'admin@example.com',
];
$argc = count($argv);
$_SERVER['argv'] = $argv;
$_SERVER['argc'] = $argc;
unset($password);
chdir($root);
require $root . '/application/commands/console.php';
