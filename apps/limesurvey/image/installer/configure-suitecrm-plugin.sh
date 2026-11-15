#!/bin/bash
# Sets up Clouve's SuiteCRM plugin for LimeSurvey. site.sh runs it as www-data at every start when
# ENABLE_SUITECRM_INTEGRATION is true, after the install or upgrade and before Apache starts.
#
#   1. It makes the plugin's two tables when they are missing, and brings a table of mappings that an earlier image
#      made to the plugin's current shape, with the plugin's own schema code (the plugin's beforeActivate runs the
#      same code when an admin activates it by hand).
#   2. It registers the plugin, switched on, when LimeSurvey has no row for it yet. A row that is there is left as it
#      is: whether the plugin is on is the admin's choice. Only the in-place upgrade switches it back on, and only
#      when it was on before LimeSurvey's database update switched every added plugin off (upgrade.sh). A mark that
#      says the plugin is faulty is cleared, because LimeSurvey never loads a plugin that has it.
#   3. It writes the connection settings from the environment (SuiteCRM's address, admin name and password, and its
#      database settings) through the plugin's own storage, so the two passwords are stored encrypted
#      (commands/ClouveCommand.php). It runs at every start, so a new SuiteCRM password reaches the plugin.
#
# The OAuth2 client in SuiteCRM is made by the plugin itself, the first time it talks to SuiteCRM, so LimeSurvey
# starts whether or not SuiteCRM is up.
#
# No password is on a command line or in the log: the database client gets its password in MYSQL_PWD, and PHP reads
# the SuiteCRM values from the environment.
#
# Between steps 2 and 3 it also leaves one survey_enabled setting for a survey that has several. The plugin keeps
# "this survey's link to SuiteCRM is on" in that setting and reads the first row it finds, so a survey with an "off"
# row in front of its "on" rows had its link off. The earlier image's demo import left such rows. The link stays on
# when any of the rows said on, and the log names the survey and what was kept.

installer=/clouve/limesurvey/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || exit 1

log() { printf '[suitecrm-plugin] %s\n' "$*"; }

if [ -z "${SUITECRM_URL:-}" ]; then
    log "SUITECRM_URL is not set, so the plugin is not set up"
    exit 1
fi
plugins="$(ls_table plugins)"
if ! ls_sql "SELECT 1 FROM \`$plugins\` LIMIT 1" >/dev/null 2>&1 ||
    ! ls_sql "SELECT 1 FROM \`$(ls_table plugin_settings)\` LIMIT 1" >/dev/null 2>&1; then
    log "LimeSurvey's plugin tables can't be read, so the plugin is not set up"
    exit 1
fi

# --- 1. the plugin's tables -------------------------------------------------------------------------------------------

# The plugin's own schema code makes them and brings an earlier install's table of mappings up to date
# (commands/ClouveCommand.php, actionSchema). This script used to carry its own copy of the two definitions, and the
# copy fell behind the plugin: its table had no transform_rule column and one CRM field per question, so the plugin
# could not save a mapping.
rc=0
out="$(cd "$LS_ROOT" && YII_CONSOLE_COMMANDS="$installer/commands" php application/commands/console.php clouve schema 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
    log "the plugin's tables could not be made or brought up to date (status $rc): $(printf '%s' "$out" | head -n 1 | cut -c1-200 | sed "s/'[^']*'/'...'/g")"
    exit 1
fi
log "$(printf '%s' "$out" | tail -n 1)"

# --- 2. the plugin's row ----------------------------------------------------------------------------------------------

