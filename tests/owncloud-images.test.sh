#!/bin/bash

# ============================================================================
# tests/owncloud-images.sh, the input of the ownCloud pin gate
# ============================================================================
# Runs the listing with a stub kubectl and a stub docker on PATH and
# KUBECONFIG=/dev/null, so no cluster, registry or Docker is needed. The stub
# kubectl answers only the query the gate needs: get, with -A, and the two
# jsonpath templates below, word for word. Anything else fails the way a
# refused read does. Checks that the listing:
#   - lists the ownCloud and owncloud-mariadb image of every Deployment and
#     StatefulSet from its pod template, init containers included, so a
#     paused one at 0 replicas is listed too;
#   - ignores every other image: the AI Assistant, WordPress, owncloud-redis,
#     and repositories whose names only look like ownCloud's;
#   - lists a running pod's image ID (what it pulled) without the runtime's
#     docker-pullable:// prefix, and says "unreadable" for an ownCloud
#     container whose image ID names no repository;
#   - gives the digest the registry names now for each spec reference, or
#     "unreadable";
#   - exits 1 with a count on stderr when any line says unreadable;
#   - exits 1, names the context and prints no list when a context's
#     workloads or pods can't be read;
#   - prints nothing but those references and digests;
#   - exits 2 with no context.
#
# Usage: bash tests/owncloud-images.test.sh
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$SCRIPT_DIR/owncloud-images.sh"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
RESET=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"; FAILED=1; }
assert_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else
  fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi; }
has() { if grep -qxF -- "$3" <<< "$2"; then pass "$1"; else fail "$1"; printf '       wanted the line: %q\n' "$3"; fi; }
lacks() { if grep -qF -- "$3" <<< "$2"; then fail "$1"; printf '       did NOT want: %q\n' "$3"; else pass "$1"; fi; }
matches() { if grep -qE -- "$3" <<< "$2"; then pass "$1"; else fail "$1"; printf '       wanted a line matching: %q\n' "$3"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
P=cr0.io/clouveinc327
R=r.clv.zone/e2eorg
D1=sha256:1111111111111111111111111111111111111111111111111111111111111111
D2=sha256:2222222222222222222222222222222222222222222222222222222222222222
D3=sha256:3333333333333333333333333333333333333333333333333333333333333333
D4=sha256:4444444444444444444444444444444444444444444444444444444444444444
TAB=$'\t'

# The query, word for word. Images only: the pod template's containers and
# init containers, and each started container's image and image ID.
printf '%s' '{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
  > "$WORK/want-workloads"
printf '%s' '{range .items[*]}{range .status.containerStatuses[*]}{.image}{"\t"}{.imageID}{"\n"}{end}{range .status.initContainerStatuses[*]}{.image}{"\t"}{.imageID}{"\n"}{end}{end}' \
  > "$WORK/want-pods"

# What each context's API prints for those templates. prod: a paused ownCloud
# (Deployment and StatefulSet at 0 replicas, its AI Assistant and Redis), a
# WordPress site, three look-alike repositories, a running ownCloud.
cat > "$WORK/prod-workloads" <<EOF
$P/owncloud:2026.02.18
$P/magneto-agent:latest
$P/owncloud-mariadb:2026.02.18
$P/owncloud-redis:2026.02.18
$P/wordpress:2026.11.12
$P/owncloudx:1
$P/myowncloud:1
$P/owncloud-mariadb-backup:1
$P/owncloud:2026.11.20
EOF
# The running pods: docker's prefix, containerd's plain form, and a container
# that hasn't started yet (no image ID, so nothing ran).
cat > "$WORK/prod-pods" <<EOF
$P/owncloud:2026.11.20${TAB}docker-pullable://$P/owncloud@$D3
$P/wordpress:2026.11.12${TAB}docker-pullable://$P/wordpress@$D2
$P/owncloud-redis:2026.02.18${TAB}$P/owncloud-redis@$D4
$P/owncloud:2026.11.20${TAB}
EOF
# uk: one StatefulSet whose tag the registry doesn't know.
echo "$P/owncloud-mariadb:2026.11.20" > "$WORK/uk-workloads"
: > "$WORK/uk-pods"
# kind: an image loaded into the node, so its image ID is a bare digest.
echo "$R/owncloud:2026.11.12" > "$WORK/kind-workloads"
echo "$R/owncloud:2026.11.12${TAB}$D4" > "$WORK/kind-pods"
# podsbad: the workloads read works, the pods read doesn't. bad: nothing reads.
echo "$P/owncloud:2026.11.20" > "$WORK/podsbad-workloads"
cat > "$WORK/digests" <<EOF
$P/owncloud:2026.02.18 $D1
$P/owncloud-mariadb:2026.02.18 $D2
$P/owncloud:2026.11.20 $D3
$R/owncloud:2026.11.12 $D1
EOF

cat > "$WORK/bin/kubectl" <<'EOF'
#!/bin/bash
echo "kubectl $*" >> "$CALLS"
[ "${KUBECONFIG:-}" = /dev/null ] || { echo "stub kubectl: KUBECONFIG isn't /dev/null" >&2; exit 1; }
ctx="" verb="" what="" all="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --context) ctx="$2"; shift ;;
    get) verb=get; what="$2"; shift ;;
    -A|--all-namespaces) all=1 ;;
    -o) out="$2"; shift ;;
    *) echo "stub kubectl: unexpected argument $1" >&2; exit 1 ;;
  esac
  shift
done
[ "$verb" = get ] || { echo "stub kubectl: only get" >&2; exit 1; }
[ -n "$all" ] || { echo "stub kubectl: no -A, so only the default namespace" >&2; exit 1; }
case "$what" in
  deployments,statefulsets) part=workloads ;;
  pods) part=pods ;;
  *) echo "stub kubectl: unexpected resource $what" >&2; exit 1 ;;
