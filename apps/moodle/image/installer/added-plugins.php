<?php
// ============================================================================
// Plugins that a site's admin added to the Moodle code tree
// ============================================================================
// upgrade.sh replaces the code tree on the volume with the image's newer
// Moodle. Plugins installed with Site administration > Plugins > Install
// plugins live in that tree, so upgrade.sh asks this script which ones to carry
// over.
//
// Usage: php added-plugins.php <old Moodle root> <new Moodle root> [<recorded versions>]
//
// <recorded versions> is a file of "<component><TAB><version>" lines, the
// plugin versions that the site's database records (its config_plugins table).
//
// A root is the folder that holds lib/components.json and lib/plugins.json:
// the previous code tree that upgrade.sh moved aside, and the image's pristine
// copy. A plugin was added when the old tree has it and the old Moodle's
// lib/plugins.json does not list it as standard. So a plugin that was part of
// the old Moodle and is gone from the new one (mod_chat in Moodle 5.0, the
// Classic theme in Moodle 5.3) is never carried over. A Classic theme that an
// admin installed again after 5.3 is an added plugin like any other.
//
// It prints one tab-separated line per added plugin, sorted by component, with
// paths relative to the roots, and then a last line "end":
//   keep  <component>  <old path>  <new path>  - (or a warning)
//   skip  <component>  <old path>  -           <reason>
//   stop  <component>  <old path>  -           <reason>
// "skip" holds back a plugin that the new Moodle ships itself, one whose
// version.php says it won't work with the new Moodle (marked incompatible with
// the new branch, a $plugin->supported range that leaves the new branch out, or
// needing a plugin that the new site won't have), one whose version.php can't be
// read, and one whose plugin type the new Moodle no longer has. Moodle would stop
// its upgrade for the incompatible ones (upgrade_plugins()) and the ones missing
// a dependency (core_plugin_manager::all_plugins_ok()). For a plugin outside its
// supported range Moodle only warns, and this script holds it back because its
// author hasn't said it works with the new branch; but a plugin that already ran
// outside its range on the old Moodle is kept, with a warning. A plugin that
// breaks in other ways is caught by upgrade.sh, which holds back the plugin that
// Moodle's upgrade failed on, or every carried plugin, and runs it once more.
//
// "stop" means the site can't move to the new Moodle as it is: the new Moodle
// ships a plugin that the site's admin added, and the added copy is newer than
// the new Moodle's (report_aiusage and aiprovider_anthropic became part of
// Moodle 5.3). Moodle refuses to go back to an older version of a plugin, so
// upgrade.sh leaves the site on its old code and says why. That also holds
// when the added copy's folder is gone but the database still records its
// newer version (the recorded versions file): Moodle compares with that.
//
// Each version.php runs in a PHP process of its own, with a time limit, so one
// that exits, fails or hangs only holds back its own plugin.
//
// Limits, all with no effect on Moodle's own plugins today: subplugin types come
// only from the old Moodle's standard plugins (an added plugin's subplugins
// travel inside its folder), deprecated and deleted subplugin types are not
// read, and a dependency counts when the plugin is there, whatever its version.
//
// Exits 1 with a message on stderr when a tree lacks that metadata.
// ============================================================================

declare(strict_types=1);

// The plan goes to stdout, so PHP's warnings must not.
ini_set('display_errors', 'stderr');

// The constants that the new Moodle's version.php uses. Without MOODLE_INTERNAL,
// its first line ("defined('MOODLE_INTERNAL') || die();") would end this script.
defined('MOODLE_INTERNAL') || define('MOODLE_INTERNAL', true);
defined('MATURITY_ALPHA') || define('MATURITY_ALPHA', 50);
defined('MATURITY_BETA') || define('MATURITY_BETA', 100);
defined('MATURITY_RC') || define('MATURITY_RC', 150);
defined('MATURITY_STABLE') || define('MATURITY_STABLE', 200);

