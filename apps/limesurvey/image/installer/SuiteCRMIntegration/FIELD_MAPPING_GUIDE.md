# Field Mapping Quick Reference Guide (v2.0)

## Overview

This guide explains how to configure per-question field mappings in LimeSurvey to automatically create records in SuiteCRM when surveys are completed.

**Version 2.0** uses a **per-question mapping approach** where each survey question can be individually configured to map to a specific SuiteCRM field. This replaces the previous JSON-based field mapping configuration.

## How Per-Question Mapping Works

In LimeSurvey v2.0 integration, each question has a custom attribute that allows you to select which SuiteCRM field it maps to:

1. **Edit any question** in your survey
2. **Scroll to the "SuiteCRM Integration" section** in question settings
3. **Select the CRM field** from the dropdown (e.g., `Leads: first_name`, `Leads: email1`)
4. **Save the question**

The plugin automatically:
- Fetches available CRM fields from SuiteCRM via the API
- Caches field definitions for performance
- Shows field labels and types in the dropdown
- Stores mappings in the `lime_survey_crm_mappings` database table

## Example: Setting Up a Contact Form

### Step 1: Create Survey Questions

Create questions with meaningful codes:
- `firstName` - Short text for first name
- `lastName` - Short text for last name
- `email` - Short text with email validation
- `phone` - Short text for phone number
- `company` - Short text for company name
- `description` - Long text for message/inquiry

### Step 2: Configure Field Mappings

For each question, set the SuiteCRM field mapping:

| Question Code | Question Text | SuiteCRM Field |
|---------------|---------------|----------------|
| firstName | First Name | Leads: first_name |
| lastName | Last Name | Leads: last_name |
| email | Email Address | Leads: email1 |
| phone | Phone Number | Leads: phone_work |
| company | Company | Leads: account_name |
| description | How can we help? | Leads: description |

### Step 3: Enable Survey Integration

1. Go to **Survey Settings** → **Plugin Settings**
2. Enable **SuiteCRM Integration for this survey**
3. Save settings

## Available Lead Fields

| SuiteCRM Field | Description | Type | Required |
|----------------|-------------|------|----------|
| `first_name` | First Name | String | No |
| `last_name` | Last Name | String | **Yes** |
| `email1` | Primary Email | Email | No |
| `phone_work` | Work Phone | Phone | No |
| `phone_mobile` | Mobile Phone | Phone | No |
| `title` | Job Title | String | No |
| `account_name` | Company Name | String | No |
| `description` | Description/Notes | Text | No |
| `lead_source` | Lead Source | Enum | Auto-set to "Survey" |
| `status` | Status | Enum | Auto-set to "New" |
| `refered_by` | Referred By | String | No |
| `website` | Website | URL | No |
| `do_not_call` | Do Not Call | Boolean | No |

## Case Field Mappings

To create Cases instead of (or in addition to) Leads, map questions to Case fields:

| Question Code | Question Text | SuiteCRM Field |
|---------------|---------------|----------------|
| subject | Issue Subject | Cases: name |
| details | Issue Description | Cases: description |
| urgency | Priority Level | Cases: priority |

### Available Case Fields

| SuiteCRM Field | Description | Type | Required |
|----------------|-------------|------|----------|
| `name` | Case Subject | String | **Yes** |
| `description` | Full Description | Text | No |
| `priority` | Priority | Enum | No |
| `status` | Status | Enum | Auto-set to "New" |
| `state` | State | Enum | Auto-set to "Open" |
| `type` | Case Type | Enum | No |
| `resolution` | Resolution | Text | No |
| `work_log` | Work Log | Text | No |

### Priority Values

- `High`
- `Medium` (default)
- `Low`

### Status Values

- `New` (default)
- `Assigned`
- `Closed`
- `Pending Input`
- `Rejected`
- `Duplicate`

### State Values

- `Open` (default)
- `Closed`

## Advanced Mapping Techniques

### Computed/Hidden Questions

You can use LimeSurvey's expression manager to create hidden questions that compute values based on other answers, then map those hidden questions to CRM fields.

Example:
1. Create a hidden question with code `Q_COMPUTED_PRIORITY`
2. Set its expression to: `{if(Q_URGENCY == 'urgent', 'High', 'Medium')}`
3. Map `Q_COMPUTED_PRIORITY` → `Cases: priority`

