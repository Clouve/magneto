<?php
// Keeps SuiteCRM's own settings in step with the container's environment. The entrypoint runs it as www-data
// at every start, before anything else runs SuiteCRM's code:
//
//     php settings.php sync [ROOT]       the database settings and the site address
//     php settings.php database [ROOT]   the database settings alone (before an upgrade, whose commands read them)
//     php settings.php cron [ROOT]       whether www-data is an allowed cron user ("yes" or "no")
//     php settings.php scheduler [ROOT]  whether SuiteCRM's settings switch the image's scheduler on ("on" or "off")
//
// sync writes the database host, port, name, user and password from DATABASE_* into public/legacy/config.php
// (dbconfig) and into .env.local (DATABASE_URL), and the site address from SUITECRM_URL into config.php
// (site_url and host_name). SuiteCRM freezes all of these at install time. A copied or restored deployment,
// and one whose database password was rotated, comes up with other values.
//
// It prints one word per thing it changed ("database", "address"), each on a line, and nothing when all was in
// step. The password comes from the environment and is never printed: display_errors is off, and whatever
// config.php prints while PHP includes it is thrown away. Exit status: 0 when it ran (changed or not), 2 when
// it could not read or write a file, and it says which.
//
// The scheduler's setting is $sugar_config['clouve']['scheduler'] in public/legacy/config_override.php. A new
// install and a release set it to 'on' (scheduler-setting.php). An install that existed before this image has
// no such line, so its scheduler stays held until someone releases it.
//
// config.php and config_override.php are PHP that www-data can change, so this script never runs as root.

ini_set('display_errors', '0');
ini_set('log_errors', '0');

if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() === 0) {
    fwrite(STDERR, "[suitecrm] ERROR: settings.php reads files that www-data can change, so it runs as www-data, never as root\n");
    exit(2);
}
$mode = $argv[1] ?? '';
$root = rtrim($argv[2] ?? '/var/www/html', '/');
$configFile = $root . '/public/legacy/config.php';
$overrideFile = $root . '/public/legacy/config_override.php';
$envFile = $root . '/.env.local';

function fail(string $message): never
{
    fwrite(STDERR, "[suitecrm] WARNING: $message\n");
    exit(2);
}

// The $sugar_config a file defines, or null. The file is PHP that www-data can change, so this script runs as
// www-data, never as root.
function load_config(string $file, array $sugar_config = []): ?array
{
    if (!is_file($file) || !is_readable($file)) {
        return null;
    }
    ob_start(static fn (string $buffer): string => '');
    try {
        include $file;
    } catch (Throwable $e) {
        ob_end_clean();
        return null;
    }
    ob_end_clean();
    return is_array($sugar_config) ? $sugar_config : null;
}

// Replaces FILE with CONTENT through a temporary file next to it, keeping FILE's mode.
function replace_file(string $file, string $content): bool
{
    $mode = is_file($file) ? (fileperms($file) & 0777) : 0640;
    $tmp = dirname($file) . '/.' . basename($file) . '.' . bin2hex(random_bytes(6));
    $old = umask(0077);
    $fh = @fopen($tmp, 'xb');
    umask($old);
    if ($fh === false) {
        return false;
    }
    $ok = fwrite($fh, $content) === strlen($content) && fflush($fh) && fclose($fh) && chmod($tmp, $mode)
        && rename($tmp, $file);
    if (!$ok) {
        @unlink($tmp);
    }
    return $ok;
}

if ($mode === 'cron') {
    $config = load_config($configFile);
    if ($config === null) {
        fail("cannot read $configFile");
    }
    $config = load_config($overrideFile, $config) ?? $config;
    $users = $config['cron']['allowed_cron_users'] ?? [];
    echo is_array($users) && in_array('www-data', $users, true) ? "yes\n" : "no\n";
    exit(0);
}
if ($mode === 'scheduler') {
    $config = load_config($configFile);
    if ($config === null) {
        fail("cannot read $configFile");
    }
    $config = load_config($overrideFile, $config) ?? $config;
    echo (($config['clouve']['scheduler'] ?? null) === 'on') ? "on\n" : "off\n";
    exit(0);
}
if ($mode !== 'sync' && $mode !== 'database') {
    fwrite(STDERR, "Usage: php settings.php sync|database|cron|scheduler [ROOT]\n");
    exit(2);
}

