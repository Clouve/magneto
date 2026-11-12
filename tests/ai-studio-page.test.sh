#!/bin/bash

# ============================================================================
# AI Studio's own address shows a fixed page, not a dev server
# ============================================================================
# The deployment's own address goes to the port the listing publishes. Before
# release 4.5.5 that was 5173, the Vite dev server, which answers anyone with
# no sign-in (and passes /api on to the Express backend). Now the listing
# publishes port 80, where an image-owned supervisor program serves a small
# fixed page that points to the AI Assistant. Previews still reach every port
# through clv-proxy, which signs the user in first.
#
# Static checks (no Docker): the listing publishes 80 and none of the dev
# ports (22, 4000, 5173, 8081, 27017); AI_STUDIO_APP_HOST is an
# applicationHost variable; the page's program is copied into the image-owned
# /etc/supervisor/conf.d (not the /opt volume); the Dockerfile exposes 80;
# serve.sh's own host check, run under busybox (or sh), links only a plain
# host name (not an empty value, one with a line break, upper case, a space,
# markup, a leading hyphen, a 64-character label or more than 253 characters).
#
# Container checks (--network none, only with Docker, skipped with --static):
#   - the image, started as a deployment starts it, answers on port 80 with the
#     page: 200, text/html, a link to https://ai-<AI_STUDIO_APP_HOST>/ and no
#     /@vite/client; any other path shows the page too (with a 404); a request
#     with another Host gets the same link;
#   - the page server runs as nobody, with no CLOUVE_OPS_PASSWORD in its
#     environment;
#   - port 5173 still serves Vite (/@vite/client), which previews reach;
#   - with AI_STUDIO_APP_HOST unset, or set to something that isn't a host
#     name (markup, or a host name with a line break and more after it), the
#     page still answers, with no link and none of the value.
# The page server's environment is read with SYS_PTRACE, which this test's
# container alone gets; a read that fails is a failure.
#
# --image REF uses an image already built (./build.sh ai-studio tags
# r.clv.zone/e2eorg/ai-studio). Without it the test builds the image and
# removes it at the end. Every container it starts is named aistudio-page-t-*.
#
# Usage: bash tests/ai-studio-page.test.sh [--static | --image REF]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$REPO_DIR/apps/ai-studio"
PREFIX="aistudio-page-t-"
READY_SECONDS=180
HOST_VALUE="acme-12.example.test"

STATIC_ONLY=false
IMAGE=""
case "${1:-}" in
  --static) STATIC_ONLY=true ;;
  --image) IMAGE="${2:-}"; [ -n "$IMAGE" ] || { echo "Usage: bash tests/ai-studio-page.test.sh [--static | --image REF]" >&2; exit 2; } ;;
  "") ;;
  *) echo "Usage: bash tests/ai-studio-page.test.sh [--static | --image REF]" >&2; exit 2 ;;
esac

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
has() { if grep -qF -- "$3" <<< "$2"; then pass "$1"; else fail "$1"; printf '       wanted: %q\n' "$3"; fi; }
lacks() { if grep -qF -- "$3" <<< "$2"; then fail "$1"; printf '       found: %q\n' "$3"; else pass "$1"; fi; }

echo "Static: the listing and the image"
static="$(python3 -I - "$APP" <<'PY'
import os
import re
import sys

import yaml

app = sys.argv[1]
with open(os.path.join(app, "clv-docker-compose.yml"), encoding="utf-8") as f:
    svc = yaml.safe_load(f)["services"]["ai-studio"]
ports = sorted({int(str(p).split(":")[-1].split("/")[0]) for p in svc.get("ports") or []})
print("ports=" + ",".join(map(str, ports)))
print("type=%s" % (svc.get("x-clouve-environment-types") or {}).get("AI_STUDIO_APP_HOST"))
with open(os.path.join(app, "image", "Dockerfile"), encoding="utf-8") as f:
    dockerfile = f.read()
copies = re.findall(r"^COPY\s+installer/supervisor-page\.conf\s+(\S+)\s*$", dockerfile, re.M)
print("conf=" + ",".join(copies))
expose = re.findall(r"^EXPOSE\s+(.+)$", dockerfile, re.M)
print("expose=" + " ".join(expose))
PY
)"
ports="$(sed -n 's/^ports=//p' <<< "$static")"
assert_eq "the listing publishes port 80 and only 80" "80" "$ports"
for dev in 22 4000 5173 8081 27017; do
  lacks "the listing doesn't publish $dev" ",$ports," ",$dev,"
