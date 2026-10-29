#!/bin/bash

# ============================================================================
# Nextcloud manifest test
# ============================================================================
# Checks the two compose files of apps/nextcloud/ against what the platform and
# this repo's scripts expect of them. It needs python3 with PyYAML (as
# check-manifests.sh does) and nothing else: no image is built and no container
# starts.
#
# clv-docker-compose.yml is the marketplace manifest that the publish wizard
# uploads. The test checks:
#   - the environment: every variable has an x-clouve-environment-types entry,
#     and the names, values and types are the planned ones (section C of the
#     design spec). Every value is a non-empty string (an unquoted true, 80 or
#     {user.firstName} would parse as something else), holds no single quote
#     and no {{, and the only {placeholders} are the platform's own
#     {user.firstName}, {user.lastName} and {user.userEmail}, in single quotes.
#     No name ends in _PORT (the agent drops those);
#   - what the platform adds to the pod by itself (the shared ops password, the
#     agent's settings, the list of sibling containers) appears nowhere in the
#     file, comments included;
#   - the secrets: the database password has the same placeholder on both
#     containers, so the platform generates one value for both, and the root
#     password and the admin password each have a placeholder of their own;
#   - the containers: names with at most one hyphen (plan changes skip names
#     with more), purpose, ports, memory and CPU, and volumes whose mounted
#     names are the x-clouve-volumes names and are declared, at 100 GB and 10 GB;
#   - the probe: the Command check, with the same numbers in
#     x-clouve-healthcheck and in the compose healthcheck, and none for the
#     database;
#   - the listing: appVersion (also the Nextcloud version that image/Dockerfile
#     pins), appTitle, adminPath, and an appDescription of 10 to 1000
#     characters (the wizard's limits) with no double quote, single quote, {{
#     or }}, no curly quote or dash, and the AI-usage, no-API-key and
#     data-ownership sentences that the other agent listings carry;
#   - x-clouve-agent: enabled, the nextcloud plugin, a 600 s sidecar pull;
#   - no key is repeated inside a mapping (a YAML parser keeps the last one
#     without a word).
#
# docker-compose.yml is the local run behind ./start.sh nextcloud and
# ./test.sh apps/nextcloud. The test checks:
#   - the order of the services: nextcloud first, then the database, the agent
#     last. test.sh falls back to the first container_name that is not a
#     database, and finds that name by grepping the file, so container_name:
#     must be on exactly three lines and in no comment;
#   - the database's container name has mariadb in it and publishes no port
#     (test.sh takes the running container with the lowest host port);
#   - the app: TEST_DOMAIN and TEST_PORT in its URL and port, the local admin
#     login, and the same health check as the manifest (the Docker health
#     status of nextcloud_app is what the local run waits for);
#   - CLOUVE_OPS_PASSWORD, with one value, on all three services;
#   - the agent: its login, the plugin, the model-access pass-through variables,
#     both CLV_SIDECAR_* lists naming nextcloud and nextcloud-mariadb, its port
#     and its four volumes;
#   - the two files agree: the same variables for the app and the database, and
#     the same skills URL.
#
# README.md has one check of its own: it must still hold the line
# "## A half-finished first install". The before-starting hook's refusal
# message sends operators to that heading, and nothing else would notice a
# rename.
#
# The files come from apps/nextcloud/ in this repo. NC_APP_DIR points the test
# at another folder with the same layout (the two compose files,
# image/Dockerfile and README.md), for trying it on a copy that is broken on
# purpose.
#
# Usage: bash tests/nextcloud-manifest.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="${NC_APP_DIR:-$REPO_DIR/apps/nextcloud}"

if ! python3 -I -c 'import yaml' 2>/dev/null; then
  echo "This test needs python3 with PyYAML." >&2
  exit 2
fi

python3 -I - "$APP_DIR/clv-docker-compose.yml" "$APP_DIR/docker-compose.yml" "$APP_DIR/image/Dockerfile" \
  "$APP_DIR/README.md" <<'PY'
import os
import re
import sys

import yaml

