<?php
// patch-vendor.php APP ZIP ARCHIVES NAME=VERSION@COMMIT...
//
// Build time only (Dockerfile). Moves PHP libraries in SuiteCRM's package to fixed releases, the way Composer would
// install them, in the unpacked package APP and in the kept release zip ZIP, which SuiteCRM's own upgrade command
// unpacks. The image has no Composer, so the Dockerfile fetches each release as the archive GitHub makes of the
// release commit (the same archive Composer installs from) to ARCHIVES/<COMMIT>.zip and checks its SHA-256 first.
// For each NAME=VERSION@COMMIT this script:
//   - checks that the archive's comment, which GitHub sets to the commit, is COMMIT, and that it holds one folder;
//   - replaces APP/vendor/NAME with that folder's files;
//   - writes the new version, commit and release time into Composer's two records of the installed packages,
//     vendor/composer/installed.json (with the release's own require, conflict and autoload) and
//     vendor/composer/installed.php, which Composer\InstalledVersions reads;
//   - replaces vendor/NAME/ in ZIP with the same files, and the two records with the new ones. Every other entry of
//     ZIP stays as it is.
// It refuses a release that adds, removes or renames a class or an autoloaded file: Composer's class map in the
// package lists every class, and it is not rebuilt here. Exit status 0 when every package is done, 1 otherwise.

function fail(string $message): void
{
    fwrite(STDERR, "patch-vendor: $message\n");
    exit(1);
}

// rmtree DIR: removes DIR and everything in it, never following a link.
function rmtree(string $dir): void
{
    if (is_link($dir) || !is_dir($dir)) {
        if (file_exists($dir) || is_link($dir)) {
            unlink($dir) || fail("cannot remove $dir");
        }
        return;
    }
    foreach (scandir($dir) as $entry) {
        if ($entry !== '.' && $entry !== '..') {
            rmtree("$dir/$entry");
        }
    }
    rmdir($dir) || fail("cannot remove $dir");
}

// php_files DIR: the PHP files under DIR, relative to it, sorted.
function php_files(string $dir): array
{
    $out = [];
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $file) {
        if ($file->isFile() && str_ends_with($file->getFilename(), '.php')) {
            $out[] = substr($file->getPathname(), strlen($dir) + 1);
        }
    }
    sort($out);
    return $out;
}

// classes DIR: "Class @ file" for every class, interface, trait and enum that the PHP files under DIR declare.
function classes(string $dir): array
{
    $out = [];
    foreach (php_files($dir) as $rel) {
        $tokens = token_get_all(file_get_contents("$dir/$rel"));
        $namespace = '';
        for ($i = 0, $n = count($tokens); $i < $n; $i++) {
            if (!is_array($tokens[$i])) {
                continue;
            }
            if ($tokens[$i][0] === T_NAMESPACE) {
                $namespace = '';
                for ($j = $i + 1; $j < $n && $tokens[$j] !== ';' && $tokens[$j] !== '{'; $j++) {
                    if (is_array($tokens[$j]) && in_array($tokens[$j][0], [T_STRING, T_NAME_QUALIFIED], true)) {
                        $namespace .= $tokens[$j][1];
                    }
                }
            } elseif (in_array($tokens[$i][0], [T_CLASS, T_INTERFACE, T_TRAIT, T_ENUM], true)) {
                // Not "Foo::class", and not an anonymous class.
                $prev = $i - 1;
                while ($prev >= 0 && is_array($tokens[$prev]) && $tokens[$prev][0] === T_WHITESPACE) {
                    $prev--;
                }
                if ($prev >= 0 && (is_array($tokens[$prev]) ? $tokens[$prev][0] === T_NEW || $tokens[$prev][0] === T_DOUBLE_COLON : false)) {
                    continue;
                }
                for ($j = $i + 1; $j < $n && is_array($tokens[$j]) && $tokens[$j][0] === T_WHITESPACE; $j++);
                if ($j < $n && is_array($tokens[$j]) && $tokens[$j][0] === T_STRING) {
                    $out[] = ltrim("$namespace\\" . $tokens[$j][1], '\\') . " @ $rel";
                }
            }
        }
    }
    sort($out);
    return $out;
}

