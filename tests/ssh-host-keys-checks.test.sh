#!/bin/bash

# ============================================================================
# The checks of tests/ssh-host-keys.test.sh, with a fake docker
# ============================================================================
# ssh-host-keys.test.sh needs Docker: it lists /etc/ssh in each Odoo image and
# compares the host keys of two containers from the same image. This test runs
# it with a fake `docker` on PATH that answers from files written for each
# case, so every check meets a case it has to catch:
#   - an image whose /etc/ssh holds ssh_host_* files fails;
#   - an image whose /etc/ssh can't be listed fails too, instead of passing
#     as an image with no key;
#   - two containers that share all their host keys fail, and so do two that
#     share only one. comm finds a shared line only when it and sort agree on
#     the order, so the cases run in en_US.UTF-8 (when this machine has it), a
#     locale in which uutils' sort and comm disagree;
#   - two containers with different keys pass, with no warning from comm;
#   - an image with no sshd script (AI Studio) starts its containers with its
#     own entrypoint, never --entrypoint.
# Nothing is built and no container starts; no Docker daemon is needed.
#
# Usage: bash tests/ssh-host-keys-checks.test.sh [path/to/ssh-host-keys.test.sh]
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_TEST="${1:-$SCRIPT_DIR/ssh-host-keys.test.sh}"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }

if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  export LC_ALL=en_US.UTF-8
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# The fake docker. It answers from the files in $FAKE_DOCKER:
#   ls-<image>   what `ls -A /etc/ssh` prints in the image (without the file, that run fails as docker does)
#   keys-<name>  the `ssh-keygen -lf` lines of the container named <name>
# and records each call in $FAKE_DOCKER/calls.
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_DOCKER/calls"
case "$1" in
  info|ps|rm|rmi|image) exit 0 ;;
  logs) echo "fake log line"; exit 0 ;;
  run)
    shift
    detached=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -d) detached=1 ;;
        --name|--network|-e|--entrypoint) shift ;;
        -*) ;;
        *) break ;;
      esac
      shift
    done
    [ -n "$detached" ] && exit 0
    file="$FAKE_DOCKER/ls-$(printf '%s' "$1" | tr '/:' '__')"
    if [ ! -f "$file" ]; then
      echo "docker: Error response from daemon: the fake run failed" >&2
      exit 125
    fi
    cat "$file"
    ;;
  exec)
    [ "$3" = bash ] && exit 0    # the port check: sshd listens
    cat "$FAKE_DOCKER/keys-$2"
    ;;
  *) echo "fake docker: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/docker"

GOOD_LS=$'moduli\nssh_config\nssh_config.d\nsshd_config\nsshd_config.d'
# Three keys per container. Sorted in en_US.UTF-8, "abcd..." comes before "Mnop...", which byte order (comm's, in
# uutils) puts the other way round.
KEYS_1=$'256 SHA256:abcdEFGHijklMNOP root@a (ED25519)\n256 SHA256:Mnop1234qrstUVWX root@a (ECDSA)\n3072 SHA256:uvwx5678yzABCDEF root@a (RSA)'
KEYS_2=$'256 SHA256:bbbbCCCCddddEEEE root@b (ED25519)\n256 SHA256:Nnnn2222ooooPPPP root@b (ECDSA)\n3072 SHA256:Pppp3333qqqqRRRR root@b (RSA)'
# Two containers that share only their RSA key, the one that sorts last.
SHARE_1=$'256 SHA256:abcdEFGHijklMNOP root@a (ED25519)\n256 SHA256:mmmm5555nnnnOOOO root@a (ECDSA)\n3072 SHA256:Xyzw1234vutsRQPO root@a (RSA)'
SHARE_2=$'256 SHA256:bbbbCCCCddddEEEE root@b (ED25519)\n256 SHA256:nnnn6666ooooPPPP root@b (ECDSA)\n3072 SHA256:Xyzw1234vutsRQPO root@b (RSA)'

# new_case <name>: a folder of answers for one run, where both images are good and their containers' keys differ.
# The case then changes what it tests, for the odoo image.
new_case() {
  CASE="$WORK/$1"
  mkdir -p "$CASE"
  printf '%s\n' "$GOOD_LS" > "$CASE/ls-fake_odoo"
  printf '%s\n' "$GOOD_LS" > "$CASE/ls-fake_odoo-postgres"
  printf '%s\n' "$KEYS_1" > "$CASE/keys-ssh-keys-t-odoo-1"
  printf '%s\n' "$KEYS_2" > "$CASE/keys-ssh-keys-t-odoo-2"
  printf '%s\n' "$KEYS_1" > "$CASE/keys-ssh-keys-t-odoo-postgres-1"
  printf '%s\n' "$KEYS_2" > "$CASE/keys-ssh-keys-t-odoo-postgres-2"
}