MANIFEST, COMPOSE, DOCKERFILE, README = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

GREEN, RED, RESET = "\033[0;32m", "\033[0;31m", "\033[0m"
checks = 0
failed = 0


def ok(label):
    global checks
    checks += 1
    print("  %sPASS%s %s" % (GREEN, RESET, label))


def bad(label, *details):
    global checks, failed
    checks += 1
    failed += 1
    print("  %sFAIL%s %s" % (RED, RESET, label))
    for detail in details:
        for line in str(detail).splitlines():
            print("       " + line)


def check(label, condition, *details):
    if condition:
        ok(label)
    else:
        bad(label, *details)
    return bool(condition)


def same(actual, expected):
    """Equal, and of the same type all the way down: True is not 1, and '80' is not 80."""
    if isinstance(expected, dict):
        return (type(actual) is dict and set(actual) == set(expected)
                and all(same(actual[key], value) for key, value in expected.items()))
    if isinstance(expected, list):
        return (type(actual) is list and len(actual) == len(expected)
                and all(same(a, e) for a, e in zip(actual, expected)))
    return type(actual) is type(expected) and actual == expected


def expect(label, actual, expected):
    return check(label, same(actual, expected),
                 "expected: %r" % (expected,), "actual:   %r" % (actual,))


class StrictLoader(yaml.SafeLoader):
    """A SafeLoader that refuses a key repeated inside one mapping."""


def _no_repeated_keys(loader, node, deep=False):
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            hash(key)
        except TypeError:
            continue
        if key in seen:
            raise yaml.constructor.ConstructorError(
                "while reading a mapping", node.start_mark,
                "the key %r appears twice" % (key,), key_node.start_mark)
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_repeated_keys)


def load(path):
    """Read and parse one file. Gives (text, document), or (None, None) after reporting why not."""
    name = os.path.basename(path)
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        bad(name + " can be read", e)
        return None, None
    try:
        doc = yaml.load(text, Loader=StrictLoader)
    except yaml.YAMLError as e:
        bad(name + " is YAML with no repeated key", e)
        return text, None
    if not isinstance(doc, dict):
        bad(name + " is a YAML mapping", "it holds a " + type(doc).__name__)
        return text, None
    ok(name + " is YAML with no repeated key")
    return text, doc


# --- what the files should hold ---------------------------------------------------------------------------------------

APP, DB, AGENT = "nextcloud", "nextcloud-mariadb", "magneto-agent"
PROBE = "/clouve/nextcloud/installer/healthcheck.sh"
SKILLS_URL = "https://github.com/Clouve/magneto-skills.git?plugins=nextcloud"
OPS_PASSWORD = "clouve_ops_dev_password"

# The secret placeholders. The platform makes one random value per distinct placeholder.
DB_PASSWORD = "nextcloud-mariadb-password"
ROOT_PASSWORD = "nextcloud-mariadb-root-password"
ADMIN_PASSWORD = "nextcloud-admin-password"

# Section C of the design spec: variable -> (value, type).
MANIFEST_ENV = {
    APP: {
        "NEXTCLOUD_DB_HOST": ("nextcloud-mariadb", "containerReference"),
        "NEXTCLOUD_DB_NAME": ("nextcloud", "static"),
        "NEXTCLOUD_DB_USER": ("nextcloud", "static"),
        "NEXTCLOUD_DB_PASSWORD": (DB_PASSWORD, "secret"),
        "NEXTCLOUD_URL": ("http://localhost", "applicationUrl"),
        "NEXTCLOUD_ADMIN_USER": ("{user.firstName}_{user.lastName}", "applicationUsername"),
        "NEXTCLOUD_ADMIN_EMAIL": ("{user.userEmail}", "applicationUsername"),
        "NEXTCLOUD_ADMIN_PASSWORD": (ADMIN_PASSWORD, "applicationPassword"),
    },
    DB: {
        "MYSQL_DATABASE": ("nextcloud", "static"),
        "MYSQL_USER": ("nextcloud", "static"),
        "MYSQL_PASSWORD": (DB_PASSWORD, "secret"),
        "MYSQL_ROOT_PASSWORD": (ROOT_PASSWORD, "secret"),
    },
}