// Reads one plugin's version.php in a PHP process of its own and prints the
// fields this script needs as JSON, after a marker. A version.php that exits or
// fails never reaches the marker.
const VERSION_READER = <<<'PHP'
define('MOODLE_INTERNAL', true);
define('MATURITY_ALPHA', 50);
define('MATURITY_BETA', 100);
define('MATURITY_RC', 150);
define('MATURITY_STABLE', 200);
define('ANY_VERSION', 'any');
$plugin = new stdClass();
ob_start();
(static function (string $file, stdClass $plugin): void {
    include $file;
})($argv[1], $plugin);
ob_end_clean();
echo "\nVERSIONINFO ", json_encode(['version' => $plugin->version ?? null, 'incompatible' => $plugin->incompatible ?? null,
    'supported' => $plugin->supported ?? null, 'dependencies' => $plugin->dependencies ?? null]), "\n";
PHP;

// A folder path as Moodle's own plugin types have them: plain, relative, no "..".
const PLAIN_PATH = '#^[a-z0-9_]+(/[a-z0-9_]+)*$#';

// A component name, as in a dependencies list.
const COMPONENT = '/^[a-z][a-z0-9]*_[a-z0-9_]+$/';

/**
 * Reads a JSON file of a Moodle tree, or stops.
 */
function read_json(string $file): array {
    $data = is_file($file) ? json_decode((string)file_get_contents($file), true) : null;
    if (!is_array($data)) {
        fwrite(STDERR, "added-plugins.php: cannot read $file\n");
        exit(1);
    }
    return $data;
}

/**
 * The folder Moodle calls dirroot, relative to the root: public/ from Moodle 5.1, the root itself before.
 */
function dirroot_prefix(string $root): string {
    return is_file("$root/public/version.php") ? 'public/' : '';
}

/**
 * Whether a folder name is a valid plugin name, as core_component::is_valid_plugin_name() has it.
 */
function valid_name(string $type, string $name): bool {
    $pattern = $type === 'mod' ? '/^[a-z][a-z0-9]*$/' : '/^[a-z](?:[a-z0-9_](?!__))*[a-z0-9]+$/';
    return (bool)preg_match($pattern, $name);
}

/**
 * The plugin types of a tree with their folders, and its standard plugins.
 *
 * The types are the core ones from lib/components.json and the subplugin types that its standard plugins declare
 * in db/subplugins.json ("subplugintypes" relative to the plugin, else "plugintypes" relative to dirroot). A type
 * whose folder is not a plain relative path is left out.
 *
 * @return array{0: array<string, string>, 1: array<string, string[]>} [type => folder relative to the root, standard]
 */
function plugin_types(string $root): array {
    $components = read_json("$root/lib/components.json");
    $standard = read_json("$root/lib/plugins.json")['standard'] ?? [];
    $types = [];
    foreach (($components['plugintypes'] ?? []) + ($components['deprecatedplugintypes'] ?? []) as $type => $dir) {
        if (is_string($dir) && preg_match(PLAIN_PATH, $dir)) {
            $types[$type] = $dir;
        }
    }
    $prefix = dirroot_prefix($root);
    $queue = array_keys($types);
    while ($queue) {
        $type = array_shift($queue);
        foreach ($standard[$type] ?? [] as $name) {
            $plugin = "{$types[$type]}/$name";
            $file = "$root/$plugin/db/subplugins.json";
            if (!is_file($file)) {
                continue;
            }
            $declared = json_decode((string)file_get_contents($file), true) ?: [];
            $subtypes = [];
            if (!empty($declared['subplugintypes'])) {
                foreach ($declared['subplugintypes'] as $subtype => $dir) {
                    $subtypes[$subtype] = is_string($dir) ? "$plugin/$dir" : '';
                }
            } else {
                foreach ($declared['plugintypes'] ?? [] as $subtype => $dir) {
                    $subtypes[$subtype] = is_string($dir) ? $prefix . $dir : '';
                }
            }
            foreach ($subtypes as $subtype => $dir) {
                if (!isset($types[$subtype]) && preg_match(PLAIN_PATH, $dir)) {
                    $types[$subtype] = $dir;
                    $queue[] = $subtype;
                }
            }
        }
    }
    return [$types, $standard];
}

