#!/bin/bash

# ============================================================================
# check-manifests.sh Test Script
# ============================================================================
# Runs a copy of check-manifests.sh against manifests written for each case,
# in a temporary directory laid out like this repo (apps/<app>/ and
# bundles/<bundle>/). Each case checks the exit code, the problem count and
# the line that names the rule. It needs python3 with PyYAML, as the script
# does, and nothing else.
#
# What it covers:
#   - good manifests pass: an Open edX-shaped app with three host aliases and
#     the two alias environment types, a bundle with aliases on a Frontend and
#     a Backend container, and manifests with no aliases at all;
#   - each host alias rule refuses a manifest that breaks it: the field's
#     place and shape, at most 3 per container, public Frontend or Backend
#     owners only, never the AI Assistant, the name's format, the reserved
#     words, no clash with a container or another alias, the titles the
#     publish wizard asks for, the size of each text, and the environment
#     types naming an alias of the same container;
#   - the check that was there first (appDescription at most 1000 characters)
#     still works;
#   - every container's own adminPath and appVersion keep the publish
#     wizard's formats, with host aliases or without (Gibbon's 30.0.01 is
#     refused), and a containerName is a DNS-1123 label (release 4.5.5);
#   - a malformed manifest (a block that isn't a mapping, a YAML syntax error,
#     a file that isn't UTF-8) gets a message that names the rule and echoes
#     none of the file's text, and the run goes on to the next manifest;
#   - lengths are counted as the publish wizard counts them (UTF-16 units,
#     after JavaScript's trim, which keeps U+0085), and only ASCII digits make
#     a version.
#
# Usage: bash tests/check-manifests.test.sh [path/to/check-manifests.sh]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SH="${1:-$SCRIPT_DIR/../check-manifests.sh}"

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "This test needs python3 with PyYAML." >&2
  exit 2
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf '  %bPASS%b %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '  %bFAIL%b %s\n' "$RED" "$NC" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
assert_contains() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       wanted: %q\n       output:\n' "$3"
  while IFS= read -r line; do printf '         %s\n' "$line"; done <<< "$2"; fi; }
assert_line() { if grep -qxF -- "$3" <<< "$2"; then pass "$1"; else
  fail "$1"; printf '       wanted the whole line: %q\n       output:\n' "$3"
  while IFS= read -r line; do printf '         %s\n' "$line"; done <<< "$2"; fi; }
count() { grep -cF -- "$2" <<< "$1"; }

# ============================================================================
# Sandbox: a copy of check-manifests.sh, with apps/ and bundles/ beside it
# ============================================================================
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Two manifests with no aliases go in every sandbox, so both of the script's
# globs always match and every run also shows that they add no problem.
cat > "$WORK/plain-app.yml" <<'YAML'
services:
  shop:
    image: registry.example.com/shop
    ports:
      - '80:80'
    environment:
      SHOP_URL: 'http://localhost'
      SHOP_HOST: 'localhost'
      SHOP_DB_HOST: 'shop-mariadb'
    x-clouve-environment-types:
      SHOP_URL: applicationUrl
      SHOP_HOST: applicationHost
      SHOP_DB_HOST: containerReference
    x-clouve-metadata:
      containerName: shop
      purpose: Frontend
      protocol: TCP
      isPublic: true
      memoryBase: 1
      cpuBase: 1
    x-clouve-bundle-metadata:
      appVersion: '1.0.0'
      appTitle: 'Shop'
      appDescription: 'An online shop for small teams.'
      adminPath: /admin
  shop-mariadb:
    image: registry.example.com/shop-mariadb
    x-clouve-metadata:
      containerName: shop-mariadb
      purpose: Database
      protocol: TCP
      isPublic: false
      memoryBase: 1
      cpuBase: 1
YAML

cat > "$WORK/plain-bundle.yml" <<'YAML'
services:
  blog:
    image: registry.example.com/blog
    x-clouve-metadata:
      containerName: blog
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appVersion: '6.4'
      appTitle: 'Blog'
      appDescription: 'Write and publish posts.'
  forum:
    image: registry.example.com/forum
    x-clouve-metadata:
      containerName: forum
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appVersion: '3'
      appTitle: 'Forum'
      appDescription: 'Talk things over with your members.'
YAML

# fresh: a new sandbox in $M, holding the script and the two plain manifests.
fresh() {
  M="$(mktemp -d "$WORK/sandbox.XXXX")"
  cp "$CHECK_SH" "$M/check-manifests.sh"
  chmod +x "$M/check-manifests.sh"
  mkdir -p "$M/apps/plain" "$M/bundles/plain"
  cp "$WORK/plain-app.yml" "$M/apps/plain/clv-docker-compose.yml"
  cp "$WORK/plain-bundle.yml" "$M/bundles/plain/clv-docker-compose.yml"
}

# put <apps|bundles>/<name>: writes stdin to that manifest in the sandbox.
put() { mkdir -p "$M/$1"; cat > "$M/$1/clv-docker-compose.yml"; }

# run_check: runs the sandbox's copy and sets RC and OUT. Call it directly (not
# in $(...)), so the variables reach the assertions.
run_check() {
  local rc=0
  OUT="$(bash "$M/check-manifests.sh" 2>&1)" || rc=$?
  RC="$rc"
}

# aliases_app: prints a manifest with one public Frontend container, "app",
# whose x-clouve-host-aliases list is the YAML read from stdin.
aliases_app() {
  local entries
  entries="$(sed 's/^/      /')"
  cat <<EOF
services:
  app:
    image: registry.example.com/app
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
    x-clouve-host-aliases:
$entries
EOF
}

# refused <label> <expected FAIL line> <expected problem count>: the run that
# just happened failed with that line and exactly that many problems, from
# three manifests (the two plain ones and the case's own).
refused() {
  assert_eq "$1: exits 1" "1" "$RC"
  assert_contains "$1: names the rule" "$OUT" "$2"
  assert_contains "$1: counts $3 problem(s)" "$OUT" "3 manifests checked, $3 problem(s)"
}