# The only {placeholders} the platform fills in when it reads a manifest value.
PLATFORM_PLACEHOLDERS = {"{user.firstName}", "{user.lastName}", "{user.userEmail}"}

# The platform adds these to the pod, so none of them belongs in the manifest.
PLATFORM_ADDED = re.compile(r"CLOUVE_OPS_PASSWORD|MAGNETO_AGENT_|CLV_SIDECAR_")

MANIFEST_SERVICE_KEYS = {
    APP: ["environment", "healthcheck", "image", "ports", "volumes", "x-clouve-bundle-metadata",
          "x-clouve-environment-types", "x-clouve-healthcheck", "x-clouve-metadata", "x-clouve-volumes"],
    DB: ["environment", "image", "ports", "volumes", "x-clouve-environment-types", "x-clouve-healthcheck",
         "x-clouve-metadata", "x-clouve-volumes"],
}
MANIFEST_PORTS = {APP: ["80:80"], DB: ["3306:3306"]}

MANIFEST_METADATA = {
    APP: {"containerName": "nextcloud", "purpose": "Frontend", "protocol": "TCP", "isPublic": True,
          "memoryBase": 2, "cpuBase": 1},
    DB: {"containerName": "nextcloud-mariadb", "purpose": "Database", "protocol": "TCP", "isPublic": False,
         "memoryBase": 1, "cpuBase": 0.5},
}

# service -> (volume name, mount path, size in GB, description)
MANIFEST_VOLUME = {
    APP: ("nextclouddata", "/var/www/html", 100, "Nextcloud code, configuration, apps and users' files"),
    DB: ("dbdata", "/var/lib/mysql", 10, "Nextcloud's MariaDB database files"),
}

# The probe: Moodle's budget (about 8.5 minutes before a restart), the same numbers twice.
MANIFEST_PROBE = {"enabled": True, "type": "Command", "path": PROBE, "port": 80, "initialDelay": 60,
                  "interval": 30, "timeout": 15, "failureThreshold": 15, "successThreshold": 1}
DB_PROBE = {"enabled": False, "type": "TCP", "path": "/", "port": 3306, "initialDelay": 30, "interval": 10,
            "timeout": 5, "failureThreshold": 3, "successThreshold": 1}
COMPOSE_PROBE = {"test": ["CMD", PROBE], "interval": "30s", "timeout": "15s", "retries": 15, "start_period": "60s"}

BUNDLE_KEYS = ["adminPath", "appDescription", "appTitle", "appVersion"]

# The sentences that the AI-enabled listings carry (apps/wordpress/clv-docker-compose.yml), as far as a
# description without apostrophes allows.
DESCRIPTION_PHRASES = [
    # Nextcloud's own sentence: the first start installs the three apps only when the app store answers, so the
    # listing promises them only on that condition.
    "The first start installs the Calendar, Contacts and Team folders apps when the Nextcloud app store is reachable.",
    "includes an AI usage allowance",
    "buy more usage at any time",
    "switch the assistant off and on again",
    "an API key or an account with an AI provider",
    "The tenant owns the Nextcloud data; Clouve hosts the containers.",
]

AGENT_BLOCK = {"enabled": True,
               "skills": {"url": SKILLS_URL, "git": {"token": "", "username": ""}},
               "advanced": {"sidecarPullTimeout": 600}}

COMPOSE_NAMES = {APP: "nextcloud_app", DB: "nextcloud_mariadb", AGENT: "nextcloud_magneto_agent"}
COMPOSE_IMAGES = {APP: "r.clv.zone/e2eorg/nextcloud", DB: "r.clv.zone/e2eorg/nextcloud-mariadb",
                  AGENT: "r.clv.zone/clouveinc/magneto-agent"}

