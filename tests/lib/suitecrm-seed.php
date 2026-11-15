<?php
// Gives a new SuiteCRM install what a customer's install holds before an upgrade. tests/suitecrm-upgrade.test.sh
// runs it once, as www-data, in the 8.9.1 container: php suitecrm-seed.php
// The passwords come from the environment: SC_T_USER_PW, SC_T_SMTP_PW, SC_T_OAUTH_SECRET.

if (PHP_SAPI !== 'cli') { exit(1); }
chdir('/var/www/html/public/legacy');
define('sugarEntry', true);
require_once 'include/entryPoint.php';
global $current_user, $db, $sugar_config;
$current_user = BeanFactory::newBean('Users');
$current_user->getSystemUser();

// Records and their links.
$acc = BeanFactory::newBean('Accounts');
$acc->name = 'Acme Research Ltd';
$acc->account_type = 'Customer';
$acc->industry = 'Technology';
$acc->billing_address_city = 'San Ramon';
$acc->assigned_user_id = $current_user->id;
$acc->save();

$con = BeanFactory::newBean('Contacts');
$con->first_name = 'Ada';
$con->last_name = 'Lovelace';
$con->email1 = 'ada@acme.example';
$con->account_id = $acc->id;
$con->assigned_user_id = $current_user->id;
$con->save();

foreach ([['Grace', 'Hopper', 'grace@navy.example'], ['Alan', 'Turing', 'alan@bletchley.example']] as $l) {
    $lead = BeanFactory::newBean('Leads');
    $lead->first_name = $l[0];
    $lead->last_name = $l[1];
    $lead->email1 = $l[2];
    $lead->status = 'New';
    $lead->lead_source = 'Web Site';
    $lead->assigned_user_id = $current_user->id;
    $lead->save();
}

foreach ([['Acme 100 seats', 'Prospecting', 12000], ['Acme support plan', 'Negotiation/Review', 4500.50],
          ['Acme pilot (won)', 'Closed Won', 900]] as $o) {
    $opp = BeanFactory::newBean('Opportunities');
    $opp->name = $o[0];
    $opp->sales_stage = $o[1];
    $opp->amount = $o[2];
    $opp->currency_id = '-99';
    $opp->date_closed = '2027-01-15';
    $opp->account_id = $acc->id;
    $opp->assigned_user_id = $current_user->id;
    $opp->save();
    $opp->load_relationship('contacts');
    $opp->contacts->add($con->id, ['contact_role' => 'Primary Decision Maker']);
}

// A custom field on Accounts, made the way Studio makes it, and a logic hook under custom/.
require_once 'modules/DynamicFields/FieldCases.php';
require_once 'modules/ModuleBuilder/parsers/parser.label.php';
$field = get_widget('varchar');
$field->name = 'sct_tier_c';
$field->vname = 'LBL_SCT_TIER';
$field->label = 'LBL_SCT_TIER';
$field->len = 50;
$field->audited = 1;
$df = new DynamicField('Accounts');
$df->setup(BeanFactory::newBean('Accounts'));
$field->save($df);
ParserLabel::addLabels('en_us', ['LBL_SCT_TIER' => 'Test Tier'], 'Accounts');
@mkdir('custom/modules/Accounts', 0775, true);
file_put_contents('custom/modules/Accounts/logic_hooks.php', "<?php\n\$hook_version = 1;\n\$hook_array = array();\n\$hook_array['before_save'] = array();\n\$hook_array['before_save'][] = array(1, 'sct stamp', 'custom/modules/Accounts/SctHook.php', 'SctHook', 'stamp');\n");
file_put_contents('custom/modules/Accounts/SctHook.php', "<?php\nclass SctHook { public function stamp(\$bean, \$event, \$args) { \$bean->sic_code = 'HOOK'; } }\n");

