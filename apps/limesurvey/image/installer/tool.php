<?php
// Small jobs that the entrypoint's shell scripts can't do safely: reading LimeSurvey's version file, and writing and
// changing its PHP configuration files. Run as www-data, never as root: these files are PHP that www-data can change.
// Values come from the environment, never from the command line, and no value is ever printed.
//
//   php tool.php version DIR        prints "<versionnumber> <dbversionnumber> <buildnumber>" of the LimeSurvey code in
//                                   DIR, or nothing when DIR has no readable version file
//   php tool.php publicurl          prints the publicurl that config.php holds (an address, never a secret)
//   php tool.php write-config       writes application/config/config.php for a new install, and security.php when
//                                   ENCRYPT_KEYPAIR or ENCRYPT_SECRET_BOX_KEY is set (otherwise LimeSurvey makes it)
//   php tool.php sync-config        makes config.php's database settings and publicurl match the environment; prints
//                                   the names of what it changed; status 2 when it could not
//   php tool.php allowed-hosts      adds localhost and PUBLIC_URL's host to allowed_hosts.php, keeping what is there
//
// LS_ROOT names the LimeSurvey folder (default /var/www/html).

$root = getenv('LS_ROOT') ?: '/var/www/html';
$configDir = $root . '/application/config';

function env(string $name, string $default = ''): string
{
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
}

// A PHP single-quoted string literal for any value.
function quote(string $value): string
{
    return "'" . str_replace(['\\', "'"], ['\\\\', "\\'"], $value) . "'";
}

// Writes a file in one step, with mode 600: these files hold the database password or the encryption keys.
function write_private(string $file, string $content): bool
{
    $tmp = $file . '.clv-new';
    @unlink($tmp);
    $old = umask(0077);
    $ok = file_put_contents($tmp, $content) !== false;
    umask($old);
    return $ok && chmod($tmp, 0600) && rename($tmp, $file);
}

// The array a LimeSurvey configuration file returns, or null when it can't be read.
function load_config(string $file): ?array
{
    if (!is_file($file)) {
        return null;
    }
    defined('BASEPATH') || define('BASEPATH', '.');
    try {
        $config = include $file;
    } catch (Throwable $e) {
        return null;
    }
    return is_array($config) ? $config : null;
}

function connection_string(): string
{
    $type = env('DB_TYPE', 'mysql');
    if (env('DB_SOCK') !== '') {
        return $type . ':unix_socket=' . env('DB_SOCK') . ';dbname=' . env('DB_NAME', 'limesurvey') . ';';
    }
    return $type . ':host=' . env('DB_HOST', 'limesurvey-mariadb') . ';port=' . env('DB_PORT', '3306')
        . ';dbname=' . env('DB_NAME', 'limesurvey') . ';';
}

function host_of(string $url): string
{
    $host = parse_url($url, PHP_URL_HOST);
    return is_string($host) ? strtolower(trim($host, " \t\n\r\0\x0B[]")) : '';
}

function valid_host(string $host): bool
{
    return filter_var($host, FILTER_VALIDATE_DOMAIN, FILTER_FLAG_HOSTNAME) !== false
        || filter_var($host, FILTER_VALIDATE_IP) !== false;
}