done
assert_eq "AI_STUDIO_APP_HOST is an applicationHost variable" "applicationHost" "$(sed -n 's/^type=//p' <<< "$static")"
assert_eq "the page's program goes into the image-owned conf.d" "/etc/supervisor/conf.d/page.conf" \
  "$(sed -n 's/^conf=//p' <<< "$static")"
has "the Dockerfile exposes 80" " $(sed -n 's/^expose=//p' <<< "$static") " " 80 "
persona="$(cat "$APP/image/context/ai-studio/CONTEXT.md.tpl")"
# The persona's SSH form is the other personas' (M7): SSHPASS on each command, never exported (an export is gone at
# the AI Assistant's next command), and the host key accepted, never ignored.
lacks "the persona never exports SSHPASS" "$persona" "export SSHPASS"
lacks "nor turns host key checks off" "$persona" "StrictHostKeyChecking=no"
has "it accepts a new host key" "$persona" "StrictHostKeyChecking=accept-new"

# serve.sh's host check as written (its case ... esac block), run under busybox when this machine has one (the image's
# shell), else under sh with the system's grep. Only a plain host name gives a link.
check_block="$(sed -n '/^case "\$host" in$/,/^esac$/p' "$APP/image/page/serve.sh")"
assert_eq "serve.sh's host check can be found" "1" "$([ -n "$check_block" ] && echo 1 || echo 0)"
host_link() {
  local bb shell=(sh)
  bb="$(command -v busybox || true)"
  if [ -n "$bb" ]; then shell=("$bb" sh); else bb='env'; fi
  "${shell[@]}" -c "BB='$bb'; host=\$1; link=''
$check_block
printf '%s' \"\$link\"" _ "$1"
}
assert_eq "a host name gets the AI Assistant's link" "https://ai-$HOST_VALUE/" "$(host_link "$HOST_VALUE")"
long="$(printf 'a%.0s' {1..60}).$(printf 'b%.0s' {1..60}).$(printf 'c%.0s' {1..60}).$(printf 'd%.0s' {1..60}).$(printf 'e%.0s' {1..60}).example"   # 312 characters
for odd in "" "$HOST_VALUE"$'\n'"evil.example.test" "Acme.example.test" "acme example.test" \
    '"><script>alert(1)</script>' "-acme.example.test" "$(printf 'x%.0s' {1..64}).example.test" "$long"; do
  assert_eq "no link for $(printf '%q' "${odd:0:40}")" "" "$(host_link "$odd")"
done

if $STATIC_ONLY; then
  echo
  if [ "$FAILED" -eq 0 ]; then printf '%sAI Studio page checks passed (static only).%s\n' "$GREEN" "$RESET"; exit 0; fi
  printf '%sAI Studio page checks failed.%s\n' "$RED" "$RESET"; exit 1
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "The container checks need Docker (run with --static for the others)." >&2
  exit 2
fi