# run_case: ssh-host-keys.test.sh on the case's answers; sets OUT (its output, without colours) and RC.
run_case() {
  OUT="$(PATH="$WORK/bin:$PATH" FAKE_DOCKER="$CASE" \
    bash "$KEYS_TEST" --image odoo=fake/odoo --image odoo-postgres=fake/odoo-postgres odoo odoo-postgres 2>&1)"
  RC=$?
  OUT="$(printf '%s\n' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')"
}

# show_run: the run's exit status and output, indented.
show_run() {
  printf '       exit %s\n' "$RC"
  printf '%s\n' "$OUT" | sed 's/^/       | /'
}

# expect <label> <status> <line>...: the run ends with that status, and its output has each line (a fixed string).
expect() {
  local label="$1" status="$2" line ok=true
  shift 2
  [ "$RC" = "$status" ] || ok=false
  for line in "$@"; do
    printf '%s\n' "$OUT" | grep -qxF -- "$line" || ok=false
  done
  if $ok; then
    pass "$label"
  else
    fail "$label"
    printf '       wanted exit %s and these lines:\n' "$status"
    printf '         %s\n' "$@"
    show_run
  fi
}

echo "Each container's keys differ"
new_case good
run_case
expect "both images pass" 0 \
  "  PASS a second container from the same image has different keys"
if printf '%s\n' "$OUT" | grep -q 'sorted order'; then
  fail "comm gives no warning about the order of its input"
  printf '%s\n' "$OUT" | grep 'sorted order' | sed 's/^/       | /'
else
  pass "comm gives no warning about the order of its input"
fi

echo
echo "The image ships host keys"
new_case baked
printf '%s\nssh_host_ed25519_key\nssh_host_ed25519_key.pub\n' "$GOOD_LS" > "$CASE/ls-fake_odoo"
run_case
expect "it fails, and names the keys" 1 \
  "  FAIL the image holds no SSH host key" \
  "       baked in: ssh_host_ed25519_key"

echo
echo "The image's /etc/ssh can't be listed"
new_case unlisted
rm "$CASE/ls-fake_odoo"
run_case
expect "it fails instead of passing as an image with no key" 1 \
  "  FAIL the image holds no SSH host key (its /etc/ssh couldn't be listed)"

echo
echo "Two containers share all their keys"
new_case shared-all
printf '%s\n' "$KEYS_1" > "$CASE/keys-ssh-keys-t-odoo-2"
run_case
expect "it fails, and names each shared key" 1 \
  "  FAIL a second container from the same image has different keys" \
  "       in both: SHA256:abcdEFGHijklMNOP" \
  "       in both: SHA256:Mnop1234qrstUVWX" \
  "       in both: SHA256:uvwx5678yzABCDEF"

echo
echo "Two containers share one key"
new_case shared-one
printf '%s\n' "$SHARE_1" > "$CASE/keys-ssh-keys-t-odoo-1"
printf '%s\n' "$SHARE_2" > "$CASE/keys-ssh-keys-t-odoo-2"
run_case
expect "it fails, and names the shared key" 1 \
  "  FAIL a second container from the same image has different keys" \
  "       in both: SHA256:Xyzw1234vutsRQPO"

echo
echo "An image with no sshd script starts its containers with its own entrypoint"
CASE="$WORK/own-entrypoint"
mkdir -p "$CASE"
printf '%s\n' "$GOOD_LS" > "$CASE/ls-fake_ai-studio"
printf '%s\n' "$KEYS_1" > "$CASE/keys-ssh-keys-t-ai-studio-1"
printf '%s\n' "$KEYS_2" > "$CASE/keys-ssh-keys-t-ai-studio-2"
OUT="$(PATH="$WORK/bin:$PATH" FAKE_DOCKER="$CASE" bash "$KEYS_TEST" --image ai-studio=fake/ai-studio ai-studio 2>&1)"
RC=$?
OUT="$(printf '%s\n' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')"
expect "it passes" 0 "  PASS a second container from the same image has different keys"
starts="$(grep -E '^run -d .*ssh-keys-t-ai-studio-' "$CASE/calls")"
if [ "$(grep -c . <<< "$starts")" = 2 ] && ! grep -q -- '--entrypoint' <<< "$starts"; then
  pass "both containers start with no --entrypoint"
else
  fail "both containers start with no --entrypoint"
  printf '%s\n' "$starts" | sed 's/^/       | /'
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sAll ssh-host-keys.test.sh check tests passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sssh-host-keys.test.sh check tests failed.%s\n' "$RED" "$RESET"
exit 1
