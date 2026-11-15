#!/bin/bash

# ============================================================================
# Listing copy for the AI Assistant
# ============================================================================
# The AI Assistant gets its AI usage in one of two ways:
#   - a paid deployment: the AI Assistant's monthly price includes AI usage,
#     and the customer can buy more;
#   - a free trial, or an organization with free services: no AI usage comes
#     with it and there is no Buy more. The customer uses the AI Assistant with
#     their own Claude subscription.
# A listing's text must be true for both. The test reads every marketplace
# manifest that offers the AI Assistant (apps/*/ and bundles/*/
# clv-docker-compose*.yml with x-clouve-agent: enabled: true) and checks the
# x-clouve-bundle-metadata of each container:
#   - appTitle is the app's own name, such as "Moodle", never "Moodle with AI
#     Assistant". The deployment page shows it whether or not the customer
#     chose the AI Assistant at install. TITLES below has the title each
#     container must have;
#   - in an appDescription, a sentence that offers more usage (buy, purchase,
#     top up, AI or usage credits), names an allowance, says what the price
#     includes, or says the customer needs no API key or no account with an AI
#     provider or company also says "paid plan". None of that is true on a
#     free trial or with free services;
#   - a description that mentions the AI Assistant's price, its usage, an
#     allowance or buying more also has one sentence that names the free
#     trial, free services and the customer's own Claude subscription.
#     PRICE_COPY lists the listings that must have both sentences, with the
#     AI usage allowance named in the paid plan's;
#   - "Claude" appears only in "Claude subscription", and no other AI company
#     or tool is named;
#   - appDescription is at most 1000 characters, counted the way the publish
#     wizard counts them (UTF-16 units, after JavaScript's trim());
#   - AI Studio's container has the title "AI Studio" and a description of one
#     sentence (10 to 1000 characters). Without them the install page names it
#     "Ai-studio" with the description "Ai-studio application". The
#     description doesn't start with the title, which the install, deployment
#     and SEO pages show just before it.
#
# --text TEXT runs the description rules (paid plan, own Claude subscription,
# no AI company named) on one text instead, such as a listing's own
# description from the publish wizard, which the SEO page shows as its About
# text and no manifest holds. It prints which rules pass, never the text.
# Save the text in a file first and pass --text "$(cat description.txt)", so
# that quotes and $ in it reach the test unchanged.
# tests/listing-ai-copy-rules.test.sh checks the rules on texts written for
# each case.
#
# Needs python3 with PyYAML, as check-manifests.sh does. Nothing is built and
# no container starts. MAGNETO_DIR points the test at another copy of this
# repo's apps/ and bundles/ folders, to try it on a copy that is broken on
# purpose.
#
# Usage: bash tests/listing-ai-copy.test.sh [--text TEXT]   (exit 0 = all pass)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${MAGNETO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TEXT_MODE=""
TEXT=""
if [ "${1:-}" = --text ]; then
  [ $# -eq 2 ] || { echo "Usage: bash tests/listing-ai-copy.test.sh [--text TEXT]" >&2; exit 2; }
  TEXT_MODE=1
  TEXT="$2"
elif [ $# -gt 0 ]; then
  echo "Usage: bash tests/listing-ai-copy.test.sh [--text TEXT]" >&2
  exit 2
fi

if ! python3 -I -c 'import yaml' 2>/dev/null; then
  echo "This test needs python3 with PyYAML." >&2
  exit 2
fi

LISTING_TEXT="$TEXT" python3 -I - "$ROOT" "$TEXT_MODE" <<'PY'
import glob
import os
import re
import sys

import yaml

ROOT = sys.argv[1]
TEXT_MODE = sys.argv[2] == "1"
AGENT = "x-clouve-agent"
BUNDLE = "x-clouve-bundle-metadata"
MAX_APP_DESCRIPTION = 1000

# The title of each container, by manifest and service: the app's own name.
TITLES = {
    "apps/ai-studio/clv-docker-compose.yml": {"ai-studio": "AI Studio"},
    "apps/gibbon/clv-docker-compose.yml": {"gibbon": "Gibbon"},
    "apps/limesurvey/clv-docker-compose.yml": {"limesurvey": "LimeSurvey"},
    "apps/moodle/clv-docker-compose.yml": {"moodle": "Moodle"},
    "apps/nextcloud/clv-docker-compose.yml": {"nextcloud": "Nextcloud"},
    "apps/odoo/clv-docker-compose.yml": {"odoo": "Odoo"},
    "apps/suitecrm/clv-docker-compose.yml": {"suitecrm": "SuiteCRM"},
    "apps/wordpress/clv-docker-compose.yml": {"wordpress": "WordPress"},
    "bundles/crm-kit/clv-docker-compose.yml": {"limesurvey": "LimeSurvey", "suitecrm": "SuiteCRM"},
    "bundles/education-kit/clv-docker-compose.yml": {"gibbon": "Gibbon", "moodle": "Moodle"},
}

# The listings whose description says what the AI Assistant's price includes. Each one must say it for a paid plan
# and for a free trial or free services.
PRICE_COPY = {
    "apps/gibbon/clv-docker-compose.yml": "gibbon",
    "apps/limesurvey/clv-docker-compose.yml": "limesurvey",
    "apps/moodle/clv-docker-compose.yml": "moodle",
    "apps/nextcloud/clv-docker-compose.yml": "nextcloud",
    "apps/odoo/clv-docker-compose.yml": "odoo",
    "apps/suitecrm/clv-docker-compose.yml": "suitecrm",
    "apps/wordpress/clv-docker-compose.yml": "wordpress",
}

AI_STUDIO = ("apps/ai-studio/clv-docker-compose.yml", "ai-studio")

PAID = re.compile(r"\bpaid plan\b", re.I)
# Buying more. "credits" counts only as AI or usage credits: a school's course credits aren't the AI Assistant's.
BUYING = r"\bbuy\b|\bpurchase\b|\btop(?:-| )?up\b|\b(?:AI|usage) credits?\b"
NEEDS_PAID = re.compile(BUYING + r"|\ballowance\b|\bprice (?:\w+ ){0,5}?includes\b|\bAPI key\b|\bAI (?:provider|company)\b",
                        re.I)
MENTIONS_USAGE = re.compile(BUYING + r"|\bprice\b|\busage\b|\ballowance\b", re.I)
PAID_FACT = re.compile(r"\bpaid plan\b.*\bAI usage allowance\b|\bAI usage allowance\b.*\bpaid plan\b", re.I)
OWN_FACTS = (re.compile(r"\bfree trial\b", re.I), re.compile(r"\bfree services\b", re.I),
             re.compile(r"\bown Claude subscription\b"))
VENDORS = re.compile(r"\b(Claude|Anthropic|OpenAI|ChatGPT|GPT|Gemini|Codex|Copilot|LiteLLM)\b", re.I)
# A sentence ends at . ! or ? followed by white space: "Node.js" and "5.2" stay inside one sentence.
SENTENCE_END = re.compile(r"(?<=[.!?])\s+")
# The characters JavaScript's String.prototype.trim() removes.
JS_TRIMMED = "\t\n\v\f\r " + "".join(map(chr, (0xA0, 0x1680, *range(0x2000, 0x200B),
                                               0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF)))

GREEN, RED, RESET = "\033[0;32m", "\033[0;31m", "\033[0m"
checks = 0
failed = 0


def check(label, condition, *details):
    global checks, failed
    checks += 1
    if condition:
        print("  %sPASS%s %s" % (GREEN, RESET, label))
    else:
        failed += 1
        print("  %sFAIL%s %s" % (RED, RESET, label))
        for detail in details:
            print("       " + str(detail)[:200])
    return bool(condition)


def wizard_length(text):
    """The length the publish wizard measures: UTF-16 units after JavaScript's trim()."""
    return len(text.strip(JS_TRIMMED).encode("utf-16-le", "surrogatepass")) // 2


def sentences(text):
    return [s for s in SENTENCE_END.split(text.strip(JS_TRIMMED)) if s]


def bundle_of(doc, service):
    svc = ((doc.get("services") or {}).get(service)) or {}
    meta = svc.get(BUNDLE)
    return meta if isinstance(meta, dict) else None


def load(rel):
    with open(os.path.join(ROOT, rel), "rb") as f:
        return yaml.safe_load(f) or {}


def check_text(label, text, quote=False):
    """The rules for any text that describes the AI Assistant to customers. With quote, a failure quotes the
    sentences that broke the rule (this repo's own text); without it, it gives only how many there are."""
    unpaid = [s for s in sentences(text) if NEEDS_PAID.search(s) and not PAID.search(s)]
    details = unpaid if quote else ["%d sentence(s) don't say \"paid plan\"" % len(unpaid)]
    check("%s: buying more, an allowance, what the price includes and \"no API key\" are said only of a paid plan"
          % label, not unpaid, *details)
    if MENTIONS_USAGE.search(text):
        check("%s: one sentence says a free trial or free services use the customer's own Claude subscription"
              % label, any(all(fact.search(s) for fact in OWN_FACTS) for s in sentences(text)))
    vendors = sorted(set(m.group(0) for m in VENDORS.finditer(text.replace("Claude subscription", ""))))
    check("%s: no AI company or tool is named, except in \"Claude subscription\"" % label, not vendors,
          "named: %s" % vendors)


if TEXT_MODE:
    print("One text")
    check_text("the text", os.environ.get("LISTING_TEXT", ""))
    print()
    print("%d checks, %d failed" % (checks, failed))
    sys.exit(1 if failed else 0)

paths = sorted(glob.glob(os.path.join(ROOT, "apps", "*", "clv-docker-compose*.yml"))
               + glob.glob(os.path.join(ROOT, "bundles", "*", "clv-docker-compose*.yml")))
manifests = {}
for path in paths:
    rel = os.path.relpath(path, ROOT)
    try:
        doc = load(rel)
    except (OSError, yaml.YAMLError) as error:
        check("%s can be read as YAML" % rel, False, type(error).__name__)
        continue
    agent = doc.get(AGENT) if isinstance(doc, dict) else None
    if isinstance(agent, dict) and agent.get("enabled") is True:
        manifests[rel] = doc

print("Listings that offer the AI Assistant: %s" % (", ".join(sorted(manifests)) or "none"))
check("the manifests that offer the AI Assistant are found", set(TITLES) <= set(manifests),
      "missing: %s" % sorted(set(TITLES) - set(manifests)))

for rel in sorted(manifests):
    doc = manifests[rel]
    print()
    print(rel)
    for service, svc in sorted((doc.get("services") or {}).items()):
        meta = (svc or {}).get(BUNDLE)
        if not isinstance(meta, dict):
            continue
        title = meta.get("appTitle")
        if title is not None:
            check("%s: the title is the app's own name, without \"AI Assistant\"" % service,
                  "ai assistant" not in str(title).lower(), "appTitle: %r" % (title,))
        text = meta.get("appDescription")
        if not isinstance(text, str) or not text.strip(JS_TRIMMED):
            continue
        check("%s: the description is at most %d characters" % (service, MAX_APP_DESCRIPTION),
              wizard_length(text) <= MAX_APP_DESCRIPTION, "it is %d" % wizard_length(text))
        check_text(service, text, quote=True)

print()
print("Titles")
for rel, services in sorted(TITLES.items()):
    doc = manifests.get(rel)
    for service, want in sorted(services.items()):
        meta = bundle_of(doc, service) if doc else None
        got = meta.get("appTitle") if meta else None
        check("%s [%s]: appTitle is %r" % (rel, service, want), got == want, "appTitle: %r" % (got,))

print()
print("What the AI Assistant's price includes")
for rel, service in sorted(PRICE_COPY.items()):
    meta = bundle_of(manifests.get(rel) or {}, service) or {}
    text = meta.get("appDescription") if isinstance(meta.get("appDescription"), str) else ""
    check("%s [%s]: a sentence says a paid plan's price includes an AI usage allowance" % (rel, service),
          any(PAID_FACT.search(s) for s in sentences(text)))
    check("%s [%s]: a sentence says a free trial or free services use the customer's own Claude subscription"
          % (rel, service), any(all(fact.search(s) for fact in OWN_FACTS) for s in sentences(text)))

print()
print("AI Studio")
rel, service = AI_STUDIO
meta = bundle_of(manifests.get(rel) or {}, service) or {}
text = meta.get("appDescription") if isinstance(meta.get("appDescription"), str) else ""
check("%s [%s]: appDescription is 10 to %d characters" % (rel, service, MAX_APP_DESCRIPTION),
      10 <= wizard_length(text) <= MAX_APP_DESCRIPTION, "it is %d" % wizard_length(text))
check("%s [%s]: appDescription is one sentence" % (rel, service),
      len(sentences(text)) == 1 and text.strip(JS_TRIMMED).endswith("."), "sentences: %d" % len(sentences(text)))
title = TITLES[rel][service]
check("%s [%s]: appDescription doesn't start with the title %r, which the pages show just before it"
      % (rel, service, title), not text.strip(JS_TRIMMED).lower().startswith(title.lower()))

print()
print("%d checks, %d failed" % (checks, failed))
sys.exit(1 if failed else 0)
PY
