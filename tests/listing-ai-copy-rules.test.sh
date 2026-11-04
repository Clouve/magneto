#!/bin/bash

# ============================================================================
# The rules of tests/listing-ai-copy.test.sh, on texts written for each case
# ============================================================================
# `listing-ai-copy.test.sh --text TEXT` checks one text against the rules for
# what a listing says about the AI Assistant:
#   - a sentence that offers more usage (buy, purchase, top up, AI or usage
#     credits), names an allowance, says what the price includes, or says the
#     customer needs no API key or no account with an AI provider or company
#     also says "paid plan";
#   - a text that mentions the price, usage, an allowance or buying more also
#     has one sentence that names the free trial, free services and the
#     customer's own Claude subscription;
#   - no AI company or tool is named, except in "Claude subscription".
# This test runs it on texts that each break a rule in words a listing could
# use, and checks that the right rule catches each one. It runs it on texts
# that keep every rule too: the sentences the manifests ship, and a school's
# "course credits", which say nothing about the AI Assistant. And it checks
# that --text never prints the text it was given.
#
# Needs python3 with PyYAML, as listing-ai-copy.test.sh does. Nothing is built
# and no container starts. A path in the argument tests another copy of
# listing-ai-copy.test.sh, such as an older one.
#
# Usage: bash tests/listing-ai-copy-rules.test.sh [path/to/listing-ai-copy.test.sh]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPY_TEST="${1:-$SCRIPT_DIR/listing-ai-copy.test.sh}"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }

if ! python3 -I -c 'import yaml' 2>/dev/null; then
  echo "This test needs python3 with PyYAML." >&2
  exit 2
fi

# A fragment of each rule's label in listing-ai-copy.test.sh's output.
PAID_RULE="only of a paid plan"
OWN_RULE="own Claude subscription"
VENDOR_RULE="no AI company or tool is named"

# The sentence that names the free trial, free services and the customer's own Claude subscription.
OWN="On a free trial, or with free services, you use it with your own Claude subscription."

# run_copy_test <text>: runs listing-ai-copy.test.sh on the text; sets OUT (its output) and RC (its exit status).
run_copy_test() {
  OUT="$(bash "$COPY_TEST" --text "$1" 2>&1)"
  RC=$?
}

# show_result: the copy test's exit status and its rule lines, indented.
show_result() {
  printf '       exit %s\n' "$RC"
  printf '%s\n' "$OUT" | grep -E 'PASS|FAIL' | sed 's/^/       /'
}

# caught <label> <rule fragment> <text>: the copy test fails the text, and one of its failures is that rule's.
caught() {
  run_copy_test "$3"
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -F 'FAIL' | grep -qF -- "$2"; then
    pass "caught: $1"
  else
    fail "caught: $1 (wanted exit 1 and a FAIL line naming \"$2\")"
    show_result
  fi
}

# kept <label> <text>: the copy test passes the text on every rule.
kept() {
  run_copy_test "$2"
  if [ "$RC" -eq 0 ]; then
    pass "kept: $1"
  else
    fail "kept: $1 (wanted exit 0)"
    show_result
  fi
}

echo "Texts that break a rule"
caught "an allowance, in checkout's words, not said of a paid plan" "$PAID_RULE" \
  "It includes a monthly AI usage allowance. $OWN"
caught "what the price includes, not said of a paid plan" "$PAID_RULE" \
  "The price of the AI Assistant includes AI usage. $OWN"
caught "the old allowance sentence, without its \"buy\"" "$PAID_RULE" \
  "The AI Assistant's monthly price includes an AI usage allowance. $OWN"
caught "buying more, as a purchase" "$PAID_RULE" \
  "You can purchase more at any time. $OWN"
caught "AI credits" "$PAID_RULE" \
  "Each month comes with 100 AI credits. $OWN"
caught "topping up usage" "$PAID_RULE" \
  "You can top up your AI usage at any time. $OWN"
caught "no account with an AI company, in the product's own words" "$PAID_RULE" \
  "You don't need an account with an AI company. $OWN"
caught "extra AI credits on their own: the own Claude subscription sentence is missing" "$OWN_RULE" \
  "Purchase extra AI credits whenever you like."
caught "the two claims 4.5.2 shipped" "$PAID_RULE" \
  "The AI Assistant's monthly price includes an AI usage allowance, and you can buy more usage at any time. You don't need an API key or an account with an AI provider. $OWN"
caught "a paid plan's allowance with nothing for a free trial" "$OWN_RULE" \
  "On a paid plan, the AI Assistant's price includes an AI usage allowance, and you can buy more."
caught "another AI company named" "$VENDOR_RULE" \
  "The AI Assistant runs on OpenAI models. $OWN"

echo
echo "Texts that keep every rule"
kept "the sentences the manifests ship" \
  "On a paid plan, the AI Assistant's price includes an AI usage allowance, and you can buy more. $OWN You can turn it on or off."
kept "Nextcloud's form, without apostrophes" \
  "On a paid plan, the price of the AI Assistant includes an AI usage allowance, and you can buy more. $OWN You can turn it on or off."
kept "a school's course credits, which aren't AI usage" \
  "Students earn course credits for each module they finish."
kept "a text that says nothing about the AI Assistant" \
  "A hosted wiki for small teams."

echo
echo "What --text prints"
marker="never-printed-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
run_copy_test "Buy more $marker usage from OpenAI."
if [ "$RC" -eq 1 ] && ! printf '%s\n' "$OUT" | grep -qF -- "$marker"; then
  pass "it fails the text and never prints it"
else
  fail "it fails the text and never prints it"
  printf '       exit %s; the text in the output: %s\n' "$RC" \
    "$(printf '%s\n' "$OUT" | grep -cF -- "$marker") line(s)"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sAll listing-ai-copy rule tests passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sListing-ai-copy rule tests failed.%s\n' "$RED" "$RESET"
exit 1