$want = [];
foreach (['DATABASE_HOST', 'DATABASE_PORT', 'DATABASE_NAME', 'DATABASE_USER', 'DATABASE_PASSWORD'] as $name) {
    $value = getenv($name);
    if (!is_string($value) || $value === '') {
        fail("$name is not set, so the database settings were left as they are");
    }
    $want[$name] = $value;
}

$config = load_config($configFile);
if ($config === null || !isset($config['dbconfig']) || !is_array($config['dbconfig'])) {
    fail("cannot read the settings in $configFile");
}
$changed = [];

$db = ['db_host_name' => $want['DATABASE_HOST'], 'db_port' => $want['DATABASE_PORT'], 'db_name' => $want['DATABASE_NAME'],
       'db_user_name' => $want['DATABASE_USER'], 'db_password' => $want['DATABASE_PASSWORD']];
foreach ($db as $key => $value) {
    if (($config['dbconfig'][$key] ?? null) !== $value) {
        $config['dbconfig'][$key] = $value;
        $changed['database'] = true;
    }
}

// The site address, the way the installer stores it: no slash at the end, and host_name without the port.
// It is written only when it is an address a browser can open: http:// or https://, a host name, and no blank
// in it. Anything else is left out with a warning, and the address SuiteCRM has stays.
if ($mode === 'sync') {
    $url = rtrim(trim((string) getenv('SUITECRM_URL')), '/');
    $parts = $url === '' ? false : parse_url($url);
    $scheme = is_array($parts) ? strtolower((string) ($parts['scheme'] ?? '')) : '';
    $host = is_array($parts) ? (string) ($parts['host'] ?? '') : '';
    if (($scheme === 'http' || $scheme === 'https') && $host !== '' && !preg_match('/[\s"\'<>\\\\]/', $url)) {
        if (($config['site_url'] ?? null) !== $url || ($config['host_name'] ?? null) !== $host) {
            $config['site_url'] = $url;
            $config['host_name'] = $host;
            $changed['address'] = true;
        }
    } else {
        fwrite(STDERR, '[suitecrm] WARNING: SUITECRM_URL is not an address with http:// or https:// and a host name'
            . ', so the site address in SuiteCRM\'s settings was left as it is ('
            . (is_string($config['site_url'] ?? null) ? $config['site_url'] : 'none') . ")\n");
    }
}

if ($changed) {
    $content = "<?php\n// created: " . gmdate('Y-m-d H:i:s') . "\n\$sugar_config = " . var_export($config, true) . ";\n";
    if (!replace_file($configFile, $content)) {
        fail("cannot write $configFile");
    }
}

// .env.local: one DATABASE_URL line. Its other lines stay as they are. SuiteCRM's installer writes the user and
// the password with urlencode(), which turns a blank into "+". Doctrine reads the line with rawurldecode(),
// which leaves "+" alone, so a password with a blank in it never reached the database. rawurlencode() writes
// every character but letters, digits, "-", "_", "." and "~" as %XX, which Doctrine reads back whole and which
// needs no quoting inside the line's double quotes.
if (is_file($envFile)) {
    $line = 'DATABASE_URL="mysql://' . rawurlencode($want['DATABASE_USER']) . ':'
        . rawurlencode($want['DATABASE_PASSWORD']) . '@' . $want['DATABASE_HOST'] . ':' . $want['DATABASE_PORT']
        . '/' . rawurlencode($want['DATABASE_NAME']) . '"';
    $text = file_get_contents($envFile);
    if ($text === false) {
        fail("cannot read $envFile");
    }
    $lines = explode("\n", $text);
    $found = false;
    foreach ($lines as $i => $current) {
        if (str_starts_with($current, 'DATABASE_URL=')) {
            if ($found) {
                unset($lines[$i]);
                continue;
            }
            $lines[$i] = $line;
            $found = true;
        }
    }
    if (!$found) {
        array_unshift($lines, $line);
    }
    $new = implode("\n", $lines);
    if ($new !== $text) {
        if (!replace_file($envFile, $new)) {
            fail("cannot write $envFile");
        }
        $changed['database'] = true;
    }
}

foreach (array_keys($changed) as $what) {
    echo $what, "\n";
}
exit(0);