version="$(sed -n 's:.*<version>\([0-9][0-9.]*\)</version>.*:\1:p' "$LS_ROOT/plugins/SuiteCRMIntegration/config.xml" | head -n 1)"
row="$(ls_sql "SELECT CONCAT(id, ' ', active) FROM \`$plugins\` WHERE name = 'SuiteCRMIntegration'")"
if [ -z "$row" ]; then
    if ! ls_sql "INSERT INTO \`$plugins\` (name, active, version, load_error, plugin_type)
        VALUES ('SuiteCRMIntegration', 1, '${version:-2.1.0}', 0, 'user')"; then
        log "the plugin could not be registered"
        exit 1
    fi
    log "registered the plugin and switched it on"
else
    ls_sql "UPDATE \`$plugins\` SET version = '${version:-2.1.0}' WHERE name = 'SuiteCRMIntegration'" || :
    # LimeSurvey never loads a plugin that it has marked as faulty, so the link would stay dead without a word. The
    # earlier image's copy of the plugin could get that mark at its first start: it wrote a log file in /tmp, and the
    # demo survey's import, run as root, failed on that file when a web request had made it first. This image's
    # plugin writes no file there. So the mark is cleared at every start. If the plugin really can't be loaded,
    # LimeSurvey sets the mark again at the next page.
    if [ "$(ls_sql "SELECT load_error FROM \`$plugins\` WHERE name = 'SuiteCRMIntegration'")" = 1 ]; then
        if ls_sql "UPDATE \`$plugins\` SET load_error = 0, load_error_message = '' WHERE name = 'SuiteCRMIntegration'"; then
            log "LimeSurvey had marked the plugin as faulty and was not loading it. The mark is cleared, so it is loaded again"
        else
            log "LimeSurvey has marked the plugin as faulty, and the mark could not be cleared: reset it in LimeSurvey's plugin manager"
        fi
    fi
    if [ "${row##* }" = 1 ]; then
        log "the plugin is registered and switched on"
    else
        log "the plugin is registered and switched off. It stays off: switch it on in LimeSurvey's plugin manager"
    fi
fi

# --- one survey_enabled setting for each survey -----------------------------------------------------------------------

settings="$(ls_table plugin_settings)"
plugin_id="$(ls_sql "SELECT id FROM \`$plugins\` WHERE name = 'SuiteCRMIntegration'")"
if [[ "$plugin_id" =~ ^[0-9]+$ ]]; then
    while IFS=$'\t' read -r survey rows on keep; do
        [[ "$survey" =~ ^[0-9]+$ ]] && [[ "$keep" =~ ^[0-9]+$ ]] || continue
        if [ "${on:-0}" -gt 0 ]; then value='"1"'; word=on; else value='"0"'; word=off; fi
        # The row that stays gets its value first, and the others go after it: the survey never has no row at all.
        if ls_sql "UPDATE \`$settings\` SET \`value\` = '$value' WHERE id = $keep;
            DELETE FROM \`$settings\` WHERE plugin_id = $plugin_id AND model = 'Survey' AND model_id = $survey
                AND \`key\` = 'survey_enabled' AND id <> $keep"; then
            log "survey $survey had $rows survey_enabled settings. One is kept, and the survey's link to SuiteCRM is $word"
        else
            log "survey $survey has $rows survey_enabled settings, and they could not be brought down to one"
        fi
    done < <(ls_sql "SELECT model_id, COUNT(*), SUM(\`value\` IN ('1', '\"1\"', 'true', '\"true\"')), MIN(id)
        FROM \`$settings\` WHERE plugin_id = $plugin_id AND model = 'Survey' AND \`key\` = 'survey_enabled'
        GROUP BY model_id HAVING COUNT(*) > 1")
fi

# --- 3. the connection settings -------------------------------------------------------------------------------------

rc=0
out="$(cd "$LS_ROOT" && YII_CONSOLE_COMMANDS="$installer/commands" php application/commands/console.php clouve suitecrm 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
    # console.php prints a stack trace when it fails. Only its first line goes to the log, without quoted text.
    log "the plugin's settings could not be written (status $rc): $(printf '%s' "$out" | head -n 1 | cut -c1-200 | sed "s/'[^']*'/'...'/g")"
    exit 1
fi
log "$(printf '%s' "$out" | tail -n 1)"
exit 0
