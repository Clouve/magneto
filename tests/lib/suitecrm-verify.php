<?php
// Prints what tests/suitecrm-upgrade.test.sh expects to find in a seeded SuiteCRM install, one fact per line.
// The output is the same on 8.9.1 and on 8.10.2 when nothing was lost, so the test compares it with what the
// 8.9.1 site printed before any upgrade. Run as www-data: php suitecrm-verify.php
// The passwords it checks come from the environment: SC_T_USER_PW, SC_T_SMTP_PW.

if (PHP_SAPI !== 'cli') { exit(1); }
chdir('/var/www/html/public/legacy');
define('sugarEntry', true);
ob_start();
require_once 'include/entryPoint.php';
global $current_user, $db, $sugar_config;
$current_user = BeanFactory::newBean('Users');
$current_user->getSystemUser();
ob_end_clean();

$out = [];
foreach (['Accounts', 'Contacts', 'Leads', 'Opportunities', 'Notes', 'Users', 'ACLRoles', 'SecurityGroups'] as $m) {
    $b = BeanFactory::newBean($m);
    $out[] = "$m=" . $db->getOne("SELECT COUNT(*) FROM {$b->table_name} WHERE deleted=0");
}
$acc = BeanFactory::newBean('Accounts');
$acc->retrieve_by_string_fields(['name' => 'Acme Research Ltd']);
$out[] = "account tier={$acc->sct_tier_c} city={$acc->billing_address_city}";
$acc->sic_code = '';
$acc->save();
$acc = BeanFactory::getBean('Accounts', $acc->id, ['use_cache' => false]);
$out[] = "hook on save={$acc->sic_code}";
$acc->load_relationship('contacts');
$names = [];
foreach ($acc->contacts->getBeans() as $c) { $names[] = "{$c->first_name} {$c->last_name} <{$c->email1}>"; }
sort($names);
$out[] = 'contacts=' . implode('; ', $names);
$acc->load_relationship('opportunities');
$names = [];
foreach ($acc->opportunities->getBeans() as $o) { $names[] = "{$o->name} | {$o->sales_stage} | " . number_format((float) $o->amount, 2, '.', ''); }
sort($names);
$out[] = 'opportunities=' . implode('; ', $names);
$out[] = 'opportunity contact roles=' . $db->getOne("SELECT COUNT(*) FROM opportunities_contacts WHERE deleted=0 AND contact_role='Primary Decision Maker'");
$out[] = 'leads=' . implode('; ', array_map(static fn ($r) => $r['last_name'], iterator_to_array((static function () use ($db) {
    $res = $db->query("SELECT last_name FROM leads WHERE deleted=0 ORDER BY last_name");
    while ($row = $db->fetchByAssoc($res)) { yield $row; }
})())));
$note = BeanFactory::newBean('Notes');
$note->retrieve_by_string_fields(['name' => 'Signed contract']);
$out[] = "note file={$note->filename} on disk=" . (is_file('upload/' . $note->id) ? trim((string) file_get_contents('upload/' . $note->id)) : 'MISSING');
$out[] = 'config override=' . ($sugar_config['list_max_entries_per_page'] ?? '?') . ' ' . ($sugar_config['sct_marker'] ?? 'MISSING');
$admin = BeanFactory::newBean('Administration');
$admin->retrieveSettings('system');
$out[] = 'system name=' . ($admin->settings['system_name'] ?? 'MISSING');
$oe = (new OutboundEmail())->getSystemMailerSettings();
$out[] = "smtp={$oe->mail_smtpserver}:{$oe->mail_smtpport} user={$oe->mail_smtpuser} password decrypts="
    . ($oe->mail_smtppass === getenv('SC_T_SMTP_PW') ? 'yes' : 'NO');
$u = BeanFactory::newBean('Users');
$u->retrieve_by_string_fields(['user_name' => 'sally']);
$roles = array_map(static fn ($r) => $r->name, (new ACLRole())->getUserRoles($u->id, false));
$groups = array_column(SecurityGroup::getUserSecurityGroups($u->id), 'name');
$out[] = "sally status={$u->status} password ok=" . (User::checkPassword(getenv('SC_T_USER_PW'), $u->user_hash) ? 'yes' : 'NO')
    . ' roles=' . implode(',', $roles) . ' groups=' . implode(',', $groups);
$out[] = 'role denies Accounts delete=' . $db->getOne("SELECT COUNT(*) FROM acl_roles_actions ra JOIN acl_actions a ON a.id = ra.action_id WHERE ra.deleted=0 AND a.category='Accounts' AND a.name='delete' AND ra.access_override = -99");
$out[] = 'custom field definition=' . $db->getOne("SELECT COUNT(*) FROM fields_meta_data WHERE custom_module='Accounts' AND name='sct_tier_c' AND deleted=0");
$out[] = 'oauth2 client=' . $db->getOne("SELECT COUNT(*) FROM oauth2clients WHERE id='limesurvey-sct1' AND deleted=0 AND allowed_grant_type='password'");
$out[] = 'extension=' . (is_file('/var/www/html/extensions/sctExt/config/extension.php') ? 'kept' : 'MISSING');
$out[] = 'custom file=' . (is_file('/var/www/html/public/legacy/custom/sct/kept.txt') ? 'kept' : 'MISSING');
echo implode("\n", $out), "\n";
