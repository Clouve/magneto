# SuiteCRM Integration plugin for LimeSurvey

Version 2.1.0. Works with LimeSurvey 6 and 7 and with SuiteCRM 8 (its V8 API, with OAuth2).

When someone completes a survey, the plugin creates a lead or a case in SuiteCRM from the answers. Each question
says which SuiteCRM fields it fills. The plugin keeps a sync log for each survey.

The plugin writes to two SuiteCRM modules, Leads and Cases, and only to fields that SuiteCRM lists for them. The
list is in the plugin's code, and no setting adds to it. See "What a mapping can name" below.

## In Clouve's Customer Kit

The LimeSurvey image carries the plugin. With `ENABLE_SUITECRM_INTEGRATION=true` the image registers the plugin,
switches it on the first time, and writes its connection settings from these variables at every start:

```yaml
limesurvey:
  environment:
    ENABLE_SUITECRM_INTEGRATION: "true"
    SUITECRM_URL: http://suitecrm:80
    SUITECRM_ADMIN_USER: admin
    SUITECRM_ADMIN_PASSWORD: Admin@123
    SUITECRM_DB_HOST: suitecrm-mariadb
    SUITECRM_DB_NAME: suitecrm
    SUITECRM_DB_USER: suitecrm
    SUITECRM_DB_PASSWORD: suitecrm_password
```

The two passwords are stored encrypted, with the keys in LimeSurvey's `application/config/security.php`. A start
never changes whether the plugin is switched on. If an admin switches it off, it stays off.

The settings page never shows a stored password or the OAuth2 client secret. Their fields are empty when the page
opens. Type a new value to change one. A field you leave empty keeps what is stored.

The plugin makes its OAuth2 client in SuiteCRM's database (`oauth2clients`, named "LimeSurvey Integration") the
first time it talks to SuiteCRM, so LimeSurvey starts whether or not SuiteCRM is up. Changing SuiteCRM's admin
password, that OAuth2 client or SuiteCRM's key pair breaks the link until the settings match again.

## Installing it by hand

1. Copy the folder to LimeSurvey: `cp -r SuiteCRMIntegration /path/to/limesurvey/plugins/`
2. Give it to the web server's user: `chown -R www-data:www-data /path/to/limesurvey/plugins/SuiteCRMIntegration`
3. In LimeSurvey, open Configuration, then Plugin manager, and activate "SuiteCRM Integration".
4. Open its settings, set "Enable SuiteCRM Integration" to Enabled, and fill in SuiteCRM's address, the admin
   name and password, and SuiteCRM's database host, name, user and password.

## Switch it on for a survey

Open the survey's settings, then its plugin settings, set "Enable SuiteCRM Integration for this survey" to
Enabled and save.

## Map questions to SuiteCRM fields

Field mapping is done in the classic question editor. LimeSurvey 7 opens its new survey editor by default, and the
new editor has no place for a plugin's fields. To switch, open the menu under your name at the top right, choose
the entry for the new editor, pick "Classic" and save. The plugin's settings page has a link that opens the same
switch. You can switch back the same way at any time.

For each question that should reach SuiteCRM:

1. Edit the question in the classic editor.
2. Open its "SuiteCRM Integration" section.
3. Choose the SuiteCRM field, for example `Leads: first_name`.
4. Save.

| Question | SuiteCRM field |
|----------|-----------|
| firstName | Leads: first_name |
| lastName | Leads: last_name |
| email | Leads: email1 |
| phone | Leads: phone_work |
| company | Leads: account_name |
| message | Leads: description |

A lead needs `last_name` and a case needs `name`. The plugin sends only the fields that are mapped. It sets no
`lead_source` and no `status` itself.
[FIELD_MAPPING_GUIDE.md](FIELD_MAPPING_GUIDE.md) lists every field.

The "SuiteCRM Integration" section shows only while the survey's link is switched on. A question keeps its mapping
while the link is off, and saving the question doesn't remove it.

### What a mapping can name