APP_FILE="apps/bad/clv-docker-compose.yml"
# The rules every container's own fields are held to (release 4.5.5).
OWN_PATH_RULE="x-clouve-bundle-metadata.adminPath must be a path such as /admin: a / first, then letters, digits and - _ . ~ % /, no //, at most 256 characters (the publish wizard and Clouve check it on every container)"
OWN_VERSION_RULE='x-clouve-bundle-metadata.appVersion must be a quoted version such as "1.0.0", "2.1" or "3.0.0-beta", with no leading zeros (the publish wizard checks it on every container)'
CNAME_RULE="x-clouve-metadata.containerName must be a DNS-1123 label: 1 to 63 lower-case letters, digits and hyphens, starting and ending with a letter or a digit (the container name rule)"

# ============================================================================
# Manifests that pass
# ============================================================================
echo "S1: an Open edX-shaped app and a bundle with host aliases pass"
fresh
put apps/openedx <<'YAML'
services:
  openedx:
    image: registry.example.com/openedx
    ports:
      - '8080:8080'
    environment:
      OPENEDX_URL: 'http://localhost:8080'
      OPENEDX_STUDIO_URL: 'studio'
      OPENEDX_STUDIO_HOST: 'studio'
      OPENEDX_PREVIEW_URL: 'preview'
    x-clouve-environment-types:
      OPENEDX_URL: applicationUrl
      OPENEDX_STUDIO_URL: applicationAliasUrl
      OPENEDX_STUDIO_HOST: applicationAliasHost
      OPENEDX_PREVIEW_URL: applicationAliasUrl
    x-clouve-metadata:
      containerName: openedx
      purpose: Frontend
      protocol: TCP
      isPublic: true
      memoryBase: 6
      cpuBase: 2
    x-clouve-bundle-metadata:
      appVersion: '22.0.3'
      appTitle: 'Learning Platform'
      appDescription: 'Courses, learners and certificates in one place.'
      adminPath: /admin
    x-clouve-host-aliases:
      - name: studio
        appTitle: Course Studio
        appDescription: Build and edit your courses.
        adminPath: /home
      - name: preview
        appTitle: Course Preview
        appVersion: '22.0-rc.1'
        adminPath: /course-authoring/home_v2.html~x%20y
      - name: abcdefghijklmno
        appTitle: 'A name of 15 characters, the longest there is'
        appDescription: ''
        appVersion: ''
        adminPath: ''
  openedx-mysql:
    image: registry.example.com/openedx-mysql
    x-clouve-metadata:
      containerName: openedx-mysql
      purpose: Database
      protocol: TCP
      isPublic: false
      memoryBase: 1
      cpuBase: 0.5
YAML
put bundles/kit <<'YAML'
services:
  portal:
    image: registry.example.com/portal
    x-clouve-metadata:
      containerName: portal
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Portal'
    x-clouve-host-aliases:
      - name: cm
        appTitle: CM
  reports:
    image: registry.example.com/reports
    environment:
      - REPORTS_DASH_URL=dash
      - REPORTS_DB_HOST=reports-db
    x-clouve-environment-types:
      REPORTS_DASH_URL: applicationAliasUrl
      REPORTS_DB_HOST: containerReference
    x-clouve-metadata:
      containerName: reports
      purpose: Backend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Reports'
    x-clouve-host-aliases:
      - name: dash
        appTitle: Dashboards
  reports-db:
    image: registry.example.com/reports-db
    x-clouve-metadata:
      containerName: reports-db
      purpose: Database
      isPublic: false
x-clouve-agent:
  enabled: true
YAML
run_check
assert_eq "exits 0" "0" "$RC"
assert_contains "checks all four manifests and finds nothing" "$OUT" "4 manifests checked, 0 problem(s)"
assert_eq "prints no FAIL line" "0" "$(count "$OUT" "FAIL")"

echo "S2: alias text at the publish wizard's limits passes"
fresh
EDGE_TITLE="$(printf 'T%.0s' {1..100})"
SHORT_DESC="$(printf 'd%.0s' {1..10})"
EDGE_DESC="$(printf 'D%.0s' {1..1000})"
EDGE_VERSION="1.0.0-$(printf 'a%.0s' {1..58})"
EDGE_PATH="/$(printf 'p%.0s' {1..255})"
put apps/edge <<YAML
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Backend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
    x-clouve-host-aliases:
      - name: edge
        appTitle: '$EDGE_TITLE'
        appDescription: '$SHORT_DESC'
        appVersion: '$EDGE_VERSION'
        adminPath: '$EDGE_PATH'
      - name: edge2
        appTitle: 'Ab'
        appDescription: '$EDGE_DESC'
YAML
run_check
assert_eq "a 64-character version is what the test meant" "64" "${#EDGE_VERSION}"
assert_eq "a 256-character admin path is what the test meant" "256" "${#EDGE_PATH}"
assert_eq "exits 0" "0" "$RC"
assert_contains "finds nothing" "$OUT" "3 manifests checked, 0 problem(s)"

# ============================================================================
# Where the field goes and its shape
# ============================================================================
echo "S3: x-clouve-host-aliases at the top level of the file is refused"
fresh
put apps/bad <<'YAML'
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
x-clouve-host-aliases:
  - name: studio
YAML
run_check
refused "top level" "FAIL $APP_FILE: x-clouve-host-aliases goes on the service that answers on the aliases, not at the top level" 1

echo "S4: x-clouve-host-aliases that isn't a list is refused"
fresh
aliases_app <<'YAML' | put apps/bad
studio
YAML
run_check
refused "a plain word" "FAIL $APP_FILE [app]: x-clouve-host-aliases must be a list of entries, each with a name" 1

echo "S5: an entry that isn't a mapping is refused"
fresh
aliases_app <<'YAML' | put apps/bad
- studio
YAML
run_check
refused "a bare name" "FAIL $APP_FILE [app]: host alias 1 must be a mapping with a name" 1

echo "S6: an entry with a field the platform doesn't take is refused"
fresh
aliases_app <<'YAML' | put apps/bad
- name: studio
  appTitle: Studio
  title: Studio
YAML
run_check
refused "a misspelt field" "FAIL $APP_FILE [app]: host alias 1 has an unknown field; an entry takes name, appTitle, appDescription, appVersion and adminPath (the icon is uploaded in the publish wizard)" 1