# Values that are fixed. The database passwords are left out: they are checked for being set, for being one value
# on the app and the database, and for the root password being another.
COMPOSE_ENV = {
    APP: {
        "NEXTCLOUD_DB_HOST": "nextcloud-mariadb",
        "NEXTCLOUD_DB_NAME": "nextcloud",
        "NEXTCLOUD_DB_USER": "nextcloud",
        "NEXTCLOUD_URL": "http://${TEST_DOMAIN:-t1.test.clv}:${TEST_PORT:-8080}",
        "NEXTCLOUD_ADMIN_USER": "admin",
        "NEXTCLOUD_ADMIN_PASSWORD": "Admin@123",
        "NEXTCLOUD_ADMIN_EMAIL": "admin@example.com",
        "CLOUVE_OPS_PASSWORD": OPS_PASSWORD,
    },
    DB: {
        "MYSQL_DATABASE": "nextcloud",
        "MYSQL_USER": "nextcloud",
        "CLOUVE_OPS_PASSWORD": OPS_PASSWORD,
    },
    AGENT: {
        "MAGNETO_AGENT_USERNAME": "admin",
        "MAGNETO_AGENT_PASSWORD": "Admin@123",
        "MAGNETO_AGENT_ROOT_PASSWORD": "Root@123",
        "MAGNETO_AGENT_LLM_BASE_URL": "${MAGNETO_AGENT_LLM_BASE_URL:-}",
        "MAGNETO_AGENT_LLM_KEY": "${MAGNETO_AGENT_LLM_KEY:-}",
        "ANTHROPIC_API_KEY": "${ANTHROPIC_API_KEY:-}",
        "MAGNETO_AGENT_SKILLS": SKILLS_URL,
        "CLOUVE_OPS_PASSWORD": OPS_PASSWORD,
        "CLV_SIDECAR_HOSTS": "nextcloud,nextcloud-mariadb",
        "CLV_SIDECAR_NAMESPACES": "nextcloud,nextcloud-mariadb",
    },
}
COMPOSE_PORTS = {APP: ["${TEST_PORT:-8080}:80"], AGENT: ["${MAGNETO_AGENT_PORT:-8081}:80"]}
COMPOSE_MOUNTS = {
    APP: ["nextcloud_data:/var/www/html"],
    DB: ["db_data:/var/lib/mysql"],
    AGENT: ["magneto_agent_home:/home", "magneto_agent_usr:/usr", "magneto_agent_opt:/opt",
            "magneto_agent_var:/var"],
}
COMPOSE_DB_PROBE = {"test": ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"],
                    "interval": "10s", "timeout": "5s", "retries": 5}
NETWORK = "nextcloud_network"


# --- clv-docker-compose.yml ----------------------------------------------------------------------------------------

def env_of(svc):
    """The environment mapping of a service, or an empty one when it is missing or not a mapping."""
    env = svc.get("environment")
    return env if isinstance(env, dict) else {}


def check_manifest_env(prefix, svc, planned):
    env, types = svc.get("environment"), svc.get("x-clouve-environment-types")
    if not (isinstance(env, dict) and isinstance(types, dict)):
        bad(prefix + "environment and x-clouve-environment-types are mappings",
            "environment is a %s, x-clouve-environment-types is a %s" % (type(env).__name__, type(types).__name__))
        return
    check(prefix + "every variable has an x-clouve-environment-types entry, and no entry is left over",
          set(env) == set(types),
          "no type for: %s" % sorted(set(env) - set(types)),
          "no variable for: %s" % sorted(set(types) - set(env)))
    expect(prefix + "the types are the planned ones", types, {k: t for k, (_, t) in planned.items()})
    expect(prefix + "the names and values are the planned ones", env, {k: v for k, (v, _) in planned.items()})

    problems = []
    for key, value in env.items():
        if not isinstance(value, str):
            problems.append("%s is %r, a %s and not a string" % (key, value, type(value).__name__))
            continue
        if not value.strip():
            problems.append("%s is empty" % key)
            continue
        if "'" in value:
            problems.append("%s holds a single quote" % key)
        if "{{" in value:
            problems.append("%s holds {{" % key)
        for placeholder in re.findall(r"\{[^{}]*\}", value):
            if placeholder not in PLATFORM_PLACEHOLDERS:
                problems.append("%s holds %s, which is not one of the platform's placeholders" % (key, placeholder))
        if "{" in re.sub(r"\{[^{}]*\}", "", value) or "}" in re.sub(r"\{[^{}]*\}", "", value):
            problems.append("%s holds a brace that is not part of a {placeholder}" % key)
    check(prefix + "every value is a non-empty string with no single quote, no {{ and only the platform's placeholders",
          not problems, *problems)
    check(prefix + "no variable name ends in _PORT (the agent drops those)",
          not [k for k in env if k.endswith("_PORT")], [k for k in env if k.endswith("_PORT")])