The plugin accepts a mapping when its module is `Leads` or `Cases`, its field name is made of letters, digits and
underscores, and SuiteCRM lists that field for the module. The plugin leaves a few system fields, such as `id` and
`assigned_user_id`, off that list, so a mapping can't name them. It refuses any other mapping, because it talks to
SuiteCRM as SuiteCRM's admin, and whoever may edit a survey can write a mapping.

The plugin checks a mapping twice:

- When someone saves it, in the question editor, through LimeSurvey's API or through the plugin's own address. The
  plugin doesn't store a mapping it refuses. It checks the field against the list it has cached, so a field that
  is new in SuiteCRM passes once the cache has it.
- When it sends a response. A survey import stores mappings without the first check, so the plugin checks each one
  again here, against SuiteCRM's current list. A refused mapping sends nothing, and the rest of the response still
  goes.

Each refusal is one line in the web server's error log, with the question's id and no answer. When the plugin
refuses a mapping while it sends a response, the survey's sync log also gets a failed row with the module `Refused`.

## Who can use the plugin's pages

The plugin's AJAX addresses (`/index.php/plugins/direct?plugin=SuiteCRMIntegration&function=...`) answer only a
signed-in LimeSurvey admin. A caller who isn't signed in gets 401, and an account without the right gets 403.

| What | Right needed |
|------|--------------|
| A survey's sync log | Read that survey's settings and its responses |
| Read a question's mappings | Read its survey's settings |
| Save a question's mappings | Change its survey's content |
| The lists the question editor loads (modules, fields, rules) | The global settings right, or read the settings or the content of the survey being edited |
| Connection status, test the connection, refresh the field cache, set up OAuth2 | Change the global settings |
| The plugin's settings page | Change the global settings |

LimeSurvey opens a plugin's settings page to an account that may only read the global settings. For such an account
this plugin's page holds a note and none of the settings.

Four addresses change something: `actionSaveMappings`, `actionTestConnection`, `actionRefreshCache` and
`actionInitializeOAuth2`. They take POST with LimeSurvey's CSRF token (`YII_CSRF_TOKEN`). A GET gets 405.

Only an account that may change the global settings makes the plugin talk to SuiteCRM from these pages. For any
other account the field lists come from the plugin's cache, however old it is, and the plugin never sets up the
OAuth2 client on its request. The cache fills when a response is completed, when an account that may change the
global settings opens the question editor, or when one calls `actionRefreshCache`.

## Troubleshooting

The sync log has one row for each record the plugin tried to make. For a sync that failed, the row keeps what was
sent, the mappings that were used and the error message, which has SuiteCRM's own error text when SuiteCRM gave
one. Those rows hold answers, so only an admin with rights on the survey can read the
log. For a sync that worked, the row keeps the id of the record SuiteCRM made and nothing of the response. The
plugin removes rows older than 90 days the next time it writes to the log. To see the latest rows:

```sql
SELECT id, response_id, crm_module, sync_status, error_message, synced_at
FROM lime_survey_crm_sync_log ORDER BY id DESC LIMIT 10;
```

Debug mode is off unless an admin switches it on in the plugin's settings. While it is on, the plugin writes what
it does to `tmp/runtime/suitecrm_integration.log` in LimeSurvey's folder, which the web server never serves. The
log holds counts and ids. It never holds answers or passwords. Switch debug mode off again when you are done.

| Problem | What to check |
|-------|----------|
| "OAuth2 client not yet initialized" or "OAuth2 initialization failed" (Check Status) | SuiteCRM's database settings in the plugin's settings, then "Initialize OAuth2" |
| "OAuth2 authentication failed" | SuiteCRM's address, admin name and password |
| No record is created | The survey's link is switched on, and `last_name` (leads) or `name` (cases) is mapped |
| A record has empty fields | The question's mapping, and that the question was answered |
| A failed row with the module `Refused` | The question it names has a mapping to a module other than Leads or Cases, or to a field SuiteCRM doesn't list |
| "SuiteCRM answered with a redirect" | The plugin doesn't follow redirects. Put SuiteCRM's own address in the settings |

To see the OAuth2 client in SuiteCRM's database:

```sql
SELECT id, name, allowed_grant_type FROM oauth2clients WHERE name = 'LimeSurvey Integration';
```

## License

MIT License