echo "S7: a fourth alias on one container is refused"
fresh
aliases_app <<'YAML' | put apps/bad
- name: one
  appTitle: One
- name: two
  appTitle: Two
- name: three
  appTitle: Three
- name: four
  appTitle: Four
YAML
run_check
refused "four aliases" "FAIL $APP_FILE [app]: x-clouve-host-aliases has 4 entries; a container takes at most 3" 1

# ============================================================================
# Which containers take aliases
# ============================================================================
echo "S8: aliases on a container that isn't public are refused"
fresh
put apps/bad <<'YAML'
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
  app-worker:
    x-clouve-metadata:
      containerName: app-worker
      purpose: Backend
      isPublic: false
    x-clouve-bundle-metadata:
      appTitle: 'Worker'
    x-clouve-host-aliases:
      - name: jobs
        appTitle: Jobs
YAML
run_check
refused "a private container" "FAIL $APP_FILE [app-worker]: only a public container takes host aliases (x-clouve-metadata.isPublic is not true)" 1

echo "S9: aliases on a public Database, Cache or Message Queue container, or one with no purpose, are refused"
fresh
put apps/bad <<'YAML'
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Database
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
    x-clouve-host-aliases:
      - name: console
        appTitle: Console
  cache:
    x-clouve-metadata:
      containerName: cache
      purpose: Cache
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Cache'
    x-clouve-host-aliases:
      - name: stats
        appTitle: Stats
  queue:
    x-clouve-metadata:
      containerName: queue
      purpose: Message Queue
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Queue'
    x-clouve-host-aliases:
      - name: jobs
        appTitle: Jobs
  nopurpose:
    x-clouve-metadata:
      containerName: nopurpose
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'No purpose'
    x-clouve-host-aliases:
      - name: extra
        appTitle: Extra
YAML
run_check
PURPOSE_RULE="only a Frontend or Backend container takes host aliases (x-clouve-metadata.purpose)"
assert_eq "exits 1" "1" "$RC"
assert_contains "a Database container" "$OUT" "FAIL $APP_FILE [app]: $PURPOSE_RULE"
assert_contains "a Cache container" "$OUT" "FAIL $APP_FILE [cache]: $PURPOSE_RULE"
assert_contains "a Message Queue container" "$OUT" "FAIL $APP_FILE [queue]: $PURPOSE_RULE"
assert_contains "a container with no purpose" "$OUT" "FAIL $APP_FILE [nopurpose]: $PURPOSE_RULE"
assert_contains "four problems" "$OUT" "3 manifests checked, 4 problem(s)"

echo "S10: aliases on the AI Assistant are refused"
fresh
put apps/bad <<'YAML'
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
  magneto-agent:
    x-clouve-metadata:
      containerName: magneto-agent
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'AI Assistant'
    x-clouve-host-aliases:
      - name: chat
        appTitle: Chat
YAML
put apps/bad2 <<'YAML'
services:
  agent:
    x-clouve-metadata:
      containerName: magneto-agent
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'AI Assistant'
    x-clouve-host-aliases:
      - name: chat
        appTitle: Chat
YAML
run_check
AGENT_RULE="the AI Assistant (magneto-agent) takes no host aliases"
assert_eq "exits 1" "1" "$RC"
assert_contains "known by its service key" "$OUT" "FAIL $APP_FILE [magneto-agent]: $AGENT_RULE"
assert_contains "known by its containerName alone" "$OUT" "FAIL apps/bad2/clv-docker-compose.yml [agent]: $AGENT_RULE"
assert_contains "two problems in four manifests" "$OUT" "4 manifests checked, 2 problem(s)"

# ============================================================================
# Names
# ============================================================================
echo "S11: names that aren't 2 to 15 lower-case letters and digits, a letter first, are refused"
fresh
aliases_app <<'YAML' | put apps/bad
- name: Studio
  appTitle: Studio
- name: s
  appTitle: Short
- name: studio-admin
  appTitle: Studio admin
YAML
put apps/bad2 <<'YAML'
services:
  web:
    x-clouve-metadata:
      containerName: web
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Web'
    x-clouve-host-aliases:
      - name: 2fa
        appTitle: Two factor
      - name: abcdefghijklmnop
        appTitle: Sixteen characters
      - appTitle: No name
YAML
run_check
NAME_RULE="the name must be 2 to 15 lower-case letters and digits, starting with a letter"
assert_eq "exits 1" "1" "$RC"
assert_contains "upper case" "$OUT" "FAIL $APP_FILE [app]: host alias 1: $NAME_RULE"
assert_contains "one character" "$OUT" "FAIL $APP_FILE [app]: host alias 2: $NAME_RULE"
assert_contains "a hyphen" "$OUT" "FAIL $APP_FILE [app]: host alias 3: $NAME_RULE"
assert_contains "a digit first" "$OUT" "FAIL apps/bad2/clv-docker-compose.yml [web]: host alias 1: $NAME_RULE"
assert_contains "16 characters" "$OUT" "FAIL apps/bad2/clv-docker-compose.yml [web]: host alias 2: $NAME_RULE"
assert_contains "no name" "$OUT" "FAIL apps/bad2/clv-docker-compose.yml [web]: host alias 3: $NAME_RULE"
assert_contains "six problems in four manifests" "$OUT" "4 manifests checked, 6 problem(s)"

echo "S12: every reserved word is refused as a name"
for word in default ai icon gcp aws azure clv magneto-agent oauth2-proxy; do
  fresh
  printf -- '- name: %s\n  appTitle: Reserved\n' "$word" | aliases_app | put apps/bad
  run_check
  refused "$word" "FAIL $APP_FILE [app]: host alias 1: the name is a reserved word (default, ai, icon, gcp, aws, azure, clv, magneto-agent, oauth2-proxy)" 1
done

echo "S13: a name that is also a container's name is refused, public or not, in any case"
fresh
put bundles/bad <<'YAML'
services:
  gibbon:
    x-clouve-metadata:
      containerName: gibbon
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Gibbon'
    x-clouve-host-aliases:
      - name: moodle
        appTitle: Moodle
      - name: reports
        appTitle: Reports
  moodle:
    x-clouve-metadata:
      containerName: moodle
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Moodle'
  worker:
    x-clouve-metadata:
      containerName: Reports
      purpose: Backend
      isPublic: false