def check_manifest_volume(prefix, svc, doc, name):
    volume, path, size, description = MANIFEST_VOLUME[name]
    mounts, listed = svc.get("volumes"), svc.get("x-clouve-volumes")
    expect(prefix + "the volume mount", mounts, [volume + ":" + path])
    expect(prefix + "x-clouve-volumes names that volume, with its size and description", listed,
           [{"name": volume, "size": size, "description": description}])
    if isinstance(mounts, list) and isinstance(listed, list) and all(isinstance(v, dict) for v in listed):
        mounted = [m.split(":")[0] for m in mounts if isinstance(m, str)]
        named = [v.get("name") for v in listed]
        check(prefix + "the mounted volume and the x-clouve-volumes entry have the same name",
              mounted == named, "mounted: %s" % mounted, "x-clouve-volumes: %s" % named)
        declared = doc.get("volumes")
        check(prefix + "the volume is declared at the top level",
              isinstance(declared, dict) and all(m in declared for m in mounted),
              "declared: %s" % (sorted(declared) if isinstance(declared, dict) else declared))


def check_description(description):
    if not isinstance(description, str):
        bad("appDescription is a string", "it is a %s" % type(description).__name__)
        return
    length = len(description.strip())
    check("appDescription is 10 to 1000 characters (the wizard's limits)", 10 <= length <= 1000,
          "it is %d characters" % length)
    found = [token for token in ('"', "'", "{{", "}}") if token in description]
    check("appDescription holds no double quote, single quote, {{ or }}", not found, "found: %s" % found)
    # En dash, em dash and the four curly quotes, as code points so that this file stays plain ASCII.
    curly = "".join(chr(code) for code in (0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D))
    found = sorted(set(re.findall("[" + curly + "]", description)))
    check("appDescription holds no curly quote, em dash or en dash", not found,
          "found: %s" % [hex(ord(c)) for c in found])
    check("appDescription is one line", "\n" not in description.strip())
    for phrase in DESCRIPTION_PHRASES:
        check("appDescription says: " + phrase, phrase in description)