esac
[ "$out" = "jsonpath=$(cat "$STUB/want-$part")" ] || { echo "stub kubectl: not the $part template" >&2; exit 1; }
case "$ctx/$part" in
  bad/* | podsbad/pods)
    echo "Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout" >&2
    exit 1 ;;
esac
[ -f "$STUB/$ctx-$part" ] || { echo "error: context \"$ctx\" does not exist" >&2; exit 1; }
cat "$STUB/$ctx-$part"
EOF
cat > "$WORK/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$CALLS"
[ "$1 $2 $3" = "buildx imagetools inspect" ] || exit 1
d="$(awk -v r="$4" '$1 == r { print $2 }' "$STUB/digests")"
[ -n "$d" ] || { echo "ERROR: $4: not found" >&2; exit 1; }
printf '"%s"\n' "$d"
EOF
chmod +x "$WORK/bin/kubectl" "$WORK/bin/docker"

# list ARGS...: runs the listing; sets RC, OUT (stdout), ERR (stderr) and CALLS_TXT.
list() {
  : > "$WORK/calls"
  OUT="$(KUBECONFIG=/dev/null CALLS="$WORK/calls" STUB="$WORK" PATH="$WORK/bin:$PATH" bash "$LIST" "$@" 2> "$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
  CALLS_TXT="$(cat "$WORK/calls")"
}
# Every stdout line is a spec, running or digest line.
SHAPE='^(spec|running) [^ ]+ [^ ]+$|^running [^ ]+ [^ ]+ unreadable$|^digest [^ ]+ (sha256:[0-9a-f]{64}|unreadable)$'

if [ ! -f "$LIST" ]; then
  fail "tests/owncloud-images.sh exists"
  exit 1
fi

echo "One context"
list prod
assert_eq "exits 0" 0 "$RC"
assert_eq "nothing on stderr" "" "$ERR"
has "a paused (0 replicas) Deployment's ownCloud image is listed" "$OUT" "spec prod $P/owncloud:2026.02.18"
has "a paused StatefulSet's owncloud-mariadb image is listed" "$OUT" "spec prod $P/owncloud-mariadb:2026.02.18"
has "a running Deployment's ownCloud image is listed" "$OUT" "spec prod $P/owncloud:2026.11.20"
has "a running pod's image ID is listed, without docker-pullable://" "$OUT" "running prod $P/owncloud@$D3"
lacks "a container with no image ID yet adds no running line" "$OUT" "running prod $P/owncloud:2026.11.20"
lacks "the AI Assistant's image in the same pod isn't listed" "$OUT" "magneto-agent"
lacks "a WordPress image isn't listed" "$OUT" "wordpress"
lacks "owncloud-redis isn't listed (spec or running)" "$OUT" "owncloud-redis"
lacks "a repository that only starts with owncloud isn't listed" "$OUT" "owncloudx"
lacks "a repository that only ends with owncloud isn't listed" "$OUT" "myowncloud"
lacks "a repository that only starts with owncloud-mariadb isn't listed" "$OUT" "owncloud-mariadb-backup"
has "each spec reference's digest now" "$OUT" "digest $P/owncloud:2026.02.18 $D1"
has "... the database image's too" "$OUT" "digest $P/owncloud-mariadb:2026.02.18 $D2"
assert_eq "every line is a spec, running or digest line" 0 "$(grep -cvE "$SHAPE" <<< "$OUT")"
assert_eq "kubectl is only asked to get" 0 "$(grep '^kubectl ' <<< "$CALLS_TXT" | grep -cv ' get ')"
assert_eq "every kubectl call reads all namespaces" 0 "$(grep '^kubectl ' <<< "$CALLS_TXT" | grep -cv ' -A ')"

echo "Two contexts, one tag the registry doesn't know"
list prod uk
has "the second context's image is listed" "$OUT" "spec uk $P/owncloud-mariadb:2026.11.20"
has "a reference the registry doesn't know says unreadable" "$OUT" "digest $P/owncloud-mariadb:2026.11.20 unreadable"
assert_eq "each reference's digest is looked up once" 1 "$(grep -c "^digest $P/owncloud:2026.11.20 " <<< "$OUT")"
assert_eq "an unreadable digest: exit 1" 1 "$RC"
matches "... with the count on stderr" "$ERR" '^ERROR: 1 line says unreadable'

echo "A running image ID with no repository"
list kind
has "the ownCloud container's image is listed as unreadable" "$OUT" "running kind $R/owncloud:2026.11.12 unreadable"
assert_eq "every line is a spec, running or digest line" 0 "$(grep -cvE "$SHAPE" <<< "$OUT")"
assert_eq "exit 1" 1 "$RC"
matches "... with the count on stderr" "$ERR" '^ERROR: 1 line says unreadable'

echo "A context that can't be read"
list prod bad
assert_eq "exit 1" 1 "$RC"
matches "the error names the context" "$ERR" '^ERROR: .*context bad'
assert_eq "no partial list: nothing on stdout" "" "$OUT"
list bad
assert_eq "the only context can't be read: exit 1" 1 "$RC"
list prod podsbad
assert_eq "only its pods can't be read: exit 1" 1 "$RC"
matches "... the error names that context" "$ERR" '^ERROR: .*context podsbad'
assert_eq "... and nothing on stdout" "" "$OUT"

echo "Usage"
list
assert_eq "no context: exit 2" 2 "$RC"

echo
if [ "$FAILED" -eq 0 ]; then
  printf '%sownCloud image listing tests passed.%s\n' "$GREEN" "$RESET"
  exit 0
fi
printf '%sownCloud image listing tests failed.%s\n' "$RED" "$RESET"
exit 1