YAML
run_check
CLASH_RULE="a container in this manifest has the same name (aliases and containers can't share a name)"
assert_eq "exits 1" "1" "$RC"
assert_contains "a public container's name" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [gibbon]: host alias 1: $CLASH_RULE"
assert_contains "a private container's name, upper-cased" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [gibbon]: host alias 2: $CLASH_RULE"
assert_contains "an upper-case containerName breaks the container name rule too" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [worker]: $CNAME_RULE"
assert_contains "three problems" "$OUT" "3 manifests checked, 3 problem(s)"

echo "S14: a name used twice in one manifest is refused, on one container or two"
fresh
put bundles/bad <<'YAML'
services:
  gibbon:
    x-clouve-metadata:
      containerName: gibbon
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Gibbon'
    x-clouve-host-aliases:
      - name: admin
        appTitle: Gibbon admin
      - name: admin
        appTitle: Gibbon admin again
  moodle:
    x-clouve-metadata:
      containerName: moodle
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Moodle'
    x-clouve-host-aliases:
      - name: admin
        appTitle: Moodle admin
YAML
run_check
DUP_RULE="another host alias in this manifest has the same name"
assert_eq "exits 1" "1" "$RC"
assert_contains "twice on one container" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [gibbon]: host alias 2: $DUP_RULE"
assert_contains "again on another container" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [moodle]: host alias 1: $DUP_RULE"
assert_eq "the first use is not refused" "0" "$(count "$OUT" "[gibbon]: host alias 1:")"
assert_contains "two problems" "$OUT" "3 manifests checked, 2 problem(s)"

# ============================================================================
# The listing text the publish wizard asks for
# ============================================================================
echo "S15: an alias with no appTitle, or an empty one, is refused"
fresh
aliases_app <<'YAML' | put apps/bad
- name: studio
  appDescription: Build and edit your courses.
- name: preview
  appTitle: '  '
YAML
run_check
TITLE_NEEDED="needs an appTitle (the publish wizard asks for one on every alias)"
assert_eq "exits 1" "1" "$RC"
assert_contains "no appTitle" "$OUT" "FAIL $APP_FILE [app]: host alias 1 $TITLE_NEEDED"
assert_contains "an appTitle of spaces" "$OUT" "FAIL $APP_FILE [app]: host alias 2 $TITLE_NEEDED"
assert_contains "two problems" "$OUT" "3 manifests checked, 2 problem(s)"

echo "S16: a container with aliases and no appTitle of its own is refused"
fresh
put apps/bad <<'YAML'
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appVersion: '1.0.0'
    x-clouve-host-aliases:
      - name: studio
        appTitle: Studio
YAML
run_check
refused "no owner title" "FAIL $APP_FILE [app]: a container with host aliases needs an appTitle in x-clouve-bundle-metadata (the publish wizard asks for it)" 1

echo "S17: every container's own adminPath is held to the rule, with host aliases or without"
fresh
put apps/bad <<'YAML'
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
      adminPath: 'admin'
    x-clouve-host-aliases:
      - name: studio
        appTitle: Studio
YAML
put apps/bad2 <<'YAML'
services:
  web:
    x-clouve-metadata:
      containerName: web
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Web'
      adminPath: 'admin'
YAML
run_check
assert_eq "exits 1" "1" "$RC"
assert_contains "the owner's adminPath with no /" "$OUT" "FAIL $APP_FILE [app]: $OWN_PATH_RULE"
assert_contains "a container without aliases is held to it too" "$OUT" "FAIL apps/bad2/clv-docker-compose.yml [web]: $OWN_PATH_RULE"
assert_eq "one message per container" "1" "$(count "$OUT" "[app]: x-clouve-bundle-metadata.adminPath")"
assert_contains "two problems in four manifests" "$OUT" "4 manifests checked, 2 problem(s)"

echo "S18: {{ or }} in an alias's title or description, or in the title, description or version of its container, is refused"
fresh
put apps/bad <<'YAML'
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My {{App}}'
      appDescription: 'An app whose description ends in }}'
      appVersion: '1.0.0-{{x'
    x-clouve-host-aliases:
      - name: studio
        appTitle: 'Studio {{name}}'
        appDescription: 'Build and edit {{ your courses.'
      - name: preview
        appTitle: 'Preview }}'
        appDescription: 'A description that closes }} here.'
YAML
put apps/bad2 <<'YAML'
services:
  web:
    x-clouve-metadata:
      containerName: web
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Web {{x}}'
      appDescription: 'A description with }} in it.'
      appVersion: '1.0.0-{{x'
YAML
run_check
OWNER_BRACES="can't contain {{ or }} (Clouve checks it on a container with host aliases)"
assert_eq "exits 1" "1" "$RC"
assert_contains "an alias's title" "$OUT" "FAIL $APP_FILE [app]: host alias 1: appTitle can't contain {{ or }}"
assert_contains "an alias's description" "$OUT" "FAIL $APP_FILE [app]: host alias 1: appDescription can't contain {{ or }}"
assert_contains "an alias's title with }} alone" "$OUT" "FAIL $APP_FILE [app]: host alias 2: appTitle can't contain {{ or }}"
assert_contains "an alias's description with }} alone" "$OUT" "FAIL $APP_FILE [app]: host alias 2: appDescription can't contain {{ or }}"
assert_contains "the owner's title" "$OUT" "FAIL $APP_FILE [app]: x-clouve-bundle-metadata.appTitle $OWNER_BRACES"
assert_contains "the owner's description" "$OUT" "FAIL $APP_FILE [app]: x-clouve-bundle-metadata.appDescription $OWNER_BRACES"
assert_contains "the owner's version" "$OUT" "FAIL $APP_FILE [app]: x-clouve-bundle-metadata.appVersion $OWNER_BRACES"
assert_contains "the owner's version also breaks the version rule" "$OUT" "FAIL $APP_FILE [app]: $OWN_VERSION_RULE"
assert_contains "a container without aliases gets the version rule" "$OUT" "FAIL apps/bad2/clv-docker-compose.yml [web]: $OWN_VERSION_RULE"
assert_eq "and no brace message: braces are checked only with aliases" "1" "$(count "$OUT" "apps/bad2/")"
assert_eq "no text from the file is echoed" "0" "$(count "$OUT" "{{name}}")"
assert_contains "nine problems in four manifests" "$OUT" "4 manifests checked, 9 problem(s)"

