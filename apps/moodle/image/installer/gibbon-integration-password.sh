#!/bin/bash
# Keeps the Education Kit's Moodle copy of Gibbon's database password in step with the deployment's (release 4.5.6,
# #109). The kit's integration SQL writes it into Moodle's own settings once (auth_db/pass for the sign-in through
# Gibbon, enrol_database/dbpass for the enrolment sync), so after a database password rotation they would keep the old
# one. entrypoint.sh runs this at every start, after update-config.sh. It does nothing unless the kit's integration is
# on (ENABLE_GIBBON_INTEGRATION=true), GIBBON_DB_PASSWORD is set, the integration has run (its marker) and Moodle is
# installed (config.php).
#
# gibbon-integration-password.php does the work as www-data. The password reaches it on stdin, from printf (a shell
# builtin), and PHP starts with an empty environment, so no command line holds the password and neither PHP nor
# Moodle's code sees it or CLOUVE_OPS_PASSWORD there. It prints one line when it changed a setting, and a warning when
# Moodle couldn't be loaded (its database is down, say); the start goes on either way. CLV_AS_WWW is for the tests.
set -u
installed="${INSTALLED_VERSIONS_PATH:-/var/www/html/clouve/installed}"
root="${MOODLE_INSTALL_PATH:-/var/www/html}"
here="$(cd "$(dirname "$0")" && pwd)"

[[ "${ENABLE_GIBBON_INTEGRATION:-}" == "true" ]] || exit 0
[[ -n "${GIBBON_DB_PASSWORD:-}" && -f "$installed/.gibbon-integration-setup" && -f "$root/config.php" ]] || exit 0

as_www="${CLV_AS_WWW:-su -s /bin/sh www-data -c}"
if out="$(printf '%s\n' "$GIBBON_DB_PASSWORD" |
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/var/www $as_www "php $here/gibbon-integration-password.php $root" 2> /dev/null)"; then
  if [[ "$out" == "changed" ]]; then
    echo "✓ Moodle's Gibbon sign-in and enrolment settings now use the deployment's Gibbon database password"
  fi
else
  echo "⚠ Warning: Moodle's Gibbon sign-in and enrolment settings couldn't be checked against the deployment's Gibbon database password (continuing)"
fi
exit 0
