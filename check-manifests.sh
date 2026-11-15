#!/bin/bash
# ============================================================================
# Marketplace manifest checks
# ============================================================================
# Static checks on every marketplace manifest (apps/*/ and bundles/*/
# clv-docker-compose*.yml) against the limits the Clouve publish wizard
# enforces, so a manifest that ships here can be uploaded as it is:
#
#   x-clouve-bundle-metadata.appDescription  at most 1000 characters
#     (meso src/Pages/Developer/SubmitApplication/utils/bundleMetadataValidation.js
#      blocks NEXT on the Container Configuration step above that)
#
#   x-clouve-host-aliases (release 4.5.2): the rules thermo and Tropo apply
#   when a listing is published, and the publish wizard's limits on its text.
#   README.md, "Host aliases", explains the field.
#     - It is a list on a service, never at the top level, with at most 3
#       entries.
#     - Only a public Frontend or Backend container takes aliases, and never
#       the AI Assistant (magneto-agent). A container with aliases states
#       isPublic and purpose in its x-clouve-metadata: this script doesn't
#       guess them the way an upload does for a manifest that leaves them out.
#     - Each entry is a mapping of name, appTitle, appDescription, appVersion
#       and adminPath. The icon is uploaded in the wizard, so there is no
#       field for it.
#     - name: 2 to 15 lower-case letters and digits, a letter first. Not a
#       reserved word (RESERVED below, kept in step with thermo's check), and
#       not the name of a container (lower-cased, public or not) or of another
#       alias anywhere in the manifest.
#     - appTitle on every alias and on the container that has them, 2 to 100
#       characters. appDescription 10 to 1000 characters. appVersion and
#       adminPath in the formats the wizard takes for a container's.
#     - No {{ or }} in an alias's appTitle or appDescription, or in the
#       appTitle, appDescription or appVersion of the container that has the
#       aliases: thermo refuses them there, as it may write those texts into a
#       template.
#     - An environment variable of type applicationAliasUrl or
#       applicationAliasHost has a value that names an alias of its own
#       container.
#
#   Every container, with host aliases or without (release 4.5.5):
#     - x-clouve-metadata.containerName, when set, is a DNS-1123 label: 1 to
#       63 lower-case letters, digits and hyphens, starting and ending with a
#       letter or a digit. Kubernetes needs one, and thermo and Tropo refuse
#       any other name. The message never repeats the name.
#     - x-clouve-bundle-metadata.adminPath keeps the format above (the publish
#       wizard and thermo check it on every container), and appVersion the
#       wizard's version format: 1 to 3 numbers with no leading zeros and an
#       optional pre-release part, written as text ("5.3", not 5.3).
#
#   x-clouve-database-password (release 4.5.6): a Database container lets its
#   app user's password be rotated from the deployment's page. README.md,
#   "Database password rotation", explains the field. It goes only on a
#   Database container, never the AI Assistant; it is a mapping with one key,
#   engine: mysql, mariadb or postgres; the service has exactly one of the
#   engine's password variables (MYSQL_PASSWORD or MARIADB_PASSWORD, or
#   POSTGRES_PASSWORD) typed secret, and its user variable (MYSQL_USER or
#   MARIADB_USER, or POSTGRES_USER, which a postgres service may leave out)
#   typed static and not root; and no other password variable of the service
#   has the same secret. thermo and Tropo check the same.
#
#   Lengths are counted as the wizard counts them: in UTF-16 units (an emoji
#   counts 2), after JavaScript's trim(). Only the digits 0 to 9 make a version.
#
#   A manifest that isn't the shape these checks read (a file that isn't valid
#   YAML or UTF-8, a top level, services: block, service, x-clouve-metadata,
#   x-clouve-bundle-metadata or x-clouve-environment-types that isn't a
#   mapping, an environment that is neither a mapping nor a list) gets one
#   message per problem, with no text from the file, and is skipped; the run
#   goes on to the next manifest.
#
# Usage: ./check-manifests.sh     exit 0 = all manifests pass, 1 = violations
# Tests: bash tests/check-manifests.test.sh
# ============================================================================

