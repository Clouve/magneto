# Customer Kit: LimeSurvey and SuiteCRM

The Customer Kit runs LimeSurvey and SuiteCRM on one deployment, each with its own MariaDB database, and links them:
a completed survey response becomes a lead or a case in SuiteCRM. Clouve's SuiteCRM plugin for LimeSurvey does that.
The kit also offers the AI Assistant, with a skill for each app.

This folder is the bundle. It has no images of its own. It runs the images of `apps/limesurvey` and `apps/suitecrm`,
and each app's README says how its image installs, upgrades and is run by hand.

## What is in it

| Container | What it is | Version | Memory and CPU on the smallest plan | Volumes |
| --- | --- | --- | --- | --- |
| `limesurvey` | LimeSurvey with Clouve's SuiteCRM plugin, public, port 8080 | 7.10.0 | 1 GB, 1 CPU | `/var/www/html` and `/var/www/html/upload`, 10 GB each |
| `limesurvey-mariadb` | LimeSurvey's database | MariaDB 11.8 | 1 GB, 0.5 CPU | `/var/lib/mysql`, 10 GB |
| `suitecrm` | SuiteCRM, public, port 80 | 8.10.2 | 1 GB, 1 CPU | `/var/www/html`, 10 GB |
| `suitecrm-mariadb` | SuiteCRM's database | MariaDB 12.3 | 1 GB, 0.5 CPU | `/var/lib/mysql`, 10 GB |

Customers pay for capacity, so it doesn't change with an app's version. `tests/crm-kit.test.sh` compares the
manifest with the one from before LimeSurvey 7 and fails when a capacity, volume, variable, health check or name
differs.

LimeSurvey is the kit's default app, so it answers on the deployment's own address. SuiteCRM answers on
`suitecrm-<deployment>`.

## How the link works

1. With `ENABLE_SUITECRM_INTEGRATION=true`, LimeSurvey's first start registers the plugin `SuiteCRMIntegration` and
   switches it on. Every start writes the plugin's connection settings again from the environment: SuiteCRM's address,
   the admin's name and password, and SuiteCRM's database settings. Both passwords are stored encrypted.
2. The link is switched on for each survey on its own, on the plugin's tab of the survey's settings. The demo
   survey has it on.
3. Each question says which CRM fields it fills, such as `Leads: first_name` or `Cases: description`. The mapping is
   kept on the question. An admin sets it in LimeSurvey's classic question editor, in the question's
   "SuiteCRM Integration" section. LimeSurvey 7 opens its new editor by default, which doesn't show that section. The
   plugin's settings page says how to switch editors. The AI Assistant can set a mapping too.
4. When someone completes an active survey, the plugin builds one record for each CRM module that has an answered,
   mapped question. It signs in to SuiteCRM's API as the SuiteCRM admin and creates the record.
5. The plugin signs in through an OAuth2 client named "LimeSurvey Integration". It makes that client itself, in
   SuiteCRM's database, the first time it needs it. So LimeSurvey starts whether or not SuiteCRM is up.
6. Every attempt goes into the plugin's log table, `lime_survey_crm_sync_log`, as sent or failed. A failed attempt
   is not sent again later. The response itself stays in LimeSurvey either way.

The demo survey is imported inactive. Activate it before you try it. A sales inquiry makes a lead. A support request
makes a case, and a lead with the person's contact details.

## What the link needs from each side

LimeSurvey's side:

| What | Where it comes from |
| --- | --- |
| The plugin is switched on and not marked as faulty | The first start. An upgrade switches it back on when it was on, and every start clears a faulty mark |
| The plugin's own "Enable SuiteCRM Integration" setting is on | The first start |
| The survey's link is on, and the survey is active | The admin, or the AI Assistant after a yes |
| The survey's questions are mapped to CRM fields | The admin in the classic question editor, or the AI Assistant |
| A lead has a last name, and a case has a subject | The survey's questions |
| SuiteCRM's address, admin name and password, and database settings | The manifest: `SUITECRM_URL`, `SUITECRM_ADMIN_USER`, `SUITECRM_ADMIN_PASSWORD` and `SUITECRM_DB_*` on the `limesurvey` container |

SuiteCRM's side:

| What | Where it comes from |
| --- | --- |
| SuiteCRM answers `/Api/access_token` and `/Api/V8/` inside the deployment, at `http://suitecrm` | The `suitecrm` container, once it has installed or upgraded |
| The main admin account is active, is an admin, and has the login and password the deployment set | The install. The manifest gives both apps the same `applicationPassword` |
| The OAuth2 client "LimeSurvey Integration" with the password grant | The plugin, at its first sign-in |
| SuiteCRM's key pair for API tokens, `public/legacy/Api/V8/OAuth2/private.key` and `public.key` | The install. An upgrade keeps it |
| SuiteCRM's database user may write to the table `oauth2clients` from the LimeSurvey container | The manifest gives LimeSurvey the same database secret as SuiteCRM |

## What breaks it

| What happened | What you see | The way back |
| --- | --- | --- |
| Someone changed the main admin's password in SuiteCRM, renamed the account, deactivated it or took away its admin rights | New responses are logged as failed | Put the account back as the deployment set it. The `suitecrm` skill has `restore-admin-password.sh` for the password |
| The OAuth2 client "LimeSurvey Integration" was deleted in SuiteCRM | New responses are logged as failed, and "Check Status" on the plugin's settings page says that SuiteCRM no longer has the client | "Initialize OAuth2" on the plugin's settings page makes a new client |
| The client was changed in SuiteCRM and is still there | New responses are logged as failed | "Initialize OAuth2" changes nothing while SuiteCRM still has the client. Delete the client in SuiteCRM, then click "Initialize OAuth2" |
| SuiteCRM's key pair for API tokens is missing, or its two files no longer match | New responses are logged as failed | Put both files back from a backup of the deployment. "Initialize OAuth2" only makes a client, so it doesn't repair this |
| A SuiteCRM restore brought back a database from before the plugin made its client | The same | The same |
| The plugin, its "Enable SuiteCRM Integration" setting or the survey's link was switched off, or the survey isn't active | Nothing is sent, and nothing is logged | Switch it on again |
| SuiteCRM is down, or is still installing or upgrading | The response is saved in LimeSurvey and logged as failed. It is not sent again | Wait for SuiteCRM. While it installs or upgrades, a stand-in answers its health check and answers every API call with 503, so the plugin never takes that for a lead |
| A mapped question was deleted | The record no longer has that field | Map another question to the field |
| One of the two database passwords changed on the platform | Nothing, after the next start of both apps: each start writes the passwords from the environment into both apps' settings | Restart the deployment |

## The AI Assistant

The manifest's `x-clouve-agent` block offers the AI Assistant with two skills from
[magneto-skills](https://github.com/Clouve/magneto-skills), `limesurvey` and `suitecrm`. The assistant's container
signs in to all four containers over the `clouve-ops` SSH channel, and each app's image carries its persona.

- The `limesurvey` skill has the survey side of the link: `crm-link.sh` shows the plugin's state, switches the link
  on or off for a survey, and maps questions to CRM fields.
- The `suitecrm` skill has SuiteCRM's side: the admin account, the OAuth2 client, the key pair and the leads once
  they are in. It never changes the main admin's password to anything but the deployment's.

A deployment made without the AI Assistant has no `CLOUVE_OPS_PASSWORD`, and then no container starts an sshd.

Each container's `appDescription` and the listing's own text in `description.txt` say what the assistant does. Both
have to be true for a paid plan and for a free trial or free services. Each text is at most 1,000 characters, and
the kit's text for an app never promises more than that app's own listing does: LimeSurvey sends invitations and
reminders through the customer's own mail server, and the kit says so too. `tests/crm-kit.test.sh` checks that
sentence and the lengths in `description.txt`, and the first command below checks each `appDescription`:

```bash
bash tests/listing-ai-copy.test.sh
bash tests/listing-ai-copy.test.sh --text "$(cat bundles/crm-kit/description.txt)"
```

## Run it locally

The bundle runs the two apps' images as they are on your machine, so build those first.

```bash
./build.sh limesurvey
./build.sh suitecrm
./start.sh crm-kit            # every volume starts as a new disk, as on a cluster
./status.sh crm-kit
./logs.sh crm-kit limesurvey
./stop.sh crm-kit             # keeps the data
./stop.sh crm-kit --cleanup   # removes the volumes too
```

| App | Address | Sign-in |
| --- | --- | --- |
| LimeSurvey | http://localhost:8080 (admin pages under `/admin`) | `admin` / `Admin@123` |
| SuiteCRM | http://localhost:8081 | `admin` / `Admin@123` |
| AI Assistant | http://localhost:8082 | `admin` / `Admin@123` |

These passwords are for local runs only. For the AI Assistant to answer, export `MAGNETO_AGENT_LLM_BASE_URL` and
`MAGNETO_AGENT_LLM_KEY`, or `ANTHROPIC_API_KEY`, before `./start.sh`.

To see the link work:

1. Sign in to LimeSurvey, open the demo survey and activate it.
2. Open the survey's public address and send in a sales inquiry.
3. Sign in to SuiteCRM and open Leads. The lead is there, and the survey's plugin tab in LimeSurvey counts one sync.

## Upgrading a kit that already runs

A kit installed with LimeSurvey 6.16.1 and SuiteCRM 8.9.1 upgrades in place the first time it starts on these
images. Both apps do their own upgrade, each behind a stand-in that keeps its health check passing, and each keeps a
backup on its volume. `apps/limesurvey/README.md` and `apps/suitecrm/README.md` have the staff runbooks: how to read
an upgrade's state, the way back, and how to remove the kept backup.

On the local kind cluster on 2026-11-12 an old kit with two responses and a lead moved to these images with only
its pods replaced: both apps served their new versions within 42 seconds of their new pods' start, no container
restarted, and the data was all there. The earlier kit's link had never worked on the rig (its demo survey's
first `survey_enabled` row said off), and after the upgrade it did.