// Whether a token is white space or a comment.
function is_filler($token): bool
{
    return is_array($token) && in_array($token[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true);
}

// The index of the next token from $i on that is no white space and no comment, or null.
function next_code(array $tokens, int $i): ?int
{
    for ($n = count($tokens); $i < $n; $i++) {
        if (!is_filler($tokens[$i])) {
            return $i;
        }
    }
    return null;
}

// Whether a token is the string literal 'NAME' or "NAME".
function is_key($token, string $name): bool
{
    return is_array($token) && $token[0] === T_CONSTANT_ENCAPSED_STRING
        && ($token[1] === "'" . $name . "'" || $token[1] === '"' . $name . '"');
}

// The index of the token after `'db' => array(` or `'db' => [` in a tokenized config.php, or null.
function find_db_array(array $tokens): ?int
{
    foreach ($tokens as $i => $token) {
        if (!is_key($token, 'db')) {
            continue;
        }
        $arrow = next_code($tokens, $i + 1);
        if ($arrow === null || !is_array($tokens[$arrow]) || $tokens[$arrow][0] !== T_DOUBLE_ARROW) {
            continue;
        }
        $open = next_code($tokens, $arrow + 1);
        if ($open !== null && $tokens[$open] === '[') {
            return $open + 1;
        }
        if ($open !== null && is_array($tokens[$open]) && $tokens[$open][0] === T_ARRAY) {
            $paren = next_code($tokens, $open + 1);
            if ($paren !== null && $tokens[$paren] === '(') {
                return $paren + 1;
            }
        }
    }
    return null;
}

// Gives the first `'KEY' => 'a string'` from token $from on the value $value. False when there is none. Comments are
// tokens of their own, so a commented-out line is never changed and never stands in the way of the real one.
function set_string_value(array &$tokens, string $key, string $value, int $from): bool
{
    for ($i = $from, $n = count($tokens); $i < $n; $i++) {
        if (!is_key($tokens[$i], $key)) {
            continue;
        }
        $arrow = next_code($tokens, $i + 1);
        if ($arrow === null || !is_array($tokens[$arrow]) || $tokens[$arrow][0] !== T_DOUBLE_ARROW) {
            continue;
        }
        $at = next_code($tokens, $arrow + 1);
        if ($at !== null && is_array($tokens[$at]) && $tokens[$at][0] === T_CONSTANT_ENCAPSED_STRING) {
            $tokens[$at][1] = quote($value);
            return true;
        }
    }
    return false;
}

$command = $argv[1] ?? '';

if ($command === 'version') {
    $file = ($argv[2] ?? $root) . '/application/config/version.php';
    if (is_file($file)) {
        try {
            $c = include $file;
        } catch (Throwable $e) {
            $c = null;
        }
        if (is_array($c) && isset($c['versionnumber'], $c['dbversionnumber'])) {
            $clean = static fn($v): string => preg_replace('/[^0-9A-Za-z.+-]/', '', (string) $v);
            echo $clean($c['versionnumber']), ' ', (int) $c['dbversionnumber'], ' ', $clean($c['buildnumber'] ?? ''), "\n";
        }
    }
    exit(0);
}

if ($command === 'publicurl') {
    $config = load_config($configDir . '/config.php');
    $url = $config['config']['publicurl'] ?? '';
    echo is_string($url) ? preg_replace('/[^\x21-\x7e]/', '', $url) : '', "\n";
    exit(0);
}

if ($command === 'write-config') {
    $file = $configDir . '/config.php';
    if (!is_file($file)) {
        $charset = env('DB_CHARSET', env('DB_TYPE', 'mysql') === 'pgsql' ? 'utf8' : 'utf8mb4');
        $request = '';
        if (env('BASE_URL') !== '' || env('HOST_INFO') !== '') {
            $request = "    'request' => array(\n      'baseUrl' => " . quote(env('BASE_URL')) . ",\n      'hostInfo' => "
                . quote(env('HOST_INFO')) . ",\n    ),\n";
        }
        $session = env('TABLE_SESSION') !== ''
            ? "    'session' => array (\n       'class' => 'application.core.web.DbHttpSession',\n       'connectionID' => 'db',\n       'sessionTableName' => '{{sessions}}',\n    ),\n"
            : "    //'session' => array (\n    //   'class' => 'application.core.web.DbHttpSession',\n    //   'connectionID' => 'db',\n    //   'sessionTableName' => '{{sessions}}',\n    //),\n";
        $content = "<?php if (!defined('BASEPATH')) exit('No direct script access allowed');\n"
            . "return array(\n"
            . "  'components' => array(\n"
            . "    'db' => array(\n"
            . "      'connectionString' => " . quote(connection_string()) . ",\n"
            . "      'emulatePrepare' => true,\n"
            . "      'username' => " . quote(env('DB_USERNAME', 'limesurvey')) . ",\n"
            . "      'password' => " . quote(env('DB_PASSWORD')) . ",\n"
            . "      'charset' => " . quote($charset) . ",\n"
            . "      'tablePrefix' => " . quote(preg_replace('/\s/', '', env('DB_TABLE_PREFIX', 'lime_'))) . ",\n"
            . "    ),\n"
            . $session
            . "    'urlManager' => array(\n"
            . "      'urlFormat' => " . quote(env('URL_FORMAT', 'path')) . ",\n"
            . "      'rules' => array(),\n"
            . "      'showScriptName' => " . (in_array(strtolower(env('SHOW_SCRIPT_NAME', 'true')), ['false', '0', 'no'], true) ? 'false' : 'true') . ",\n"
            . "    ),\n"
            . $request
            . "  ),\n"
            . "  'config'=>array(\n"
            . "    'publicurl'=>" . quote(env('PUBLIC_URL')) . ",\n"
            . "    'debug'=>" . (int) env('DEBUG', '0') . ",\n"
            . "    'debugsql'=>" . (int) env('DEBUG_SQL', '0') . ",\n"
            . "    'mysqlEngine' => " . quote(env('DB_MYSQL_ENGINE', 'InnoDB')) . ",\n"
            . "  )\n"
            . ");\n";
        if (!write_private($file, $content)) {
            fwrite(STDERR, "could not write $file\n");
            exit(1);
        }
    }
    $security = $configDir . '/security.php';
    if (!is_file($security) && (env('ENCRYPT_KEYPAIR') !== '' || env('ENCRYPT_SECRET_BOX_KEY') !== '')) {
        $content = "<?php if (!defined('BASEPATH')) exit('No direct script access allowed');\n\$config = array();\n";
        foreach (['encryptionkeypair' => 'ENCRYPT_KEYPAIR', 'encryptionpublickey' => 'ENCRYPT_PUBLIC_KEY',
            'encryptionsecretkey' => 'ENCRYPT_SECRET_KEY', 'encryptionnonce' => 'ENCRYPT_NONCE',
            'encryptionsecretboxkey' => 'ENCRYPT_SECRET_BOX_KEY'] as $key => $name) {
            $content .= "\$config['$key'] = " . quote(env($name)) . ";\n";
        }
        $content .= "return \$config;\n";
        if (!write_private($security, $content)) {
            fwrite(STDERR, "could not write $security\n");
            exit(1);
        }
    }
    exit(0);
}

if ($command === 'sync-config') {
    $file = $configDir . '/config.php';
    $config = load_config($file);
    $text = is_file($file) ? file_get_contents($file) : false;
    if ($config === null || $text === false) {
        fwrite(STDERR, "config.php can't be read\n");
        exit(2);
    }
    // What config.php should say, by the name used in the log.
    $want = [
        'connectionString' => connection_string(),
        'username' => env('DB_USERNAME', 'limesurvey'),
        'password' => env('DB_PASSWORD'),
    ];
    $have = $config['components']['db'] ?? [];
    $changed = [];
    // PHP's own tokenizer finds the values, so a line that is commented out is never taken for the real one.
    $tokens = token_get_all($text);
    $db = find_db_array($tokens);
    if ($db !== null) {
        foreach ($want as $key => $value) {
            if (($have[$key] ?? null) === $value || ($key === 'password' && $value === '')) {
                continue;
            }
            if (set_string_value($tokens, $key, $value, $db)) {
                $changed[] = $key;
            } else {
                fwrite(STDERR, "config.php has no '$key' line that this image knows, so it stays as it is\n");
            }
        }
    } else {
        fwrite(STDERR, "config.php has no 'db' settings that this image knows, so they stay as they are\n");
    }
    $publicUrl = env('PUBLIC_URL');
    if ($publicUrl !== '' && ($config['config']['publicurl'] ?? null) !== $publicUrl) {
        if (set_string_value($tokens, 'publicurl', $publicUrl, 0)) {
            $changed[] = 'publicurl';
        } else {
            fwrite(STDERR, "config.php has no 'publicurl' line that this image knows, so it stays as it is\n");
        }
    }
    $text = '';
    foreach ($tokens as $token) {
        $text .= is_array($token) ? $token[1] : $token;
    }
    if (!$changed) {
        exit(0);
    }
    // The changed file has to load and say what was asked before it replaces config.php.
    $probe = $file . '.clv-check';
    @unlink($probe);
    $old = umask(0077);
    file_put_contents($probe, $text);
    umask($old);
    $check = load_config($probe);
    @unlink($probe);
    $ok = is_array($check);
    foreach ($changed as $key) {
        $got = $key === 'publicurl' ? ($check['config']['publicurl'] ?? null) : ($check['components']['db'][$key] ?? null);
        $ok = $ok && $got === ($key === 'publicurl' ? $publicUrl : $want[$key]);
    }
    if (!$ok || !write_private($file, $text)) {
        fwrite(STDERR, "the changed config.php did not read back as expected, so config.php stays as it was\n");
        exit(2);
    }
    echo implode(' ', $changed), "\n";
    exit(0);
}

if ($command === 'allowed-hosts') {
    $file = $configDir . '/allowed_hosts.php';
    $current = load_config($file);
    $hosts = [];
    foreach ((array) ($current['allowedHosts'] ?? []) as $host) {
        if (is_string($host) && valid_host(trim($host)) && !in_array(trim($host), $hosts, true)) {
            $hosts[] = trim($host);
        }
    }
    $before = $hosts;
    foreach (['localhost', host_of(env('PUBLIC_URL'))] as $host) {
        if ($host !== '' && valid_host($host) && !in_array($host, array_map('strtolower', $hosts), true)) {
            $hosts[] = $host;
        }
    }
    if ($hosts === $before && $current !== null) {
        exit(0);
    }
    $content = "<?php if (!defined('BASEPATH')) exit('No direct script access allowed');\n"
        . "/**\n"
        . " * Allowed hosts.\n"
        . " *\n"
        . " * LimeSurvey answers its admin pages only for the host names listed here and for the host of 'publicurl'\n"
        . " * in config.php. Each entry is a host name only, with no http:// or https:// and no port.\n"
        . " * Clouve's image adds localhost and the host of PUBLIC_URL at every start and keeps the other entries.\n"
        . " */\n"
        . "\$config = array();\n"
        . "\$config['allowedHosts'] = array(\n";
    foreach ($hosts as $host) {
        $content .= '    ' . quote($host) . ",\n";
    }
    $content .= ");\nreturn \$config;\n";
    if (!write_private($file, $content)) {
        fwrite(STDERR, "could not write $file\n");
        exit(2);
    }
    echo implode(' ', array_diff($hosts, $before)), "\n";
    exit(0);
}

fwrite(STDERR, "usage: php tool.php version DIR | publicurl | write-config | sync-config | allowed-hosts\n");
exit(64);