def check_manifest(text, doc):
    expect("top level holds version, services, volumes and x-clouve-agent, and nothing else",
           sorted(doc), ["services", "version", "volumes", "x-clouve-agent"])
    expect("the compose version is 3.8", doc.get("version"), "3.8")

    found = sorted(set(PLATFORM_ADDED.findall(text)))
    check("nothing the platform adds to the pod appears in the file: "
          "CLOUVE_OPS_PASSWORD, MAGNETO_AGENT_*, CLV_SIDECAR_* (comments included)", not found, "found: %s" % found)
    lines = [line.strip() for line in text.splitlines()]
    for line in ("NEXTCLOUD_ADMIN_USER: '{user.firstName}_{user.lastName}'",
                 "NEXTCLOUD_ADMIN_EMAIL: '{user.userEmail}'"):
        check("the platform placeholders are in single quotes, so YAML reads a string: " + line, line in lines)

    services = doc.get("services")
    if not isinstance(services, dict):
        bad("services is a mapping", "it is %r" % (services,))
        return
    if not expect("two services, the app first", list(services), [APP, DB]):
        return
    for name in (APP, DB):
        if not isinstance(services[name], dict):
            bad(name + " is a mapping", "it is %r" % (services[name],))
            return

    for name in (APP, DB):
        svc = services[name]
        prefix = name + ": "
        expect(prefix + "keys", sorted(svc), sorted(MANIFEST_SERVICE_KEYS[name]))
        expect(prefix + "image", svc.get("image"), name)
        expect(prefix + "ports", svc.get("ports"), MANIFEST_PORTS[name])
        check_manifest_env(prefix, svc, MANIFEST_ENV[name])
        expect(prefix + "x-clouve-metadata", svc.get("x-clouve-metadata"), MANIFEST_METADATA[name])
        container = (svc.get("x-clouve-metadata") or {}).get("containerName")
        check(prefix + "the container name has at most one hyphen (plan changes skip names with more)",
              isinstance(container, str) and container.count("-") <= 1 and name.count("-") <= 1,
              "container name %r, service name %r" % (container, name))
        check_manifest_volume(prefix, svc, doc, name)

    secrets = [(name, key) for name in (APP, DB) for key, (_, kind) in MANIFEST_ENV[name].items()
               if kind in ("secret", "applicationPassword")]
    values = {pair: env_of(services[pair[0]]).get(pair[1]) for pair in secrets}
    check("the database password has the same placeholder on both containers: " + DB_PASSWORD,
          values[(APP, "NEXTCLOUD_DB_PASSWORD")] == DB_PASSWORD == values[(DB, "MYSQL_PASSWORD")],
          "nextcloud: %r, nextcloud-mariadb: %r" % (values[(APP, "NEXTCLOUD_DB_PASSWORD")],
                                                    values[(DB, "MYSQL_PASSWORD")]))
    check("the root password and the admin password each have a placeholder of their own",
          len(set(map(repr, values.values()))) == 3, "placeholders: %s" % sorted(map(repr, values.values())))

    expect("nextcloud: x-clouve-healthcheck is the Command probe", services[APP].get("x-clouve-healthcheck"),
           MANIFEST_PROBE)
    expect("nextcloud: the compose healthcheck runs the same script, with the same numbers",
           services[APP].get("healthcheck"), COMPOSE_PROBE)
    expect("nextcloud-mariadb: x-clouve-healthcheck is disabled, as in the other apps",
           services[DB].get("x-clouve-healthcheck"), DB_PROBE)

    bundle = services[APP].get("x-clouve-bundle-metadata")
    if isinstance(bundle, dict):
        expect("x-clouve-bundle-metadata holds appVersion, appTitle, appDescription and adminPath, and nothing else",
               sorted(bundle), BUNDLE_KEYS)
        expect("appVersion", bundle.get("appVersion"), "35.0.2")
        expect("appTitle", bundle.get("appTitle"), "Nextcloud with AI Assistant")
        expect("adminPath", bundle.get("adminPath"), "/settings/admin")
        check_description(bundle.get("appDescription"))
        try:
            with open(DOCKERFILE, encoding="utf-8") as f:
                dockerfile = f.read()
        except OSError as e:
            bad("image/Dockerfile can be read, to compare the Nextcloud version", e)
        else:
            pinned = re.search(r"(?m)^FROM\s+(?:[\w.\-]+/)*nextcloud:([0-9][0-9.]*)-apache\s*$", dockerfile)
            check("appVersion is the Nextcloud version that image/Dockerfile pins",
                  bool(pinned) and pinned.group(1) == bundle.get("appVersion"),
                  "Dockerfile pins %s, appVersion is %r" % (pinned.group(1) if pinned else "no nextcloud:*-apache",
                                                           bundle.get("appVersion")))
    else:
        bad("nextcloud: x-clouve-bundle-metadata is a mapping", "it is %r" % (bundle,))

    expect("the volumes are declared, with the local driver", doc.get("volumes"),
           {"nextclouddata": {"driver": "local"}, "dbdata": {"driver": "local"}})
    expect("x-clouve-agent is enabled, with the nextcloud plugin and a 600 s sidecar pull",
           doc.get("x-clouve-agent"), AGENT_BLOCK)


# --- docker-compose.yml --------------------------------------------------------------------------------------------