echo "S19: alias text outside the publish wizard's limits is refused"
fresh
LONG_TITLE="$(printf 'T%.0s' {1..101})"
LONG_DESC="$(printf 'D%.0s' {1..1001})"
LONG_PATH="/$(printf 'p%.0s' {1..256})"
LONG_VERSION="1.0.0-$(printf 'a%.0s' {1..59})"
put apps/bad <<YAML
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
    x-clouve-host-aliases:
      - name: one
        appTitle: 'S'
        appDescription: 'Too short'
      - name: two
        appTitle: '$LONG_TITLE'
        appDescription: '$LONG_DESC'
      - name: three
        appTitle: 12345
        appVersion: 1.0
  web:
    x-clouve-metadata:
      containerName: web
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Web'
    x-clouve-host-aliases:
      - name: four
        appTitle: Four
        appVersion: 'v1.0'
        adminPath: admin
      - name: five
        appTitle: Five
        appVersion: '$LONG_VERSION'
        adminPath: '/admin//panel'
      - name: six
        appTitle: Six
        adminPath: '$LONG_PATH'
YAML
run_check
TITLE_RULE="appTitle must be text of 2 to 100 characters"
DESC_RULE="appDescription must be text of 10 to 1000 characters"
VERSION_RULE='appVersion must be a quoted version such as "1.0.0", "2.1" or "3.0.0-beta"'
PATH_RULE="adminPath must be a path such as /admin: a / first, then letters, digits and - _ . ~ % /, no //, at most 256 characters"
assert_eq "exits 1" "1" "$RC"
assert_contains "a title of 1 character" "$OUT" "FAIL $APP_FILE [app]: host alias 1: $TITLE_RULE"
assert_contains "a description of 9 characters" "$OUT" "FAIL $APP_FILE [app]: host alias 1: $DESC_RULE"
assert_contains "a title of 101 characters" "$OUT" "FAIL $APP_FILE [app]: host alias 2: $TITLE_RULE"
assert_contains "a description of 1001 characters" "$OUT" "FAIL $APP_FILE [app]: host alias 2: $DESC_RULE"
assert_contains "a title that is a number" "$OUT" "FAIL $APP_FILE [app]: host alias 3: $TITLE_RULE"
assert_contains "an unquoted version, read as a number" "$OUT" "FAIL $APP_FILE [app]: host alias 3: $VERSION_RULE"
assert_contains "a version with a v" "$OUT" "FAIL $APP_FILE [web]: host alias 1: $VERSION_RULE"
assert_contains "an admin path with no /" "$OUT" "FAIL $APP_FILE [web]: host alias 1: $PATH_RULE"
assert_eq "a 65-character version is what the test meant" "65" "${#LONG_VERSION}"
assert_contains "a version of 65 characters" "$OUT" "FAIL $APP_FILE [web]: host alias 2: $VERSION_RULE"
assert_contains "an admin path with //" "$OUT" "FAIL $APP_FILE [web]: host alias 2: $PATH_RULE"
assert_contains "an admin path of 257 characters" "$OUT" "FAIL $APP_FILE [web]: host alias 3: $PATH_RULE"
assert_contains "eleven problems" "$OUT" "3 manifests checked, 11 problem(s)"

echo "S20: an admin path with a character outside the allowed set is refused"
fresh
aliases_app <<'YAML' | put apps/bad
- name: studio
  appTitle: Studio
  adminPath: '/admin<script>'
YAML
run_check
refused "angle brackets" "FAIL $APP_FILE [app]: host alias 1: $PATH_RULE" 1

# ============================================================================
# The alias environment types
# ============================================================================
echo "S21: applicationAliasUrl and applicationAliasHost must name an alias of the same container"
fresh
put bundles/bad <<'YAML'
services:
  gibbon:
    environment:
      GIBBON_STUDIO_URL: 'studio'
      GIBBON_OTHER_HOST: 'learn'
      GIBBON_MISSING_URL: 'nothere'
    x-clouve-environment-types:
      GIBBON_STUDIO_URL: applicationAliasUrl
      GIBBON_OTHER_HOST: applicationAliasHost
      GIBBON_MISSING_URL: applicationAliasUrl
      GIBBON_UNSET_HOST: applicationAliasHost
    x-clouve-metadata:
      containerName: gibbon
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Gibbon'
    x-clouve-host-aliases:
      - name: studio
        appTitle: Studio
  moodle:
    environment:
      - MOODLE_STUDIO_URL=studio
    x-clouve-environment-types:
      MOODLE_STUDIO_URL: applicationAliasUrl
    x-clouve-metadata:
      containerName: moodle
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Moodle'
    x-clouve-host-aliases:
      - name: learn
        appTitle: Learn
YAML
run_check
assert_eq "exits 1" "1" "$RC"
assert_eq "the variable naming its own container's alias passes" "0" "$(count "$OUT" "GIBBON_STUDIO_URL")"
assert_contains "naming another container's alias" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [gibbon]: GIBBON_OTHER_HOST (applicationAliasHost) must name a host alias of this container"
assert_contains "naming no alias at all" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [gibbon]: GIBBON_MISSING_URL (applicationAliasUrl) must name a host alias of this container"
assert_contains "a type with no value in environment" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [gibbon]: GIBBON_UNSET_HOST (applicationAliasHost) must name a host alias of this container"
assert_contains "a list-form environment, naming another container's alias" "$OUT" "FAIL bundles/bad/clv-docker-compose.yml [moodle]: MOODLE_STUDIO_URL (applicationAliasUrl) must name a host alias of this container"
assert_contains "four problems" "$OUT" "3 manifests checked, 4 problem(s)"

echo "S22: an alias type on a container with no aliases is refused"
fresh
put apps/bad <<'YAML'
services:
  app:
    environment:
      APP_STUDIO_URL: 'studio'
    x-clouve-environment-types:
      APP_STUDIO_URL: applicationAliasUrl
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
YAML
run_check
refused "no aliases" "FAIL $APP_FILE [app]: APP_STUDIO_URL (applicationAliasUrl) must name a host alias of this container" 1

