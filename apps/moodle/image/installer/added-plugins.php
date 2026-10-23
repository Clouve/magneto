<?php
// ============================================================================
// Plugins that a site's admin added to the Moodle code tree
// ============================================================================
// upgrade.sh replaces the code tree on the volume with the image's newer
// Moodle. Plugins installed with Site administration > Plugins > Install
// plugins live in that tree, so upgrade.sh asks this script which ones to carry
// over.
//
// Usage: php added-plugins.php <old Moodle root> <new Moodle root>
//
// A root is the folder that holds lib/components.json and lib/plugins.json:
// the previous code tree that upgrade.sh moved aside, and the image's pristine
// copy. A plugin was added when the old tree has it and the old Moodle's
// lib/plugins.json does not list it as standard. So a plugin that was part of
// the old Moodle and is gone from the new one (mod_chat in Moodle 5.0) is never
// carried over.
//
// It prints one tab-separated line per added plugin, sorted by component, with
// paths relative to the roots, and then a last line "end":
//   keep  <component>  <old path>  <new path>  -
//   skip  <component>  <old path>  -           <reason>
// "skip" holds back a plugin that the new Moodle ships itself, one whose
// version.php says it won't work with the new Moodle (marked incompatible with
// the new branch, or needing a plugin that the new site won't have), one whose
// version.php can't be read, and one whose plugin type the new Moodle no longer
// has. Moodle would stop its upgrade for the incompatible ones
// (upgrade_plugins()) and the ones missing a dependency
// (core_plugin_manager::all_plugins_ok()). A plugin that breaks in other ways is
// caught by upgrade.sh, which holds back every carried plugin when Moodle's
// upgrade fails twice and then runs it once more.
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
echo "\nVERSIONINFO ", json_encode(['incompatible' => $plugin->incompatible ?? null,
    'dependencies' => $plugin->dependencies ?? null]), "\n";
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

if ($argc !== 3) {
    fwrite(STDERR, "Usage: php added-plugins.php <old Moodle root> <new Moodle root>\n");
    exit(2);
}
$oldroot = rtrim($argv[1], '/');
$newroot = rtrim($argv[2], '/');
[$oldtypes, $oldstandard] = plugin_types($oldroot);
[$newtypes, $newstandard] = plugin_types($newroot);
$newbranch = moodle_branch($newroot);

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
    $plan[$component] = ['old' => $p['old'], 'new' => '-', 'reason' => '-'];
    if (!isset($newtypes[$p['type']])) {
        $plan[$component]['reason'] = "the new Moodle has no {$p['type']} plugins";
        continue;
    }
    $new = "{$newtypes[$p['type']]}/{$p['name']}";
    if (is_standard($component, $newstandard) || file_exists("$newroot/$new")) {
        $plan[$component]['reason'] = 'the new Moodle has its own copy';
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
    $needs = $info['dependencies'] ?? [];
    if (!is_array($needs) || array_filter(array_keys($needs), fn($k) => !is_string($k) || !preg_match(COMPONENT, $k))) {
        $plan[$component]['reason'] = 'its version.php has dependencies this script cannot read';
        continue;
    }
    $plan[$component]['new'] = $new;
    $dependencies[$component] = array_keys($needs);
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

ksort($plan);
foreach ($plan as $component => $p) {
    echo implode("\t", [$p['new'] === '-' ? 'skip' : 'keep', $component, $p['old'], $p['new'], $p['reason']]), "\n";
}
echo "end\n";
