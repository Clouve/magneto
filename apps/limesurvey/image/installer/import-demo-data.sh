#!/bin/bash
# Imports the demo survey. site.sh runs it as www-data when INSTALL_DEMO_DATA is true, after the install and the
# SuiteCRM plugin's setup and before Apache starts. The marker .demo_data_installed in the web root keeps a later
# start from importing it again.
#
# A start that is cut off must not import the demo survey a second time. So the script writes .demo_data_importing,
# with the survey's id, before it imports, adds "imported=yes" once the import is through, and removes the file
# when the marker is written. A start that finds the file knows what the last one left:
#   - "imported=yes" and the survey is there: the import had finished. Only the rest is done (the link to SuiteCRM
#     and the marker).
#   - no "imported=yes" and the survey is there: the import was cut off halfway. LimeSurvey's command line has no
#     way to remove a survey, so the unfinished survey stays, nothing is imported beside it, and the log says how to
#     get the demo survey after all.
#   - the survey is not there: nothing was left, and the import runs again.
#
# With the SuiteCRM plugin (ENABLE_SUITECRM_INTEGRATION=true), the survey's link to SuiteCRM is switched on: the
# plugin keeps that in one survey_enabled setting, and this script leaves exactly one row of it, with the value 1.
# Two rows used to switch the link off, because the plugin then read the first one.
#
# No password is on a command line: the database client gets its password in MYSQL_PWD.

installer=/clouve/limesurvey/installer
# shellcheck source=/dev/null
. "$installer/lib.sh" || exit 1

log() { printf '[demo-data] %s\n' "$*"; }

source_file="${DEMO_DATA_SOURCE:-$installer/demo_data.lss}"
language="${DEMO_DATA_LANG:-en}"
marker="$LS_ROOT/.demo_data_installed"
stamp="$LS_ROOT/.demo_data_importing"

if [ -f "$marker" ]; then
    log "the demo survey was imported before ($(sed -n 's/^Survey ID: //p' "$marker" | head -n 1))"
    exit 0
fi
if [ ! -f "$source_file" ]; then
    log "the demo survey file $source_file is missing"
    exit 1
fi
case "$language" in
    *[!A-Za-z0-9_-]* | '') log "DEMO_DATA_LANG is not a language code"; exit 1 ;;
esac

# What a start that was cut off left behind.
survey_id=""
if [ -f "$stamp" ] && [ ! -L "$stamp" ]; then
    cut_off="$(sed -n 's/^sid=\([0-9]\{1,\}\)$/\1/p' "$stamp" | head -n 1)"
    if [ -n "$cut_off" ] && [ "$(ls_sql "SELECT COUNT(*) FROM \`$(ls_table surveys)\` WHERE sid = $cut_off")" = 1 ]; then
        if grep -qx 'imported=yes' "$stamp"; then
            log "the demo survey was imported as survey $cut_off before the last start was cut off. It is not imported again"
            survey_id="$cut_off"
        else
            log "an import of the demo survey was cut off and left survey $cut_off unfinished. It is not imported a second" \
                "time. To get the demo survey, delete survey $cut_off in LimeSurvey, then restart: the import runs again."
            exit 0
        fi
    fi
fi

if [ -z "$survey_id" ]; then
    # The id the survey file asks for. LimeSurvey gives the survey another one when that id is taken.
    want_id="$(sed -n 's:.*<sid><!\[CDATA\[\([0-9]\{1,\}\)\]\]></sid>.*:\1:p' "$source_file" | head -n 1)"
    printf 'sid=%s\nstarted=%s\n' "$want_id" "$(ls_now)" > "$stamp" || { log "cannot write $stamp"; exit 1; }

    # The importer can rewrite or delete the file it is given, so it gets a copy.
    work="$(mktemp -d)" || exit 1
    trap 'rm -rf "$work"' EXIT
    cp "$source_file" "$work/demo.lss" || exit 1
    rc=0
    result="$(ls_console importsurvey "$work/demo.lss:$language" 2>&1)" || rc=$?
    survey_id="$(printf '%s' "$result" | tr -d ' \r\n')"
    if [ "$rc" -ne 0 ] || ! [[ "$survey_id" =~ ^[0-9]+$ ]]; then
        log "the demo survey could not be imported (status $rc): $(printf '%s' "$result" | head -n 1 | cut -c1-200)"
        exit 1
    fi
    printf 'sid=%s\nstarted=%s\nimported=yes\n' "$survey_id" "$(ls_now)" > "$stamp" || { log "cannot write $stamp"; exit 1; }
    log "imported the demo survey as survey $survey_id"
    ls_test_pause demo-imported
fi

if [ "${ENABLE_SUITECRM_INTEGRATION:-}" = true ]; then
    settings="$(ls_table plugin_settings)"
    plugin_id="$(ls_sql "SELECT id FROM \`$(ls_table plugins)\` WHERE name = 'SuiteCRMIntegration'")"
    if [[ "$plugin_id" =~ ^[0-9]+$ ]]; then
        if ls_sql "DELETE FROM \`$settings\` WHERE plugin_id = $plugin_id AND model = 'Survey' AND model_id = $survey_id AND \`key\` = 'survey_enabled';
            INSERT INTO \`$settings\` (plugin_id, model, model_id, \`key\`, \`value\`) VALUES ($plugin_id, 'Survey', $survey_id, 'survey_enabled', '\"1\"')"; then
            log "the demo survey's link to SuiteCRM is switched on"
        else
            log "the demo survey's link to SuiteCRM could not be switched on"
        fi
    else
        log "the SuiteCRM plugin is not registered, so the demo survey's link to it stays off"
    fi
fi

printf 'Survey ID: %s\nImported: %s\nSource: %s\n' "$survey_id" "$(ls_now)" "$source_file" > "$marker" || exit 1
rm -f -- "$stamp"
log "done"
exit 0