# ============================================================================
# The check that was there before host aliases
# ============================================================================
echo "S23: an appDescription over 1000 characters is still refused"
fresh
LONG_DESC="$(printf 'D%.0s' {1..1001})"
put apps/bad <<YAML
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
      appDescription: '$LONG_DESC'
YAML
run_check
refused "a long description" "FAIL $APP_FILE [app]: appDescription is 1001 characters (the publish wizard allows 1000)" 1

# ============================================================================
# Text from the file in a message
# ============================================================================
echo "S24: control characters in a service or variable name are printed escaped"
fresh
LONG_DESC="$(printf 'D%.0s' {1..1001})"
put apps/bad <<YAML
services:
  "app\e[31m":
    environment:
      "APP\e[2J_URL": 'studio'
    x-clouve-environment-types:
      "APP\e[2J_URL": applicationAliasUrl
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
      appDescription: '$LONG_DESC'
YAML
run_check
assert_eq "exits 1" "1" "$RC"
assert_contains "the service name, escaped" "$OUT" 'FAIL apps/bad/clv-docker-compose.yml [app\x1b[31m]: appDescription is 1001 characters'
assert_contains "the variable name, escaped" "$OUT" 'APP\x1b[2J_URL (applicationAliasUrl) must name a host alias of this container'
assert_eq "no escape character reaches the terminal" "0" "$(grep -c $'\x1b' <<< "$OUT")"
assert_contains "two problems" "$OUT" "3 manifests checked, 2 problem(s)"

# ============================================================================
# Malformed manifests
# ============================================================================
echo "S25: a malformed manifest gets a message naming the rule, and the run goes on to the next one"
fresh
put apps/m1 <<'YAML'
- services
- SECRET-TEXT-m1
YAML
put apps/m2 <<'YAML'
services:
  - SECRET-TEXT-m2
YAML
put apps/m3 <<'YAML'
services:
  app: 'SECRET-TEXT-m3'
YAML
put apps/m4 <<'YAML'
services:
  app:
    x-clouve-metadata: 'SECRET-TEXT-m4'
YAML
put apps/m5 <<'YAML'
services:
  app:
    x-clouve-metadata:
      containerName: app
    x-clouve-bundle-metadata: 'SECRET-TEXT-m5'
YAML
put apps/m6 <<'YAML'
services:
  app:
    environment: 'SECRET-TEXT-m6'
    x-clouve-environment-types:
      - SECRET-TEXT-m6
YAML
put apps/m7 <<'YAML'
services:
  app:
    image: one
   SECRET-TEXT-m7: two
YAML
printf 'services:\n  app: \xff\xfe SECRET-TEXT-m8\n' | put apps/m8
printf -- '- name: ai\n  appTitle: Reserved\n' | aliases_app | put apps/zz
run_check
assert_eq "exits 1" "1" "$RC"
assert_contains "a list at the top level" "$OUT" "FAIL apps/m1/clv-docker-compose.yml: the top level must be a mapping, with the services under services:"
assert_contains "services as a list" "$OUT" "FAIL apps/m2/clv-docker-compose.yml: services: must be a mapping of service names to their settings"
assert_contains "a service that is a string" "$OUT" "FAIL apps/m3/clv-docker-compose.yml [app]: the service must be a mapping of its settings"
assert_contains "x-clouve-metadata as a string, with no aliases anywhere" "$OUT" "FAIL apps/m4/clv-docker-compose.yml [app]: x-clouve-metadata must be a mapping"
assert_contains "x-clouve-bundle-metadata as a string" "$OUT" "FAIL apps/m5/clv-docker-compose.yml [app]: x-clouve-bundle-metadata must be a mapping"
assert_contains "x-clouve-environment-types as a list" "$OUT" "FAIL apps/m6/clv-docker-compose.yml [app]: x-clouve-environment-types must be a mapping"
assert_contains "environment as a string" "$OUT" "FAIL apps/m6/clv-docker-compose.yml [app]: environment must be a mapping or a list"
assert_contains "a YAML syntax error, by line and column" "$OUT" "FAIL apps/m7/clv-docker-compose.yml: the file isn't valid YAML (line 4, column 4)"
assert_line "a file that isn't UTF-8" "$OUT" "FAIL apps/m8/clv-docker-compose.yml: the file isn't valid YAML"
assert_contains "the manifest after them is still checked" "$OUT" "FAIL apps/zz/clv-docker-compose.yml [app]: host alias 1: the name is a reserved word"
assert_eq "no traceback" "0" "$(count "$OUT" "Traceback")"
assert_eq "no text from the files is echoed" "0" "$(count "$OUT" "SECRET-TEXT")"
assert_contains "ten problems in eleven manifests" "$OUT" "11 manifests checked, 10 problem(s)"

# ============================================================================
# Lengths and digits, counted the way the publish wizard counts them
# ============================================================================
echo "S26: lengths count UTF-16 units after JavaScript's trim, and only ASCII digits make a version"
fresh
emoji() { printf '\\U0001F600%.0s' $(seq "$1"); }   # YAML escapes for N emoji, 2 UTF-16 units each
put apps/bad <<YAML
services:
  app:
    x-clouve-metadata:
      containerName: app
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'My App'
    x-clouve-host-aliases:
      - name: one
        appTitle: "$(emoji 51)"
        appVersion: "1.0-\u0663a"
      - name: two
        appTitle: "$(emoji 50)"
        appDescription: "$(emoji 501)"
      - name: three
        appTitle: "A\uFEFF"
        appVersion: "1\u0660"
  web:
    x-clouve-metadata:
      containerName: web
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appTitle: 'Web'
      appDescription: "$(emoji 501)"
    x-clouve-host-aliases:
      - name: four
        appTitle: Four
        appDescription: "$(emoji 500)"
      - name: five
        appTitle: "\uD800"
      - name: six
        appTitle: "$(emoji 1)"