/**
 * The incompatible and dependencies fields of a plugin's version.php, or null when it can't be read.
 *
 * The file runs in a PHP process of its own for at most 20 seconds.
 */
function read_version_file(string $file): ?array {
    $command = ['timeout', '20', PHP_BINARY, '-n', '-d', 'display_errors=stderr', '-r', VERSION_READER, '--', $file];
    $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
    if (!is_resource($process)) {
        return null;
    }
    $output = (string)stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    if (proc_close($process) !== 0 || !preg_match('/\nVERSIONINFO (.*)\n$/', $output, $match)) {
        return null;
    }
    $info = json_decode($match[1], true);
    return is_array($info) ? $info : null;
}

/**
 * The branch of a Moodle tree (503 for 5.3), from its version.php.
 */
function moodle_branch(string $root): int {
    $file = $root . '/' . dirroot_prefix($root) . 'version.php';
    $branch = (static function (string $file) {
        ob_start();
        include $file;
        ob_end_clean();
        return $branch ?? 0;
    })($file);
    return (int)$branch;
}

/**
 * Whether a component is a standard plugin of a tree.
 */
function is_standard(string $component, array $standard): bool {
    [$type, $name] = array_pad(explode('_', $component, 2), 2, '');
    return in_array($name, $standard[$type] ?? [], true);
}

if ($argc !== 3 && $argc !== 4) {
    fwrite(STDERR, "Usage: php added-plugins.php <old Moodle root> <new Moodle root> [<recorded versions>]\n");
    exit(2);
}
$oldroot = rtrim($argv[1], '/');
$newroot = rtrim($argv[2], '/');
[$oldtypes, $oldstandard] = plugin_types($oldroot);
[$newtypes, $newstandard] = plugin_types($newroot);
$newbranch = moodle_branch($newroot);
$oldbranch = moodle_branch($oldroot);

// The added plugins of the old tree.
$added = [];
foreach ($oldtypes as $type => $dir) {
    if (!is_dir("$oldroot/$dir")) {
        continue;
    }
    foreach (scandir("$oldroot/$dir") ?: [] as $name) {
        if (!valid_name($type, $name) || !is_file("$oldroot/$dir/$name/version.php")) {
            continue;
        }
        if (!in_array($name, $oldstandard[$type] ?? [], true)) {
            $added["{$type}_$name"] = ['type' => $type, 'name' => $name, 'old' => "$dir/$name"];
        }
    }
}