// release_time ARCHIVE: the commit's time, in seconds since 1970, from the UTC time GitHub writes into the first entry
// of its archives (the zip extra field 0x5455). The entries' plain zip times are the committer's local time.
function release_time(string $archive): int
{
    $head = file_get_contents($archive, false, null, 0, 1024);
    if (strlen($head) < 30 || substr($head, 0, 4) !== "PK\x03\x04") {
        fail("$archive is not a zip");
    }
    $nameLength = unpack('v', $head, 26)[1];
    $extraLength = unpack('v', $head, 28)[1];
    $extra = substr($head, 30 + $nameLength, $extraLength);
    for ($at = 0; $at + 4 <= strlen($extra);) {
        [$id, $size] = array_values(unpack('vid/vsize', $extra, $at));
        if ($id === 0x5455 && $size >= 5 && (ord($extra[$at + 4]) & 1)) {
            return unpack('V', $extra, $at + 5)[1];
        }
        $at += 4 + $size;
    }
    fail("$archive has no UTC time in its first entry");
}

// canonical VALUE: VALUE as JSON with every object's keys sorted, so that two autoload sections that differ only in
// the order of their keys compare equal.
function canonical($value): string
{
    $sort = function ($v) use (&$sort) {
        if (is_object($v)) {
            $v = (array) $v;
            ksort($v);
            return (object) array_map($sort, $v);
        }
        return is_array($v) ? array_map($sort, $v) : $v;
    };
    return json_encode($sort($value));
}

// tree DIR: every folder and file under DIR, relative to it, folders first in each folder.
function tree(string $dir, string $rel = ''): array
{
    $out = [];
    $entries = array_diff(scandir($dir . ($rel === '' ? '' : "/$rel")), ['.', '..']);
    sort($entries);
    foreach ($entries as $entry) {
        $path = $rel === '' ? $entry : "$rel/$entry";
        if (is_link("$dir/$path")) {
            fail("the release has a link, $path, which this script doesn't copy");
        }
        if (is_dir("$dir/$path")) {
            $out[] = "$path/";
            array_push($out, ...tree($dir, $path));
        } else {
            $out[] = $path;
        }
    }
    return $out;
}

[$self, $app, $zipPath, $archives] = array_pad(array_slice($argv, 0, 4), 4, null);
$specs = array_slice($argv, 4);
if ($archives === null || !$specs) {
    fail('usage: patch-vendor.php APP ZIP ARCHIVES NAME=VERSION@COMMIT...');
}
$vendor = "$app/vendor";
$jsonFile = "$vendor/composer/installed.json";
$phpFile = "$vendor/composer/installed.php";
$installed = json_decode(file_get_contents($jsonFile), false, 512, JSON_THROW_ON_ERROR);
$installedPhp = file_get_contents($phpFile);
$work = sys_get_temp_dir() . '/patch-vendor.' . getmypid();
mkdir($work, 0700) || fail("cannot make $work");
$zip = new ZipArchive();
if ($zip->open($zipPath) !== true) {
    fail("cannot open $zipPath");
}