def check_compose(text, doc, manifest):
    services = doc.get("services")
    if not isinstance(services, dict):
        bad("services is a mapping", "it is %r" % (services,))
        return
    if not expect("three services: nextcloud first, then the database, magneto-agent last",
                  list(services), [APP, DB, AGENT]):
        return
    for name in (APP, DB, AGENT):
        if not isinstance(services[name], dict):
            bad(name + " is a mapping", "it is %r" % (services[name],))
            return

    # test.sh and start.sh read this file with grep, not as YAML.
    lines = text.splitlines()
    named = [line for line in lines if "container_name:" in line]
    check("container_name: is on exactly three lines, and on no comment (test.sh finds the app by grepping for it)",
          len(named) == 3 and not any(line.lstrip().startswith("#") for line in named), *named)
    paths = [line for line in lines if re.match(r"^\s*-\s+[./]", line)]
    check("no line starts with a host path (./start.sh --cleanup removes the paths it finds that way)",
          not paths, *paths)

    names = [services[n].get("container_name") for n in (APP, DB, AGENT)]
    expect("container names", names, [COMPOSE_NAMES[n] for n in (APP, DB, AGENT)])
    first_app = next((n for n in names if isinstance(n, str)
                      and not re.search(r"mariadb|mysql|postgres|_db|redis", n)), None)
    expect("test.sh's fallback, the first container_name that is not a database, is the app", first_app,
           COMPOSE_NAMES[APP])
    check("the database container name has mariadb in it", isinstance(names[1], str) and "mariadb" in names[1],
          "it is %r" % (names[1],))
    check("the database publishes no port (test.sh takes the running container with the lowest host port)",
          "ports" not in services[DB], "ports: %r" % (services[DB].get("ports"),))

    for name in (APP, DB, AGENT):
        svc = services[name]
        prefix = name + ": "
        expect(prefix + "image", svc.get("image"), COMPOSE_IMAGES[name])
        expect(prefix + "restart policy", svc.get("restart"), "unless-stopped")
        expect(prefix + "network", svc.get("networks"), [NETWORK])
        expect(prefix + "volume mounts", svc.get("volumes"), COMPOSE_MOUNTS[name])
        if name in COMPOSE_PORTS:
            expect(prefix + "published port", svc.get("ports"), COMPOSE_PORTS[name])

        env = svc.get("environment")
        if not isinstance(env, dict):
            bad(prefix + "environment is a mapping", "it is %r" % (env,))
            continue
        check(prefix + "no variable name ends in _PORT (the agent drops those)",
              not [k for k in env if k.endswith("_PORT")], [k for k in env if k.endswith("_PORT")])
        passwords = ("NEXTCLOUD_DB_PASSWORD", "MYSQL_PASSWORD", "MYSQL_ROOT_PASSWORD")
        expect(prefix + "environment (the database passwords aside)",
               {k: v for k, v in env.items() if k not in passwords}, COMPOSE_ENV[name])

    app_env, db_env = env_of(services[APP]), env_of(services[DB])
    check("the app and the database use one database password, which is not empty",
          isinstance(app_env.get("NEXTCLOUD_DB_PASSWORD"), str) and app_env["NEXTCLOUD_DB_PASSWORD"].strip() != ""
          and app_env.get("NEXTCLOUD_DB_PASSWORD") == db_env.get("MYSQL_PASSWORD"),
          "app: %s, database: %s" % ("set" if app_env.get("NEXTCLOUD_DB_PASSWORD") else "missing",
                                    "set" if db_env.get("MYSQL_PASSWORD") else "missing"))
    check("the database root password is set and differs from the database password",
          isinstance(db_env.get("MYSQL_ROOT_PASSWORD"), str) and db_env["MYSQL_ROOT_PASSWORD"].strip() != ""
          and db_env.get("MYSQL_ROOT_PASSWORD") != db_env.get("MYSQL_PASSWORD"),
          "root password: %s" % ("set" if db_env.get("MYSQL_ROOT_PASSWORD") else "missing"))
    ops = [env_of(services[n]).get("CLOUVE_OPS_PASSWORD") for n in (APP, DB, AGENT)]
    check("CLOUVE_OPS_PASSWORD is set, to one value, on all three services",
          all(isinstance(v, str) and v for v in ops) and len(set(ops)) == 1, "set on: %s" % [bool(v) for v in ops])

    sidecar = env_of(services[AGENT])
    for key in ("CLV_SIDECAR_HOSTS", "CLV_SIDECAR_NAMESPACES"):
        value = sidecar.get(key)
        check(key + " names the app and the database, which are services of this file",
              isinstance(value, str) and value.split(",") == [APP, DB] and all(n in services for n in value.split(",")),
              "it is %r" % (value,))

    expect("nextcloud: the Docker health check runs the same script as the manifest's",
           services[APP].get("healthcheck"), COMPOSE_PROBE)
    expect("nextcloud-mariadb: the Docker health check is healthcheck.sh --connect --innodb_initialized",
           services[DB].get("healthcheck"), COMPOSE_DB_PROBE)

    declared = doc.get("volumes")
    mounted = sorted({m.split(":")[0] for n in (APP, DB, AGENT) for m in services[n].get("volumes") or []
                      if isinstance(m, str)})
    check("every mounted volume is declared, and every declared volume is mounted",
          isinstance(declared, dict) and sorted(declared) == mounted,
          "mounted: %s" % mounted, "declared: %s" % (sorted(declared) if isinstance(declared, dict) else declared))
    check("the network is declared, as a bridge",
          isinstance(doc.get("networks"), dict) and doc["networks"].get(NETWORK) == {"driver": "bridge"},
          "networks: %r" % (doc.get("networks"),))

    if isinstance(manifest, dict) and isinstance(manifest.get("services"), dict):
        for name in (APP, DB):
            in_manifest = set((manifest["services"].get(name) or {}).get("environment") or {})
            in_compose = set(env_of(services[name])) - {"CLOUVE_OPS_PASSWORD"}
            check(name + ": the local run sets the manifest's variables (and CLOUVE_OPS_PASSWORD, which the platform adds)",
                  in_manifest == in_compose, "only in the manifest: %s" % sorted(in_manifest - in_compose),
                  "only in docker-compose.yml: %s" % sorted(in_compose - in_manifest))
        url = ((manifest.get("x-clouve-agent") or {}).get("skills") or {}).get("url")
        check("MAGNETO_AGENT_SKILLS is the manifest's skills URL",
              sidecar.get("MAGNETO_AGENT_SKILLS") == url,
              "manifest: %r" % (url,), "docker-compose.yml: %r" % (sidecar.get("MAGNETO_AGENT_SKILLS"),))