For the link, the upgrade does this:

- The plugin is switched on again when it was on. LimeSurvey's own update switches every added plugin off, and any
  other plugin an admin added stays off and is named in the log and in the backup folder.
- The plugin's settings, its OAuth2 client and the earlier leads, responses and sync log stay as they were, with
  two changes that happen once: the two passwords, which the earlier image stored in clear text, are stored
  encrypted from then on, and the plugin's debug mode is switched off.
- The plugin's table of mappings gets its current shape. The earlier image made it without the column and the key
  that let one question fill several fields, so saving a mapping failed.
- A plugin that LimeSurvey had marked as faulty is loaded again. The earlier image could leave that mark at its
  first start.
- A survey that has several `survey_enabled` settings, as the earlier image's demo import left them, keeps one.
  The survey's link stays on when any of them said on, and the log names the survey and what was kept.
- SuiteCRM's scheduler is held until someone releases it, because scheduled jobs never ran on the earlier image.
  `apps/suitecrm/README.md` says how to look at what is queued and release it.

One thing stays as the earlier kit had it, because it is the customer's data:

- A demo survey that the earlier image imported keeps its mapping of the company question to `Cases: account_name`.
  With it, a sales inquiry that names a company also makes a case with no subject. Clear that one mapping in the
  question's "SuiteCRM Integration" section, or ask the AI Assistant to. A new install's demo survey doesn't have it.

## Tests

```bash
# The bundle's files, then a new kit on new disks: the four probes, the plugin, the demo survey, a response
# that becomes a lead, a support request that becomes a case, the plugin's endpoints, and the clouve-ops channel
bash tests/crm-kit.test.sh

# An old kit first (LimeSurvey 6.16.1 and SuiteCRM 8.9.1 on MariaDB 11.8 and 12.1, with a lead made through the
# plugin), then the new images on copies of its volumes: both apps upgrade in one start, the link still works,
# nothing the customer had is lost, and a response sent in while SuiteCRM upgrades is logged as failed
bash tests/crm-kit.test.sh --upgrade-from

# The bundle as a cluster starts it, judged by each container's own probe. Build both apps first
bash tests/new-disk-start.test.sh crm-kit

./check-manifests.sh
```

The kit test takes `--image NAME=REF` and `--old-image NAME=REF` for images that are already built, and `--keep` to
leave its containers up for a look.

## Files

- `clv-docker-compose.yml` is the marketplace manifest: the four containers, their settings and the
  `x-clouve-agent` block.
- `docker-compose.yml` is for local runs. It adds the `magneto-agent` service, which a deployment gets from the
  manifest's block.
- `description.txt` holds the listing's short and long description, typed into the publish wizard.
- `logo.png`, `limesurvey.png` and `suitecrm.png` are the listing's logo and the two apps' icons.