set -euo pipefail
cd "$(dirname "$0")"

python3 - apps/*/clv-docker-compose*.yml bundles/*/clv-docker-compose*.yml <<'PY'
import re
import sys

import yaml

MAX_APP_DESCRIPTION = 1000

ALIASES_KEY = "x-clouve-host-aliases"
MAX_ALIASES = 3
ALIAS_NAME = re.compile(r"[a-z][a-z0-9]{1,14}", re.ASCII)
RESERVED = ("default", "ai", "icon", "gcp", "aws", "azure", "clv", "magneto-agent", "oauth2-proxy")
ALIAS_FIELDS = ("name", "appTitle", "appDescription", "appVersion", "adminPath")
ALIAS_TYPES = ("applicationAliasUrl", "applicationAliasHost")
AGENT = "magneto-agent"
# The wizard's rules for a container's appVersion (meso src/Utils/versionUtils.js,
# BUNDLE_VERSION_REGEX, at most 64 characters) and adminPath (validateAdminPath).
# re.ASCII: in JavaScript \d is 0-9 only, and in Python it would take any digit.
VERSION = re.compile(r"(0|[1-9]\d*)(\.(0|[1-9]\d*)){0,2}"
                     r"(-((0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?",
                     re.ASCII)
ADMIN_PATH = re.compile(r"/[a-zA-Z0-9\-_./~%]*", re.ASCII)
# A container's name is a DNS-1123 label, as Kubernetes needs: Tropo's rule (thermo/app/internal/validator,
# containerName) and thermo's (containerNameValidation.js). fullmatch, so a trailing line break can't pass.
CONTAINER_NAME = re.compile(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", re.ASCII)
MAX_CONTAINER_NAME = 63
# The characters JavaScript's String.prototype.trim() removes: its white space and line terminators.
JS_TRIMMED = "\t\n\v\f\r " + "".join(map(chr, (0xA0, 0x1680, *range(0x2000, 0x200B),
                                               0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF)))
# x-clouve-database-password (release 4.5.6): the engines strato's rotate_db_password knows, and each engine's password
# and user variables (thermo's databasePasswordValidation.js and Tropo's validator keep the same).
DBP_KEY = "x-clouve-database-password"
DBP_VARIABLES = {
    "mysql": (("MYSQL_PASSWORD", "MARIADB_PASSWORD"), ("MYSQL_USER", "MARIADB_USER")),
    "mariadb": (("MYSQL_PASSWORD", "MARIADB_PASSWORD"), ("MYSQL_USER", "MARIADB_USER")),
    "postgres": (("POSTGRES_PASSWORD",), ("POSTGRES_USER",)),
}
DBP_RULE = " (the database password rule)"
# Blocks of a service that the checks read as mappings.
MAPPING_BLOCKS = ("x-clouve-metadata", "x-clouve-bundle-metadata", "x-clouve-environment-types")

failures = 0


def report(path, service, message):
    global failures
    failures += 1
    where = path if service is None else "%s [%s]" % (path, show(service))
    print("FAIL %s: %s" % (where, message))


def show(text):
    """File text, printable: control and non-ASCII characters come out escaped."""
    return ascii(str(text))[1:-1]


def trimmed(text):
    """The text as the wizard measures it, after JavaScript's trim()."""
    return text.strip(JS_TRIMMED)


def length(text):
    """The length JavaScript gives a string: UTF-16 units, so an emoji counts 2."""
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


def present(value):
    return value is not None and not (isinstance(value, str) and trimmed(value) == "")


def has_braces(value):
    """Whether the text holds {{ or }}: thermo refuses them where it may write the text into a template."""
    return isinstance(value, str) and ("{{" in value or "}}" in value)


def text_between(value, shortest, longest):
    return isinstance(value, str) and shortest <= length(trimmed(value)) <= longest


def good_version(value):
    return isinstance(value, str) and length(trimmed(value)) <= 64 and VERSION.fullmatch(trimmed(value)) is not None


def good_admin_path(value):
    if not isinstance(value, str):
        return False
    path = trimmed(value)
    return ADMIN_PATH.fullmatch(path) is not None and length(path) <= 256 and "//" not in path


def environment(svc):
    """The service's environment as a mapping, from either compose form."""
    env = svc.get("environment") or {}
    if isinstance(env, dict):
        return env
    pairs = {}
    if isinstance(env, list):
        for item in env:
            if isinstance(item, str) and "=" in item:
                key, value = item.split("=", 1)
                pairs[key] = value
    return pairs


def check_alias(problem, service, number, entry, containers, taken):
    label = "host alias %d" % number
    if not isinstance(entry, dict):
        problem(service, "%s must be a mapping with a name" % label)
        return
    if any(key not in ALIAS_FIELDS for key in entry):
        problem(service, "%s has an unknown field; an entry takes name, appTitle, appDescription, appVersion "
                         "and adminPath (the icon is uploaded in the publish wizard)" % label)
    name = entry.get("name")
    if name in RESERVED:
        problem(service, "%s: the name is a reserved word (%s)" % (label, ", ".join(RESERVED)))
    elif not (isinstance(name, str) and ALIAS_NAME.fullmatch(name)):
        problem(service, "%s: the name must be 2 to 15 lower-case letters and digits, starting with a letter" % label)
    elif name in containers:
        problem(service, "%s: a container in this manifest has the same name "
                         "(aliases and containers can't share a name)" % label)
    elif name in taken:
        problem(service, "%s: another host alias in this manifest has the same name" % label)
    else:
        taken.add(name)

    title = entry.get("appTitle")
    if not present(title):
        problem(service, "%s needs an appTitle (the publish wizard asks for one on every alias)" % label)
    elif not text_between(title, 2, 100):
        problem(service, "%s: appTitle must be text of 2 to 100 characters" % label)
    if has_braces(title):
        problem(service, "%s: appTitle can't contain {{ or }}" % label)
    description = entry.get("appDescription")
    if present(description) and not text_between(description, 10, MAX_APP_DESCRIPTION):
        problem(service, "%s: appDescription must be text of 10 to %d characters" % (label, MAX_APP_DESCRIPTION))
    if has_braces(description):
        problem(service, "%s: appDescription can't contain {{ or }}" % label)
    version = entry.get("appVersion")
    if present(version) and not good_version(version):
        problem(service, '%s: appVersion must be a quoted version such as "1.0.0", "2.1" or "3.0.0-beta"' % label)
    admin_path = entry.get("adminPath")
    if present(admin_path) and not good_admin_path(admin_path):
        problem(service, "%s: adminPath must be a path such as /admin: a / first, then letters, digits and "
                         "- _ . ~ %% /, no //, at most 256 characters" % label)


def check_aliases(problem, service, svc, meta, containers, taken):
    entries = svc[ALIASES_KEY]
    if not isinstance(entries, list):
        problem(service, "%s must be a list of entries, each with a name" % ALIASES_KEY)
        return
    if not entries:
        return
    if service == AGENT or meta.get("containerName") == AGENT:
        problem(service, "the AI Assistant (magneto-agent) takes no host aliases")
        return
    owner_ok = True
    if meta.get("isPublic") is not True:
        problem(service, "only a public container takes host aliases (x-clouve-metadata.isPublic is not true)")
        owner_ok = False
    if meta.get("purpose") not in ("Frontend", "Backend"):
        problem(service, "only a Frontend or Backend container takes host aliases (x-clouve-metadata.purpose)")
        owner_ok = False
    if not owner_ok:
        return
    if len(entries) > MAX_ALIASES:
        problem(service, "%s has %d entries; a container takes at most %d" % (ALIASES_KEY, len(entries), MAX_ALIASES))
    bundle_meta = svc.get("x-clouve-bundle-metadata") or {}
    if not present(bundle_meta.get("appTitle")):
        problem(service, "a container with host aliases needs an appTitle in x-clouve-bundle-metadata "
                         "(the publish wizard asks for it)")
    for field in ("appTitle", "appDescription", "appVersion"):
        if has_braces(bundle_meta.get(field)):
            problem(service, "x-clouve-bundle-metadata.%s can't contain {{ or }} "
                             "(Clouve checks it on a container with host aliases)" % field)
    for number, entry in enumerate(entries, 1):
        check_alias(problem, service, number, entry, containers, taken)


def check_container_text(problem, service, bundle_meta):
    """Every container's own admin path and version, with host aliases or without: the publish wizard checks both on
    every container, and thermo the admin path (release 4.5.3)."""
    if present(bundle_meta.get("adminPath")) and not good_admin_path(bundle_meta.get("adminPath")):
        problem(service, "x-clouve-bundle-metadata.adminPath must be a path such as /admin: a / first, then letters, "
                         "digits and - _ . ~ % /, no //, at most 256 characters "
                         "(the publish wizard and Clouve check it on every container)")
    if present(bundle_meta.get("appVersion")) and not good_version(bundle_meta.get("appVersion")):
        problem(service, 'x-clouve-bundle-metadata.appVersion must be a quoted version such as "1.0.0", "2.1" or '
                         '"3.0.0-beta", with no leading zeros (the publish wizard checks it on every container)')


def check_container_name(problem, service, meta):
    """x-clouve-metadata.containerName, when it is set, is a DNS-1123 label. The message never repeats the name."""
    name = meta.get("containerName")
    if name is None:
        return
    if not (isinstance(name, str) and len(name) <= MAX_CONTAINER_NAME and CONTAINER_NAME.fullmatch(name)):
        problem(service, "x-clouve-metadata.containerName must be a DNS-1123 label: 1 to 63 lower-case letters, "
                         "digits and hyphens, starting and ending with a letter or a digit (the container name rule)")


def declared_names(svc):
    """The names the service's alias entries give, refused ones too, so a bad alias gets one message, not two."""
    entries = svc.get(ALIASES_KEY)
    if not isinstance(entries, list):
        return []
    return [entry["name"] for entry in entries if isinstance(entry, dict) and isinstance(entry.get("name"), str)]


def check_alias_types(problem, service, svc):
    types = svc.get("x-clouve-environment-types") or {}
    if not isinstance(types, dict):
        return
    env = environment(svc)
    declared = declared_names(svc)
    for var, kind in types.items():
        if kind in ALIAS_TYPES and env.get(var) not in declared:
            problem(service, "%s (%s) must name a host alias of this container" % (show(var), kind))


def check_database_password(problem, service, svc, meta):
    """x-clouve-database-password (release 4.5.6): on a Database container only, one engine, the engine's password
    variable typed secret and its user variable typed static. The messages repeat no value."""
    if service == AGENT or meta.get("containerName") == AGENT or meta.get("purpose") != "Database":
        problem(service, "%s goes only on a Database container (x-clouve-metadata.purpose), and never on the AI "
                         "Assistant%s" % (DBP_KEY, DBP_RULE))
        return
    block = svc[DBP_KEY]
    if not (isinstance(block, dict) and list(block) == ["engine"] and block["engine"] in DBP_VARIABLES):
        problem(service, "%s names one engine and nothing else: engine: mysql, mariadb or postgres%s" % (DBP_KEY, DBP_RULE))
        return
    passwords, users = DBP_VARIABLES[block["engine"]]
    env = environment(svc)
    types = svc.get("x-clouve-environment-types") or {}
    found = [name for name in passwords if name in env]
    if len(found) != 1 or types.get(found[0]) != "secret" or not present(env.get(found[0])):
        problem(service, "%s needs exactly one of the engine's password variables (MYSQL_PASSWORD or MARIADB_PASSWORD, "
                         "or POSTGRES_PASSWORD), typed secret%s" % (DBP_KEY, DBP_RULE))
        return
    user = next((name for name in users if name in env), None)
    if (user is None and block["engine"] != "postgres") or (
            user is not None and (types.get(user) != "static" or not present(env.get(user)) or env.get(user) == "root")):
        problem(service, "%s needs the engine's user variable (MYSQL_USER or MARIADB_USER, or POSTGRES_USER), typed "
                         "static and not root%s" % (DBP_KEY, DBP_RULE))
        return
    key = env.get(found[0])
    if any(name != found[0] and value == key and types.get(name) in ("secret", "applicationPassword")
           for name, value in env.items()):
        problem(service, "%s: the password's secret can't be another password variable's too%s" % (DBP_KEY, DBP_RULE))


def shape_problems(doc):
    """(service, message) for each block that isn't the shape the checks read. The messages quote no file text."""
    if not isinstance(doc, dict):
        return [(None, "the top level must be a mapping, with the services under services:")]
    services = doc.get("services")
    if services is None:
        return []
    if not isinstance(services, dict):
        return [(None, "services: must be a mapping of service names to their settings")]
    found = []
    for name, svc in services.items():
        if svc is None:
            continue
        if not isinstance(svc, dict):
            found.append((name, "the service must be a mapping of its settings"))
            continue
        for block in MAPPING_BLOCKS:
            if svc.get(block) is not None and not isinstance(svc[block], dict):
                found.append((name, "%s must be a mapping" % block))
        if svc.get("environment") is not None and not isinstance(svc["environment"], (dict, list)):
            found.append((name, "environment must be a mapping or a list"))
    return found


def check_manifest(path, doc):
    def problem(service, message):
        report(path, service, message)

    services = doc.get("services") or {}
    if ALIASES_KEY in doc:
        problem(None, "%s goes on the service that answers on the aliases, not at the top level" % ALIASES_KEY)
    containers = {str(((svc or {}).get("x-clouve-metadata") or {}).get("containerName") or name).lower()
                  for name, svc in services.items()}
    taken = set()
    for name, svc in services.items():
        svc = svc or {}
        meta = svc.get("x-clouve-metadata") or {}
        bundle_meta = svc.get("x-clouve-bundle-metadata") or {}
        desc = trimmed(str(bundle_meta.get("appDescription") or ""))
        if length(desc) > MAX_APP_DESCRIPTION:
            problem(name, "appDescription is %d characters (the publish wizard allows %d)"
                    % (length(desc), MAX_APP_DESCRIPTION))
        check_container_name(problem, name, meta)
        check_container_text(problem, name, bundle_meta)
        if ALIASES_KEY in svc:
            check_aliases(problem, name, svc, meta, containers, taken)
        check_alias_types(problem, name, svc)
        if DBP_KEY in svc:
            check_database_password(problem, name, svc, meta)


for path in sys.argv[1:]:
    try:
        # Bytes, so that PyYAML finds the encoding itself and reports a file that isn't UTF-8 as a YAMLError.
        with open(path, "rb") as f:
            doc = yaml.safe_load(f)
    except yaml.YAMLError as error:
        mark = getattr(error, "problem_mark", None)
        where = " (line %d, column %d)" % (mark.line + 1, mark.column + 1) if mark else ""
        report(path, None, "the file isn't valid YAML%s" % where)
        continue
    doc = {} if doc is None else doc
    shape = shape_problems(doc)
    for service, message in shape:
        report(path, service, message)
    if not shape:
        check_manifest(path, doc)
print(f"{len(sys.argv) - 1} manifests checked, {failures} problem(s)")
sys.exit(1 if failures else 0)
PY