# --- README.md ------------------------------------------------------------------------------------------------------

# before-starting/10-clouve.sh logs 'See apps/nextcloud/README.md, "A half-finished first install".' when it refuses to
# start, so the README has to keep this heading.
HALF_FINISHED_HEADING = "## A half-finished first install"


def check_readme():
    try:
        with open(README, encoding="utf-8") as f:
            lines = [line.rstrip() for line in f.read().splitlines()]
    except OSError as e:
        bad("README.md can be read, to find the heading that the before-starting hook cites", e)
        return
    check("README.md has the line %r, which the before-starting hook's refusal message cites" % HALF_FINISHED_HEADING,
          HALF_FINISHED_HEADING in lines, "no line of README.md is exactly %r" % HALF_FINISHED_HEADING)


print("clv-docker-compose.yml (the marketplace manifest)")
manifest_text, manifest_doc = load(MANIFEST)
if manifest_doc is not None:
    check_manifest(manifest_text, manifest_doc)

print("docker-compose.yml (the local run)")
compose_text, compose_doc = load(COMPOSE)
if compose_doc is not None:
    check_compose(compose_text, compose_doc, manifest_doc)

print("README.md (the heading that the before-starting hook cites)")
check_readme()

print()
if failed:
    print("%s%d of %d checks failed%s" % (RED, failed, checks, RESET))
    sys.exit(1)
print("%sAll %d checks passed%s" % (GREEN, checks, RESET))
PY