// Keep or hold back each one.
$plan = [];
$dependencies = [];
foreach ($added as $component => $p) {
    $plan[$component] = ['old' => $p['old'], 'new' => '-', 'reason' => '-', 'stop' => false];
    if (!isset($newtypes[$p['type']])) {
        $plan[$component]['reason'] = "the new Moodle has no {$p['type']} plugins";
        continue;
    }
    $new = "{$newtypes[$p['type']]}/{$p['name']}";
    if (is_standard($component, $newstandard) || file_exists("$newroot/$new")) {
        $plan[$component]['reason'] = 'the new Moodle has its own copy';
        $added = read_version_file("$oldroot/{$p['old']}/version.php");
        $core = read_version_file("$newroot/$new/version.php");
        if (is_numeric($added['version'] ?? null) && is_numeric($core['version'] ?? null)
                && (float)$added['version'] > (float)$core['version']) {
            $plan[$component]['stop'] = true;
            $plan[$component]['reason'] = "the site has version {$added['version']} of it, newer than the new Moodle's " .
                "{$core['version']}, and Moodle can't go back to an older version";
        }
        continue;
    }
    $info = read_version_file("$oldroot/{$p['old']}/version.php");
    if ($info === null) {
        $plan[$component]['reason'] = 'its version.php cannot be read';
        continue;
    }
    $incompatible = $info['incompatible'];
    if ($incompatible !== null && !is_numeric($incompatible)) {
        $plan[$component]['reason'] = 'its version.php has an incompatible value this script cannot read';
        continue;
    }
    if ($incompatible && $newbranch >= (int)$incompatible) {
        $plan[$component]['reason'] = "incompatible with Moodle $incompatible and later";
        continue;
    }
    $supported = $info['supported'];
    if ($supported !== null) {
        if (!is_array($supported) || !array_is_list($supported) || count($supported) !== 2
                || !is_int($supported[0]) || !is_int($supported[1])) {
            $plan[$component]['reason'] = 'its version.php has a supported value this script cannot read';
            continue;
        }
        if ($newbranch < $supported[0] || $newbranch > $supported[1]) {
            $range = "its version.php supports Moodle {$supported[0]} to {$supported[1]}, not $newbranch";
            if ($oldbranch >= $supported[0] && $oldbranch <= $supported[1]) {
                $plan[$component]['reason'] = $range;
                continue;
            }
            // It already ran outside its range on the old Moodle: keep it, as Moodle would, and say so.
            $plan[$component]['reason'] = "$range, and it already ran on $oldbranch outside that range";
        }
    }
    $needs = $info['dependencies'] ?? [];
    if (!is_array($needs) || array_filter(array_keys($needs), fn($k) => !is_string($k) || !preg_match(COMPONENT, $k))) {
        $plan[$component]['reason'] = 'its version.php has dependencies this script cannot read';
        continue;
    }
    $plan[$component]['new'] = $new;
    $dependencies[$component] = array_keys($needs);
    if (!str_contains($plan[$component]['reason'], 'already ran')) {
        $plan[$component]['reason'] = '-';
    }
}

// A kept plugin needs each dependency to be standard in the new Moodle or kept too.
do {
    $changed = false;
    foreach ($dependencies as $component => $needs) {
        if ($plan[$component]['new'] === '-') {
            continue;
        }
        foreach ($needs as $need) {
            if (is_standard($need, $newstandard) || (isset($plan[$need]) && $plan[$need]['new'] !== '-')) {
                continue;
            }
            $plan[$component]['new'] = '-';
            $plan[$component]['reason'] = isset($plan[$need]) ? "needs $need, which is held back too" :
                "needs $need, which the new Moodle does not have";
            $changed = true;
            break;
        }
    }
} while ($changed);

// Plugins the new Moodle ships and the old one didn't, whose version the database records as newer than the new
// Moodle's copy: an admin added one and later deleted only its folder. Moodle would refuse to go back to the older
// version, so the site can't move to the new Moodle as it is.
if ($argc === 4) {
    $recorded = [];
    foreach (file($argv[3], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
        [$name, $version] = array_pad(explode("\t", $line, 2), 2, '');
        if (preg_match(COMPONENT, $name) && is_numeric($version)) {
            $recorded[$name] = $version;
        }
    }
    foreach ($newstandard as $type => $names) {
        foreach ($names as $name) {
            $component = "{$type}_$name";
            if (!isset($recorded[$component], $newtypes[$type]) || is_standard($component, $oldstandard)
                    || !empty($plan[$component]['stop'])) {
                continue;
            }
            $core = read_version_file("$newroot/{$newtypes[$type]}/$name/version.php");
            if (is_numeric($core['version'] ?? null) && (float)$recorded[$component] > (float)$core['version']) {
                $plan[$component] = ['old' => $plan[$component]['old'] ?? '-', 'new' => '-', 'stop' => true,
                    'reason' => "Moodle has version {$recorded[$component]} of it recorded, newer than the new " .
                        "Moodle's {$core['version']}, and Moodle can't go back to an older version"];
            }
        }
    }
}

ksort($plan);
foreach ($plan as $component => $p) {
    $action = $p['stop'] ? 'stop' : ($p['new'] === '-' ? 'skip' : 'keep');
    echo implode("\t", [$action, $component, $p['old'], $p['new'], $p['reason']]), "\n";
}
echo "end\n";