YAML
run_check
assert_eq "exits 1" "1" "$RC"
assert_contains "51 emoji are 102 units, too long for a title" "$OUT" "FAIL $APP_FILE [app]: host alias 1: $TITLE_RULE"
assert_eq "50 emoji are 100 units, a title that fits" "0" "$(count "$OUT" "[app]: host alias 2: $TITLE_RULE")"
assert_contains "501 emoji are 1002 units, too long for a description" "$OUT" "FAIL $APP_FILE [app]: host alias 2: $DESC_RULE"
assert_contains "a byte order mark is trimmed, as JavaScript trims it" "$OUT" "FAIL $APP_FILE [app]: host alias 3: $TITLE_RULE"
assert_contains "an Arabic-Indic digit after the first one doesn't make a version" "$OUT" "FAIL $APP_FILE [app]: host alias 3: $VERSION_RULE"
assert_contains "nor does one in a pre-release part" "$OUT" "FAIL $APP_FILE [app]: host alias 1: $VERSION_RULE"
assert_contains "a container's description of 501 emoji counts 1002" "$OUT" "FAIL $APP_FILE [web]: appDescription is 1002 characters (the publish wizard allows 1000)"
assert_eq "500 emoji are 1000 units, a description that fits" "0" "$(count "$OUT" "[web]: host alias 1:")"
assert_contains "a lone surrogate counts one unit, with no traceback" "$OUT" "FAIL $APP_FILE [web]: host alias 2: $TITLE_RULE"
assert_eq "one emoji is 2 units, a title that fits" "0" "$(count "$OUT" "[web]: host alias 3:")"
assert_eq "no traceback" "0" "$(count "$OUT" "Traceback")"
assert_contains "seven problems" "$OUT" "3 manifests checked, 7 problem(s)"

echo "S27: every container's own appVersion keeps the publish wizard's rule, with host aliases or without"
fresh
put apps/bad <<'YAML'
services:
  gibbon:
    x-clouve-metadata:
      containerName: gibbon
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appVersion: 30.0.01
      appTitle: Gibbon
  moodle:
    x-clouve-metadata:
      containerName: moodle
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appVersion: 5.3
      appTitle: Moodle
YAML
put apps/good <<'YAML'
services:
  gibbon:
    x-clouve-metadata:
      containerName: gibbon
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appVersion: 30.0.1
      appTitle: Gibbon
  moodle:
    x-clouve-metadata:
      containerName: moodle
      purpose: Frontend
      isPublic: true
    x-clouve-bundle-metadata:
      appVersion: '5.3'
      appTitle: Moodle
YAML
run_check
assert_eq "exits 1" "1" "$RC"
assert_contains "a leading zero (Gibbon's 30.0.01) is refused" "$OUT" "FAIL $APP_FILE [gibbon]: $OWN_VERSION_RULE"
assert_contains "an unquoted 5.3 is a number, not a version" "$OUT" "FAIL $APP_FILE [moodle]: $OWN_VERSION_RULE"
assert_eq "30.0.1 and '5.3' pass" "0" "$(count "$OUT" "apps/good/")"
assert_eq "the value isn't echoed" "0" "$(count "$OUT" "30.0.01")"
assert_contains "two problems in four manifests" "$OUT" "4 manifests checked, 2 problem(s)"

echo "S28: x-clouve-metadata.containerName must be a DNS-1123 label"
fresh
NAME63="$(printf 'a%.0s' {1..63})"
NAME64="$(printf 'b%.0s' {1..64})"
bad_names=("Web" "-web" "web-" "web_1" "web.app" "$NAME64")
{
  echo "services:"
  i=0
  for n in "${bad_names[@]}"; do
    i=$((i + 1))
    printf '  s%d:\n    x-clouve-metadata:\n      containerName: %s\n' "$i" "$n"
  done
  printf '  s7:\n    x-clouve-metadata:\n      containerName: "web\\n"\n'
  printf '  s8:\n    x-clouve-metadata:\n      containerName: 123\n'
  printf '  s9:\n    x-clouve-metadata:\n      containerName: [web]\n'
  printf '  s10:\n    x-clouve-metadata:\n      containerName: web-1\n'
  printf '  s11:\n    x-clouve-metadata:\n      containerName: %s\n' "$NAME63"
  printf '  s12:\n    x-clouve-metadata:\n      purpose: Backend\n'
} | put apps/bad
run_check
assert_eq "exits 1" "1" "$RC"
for i in 1 2 3 4 5 6 7 8 9; do
  assert_contains "refused: s$i" "$OUT" "FAIL $APP_FILE [s$i]: $CNAME_RULE"
done
assert_eq "web-1 passes" "0" "$(count "$OUT" "[s10]")"
assert_eq "63 characters pass" "0" "$(count "$OUT" "[s11]")"
assert_eq "a service with no containerName isn't checked here" "0" "$(count "$OUT" "[s12]")"
assert_eq "no name is echoed" "0" "$(grep -cE "web_1|web\.app|bbbbbbbb|: Web|-web|web-$" <<< "$OUT")"
assert_contains "nine problems" "$OUT" "3 manifests checked, 9 problem(s)"

echo "S29: JavaScript's trim keeps U+0085, so a description of it alone is one character, too short"
fresh
aliases_app <<'YAML' | put apps/bad
- name: studio
  appTitle: Studio
  appDescription: "\x85"
YAML
run_check
refused "a NEL description" "FAIL $APP_FILE [app]: host alias 1: $DESC_RULE" 1

echo "S30: a container that can't take aliases gets that message alone, not the brace rule on top"
fresh
put apps/bad <<'YAML'
services:
  app-worker:
    x-clouve-metadata:
      containerName: app-worker
      purpose: Backend
      isPublic: false
    x-clouve-bundle-metadata:
      appTitle: 'Worker {{x}}'
    x-clouve-host-aliases:
      - name: jobs
        appTitle: Jobs
YAML
run_check
refused "a private container with braces" "FAIL $APP_FILE [app-worker]: only a public container takes host aliases (x-clouve-metadata.isPublic is not true)" 1
assert_eq "no brace message" "0" "$(count "$OUT" "can't contain {{ or }}")"