foreach ($specs as $spec) {
    if (!preg_match('#^([a-z0-9_.-]+/[a-z0-9_.-]+)=(v?([0-9]+\.[0-9]+\.[0-9]+))@([0-9a-f]{40})$#', $spec, $m)) {
        fail("not NAME=VERSION@COMMIT: $spec");
    }
    [, $name, $version, $plain, $commit] = $m;
    $normalized = "$plain.0";

    // The package as it is now.
    $package = null;
    foreach ($installed->packages as $candidate) {
        if ($candidate->name === $name) {
            $package = $candidate;
        }
    }
    if ($package === null || ($package->{'install-path'} ?? '') !== "../$name") {
        fail("$name is not in installed.json, or not in vendor/$name");
    }
    $oldCommit = $package->dist->reference;
    $oldVersion = $package->version;

    // The release: GitHub's archive of the commit, with the commit in its comment and one folder in it.
    $archive = new ZipArchive();
    if ($archive->open("$archives/$commit.zip") !== true || $archive->getArchiveComment() !== $commit) {
        fail("$archives/$commit.zip is not GitHub's archive of commit $commit");
    }
    $top = explode('/', $archive->getNameIndex(0))[0];
    for ($i = 0; $i < $archive->numFiles; $i++) {
        if (!str_starts_with($archive->getNameIndex($i), "$top/")) {
            fail("$archives/$commit.zip holds more than one folder");
        }
    }
    $mtime = release_time("$archives/$commit.zip");
    $archive->extractTo("$work/$commit") || fail("cannot unpack $archives/$commit.zip");
    $archive->close();
    $new = "$work/$commit/$top";
    $release = json_decode(file_get_contents("$new/composer.json"), false, 512, JSON_THROW_ON_ERROR);
    if (($release->name ?? '') !== $name) {
        fail("the release's composer.json names " . ($release->name ?? 'nothing') . ", not $name");
    }

    // Composer's class map lists every class in the package and is not rebuilt here, so the release must declare
    // the same classes in the same files, and autoload the same way.
    if (classes("$vendor/$name") !== classes($new)) {
        fail("$name $version declares other classes or keeps them in other files than $oldVersion");
    }
    if (canonical($release->autoload ?? null) !== canonical($package->autoload ?? null)) {
        fail("$name $version autoloads otherwise than $oldVersion");
    }

    // The files on disk.
    rmtree("$vendor/$name");
    rename($new, "$vendor/$name") || fail("cannot put $name in place");

    // installed.json.
    $package->version = $version;
    $package->version_normalized = $normalized;
    foreach (['source', 'dist'] as $key) {
        if (isset($package->$key)) {
            $package->$key->reference = $commit;
            $package->$key->url = str_replace($oldCommit, $commit, $package->$key->url);
        }
    }
    foreach (['require', 'conflict'] as $key) {
        if (isset($release->$key)) {
            $package->$key = $release->$key;
        } else {
            unset($package->$key);
        }
    }
    $package->time = gmdate('Y-m-d\TH:i:s+00:00', $mtime);

    // installed.php: the three lines of the package's own entry.
    $pattern = sprintf("~(        '%s' => array\\(\n            'pretty_version' => )'[^']*'(,\n            'version' => )'[^']*'(,\n            'reference' => )'%s'~",
        preg_quote($name, '~'), $oldCommit);
    $installedPhp = preg_replace($pattern, "\${1}'$version'\${2}'$normalized'\${3}'$commit'", $installedPhp, -1, $count);
    if ($count !== 1) {
        fail("$name's entry in installed.php is not where it should be");
    }

    // The zip: the package's old entries go, the release's files come in, folders 2755 and files 644 as in the
    // package's other entries, with the release's own times.
    $prefix = "vendor/$name/";
    for ($i = $zip->numFiles - 1; $i >= 0; $i--) {
        $entry = $zip->getNameIndex($i);
        if ($entry !== false && str_starts_with($entry, $prefix)) {
            $zip->deleteIndex($i) || fail("cannot remove $entry from $zipPath");
        }
    }
    $zip->addEmptyDir(rtrim($prefix, '/')) || fail("cannot add $prefix to $zipPath");
    $zip->setExternalAttributesName($prefix, ZipArchive::OPSYS_UNIX, 042755 << 16);
    $zip->setMtimeName($prefix, $mtime);
    foreach (tree("$vendor/$name") as $rel) {
        $entry = $prefix . $rel;
        if (str_ends_with($rel, '/')) {
            $zip->addEmptyDir(rtrim($entry, '/')) || fail("cannot add $entry to $zipPath");
            $zip->setExternalAttributesName($entry, ZipArchive::OPSYS_UNIX, 042755 << 16);
        } else {
            $zip->addFromString($entry, file_get_contents("$vendor/$name/$rel")) || fail("cannot add $entry to $zipPath");
            $zip->setExternalAttributesName($entry, ZipArchive::OPSYS_UNIX, 0100644 << 16);
        }
        $zip->setMtimeName($entry, $mtime);
    }
    fwrite(STDOUT, "patch-vendor: $name $oldVersion -> $version ($commit)\n");
}

// The two records, on disk and in the zip.
file_put_contents($jsonFile, json_encode($installed, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n") ||
    fail("cannot write $jsonFile");
file_put_contents($phpFile, $installedPhp) || fail("cannot write $phpFile");
$check = include $phpFile;
foreach ($specs as $spec) {
    preg_match('#^(.+)=(.+)@(.+)$#', $spec, $m);
    if (($check['versions'][$m[1]]['pretty_version'] ?? '') !== $m[2] || ($check['versions'][$m[1]]['reference'] ?? '') !== $m[3]) {
        fail("installed.php does not read back $spec");
    }
}
foreach (['installed.json' => $jsonFile, 'installed.php' => $phpFile] as $entry => $file) {
    $zip->addFromString("vendor/composer/$entry", file_get_contents($file)) || fail("cannot add vendor/composer/$entry to $zipPath");
    $zip->setExternalAttributesName("vendor/composer/$entry", ZipArchive::OPSYS_UNIX, 0100644 << 16);
}
$zip->close() || fail("cannot write $zipPath");
rmtree($work);
exit(0);
