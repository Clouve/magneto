#!/bin/bash

# ============================================================================
# Personas: SSH commands that work as written, and no promise the customer can't keep
# ============================================================================
# A persona (apps/<app>/image/context/<app>/CONTEXT.md.tpl) becomes the AI Assistant's CLAUDE.md, so its commands run
# as written (release 4.5.5, M7 with M1, M2, M3 and M10's persona part). For gibbon, moodle, wordpress and ai-studio:
#   - every ssh or scp command to clouve-ops@ passes -o StrictHostKeyChecking=accept-new and
#     -o UserKnownHostsFile=/dev/null on its line, checked through the real `ssh -G -F /dev/null`, which connects to
#     nothing. The containers make new host keys (at a rebuild, and moodle's at every start), so a saved key is
#     wrong, and on an agent without the Magneto Agent's sibling SSH settings a new key stops at a prompt that
#     sshpass can't answer. nextcloud's persona already passes and is checked too;
#   - SSHPASS is set on each sshpass command, never exported once: the assistant's next Bash call doesn't have it;
#   - no text says to accept a host key once or that it is kept in ~/.ssh/known_hosts, or that the keys change only
#     when an image is rebuilt (after N6 every container makes new ones at each start).
# For gibbon and moodle, whose images are built on php:8.3-apache with no systemd:
#   - no tail of /var/log/apache2/error.log, a link to the container's stderr (the tail hangs), and no "restarting
#     mysqld";
#   - no "prefer the env-driven path" for a password rotation: the image writes config.php's database lines from
#     the deployment's settings at every start and only Clouve can change them;
#   - no "showing the diff" of config.php, which holds the database password.
# For wordpress: wp runs through the skill's scripts/wp.sh, never a plain `sudo -u www-data wp` over SSH (it can't
# reach the database) and never an --allow-root fallback.
#
# Reads files only. Needs ssh and python3.
#
# Usage: bash tests/persona-ssh-commands.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_DIR="$SCRIPT_DIR/../apps"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

FAILED=0
pass() { printf "  ${GREEN}PASS${NC} %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC} %s\n" "$1"; FAILED=1; }

# none_match LABEL FILE ERE: passes when no line of FILE matches ERE (any case).
none_match() {
  local hits
  hits="$(grep -niE -- "$3" "$2" || true)"
  if [ -z "$hits" ]; then pass "$1"; else fail "$1"; printf '%s\n' "$hits" | sed 's/^/       /' | cut -c1-160; fi
}

command -v ssh > /dev/null 2>&1 || { echo "ssh not found (needed for ssh -G)"; exit 1; }

# ssh_commands FILE: "ok LINE" or "bad LINE: why" for each ssh or scp command to clouve-ops@ in FILE, with
# backslash-continued lines joined. The same reading as magneto-skills' tests/lib/ssh-host-key-check.py: an
# ordinary word between ssh and the target makes it prose only outside a fenced code block, and an option's value
# (-o LogLevel ERROR, -p 22) is no ordinary word.
ssh_commands() {
  python3 -I - "$1" <<'PY'
import re, subprocess, sys
word = re.compile(r"""(?:^|(?<=[\s"'(|;&`]))(ssh|scp)(?=\s)""")
ends = re.compile(r"[|;&()`]")
option = re.compile(r"""(?:^|\s)-o\s*["']?([A-Za-z]+[=\s][^\s"']+)""")
want = ("userknownhostsfile /dev/null", "stricthostkeychecking accept-new")
takes_value = {"-b", "-B", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-P", "-p", "-Q",
               "-R", "-S", "-W", "-w"}
def is_prose(words):
    i = 0
    while i < len(words):
        w = words[i]
        if w == "-o":
            i += 3 if i + 1 < len(words) and "=" not in words[i + 1] else 2
        elif w in takes_value:
            i += 2
        elif re.fullmatch(r"[A-Za-z]+", w):
            return True
        else:
            i += 1
    return False
text = open(sys.argv[1]).read()
in_code, inside, fence = set(), False, ""
for n, line in enumerate(text.splitlines(), 1):
    mark = line.lstrip(" >")[:3]
    if mark in ("```", "~~~") and (not inside or mark == fence):
        inside, fence = not inside, mark
        in_code.add(n)
    elif inside:
        in_code.add(n)
lines, buf, start = [], "", None
for n, line in enumerate(text.splitlines(), 1):
    start = start or n
    if line.endswith("\\"):
        buf += line[:-1] + " "
        continue
    lines.append((start, buf + line))
    buf, start = "", None
for n, line in lines:
    for m in word.finditer(line):
        rest = line[m.end():]
        at = rest.find("clouve-ops@")
        if at < 0 or ends.search(rest[:at]):
            continue
        # Prose (an error message quoted in the text) only outside fenced code; scp's sources are never prose.
        if n not in in_code and m.group(1) == "ssh" and is_prose(rest[:at].split()):
            continue
        args = ["ssh", "-G", "-F", "/dev/null"]
        for o in option.findall(rest[:at]):
            args += ["-o", o.replace(" ", "=", 1)]
        got = subprocess.run(args + ["clouve-ops@tkt-7-app"], capture_output=True, text=True).stdout.splitlines()
        print(f"ok {n}" if all(w in got for w in want) else f"bad {n}: lacks a host-key option")
PY
}

