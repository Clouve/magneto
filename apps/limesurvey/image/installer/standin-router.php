<?php
// The stand-in for LimeSurvey's health check. The entrypoint runs it with PHP's built-in server on LimeSurvey's port
// while it waits for the database, installs or upgrades, and stops it right before Apache starts. It serves no
// LimeSurvey code and reads nothing from the volume.
//
// GET / (and HEAD /), the request the health check makes, gets 200 and a short page. Everything else gets 503 with
// Retry-After, so a program that calls LimeSurvey, such as the SuiteCRM plugin or a RemoteControl client, never takes
// the page for an answer.
//
// While the entrypoint waits for a restore from a backup to finish, it keeps the file /run/clouve-limesurvey-restoring
// in place, and the page says that the site is being restored. While it waits for a person to repair a site that
// it could not start, it keeps /run/clouve-limesurvey-attention, and the page says that the site needs attention.

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$uri = $_SERVER['REQUEST_URI'] ?? '/';
header('Cache-Control: no-store');
// A program that waits for the real site, such as ./test.sh, tells the stand-in from LimeSurvey by this header.
header('X-Clouve-Standin: limesurvey');

$restoring = is_file('/run/clouve-limesurvey-restoring');
$attention = !$restoring && is_file('/run/clouve-limesurvey-attention');

if (($method === 'GET' || $method === 'HEAD') && $uri === '/') {
    http_response_code(200);
    header('Content-Type: text/html; charset=utf-8');
    if ($restoring) {
        $title = 'LimeSurvey is being restored';
        $text = 'This site is being restored from a backup. The page loads again by itself every 30 seconds.';
    } elseif ($attention) {
        $title = 'LimeSurvey needs attention from Clouve support';
        $text = 'This site could not be started and is waiting for a repair. Nothing was lost by waiting. '
            . 'The page loads again by itself every 30 seconds.';
    } else {
        $title = 'LimeSurvey is starting';
        $text = 'This site is being set up or upgraded. The page loads again by itself every 30 seconds.';
    }
    echo '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="30">',
        '<title>', $title, '</title></head><body>',
        '<h1>', $title, '</h1>',
        '<p>', $text, '</p>',
        '</body></html>', "\n";
    return true;
}

http_response_code(503);
header('Retry-After: 30');
header('Content-Type: text/plain; charset=utf-8');
if ($restoring) {
    echo "LimeSurvey is being restored from a backup. Try again in a few minutes.\n";
} elseif ($attention) {
    echo "LimeSurvey needs attention from Clouve support and is not running.\n";
} else {
    echo "LimeSurvey is being set up or upgraded. Try again in a few minutes.\n";
}
return true;