### Multiple Choice Questions

For multiple choice (radio/dropdown) questions, the selected option's code or text is sent to SuiteCRM.

Example:
- Question Type: Radio buttons
- Options: High (H), Medium (M), Low (L)
- Map to: `Cases: priority`

**Tip**: Ensure option codes match SuiteCRM's expected enum values.

### Long Text Questions

Long text responses work well with description/text fields:
- Map feedback questions → `Leads: description`
- Map issue details → `Cases: description`

### Email Validation

Enable email validation on email questions to ensure valid addresses are sent to SuiteCRM.

## Common Mapping Patterns

### Customer Feedback Survey → Lead

| Question | Maps To |
|----------|---------|
| Name | Leads: first_name |
| Surname | Leads: last_name |
| Email | Leads: email1 |
| Phone | Leads: phone_work |
| Company | Leads: account_name |
| Feedback | Leads: description |

### Support Request Survey → Case

| Question | Maps To |
|----------|---------|
| Issue Title | Cases: name |
| Issue Description | Cases: description |
| Urgency | Cases: priority |

### Product Interest Survey → Lead

| Question | Maps To |
|----------|---------|
| First Name | Leads: first_name |
| Last Name | Leads: last_name |
| Email | Leads: email1 |
| Mobile Phone | Leads: phone_mobile |
| Company Name | Leads: account_name |
| Product Interest | Leads: description |

## Validation Tips

1. **Test Your Mapping**: Always test with a sample survey response before going live
2. **Required Fields**: Ensure `last_name` (for Leads) or `name` (for Cases) are mapped
3. **Data Types**: Ensure survey question types match expected CRM field types
4. **Enable Debug Mode**: Check logs at `/tmp/suitecrm_integration.log` for detailed information

## Troubleshooting

### Issue: Records not created

**Check:**
- Is the survey enabled for SuiteCRM integration?
- Are required fields mapped (last_name for Leads, name for Cases)?
- Is the plugin enabled globally?
- Check debug logs: `docker exec <container> cat /tmp/suitecrm_integration.log`

### Issue: Wrong data in CRM fields

**Check:**
- Are the correct questions mapped to CRM fields?
- Do multiple choice values match SuiteCRM's expected enum values?
- Check the `lime_survey_crm_sync_log` table for request/response details

### Issue: Some fields empty in CRM

**Check:**
- Are those questions required in the survey?
- Are respondents actually filling them out?
- Check the sync log table: `SELECT * FROM lime_survey_crm_sync_log ORDER BY id DESC LIMIT 5;`

## Database Tables (v2.0)

The plugin uses two database tables:

### `lime_survey_crm_mappings`
Stores per-question field mappings:
```sql
SELECT * FROM lime_survey_crm_mappings WHERE survey_id = YOUR_SURVEY_ID;
```

### `lime_survey_crm_sync_log`
Logs all sync attempts with request/response data:
```sql
SELECT id, response_id, crm_module, crm_record_id, sync_status, synced_at
FROM lime_survey_crm_sync_log ORDER BY id DESC LIMIT 10;
```

## Example: Complete Integration Setup

### Step 1: Create Survey Questions
| Code | Question | Type |
|------|----------|------|
| firstName | First Name | Short text |
| lastName | Last Name | Short text |
| email | Email | Short text (email validation) |
| phone | Phone | Short text |
| company | Company | Short text |
| message | How can we help? | Long text |

### Step 2: Configure Field Mappings
For each question, select the SuiteCRM field in question settings:
| Question | SuiteCRM Field |
|----------|----------------|
| firstName | Leads: first_name |
| lastName | Leads: last_name |
| email | Leads: email1 |
| phone | Leads: phone_work |
| company | Leads: account_name |
| message | Leads: description |

### Step 3: Enable Survey Integration
Go to **Survey Settings** → **Plugin Settings** → Enable SuiteCRM Integration

### Result in SuiteCRM
When a survey is completed, a new Lead is created with:
- First Name: [firstName response]
- Last Name: [lastName response]
- Email: [email response]
- Work Phone: [phone response]
- Company: [company response]
- Description: [message response]
- Lead Source: "Survey" (automatic)
- Status: "New" (automatic)