BUILT=""
remove_test_containers() {
  local name
  while IFS= read -r name; do
    case "$name" in "$PREFIX"*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
}
# shellcheck disable=SC2329  # the EXIT trap runs it
cleanup() {
  remove_test_containers
  [ -z "$BUILT" ] || docker rmi -f "$BUILT" >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
remove_test_containers

if [ -z "$IMAGE" ]; then
  IMAGE="clouve-test/ai-studio:page-test"
  if log="$(docker build -t "$IMAGE" "$APP/image" 2>&1)"; then
    BUILT="$IMAGE"
  else
    fail "the image builds"
    printf '%s\n' "$log" | tail -n 15 | sed 's/^/       /'
    exit 1
  fi
fi

# answers <container> <port>: 0 once something answers HTTP on that port inside the container.
answers() {
  local _
  for _ in $(seq 1 $((READY_SECONDS / 2))); do
    docker exec "$1" curl -s -o /dev/null "http://127.0.0.1:$2/" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}
# get <container> <path> [Host]: status line, headers and body of a GET on port 80, from inside the container.
get() {
  local host=()
  [ -n "${3:-}" ] && host=(-H "Host: $3")
  docker exec "$1" curl -s -i "${host[@]}" "http://127.0.0.1$2"
}

echo
echo "A workspace started as a deployment starts it"
C="${PREFIX}main"
# SYS_PTRACE (this test only) lets root in the container read the environment of httpd, which runs as nobody.
docker run -d --pull=never --name "$C" --network none --cap-add SYS_PTRACE \
  -e "CLOUVE_OPS_PASSWORD=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')" -e "AI_STUDIO_APP_HOST=$HOST_VALUE" \
  "$IMAGE" >/dev/null
if answers "$C" 80; then
  pass "port 80 answers"
  page="$(get "$C" /)"
  has "GET / is 200" "$(head -n 1 <<< "$page")" " 200"
  # Header names are case-insensitive (busybox httpd sends Content-type).
  has "it is HTML" "$(grep -i '^content-type:' <<< "$page" | tr '[:upper:]' '[:lower:]')" "content-type: text/html"
  has "it links to the AI Assistant" "$page" "href=\"https://ai-$HOST_VALUE/\""
  lacks "it is not the Vite dev server" "$page" "/@vite/client"
  other="$(get "$C" /src/main.jsx)"
  has "another path is a 404" "$(head -n 1 <<< "$other")" " 404"
  has "with the same page" "$other" "href=\"https://ai-$HOST_VALUE/\""
  lacks "and no source" "$other" "createRoot"
  spoof="$(get "$C" / evil.example.test)"
  has "a request with another Host gets the same link" "$spoof" "href=\"https://ai-$HOST_VALUE/\""
  lacks "and never one built from its Host" "$spoof" "evil.example.test"
  # The page server: the process whose arguments start /clouve/busybox httpd -f -p 80 (matched from the start, so this
  # lookup's own sh, whose command line holds the pattern, never matches).
  # shellcheck disable=SC2016  # the script is for the sh inside the container
  pid="$(docker exec "$C" sh -c 'for p in /proc/[0-9]*; do
      tr "\0" " " < "$p/cmdline" 2>/dev/null | grep -q "^/clouve/busybox httpd -f -p 80 " && { echo "${p#/proc/}"; break; }
    done')"
  if [ -n "$pid" ]; then
    assert_eq "the page server runs as nobody" "nobody" "$(docker exec "$C" stat -c %U "/proc/$pid")"
    # A read that fails proves nothing, so it fails the check. env -i leaves httpd's environment empty.
    # shellcheck disable=SC2016  # the script is for the sh inside the container
    if names="$(docker exec "$C" sh -c 'cat "/proc/$0/environ" > /tmp/clv-env || exit 3
        tr "\0" "\n" < /tmp/clv-env | cut -d= -f1; rm -f /tmp/clv-env' "$pid")"; then
      pass "its environment can be read"
      lacks "its environment has no CLOUVE_OPS_PASSWORD" "$names" "CLOUVE_OPS_PASSWORD"
    else
      fail "its environment can be read"
    fi
  else
    fail "the page server (busybox httpd on port 80) is running"
  fi
else
  fail "port 80 answers"
  docker logs --tail 15 "$C" 2>&1 | sed 's/^/       | /'
fi
if answers "$C" 5173; then
  has "port 5173 still serves Vite, which previews reach" "$(docker exec "$C" curl -s http://127.0.0.1:5173/)" "/@vite/client"
else
  fail "port 5173 still answers"
fi
docker rm -f -v "$C" >/dev/null 2>&1

for case in unset bad multiline; do
  echo
  echo "AI_STUDIO_APP_HOST $case: the page has no link"
  C="${PREFIX}$case"
  env_args=()
  bad='"><script>alert(1)</script><a href="https://evil.example.test/'
  [ "$case" = bad ] && env_args=(-e "AI_STUDIO_APP_HOST=$bad")
  # A host name on its first line and more after it: still not a plain host name.
  [ "$case" = multiline ] && env_args=(-e "AI_STUDIO_APP_HOST=$HOST_VALUE"$'\n'"evil.example.test")
  docker run -d --pull=never --name "$C" --network none --entrypoint /clouve/page/serve.sh "${env_args[@]}" \
    "$IMAGE" >/dev/null
  if answers "$C" 80; then
    page="$(get "$C" /)"
    has "GET / is 200" "$(head -n 1 <<< "$page")" " 200"
    lacks "no link to an AI Assistant" "$page" "href=\"https://ai-"
    lacks "none of the value" "$page" "evil.example.test"
    lacks "no script" "$page" "<script"
    has "it says where to find the AI Assistant" "$page" "deployment's page in Clouve"
  else
    fail "port 80 answers"
    docker logs --tail 15 "$C" 2>&1 | sed 's/^/       | /'
  fi
  docker rm -f -v "$C" >/dev/null 2>&1
done

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sAI Studio page checks passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sAI Studio page checks failed.%s\n' "$RED" "$RESET"
exit 1