// Settings: config_override.php and a row in the config table.
require_once 'modules/Configurator/Configurator.php';
$cfg = new Configurator();
$cfg->config['list_max_entries_per_page'] = 33;
$cfg->config['sct_marker'] = 'kept-through-upgrade';
$cfg->handleOverride();
BeanFactory::newBean('Administration')->saveSetting('system', 'name', 'Test CRM Ltd');

require_once 'modules/Administration/QuickRepairAndRebuild.php';
ob_start();
ob_start();
(new RepairAndClear())->repairAndClearAll(['clearAll'], ['Accounts'], true, false);
while (ob_get_level() > 0) { ob_end_clean(); }

// The field's value. This process loaded Accounts before the field existed, so the row is written directly.
$db->query("REPLACE INTO accounts_cstm (id_c, sct_tier_c) VALUES (" . $db->quoted($acc->id) . ", 'Gold')");

// A note with a file in public/legacy/upload.
$note = BeanFactory::newBean('Notes');
$note->name = 'Signed contract';
$note->parent_type = 'Accounts';
$note->parent_id = $acc->id;
$note->filename = 'contract.txt';
$note->file_mime_type = 'text/plain';
$note->save();
file_put_contents('upload/' . $note->id, "attachment body\n");

// A second user with a role and a security group.
$u = BeanFactory::newBean('Users');
$u->user_name = 'sally';
$u->first_name = 'Sally';
$u->last_name = 'Sales';
$u->status = 'Active';
$u->employee_status = 'Active';
$u->is_admin = 0;
$u->email1 = 'sally@example.test';
$u->user_hash = User::getPasswordHash(getenv('SC_T_USER_PW'));
$u->save();
$role = BeanFactory::newBean('ACLRoles');
$role->name = 'Sales Rep';
$role->save();
$role->load_relationship('users');
$role->users->add($u->id);
$actionId = $db->getOne("SELECT id FROM acl_actions WHERE deleted=0 AND category='Accounts' AND name='delete'");
$role->setAction($role->id, $actionId, ACL_ALLOW_NONE);
$sg = BeanFactory::newBean('SecurityGroups');
$sg->name = 'West Team';
$sg->save();
$sg->load_relationship('users');
$sg->users->add($u->id);

// The system's outgoing mail account, with a password (stored encrypted).
$oe = new OutboundEmail();
$oe = $oe->getSystemMailerSettings();
$oe->mail_smtpserver = 'smtp.example.test';
$oe->mail_smtpport = 587;
$oe->mail_smtpauth_req = 1;
$oe->mail_smtpuser = 'mailer@example.test';
$oe->mail_smtppass = getenv('SC_T_SMTP_PW');
$oe->mail_smtpssl = 2;
$oe->smtp_from_name = 'Test CRM';
$oe->smtp_from_addr = 'crm@example.test';
$oe->saveSystem();

// The OAuth2 client, exactly as the LimeSurvey plugin of the Customer Kit inserts it.
$now = date('Y-m-d H:i:s');
$db->query("INSERT INTO oauth2clients (id, name, date_entered, date_modified, created_by, deleted, secret, is_confidential, allowed_grant_type, duration_value, duration_amount, duration_unit) VALUES ('limesurvey-sct1', 'LimeSurvey Integration', '$now', '$now', '1', 0, '" . hash('sha256', getenv('SC_T_OAUTH_SECRET')) . "', 1, 'password', 3600, 1, 'hour')");

// Files where 8.9 keeps email attachments and file fields, an extension, a file under custom/, and one in
// the install root that SuiteCRM doesn't know.
chdir('/var/www/html');
@mkdir('uploads/documents', 0755, true);
file_put_contents('uploads/documents/sct-private.txt', "private file\n");
@mkdir('public/media-upload/images', 0755, true);
file_put_contents('public/media-upload/images/sct-public.txt', "public file\n");
@mkdir('extensions/sctExt/config', 0755, true);
file_put_contents('extensions/sctExt/config/extension.php', "<?php\n// test extension\n");
@mkdir('public/legacy/custom/sct', 0755, true);
file_put_contents('public/legacy/custom/sct/kept.txt', "custom file\n");
echo "seeded\n";
