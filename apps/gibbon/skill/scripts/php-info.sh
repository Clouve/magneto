#!/bin/bash
# Gibbon DevOps Skill — php-info.sh
#
# Fetches PHP runtime info from the gibbon container, via HTTP, without
# requiring a shell inside that container. Gibbon itself does not expose
# phpinfo(), so this script writes a one-off probe page into the container's
# web root and reads it back.
#
# WAIT — we cannot write to /var/www/html from AI Studio. So this script is
# read-only: it probes what Gibbon itself surfaces (version.php, system
# requirements page, etc.) and prints the subset of ini values we can
# deduce. If you need full phpinfo(), ask the tenant to drop a phpinfo.php
# file into uploads/ temporarily OR escalate to Clouve ops for a
# `kubectl exec` phpinfo dump.
#
# Env vars:
#   GIBBON_HOST (default: gibbon)

set -u

: "${GIBBON_HOST:=gibbon}"

echo "Gibbon container PHP probe via http://${GIBBON_HOST}"
echo

# 1. Version
echo "--- Gibbon version (from DB; no CLI access) ---"
if [ -n "${GIBBON_DB_HOST:-}" ] && [ -n "${GIBBON_DB_PASSWORD:-}" ]; then
  MYSQL_PWD="${GIBBON_DB_PASSWORD}" mysql \
    -h "${GIBBON_DB_HOST}" -u "${GIBBON_DB_USER:-gibbon}" "${GIBBON_DB_NAME:-gibbon}" \
    --skip-ssl -sN -e \
    "SELECT value FROM gibbonSetting WHERE scope='System' AND name='version';" 2>/dev/null
  unset MYSQL_PWD
else
  echo "  (GIBBON_DB_* env not set — cannot query)"
fi
echo

# 2. HTTP headers — tells us PHP version and the Apache config
echo "--- HTTP headers from /index.php ---"
curl -sI "http://${GIBBON_HOST}/index.php" | sed 's/^/  /'
echo

# 3. Server-version header (if Apache is configured to send it)
echo "--- Server header ---"
curl -sI "http://${GIBBON_HOST}/" | grep -i "^server:" | sed 's/^/  /'
echo

# 4. Helpful reminders
echo "--- What we cannot see from AI Studio ---"
echo "  For full phpinfo() output, one of the following:"
echo "    - Tenant drops /var/www/html/uploads/phpinfo.php temporarily"
echo "      and visits it. REMIND THEM TO DELETE IT AFTER."
echo "    - Clouve ops runs 'kubectl exec gibbon -- php -i'."
echo
echo "  For max_input_vars, memory_limit, upload_max_filesize: see the"
echo "  image's php.ini settings at apps/gibbon/image/Dockerfile — they are"
echo "  fixed at build time (max_input_vars=8000, memory_limit=512M,"
echo "  upload_max_filesize=20M, post_max_size=20M)."
echo "  .htaccess at /var/www/html/.htaccess may override max_input_vars."