# The reading above, on made-up text: a command in a fenced block or with a spaced option value is a command, and an
# error message quoted in prose outside code is not.
probe="$(mktemp)"
printf '%s\n' 'Run `sshpass -e ssh -o LogLevel ERROR clouve-ops@h true` first.' '```bash' 'sshpass -e ssh to clouve-ops@h true' \
  '```' 'If it fails, it prints `ssh to clouve-ops@<host> failed`.' > "$probe"
got="$(ssh_commands "$probe" | tr '\n' ' ')"
rm -f "$probe"
if [ "$got" = "bad 1: lacks a host-key option bad 3: lacks a host-key option " ]; then
  pass "the reading counts commands in code and with spaced option values, and skips quoted error messages"
else
  fail "the reading counts commands in code and with spaced option values, and skips quoted error messages"
  printf '       got: %s\n' "$got"
fi

for app in gibbon moodle wordpress nextcloud ai-studio; do
  tpl="$APPS_DIR/$app/image/context/$app/CONTEXT.md.tpl"
  echo "$app"
  if [ ! -f "$tpl" ]; then fail "$app: persona exists"; continue; fi
  out="$(ssh_commands "$tpl")"
  ok="$(grep -c '^ok ' <<< "$out" || true)"
  bad="$(grep '^bad ' <<< "$out" || true)"
  if [ "$ok" -ge 1 ] && [ -z "$bad" ]; then
    pass "$app: every ssh and scp command passes both host-key options ($ok checked)"
  else
    fail "$app: every ssh and scp command passes both host-key options ($ok ok)"
    printf '%s\n' "$bad" | sed 's/^bad /       line /'
  fi
  [ "$app" = nextcloud ] && continue
  none_match "$app: SSHPASS is never exported once per shell" "$tpl" '(^|[;&|][[:space:]]*)[[:space:]]*export SSHPASS='
  bare="$(grep -nE 'sshpass -e (ssh|scp)' "$tpl" | grep -vF 'SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e' || true)"
  if [ -z "$bare" ]; then pass "$app: every sshpass command sets SSHPASS itself"; else
    fail "$app: every sshpass command sets SSHPASS itself"; printf '%s\n' "$bare" | sed 's/^/       /' | cut -c1-160; fi
  none_match "$app: no text says to accept a host key once or keep it" "$tpl" \
    'accept it once|accept it interactively|captured to `?~/\.ssh/known_hosts|first connection prints'
  # N6: the images ship no host keys, so every container makes new ones at each start, not only after a rebuild.
  none_match "$app: no text says the host keys change only when an image is rebuilt" "$tpl" \
    'when (its|their) images? (is|are) rebuilt'
  case "$app" in
    gibbon | moodle)
      none_match "$app: no tail of Apache's error log (a link to the container's stderr)" "$tpl" \
        'tail[^|;]*/var/log/apache2/error\.log|tailing `?/var/log/apache2'
      none_match "$app: no restarting mysqld (no systemd; stopping it stops the container)" "$tpl" 'restarting `?mysqld'
      none_match "$app: no env-driven path for a password rotation" "$tpl" 'prefer (the |that )?env[- ]'
      none_match "$app: no diff of config.php (it holds the database password)" "$tpl" 'showing the diff|show(ing)? a diff'
      ;;
    wordpress)
      none_match "wordpress: no plain wp over SSH (it can't reach the database)" "$tpl" 'sudo -u www-data wp'
      none_match "wordpress: no --allow-root fallback" "$tpl" 'fall back to[^.]*--allow-root|`sudo wp '
      if grep -qF '/clouve/skills/wordpress/plugin/skills/wordpress/scripts/wp.sh' "$tpl"; then
        pass "wordpress: wp runs through the skill's scripts/wp.sh"
      else
        fail "wordpress: wp runs through the skill's scripts/wp.sh"
      fi
      ;;
  esac
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf "${GREEN}All persona SSH command checks passed.${NC}\n"
else
  printf "${RED}Persona SSH command checks failed.${NC}\n"
fi
exit "$FAILED"
