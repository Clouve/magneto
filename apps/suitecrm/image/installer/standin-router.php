<?php
// The stand-in for SuiteCRM's health check. The entrypoint runs it with PHP's built-in server on port 80 from
// before it waits for the database until Apache starts, so that the platform's probe (GET /) keeps passing
// while an install, an upgrade or a way back runs, and the container is not restarted in the middle. It serves
// no SuiteCRM code and reads nothing from the volume.
//
// GET / and HEAD / get a short page with status 200 (Docker's own health check asks with HEAD). Everything
// else gets 503 with Retry-After, so that a caller such as the LimeSurvey plugin never takes this page for an
// API reply. Every answer carries the header X-Clouve-Standin: suitecrm, which tells a tool that waits for
// SuiteCRM itself that this is not it yet.
//
// The page says one of three things. The entrypoint chooses with two empty files in /run, which only root can
// make: clouve-suitecrm-restoring while the AI Assistant's restore is under way, and clouve-suitecrm-attention
// when it found a site that it must not start and that a person has to repair.

$uri = $_SERVER['REQUEST_URI'] ?? '';
$method = $_SERVER['REQUEST_METHOD'] ?? '';
header('X-Clouve-Standin: suitecrm');
header('Cache-Control: no-store');
if (is_file('/run/clouve-suitecrm-restoring')) {
    $title = 'SuiteCRM is being restored';
    $text = 'A backup is being put back. This page reloads by itself, and SuiteCRM opens when the restore has finished.';
    $short = 'SuiteCRM is being restored. Try again in a few minutes.';
} elseif (is_file('/run/clouve-suitecrm-attention')) {
    $title = 'SuiteCRM needs attention';
    $text = 'SuiteCRM was not started, because the site has to be repaired first. '
        . 'Please contact support, or ask the AI Assistant to look at it.';
    $short = 'SuiteCRM needs attention and was not started.';
} else {
    $title = 'SuiteCRM is starting';
    $text = 'A new install or an upgrade takes a few minutes. This page reloads by itself, and SuiteCRM opens '
        . 'when it is ready.';
    $short = 'SuiteCRM is starting. Try again in a few minutes.';
}
if ($uri === '/' && ($method === 'GET' || $method === 'HEAD')) {
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="20">',
        '<title>SuiteCRM</title></head><body style="font-family: sans-serif; margin: 3em">',
        '<h1>', $title, '</h1>',
        '<p>', $text, '</p>',
        '</body></html>', "\n";
    return true;
}
http_response_code(503);
header('Retry-After: 30');
header('Content-Type: text/plain; charset=utf-8');
echo $short, "\n";
return true;