# ============================================================================
# x-clouve-database-password (release 4.5.6, #109)
# ============================================================================
DBP_CONTAINER="x-clouve-database-password goes only on a Database container (x-clouve-metadata.purpose), and never on the AI Assistant (the database password rule)"
DBP_ENGINE="x-clouve-database-password names one engine and nothing else: engine: mysql, mariadb or postgres (the database password rule)"
DBP_VARIABLE="x-clouve-database-password needs exactly one of the engine's password variables (MYSQL_PASSWORD or MARIADB_PASSWORD, or POSTGRES_PASSWORD), typed secret (the database password rule)"
DBP_USER="x-clouve-database-password needs the engine's user variable (MYSQL_USER or MARIADB_USER, or POSTGRES_USER), typed static and not root (the database password rule)"
DBP_KEY="x-clouve-database-password: the password's secret can't be another password variable's too (the database password rule)"

# db_app <block> [environment] [types] [purpose]: a manifest with an app and its database, "db", whose
# x-clouve-database-password is <block> (YAML, indented under the key).
db_app() {
  local block="$1"
  local env="${2:-      MYSQL_USER: shop
      MYSQL_PASSWORD: shop-db-password
      MYSQL_ROOT_PASSWORD: shop-db-root-password}"
  local types="${3:-      MYSQL_USER: static
      MYSQL_PASSWORD: secret
      MYSQL_ROOT_PASSWORD: secret}"
  local purpose="${4:-Database}"
  cat <<YAML
services:
  shop:
    image: registry.example.com/shop
    environment:
      SHOP_DB_PASSWORD: shop-db-password
    x-clouve-environment-types:
      SHOP_DB_PASSWORD: secret
    x-clouve-metadata:
      containerName: shop
      purpose: Frontend
      isPublic: true
  db:
    image: registry.example.com/shop-db
    environment:
$env
    x-clouve-environment-types:
$types
    x-clouve-metadata:
      containerName: db
      purpose: $purpose
      isPublic: false
    x-clouve-database-password:
$block
YAML
}

echo "S31: a database with a password rotation passes, for each engine"
for engine in mysql mariadb; do
  fresh
  db_app "      engine: $engine" | put apps/shop
  run_check
  assert_eq "$engine: exits 0" "0" "$RC"
  assert_contains "$engine: no problem" "$OUT" "3 manifests checked, 0 problem(s)"
done
fresh
db_app "      engine: postgres" "      POSTGRES_PASSWORD: shop-pg-password" "      POSTGRES_PASSWORD: secret" | put apps/shop
run_check
assert_eq "postgres without a user: exits 0" "0" "$RC"

echo "S32: each database password rule refuses a manifest that breaks it"
DB_FILE="apps/bad/clv-docker-compose.yml"
fresh
db_app "      engine: mysql" "" "" Frontend | put apps/bad
run_check
refused "on a Frontend" "FAIL $DB_FILE [db]: $DBP_CONTAINER" 1
fresh
db_app "      engine: oracle" | put apps/bad
run_check
refused "an engine Clouve doesn't know" "FAIL $DB_FILE [db]: $DBP_ENGINE" 1
fresh
db_app "      engine: mysql
      user: root" | put apps/bad
run_check
refused "another field in the block" "FAIL $DB_FILE [db]: $DBP_ENGINE" 1
fresh
db_app "      - mysql" | put apps/bad
run_check
refused "a block that isn't a mapping" "FAIL $DB_FILE [db]: $DBP_ENGINE" 1
fresh
db_app "      engine: mysql" "      MYSQL_USER: shop" "      MYSQL_USER: static" | put apps/bad
run_check
refused "no password variable" "FAIL $DB_FILE [db]: $DBP_VARIABLE" 1
fresh
db_app "      engine: mysql" "      MYSQL_USER: shop
      MYSQL_PASSWORD: plain-value" "      MYSQL_USER: static
      MYSQL_PASSWORD: static" | put apps/bad
run_check
refused "a password variable that isn't a secret" "FAIL $DB_FILE [db]: $DBP_VARIABLE" 1
assert_eq "the value isn't repeated" "0" "$(count "$OUT" "plain-value")"
fresh
db_app "      engine: mysql" "      MYSQL_PASSWORD: shop-db-password" "      MYSQL_PASSWORD: secret" | put apps/bad
run_check
refused "no user variable" "FAIL $DB_FILE [db]: $DBP_USER" 1
fresh
db_app "      engine: mariadb" "      MYSQL_USER: root
      MYSQL_PASSWORD: shop-db-password" "      MYSQL_USER: static
      MYSQL_PASSWORD: secret" | put apps/bad
run_check
refused "the root user" "FAIL $DB_FILE [db]: $DBP_USER" 1
fresh
db_app "      engine: mysql" "      MYSQL_USER: shop
      MYSQL_PASSWORD: shop-db-root-password
      MYSQL_ROOT_PASSWORD: shop-db-root-password" | put apps/bad
run_check
refused "the root password's secret" "FAIL $DB_FILE [db]: $DBP_KEY" 1
fresh
db_app "      engine: mariadb" "      MYSQL_USER: shop
      MYSQL_PASSWORD: shop-db-password
      MARIADB_PASSWORD: shop-db-password-2" "      MYSQL_USER: static
      MYSQL_PASSWORD: secret
      MARIADB_PASSWORD: secret" | put apps/bad
run_check
refused "both MYSQL_PASSWORD and MARIADB_PASSWORD" "FAIL $DB_FILE [db]: $DBP_VARIABLE" 1
fresh
db_app "      engine: mysql" "      MYSQL_USER: shop
      MYSQL_PASSWORD: shop-db-password" "      MYSQL_USER: userConfigurable
      MYSQL_PASSWORD: secret" | put apps/bad
run_check
refused "a user variable that isn't static" "FAIL $DB_FILE [db]: $DBP_USER" 1
fresh
# The AI Assistant, even one that says it's a Database (x-clouve-metadata.containerName magneto-agent).
db_app "      engine: mysql" | sed 's/containerName: db$/containerName: magneto-agent/' | put apps/bad
run_check
refused "on the AI Assistant" "FAIL $DB_FILE [db]: $DBP_CONTAINER" 1

echo
if [[ $FAILED -eq 0 ]]; then
  printf '%bAll check-manifests.sh tests passed.%b\n' "$GREEN" "$NC"; exit 0
else
  printf '%bcheck-manifests.sh tests FAILED.%b\n' "$RED" "$NC"; exit 1
fi
