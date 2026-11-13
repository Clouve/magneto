<?php
// Reads the keep-list that SuiteCRM has compiled, which is the one its upgrade command works with.
//
// SuiteCRM's upgrade deletes every file and folder at the top of the install, of public/ and of public/legacy/
// that the new package doesn't ship and that the list parameters.upgrades.toKeep doesn't name. The list is in
// config/services/system/upgrades.yaml, but the command reads it from SuiteCRM's compiled cache (cache/prod).
// A cache that was compiled before the file was changed still holds the old list. So this script starts
// SuiteCRM's kernel the way bin/console does and reads the parameter from the container the kernel loads. That
// is the same container the upgrade command gets a moment later. bin/console debug:container can't be used for
// this: it builds a new container from the files and never looks at the cache.
//
//     php keep-list.php ROOT ENTRY...   exit status 0 when the compiled list names every ENTRY, 1 when not
//     php keep-list.php ROOT --list     prints the compiled list, an entry a line
//
// It loads SuiteCRM's own code, so it runs as www-data, never as root.

if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() === 0) {
    fwrite(STDERR, "[suitecrm] ERROR: keep-list.php loads SuiteCRM's code, so it runs as www-data, never as root\n");
    exit(2);
}
ini_set('display_errors', '0');
$root = rtrim($argv[1] ?? '', '/');
$entries = array_slice($argv, 2);
if ($root === '' || $entries === [] || !@chdir($root)) {
    fwrite(STDERR, "Usage: php keep-list.php ROOT ENTRY... | --list\n");
    exit(2);
}
try {
    require $root . '/vendor/autoload.php';
    require $root . '/config/bootstrap.php';
    $kernel = new App\Kernel($_SERVER['APP_ENV'], (bool) $_SERVER['APP_DEBUG']);
    $kernel->boot();
    $upgrades = $kernel->getContainer()->getParameter('upgrades');
} catch (Throwable $e) {
    fwrite(STDERR, '[suitecrm] WARNING: could not read SuiteCRM\'s compiled keep-list: ' . get_class($e) . ': '
        . substr($e->getMessage(), 0, 200) . "\n");
    exit(1);
}
$keep = is_array($upgrades) ? ($upgrades['toKeep'] ?? null) : null;
if (!is_array($keep)) {
    fwrite(STDERR, "[suitecrm] WARNING: SuiteCRM's compiled settings hold no keep-list\n");
    exit(1);
}
if ($entries === ['--list']) {
    foreach ($keep as $entry) {
        if (is_string($entry)) {
            echo $entry, "\n";
        }
    }
    exit(0);
}
$missing = array_values(array_diff($entries, $keep));
if ($missing !== []) {
    fwrite(STDERR, '[suitecrm] WARNING: not on SuiteCRM\'s compiled keep-list: ' . implode(' ', $missing) . "\n");
    exit(1);
}
exit(0);
