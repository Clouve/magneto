#!/bin/bash
# ============================================================================
# New-disk volumes test
# ============================================================================
# On a cluster, every volume of a new install is a new disk: an empty
# filesystem whose top folder is root's (mode 755) with lost+found in it, and
# none of the files the image keeps at that path. Docker fills a new named
# volume with a copy of the image's folder instead, so a local start would hide
# what a first cluster start looks like. lib/new-disk-volumes.sh makes Compose
# volumes in the cluster's shape before Compose creates the containers, and
# start.sh, test.sh and tests/new-disk-start.test.sh use it. This test checks:
#   1. the helper: the shape, Compose's labels, a volume two services share, an
#      explicit name, an external volume, a volume that exists already, down -v,
#      a shaper that can't run, and bash 3.2 (the version macOS ships);
#   2. start.sh, on a copy with a fake app: new disks by default, a volume that
#      exists left as it is, --docker-volumes, --cleanup, no python3, a shaper
#      that can't run; test.sh's start by contract; both parse on bash 3.2;
#   3. the runner, tests/new-disk-start.test.sh, on fake apps: a good one, one
#      that needs the image's files in its volume, one that runs as uid 1000,
#      one too slow for its deadline, one that crashes after it passed, HTTP
#      302 and 500, command probes, a probe that is off, a fixed name and port,
#      the Magneto Agent left out, the plan's CPU and memory, nothing left
#      behind, --upgrade-from, a probe that never passes, and in the settle
#      period a short failure (noted) and one longer than the platform allows.
#   4. the pass records and the push gate, in a throwaway git repository with
#      copies of the build scripts, fake apps and a stub docker: the source hash
#      (tracked, untracked and ignored files), a recorded pass, build.sh's gate
#      with NEW_DISK_GATE=1 and --push (one app, --all, --skip-new-disk-check),
#      no gate elsewhere, the UAT and prod wrappers turning it on, the runner
#      recording a pass only for an app it built, bash 3.2, and build-prune's
#      own test still passing.
#
# Needs Docker. Every container, volume, network and image it makes is named
# nd-test-* or ndt<N>*, and it removes them when it exits.
#
# Usage: bash tests/new-disk-volumes.test.sh [SECTION...]   (default: every section)
# Exit status: 0 when every check passes, 1 when one fails, 2 without Docker.
# ============================================================================

# shellcheck disable=SC2016  # the single-quoted scripts are for the shells inside the containers
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO/lib/new-disk-volumes.sh"
ALPINE="mirror.gcr.io/library/alpine:3.20"
BASH32="mirror.gcr.io/library/bash:3.2"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'
FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1"; FAILED=1; }
# assert_eq LABEL EXPECTED ACTUAL
assert_eq() {
  if [[ "$3" == "$2" ]]; then pass "$1"; else
    fail "$1"; printf '       expected: %q\n       actual:   %q\n' "$2" "$3"; fi
}
# assert_contains LABEL TEXT NEEDLE
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else
    fail "$1"; printf '       wanted: %q\n       in:     %q\n' "$3" "$2"; fi
}
# assert_lacks LABEL TEXT NEEDLE
assert_lacks() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else
    fail "$1"; printf '       did not want: %q\n       in:           %q\n' "$3" "$2"; fi
}
# count TEXT NEEDLE: how many lines of TEXT hold NEEDLE
count() { grep -cF -- "$2" <<< "$1"; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "This test needs Docker." >&2
  exit 2
fi

WORK="$(mktemp -d)"
# Removes what this test makes, and nothing else: names that begin with nd-test- or ndt<digits>.
remove_test_resources() {
  local name
  while IFS= read -r name; do
    case "$name" in nd-test-*|ndt[0-9]*) docker rm -f -v "$name" >/dev/null 2>&1 ;; esac
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in nd-test-*|ndt[0-9]*) docker volume rm -f "$name" >/dev/null 2>&1 ;; esac
  done < <(docker volume ls -q 2>/dev/null)
  while IFS= read -r name; do
    case "$name" in nd-test-*|ndt[0-9]*) docker network rm "$name" >/dev/null 2>&1 ;; esac
  done < <(docker network ls --format '{{.Name}}' 2>/dev/null)
}
cleanup() {
  remove_test_resources
  docker image rm -f nd-test-image:latest nd-test-user:latest nd-test-up:old nd-test-up:latest nd-test-py:latest \
    r.clv.zone/e2eorg/nd-test-own:pinned >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
remove_test_resources    # leftovers of a run that was killed

# The sections to run: the arguments, or all of them.
SECTIONS="${*:-1 2 3 4}"
wants() { [[ " $SECTIONS " == *" $1 "* ]]; }

# The image every section uses: /data holds a file and a folder of uid 1000's, mode 750, the way an app image keeps
# its files at a volume path. Docker would copy all of that into a new named volume; a new disk has none of it.
build_test_image() {
  mkdir -p "$WORK/img"
  cat > "$WORK/img/Dockerfile" <<EOF
FROM $ALPINE
RUN mkdir -p /data/up && echo seed > /data/seed.txt && chown -R 1000:1000 /data && chmod 750 /data
EOF
  docker build -q -t nd-test-image:latest "$WORK/img" >/dev/null
}
if ! build_test_image; then
  echo "Could not build the test image from $ALPINE." >&2
  exit 2
fi

# ============================================================================
# 1. The helper
# ============================================================================
if wants 1; then
  echo
  echo "1. lib/new-disk-volumes.sh"
  C1="$WORK/c1"
  mkdir -p "$C1"
  cat > "$C1/docker-compose.yml" <<'EOF'
services:
  app:
    image: nd-test-image:latest
    command: ["sleep", "infinity"]
    volumes:
      - data:/data
      - up:/data/up
  other:
    image: nd-test-image:latest
    command: ["sleep", "infinity"]
    volumes:
      - data:/data
      - named:/n
      - ext:/e
volumes:
  data:
  up:
  named:
    name: nd-test-explicit
  ext:
    external: true
    name: nd-test-ext
EOF
  # helper ARGS...: prepare_new_disk_volumes in the compose folder, as start.sh runs it
  # shellcheck source=/dev/null
  helper() { (cd "$C1" && . "$LIB" && prepare_new_disk_volumes "$@"); }
  dc1() { docker compose -p ndt1 -f "$C1/docker-compose.yml" "$@"; }
  in_app() { dc1 exec -T app sh -c "$1" 2>&1; }

  docker volume create nd-test-ext >/dev/null
  docker run --rm -v nd-test-ext:/v "$ALPINE" sh -c 'echo m > /v/marker'

  out="$(helper -p ndt1 -f docker-compose.yml 2>&1)"
  rc=$?
  assert_eq "the helper exits 0" 0 "$rc"
  assert_eq "it makes three volumes (the shared one once, not the external one)" 3 "$(count "$out" "New volume ")"
  assert_contains "... ndt1_data" "$out" "New volume ndt1_data: shaped like a new cluster disk"
  assert_contains "... ndt1_up" "$out" "New volume ndt1_up: shaped like a new cluster disk"
  assert_contains "... nd-test-explicit, the explicit name" "$out" "New volume nd-test-explicit: shaped like a new cluster disk"
  assert_lacks "... and not the external nd-test-ext" "$out" "nd-test-ext"

  up_out="$(dc1 up -d 2>&1)"
  assert_lacks "Compose adopts the volumes without a warning" "$up_out" "already exists"
  assert_eq "the top folder is root's, mode 755" "0:0 755" "$(in_app 'stat -c "%u:%g %a" /data')"
  assert_eq "it holds lost+found and the nested mount point, and none of the image's files" "lost+found up" \
    "$(in_app 'ls -A /data | sort | tr "\n" " " | sed "s/ $//"')"
  assert_eq "lost+found is root's, mode 700" "0:0 700" "$(in_app 'stat -c "%u:%g %a" /data/lost+found')"
  assert_eq "the nested volume is a new disk too" "0:0 755 lost+found" \
    "$(in_app 'printf "%s %s" "$(stat -c "%u:%g %a" /data/up)" "$(ls -A /data/up)"')"
  assert_eq "Compose's project and volume labels" "ndt1 data" \
    "$(docker volume inspect ndt1_data --format '{{index .Labels "com.docker.compose.project"}} {{index .Labels "com.docker.compose.volume"}}')"
  ver="$(docker volume inspect ndt1_data --format '{{index .Labels "com.docker.compose.version"}}')"
  if [[ -n "$ver" ]]; then pass "Compose's version label ($ver)"; else fail "Compose's version label"; fi
  assert_eq "the external volume keeps what it had" "m" "$(dc1 exec -T other cat /e/marker 2>&1)"

  in_app 'echo k > /data/kept.txt' >/dev/null
  dc1 down >/dev/null 2>&1
  out="$(helper -p ndt1 -f docker-compose.yml 2>&1)"
  rc=$?
  assert_eq "with every volume there already: exit 0 and no output" "0|" "$rc|$out"
  dc1 up -d >/dev/null 2>&1
  assert_eq "... and a volume that exists keeps what it has" "k" "$(in_app 'cat /data/kept.txt')"

  dc1 down -v >/dev/null 2>&1
  assert_eq "down -v removes the volumes the helper made" "" \
    "$(docker volume ls -q | grep -E '^(ndt1_|nd-test-explicit$)' || true)"
  assert_eq "... and leaves the external one" "nd-test-ext" "$(docker volume ls -q | grep -E '^nd-test-ext$' || true)"

  out="$(ND_SHAPER_IMAGE=nd-test-missing:none helper -p ndt2 -f docker-compose.yml 2>&1)"
  rc=$?
  assert_eq "a shaper that can't run: exit 1" 1 "$rc"
  assert_contains "... with a message" "$out" "✗ could not fetch nd-test-missing:none, the image that shapes new volumes"
  assert_eq "... and no half-made volume left" "" "$(docker volume ls -q | grep -E '^(ndt2_|nd-test-explicit$)' || true)"

  # The shaper image is fetched before any volume is made, so a failed fetch makes nothing at all.
  mkdir -p "$WORK/spy"
  REAL_DOCKER="$(command -v docker)"
  printf '#!/bin/bash\necho "$*" >> "%s/spy/calls"\nexec "%s" "$@"\n' "$WORK" "$REAL_DOCKER" > "$WORK/spy/docker"
  chmod +x "$WORK/spy/docker"
  : > "$WORK/spy/calls"
  PATH="$WORK/spy:$PATH" ND_SHAPER_IMAGE=nd-test-missing:none helper -p ndt2 -f docker-compose.yml >/dev/null 2>&1
  assert_eq "... the shaper is fetched before any volume is made" 0 "$(grep -c '^volume create' "$WORK/spy/calls")"
  # A volume that holds files is never changed or removed, even when the helper takes it for missing (a docker volume
  # inspect that fails, or a second start of the same project racing this one).
  docker volume create ndt2_data >/dev/null
  docker run --rm -v ndt2_data:/v "$ALPINE" sh -c 'echo keep > /v/keep.txt && chown -R 1000:1000 /v && chmod 750 /v'
  printf '#!/bin/bash\nif [ "$1 $2" = "volume inspect" ]; then exit 1; fi\nexec "%s" "$@"\n' "$REAL_DOCKER" > "$WORK/spy/docker"
  out="$(PATH="$WORK/spy:$PATH" helper -p ndt2 -f docker-compose.yml 2>&1)"
  assert_eq "a volume that holds files, taken for missing: exit 0" 0 "$?"
  assert_contains "... it says it left it as it is" "$out" "Volume ndt2_data already holds files; left as it is"
  assert_eq "... and it keeps its files, owner and mode" "keep 1000:1000 750" \
    "$(docker run --rm -v ndt2_data:/v:ro "$ALPINE" sh -c 'printf "%s %s" "$(cat /v/keep.txt)" "$(stat -c "%u:%g %a" /v)"' 2>&1)"
  docker volume rm -f ndt2_data ndt2_up nd-test-explicit >/dev/null 2>&1

  # bash 3.2: bash -n catches syntax only, so the file is also scanned for what bash 3.2 lacks, and run there. lib/ is
  # bind-mounted only when the file is there: Docker would make a missing folder itself, as root, inside the repository.
  if [[ ! -f "$LIB" ]]; then
    fail "lib/new-disk-volumes.sh exists, so it can be checked under bash 3.2"
  else
    out="$(docker run --rm -v "$REPO/lib:/nd-lib:ro" "$BASH32" bash -n /nd-lib/new-disk-volumes.sh 2>&1)"
    assert_eq "bash 3.2 parses it" "0|" "$?|$out"
    assert_eq "it uses nothing bash 3.2 lacks" "" \
      "$(grep -nE 'mapfile|readarray|declare -A|local -A|local -n|declare -n|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|\[\[ -v|\|&|&>>' "$LIB" || true)"
    mkdir -p "$WORK/stub"
    cat > "$WORK/stub/docker" <<'EOF'
#!/bin/sh
echo "$*" >> /tmp/calls
case "$*" in
  "compose version") echo "Docker Compose version v5.6.1" ;;
  *"version --short") echo "5.6.1" ;;
  *"config --format json") echo "{}" ;;
  "volume inspect"*) exit 1 ;;
  "volume create"*) echo created ;;
esac
exit 0
EOF
    printf '#!/bin/sh\nprintf "nd-a\\tp\\ta\\nnd-b\\tp\\tb\\n"\n' > "$WORK/stub/python3"
    chmod +x "$WORK/stub/docker" "$WORK/stub/python3"
    out="$(docker run --rm -v "$REPO/lib:/nd-lib:ro" -v "$WORK/stub:/stub:ro" "$BASH32" bash -c '
      export PATH=/stub:$PATH
      . /nd-lib/new-disk-volumes.sh && prepare_new_disk_volumes -p p -f x.yml
      echo "rc=$?"
      echo "creates=$(grep -c "^volume create" /tmp/calls)"' 2>&1)"
    assert_contains "under bash 3.2, with stubs: exit 0" "$out" "rc=0"
    assert_eq "... both volumes reported" 2 "$(count "$out" "New volume nd-")"
    assert_contains "... and created" "$out" "creates=2"
  fi
fi

# ============================================================================
# 2. start.sh and test.sh
# ============================================================================
if wants 2; then
  echo
  echo "2. start.sh and test.sh start on new disks"
  # A copy of the scripts and lib/ with one fake app, so ./start.sh finds it by name. The app's folder name is the
  # Compose project, so ndt3app_data is its volume and ndt3app-app-1 its container.
  M="$WORK/m"
  mkdir -p "$M/apps/ndt3app"
  cp "$REPO/start.sh" "$REPO/stop.sh" "$M/"
  cp -R "$REPO/lib" "$M/lib"
  cat > "$M/apps/ndt3app/docker-compose.yml" <<'EOF'
services:
  app:
    image: nd-test-image:latest
    command: ["sleep", "infinity"]
    volumes:
      - data:/data
volumes:
  data:
EOF
  in_ndapp() { docker exec ndt3app-app-1 sh -c "$1" 2>&1; }
  no_ndapp() { [[ -z "$(docker ps -aq --filter name=ndt3app)" ]] && echo none || echo some; }

  out="$("$M/start.sh" ndt3app 2>&1)"
  assert_eq "./start.sh ndt3app: exit 0" 0 "$?"
  assert_contains "... it makes the volume as a new disk" "$out" "New volume ndt3app_data: shaped like a new cluster disk"
  assert_eq "... the top folder is root's, mode 755, with lost+found and none of the image's files" "0:0 755 lost+found" \
    "$(in_ndapp 'printf "%s %s" "$(stat -c "%u:%g %a" /data)" "$(ls -A /data | tr "\n" " " | sed "s/ $//")"')"

  in_ndapp 'echo k > /data/kept.txt' >/dev/null
  out="$("$M/start.sh" ndt3app 2>&1)"
  assert_eq "./start.sh again: exit 0" 0 "$?"
  assert_lacks "... no new volume" "$out" "New volume"
  assert_eq "... and the volume keeps what it has" "k" "$(in_ndapp 'cat /data/kept.txt')"

  "$M/stop.sh" ndt3app --cleanup >/dev/null 2>&1
  out="$("$M/start.sh" ndt3app --docker-volumes 2>&1)"
  assert_eq "./start.sh --docker-volumes: exit 0" 0 "$?"
  assert_contains "... it says what that means" "$out" "⚠ --docker-volumes: new volumes get Docker's copy of the image's files, owner and mode. A cluster never does this."
  assert_eq "... and Docker copies the image's folder into the new volume" "1000:1000 750 seed.txt" \
    "$(in_ndapp 'printf "%s %s" "$(stat -c "%u:%g %a" /data)" "$(ls /data | tr "\n" " " | sed "s/ up//;s/ $//")"')"

  # A volume that holds Docker's copy (made before this change, or with --docker-volumes) stays as it is on a default
  # start, and Compose says nothing about it.
  out="$("$M/start.sh" ndt3app 2>&1)"
  assert_eq "a default start on a volume that holds Docker's copy: exit 0" 0 "$?"
  assert_lacks "... no new volume" "$out" "New volume"
  assert_lacks "... no warning from Compose" "$out" "already exists"
  assert_eq "... and the volume keeps Docker's copy" "1000:1000 750 seed.txt" \
    "$(in_ndapp 'printf "%s %s" "$(stat -c "%u:%g %a" /data)" "$(ls /data | tr "\n" " " | sed "s/ up//;s/ $//")"')"

  out="$("$M/start.sh" ndt3app --cleanup 2>&1)"
  assert_eq "./start.sh --cleanup: exit 0" 0 "$?"
  assert_eq "... and the volume is a new disk again" "0:0 755 lost+found" \
    "$(in_ndapp 'printf "%s %s" "$(stat -c "%u:%g %a" /data)" "$(ls -A /data | tr "\n" " " | sed "s/ $//")"')"

  "$M/stop.sh" ndt3app --cleanup >/dev/null 2>&1
  mkdir -p "$WORK/nopy"
  printf '#!/bin/sh\nexit 127\n' > "$WORK/nopy/python3"
  chmod +x "$WORK/nopy/python3"
  out="$(PATH="$WORK/nopy:$PATH" "$M/start.sh" ndt3app 2>&1)"
  assert_eq "without python3: exit 1" 1 "$?"
  assert_contains "... with the message" "$out" "✗ start.sh needs python3 to make new volumes like new cluster disks (or start with --docker-volumes)"
  assert_eq "... and nothing started" none "$(no_ndapp)"

  out="$(ND_SHAPER_IMAGE=nd-test-missing:none "$M/start.sh" ndt3app 2>&1)"
  assert_eq "a shaper that can't run: exit 1" 1 "$?"
  assert_contains "... with the message" "$out" "✗ Could not make the new volumes like new cluster disks, so nothing was started. --docker-volumes starts on Docker's copies of the image instead, which a cluster never does."
  assert_eq "... nothing started" none "$(no_ndapp)"
  assert_eq "... and no half-made volume left" "" "$(docker volume ls -q | grep -E '^ndt3app_' || true)"

  # test.sh runs against real apps (the audit does that); here its start is checked by contract.
  bash -n "$REPO/test.sh"
  assert_eq "test.sh parses" 0 "$?"
  up_fn="$(sed -n '/^docker_compose_up()/,/^}/p' "$REPO/test.sh")"
  assert_contains "test.sh's docker_compose_up makes new disks" "$up_fn" "prepare_new_disk_volumes"
  assert_contains "... unless --docker-volumes" "$up_fn" "--docker-volumes"
  out="$(docker run --rm -v "$REPO:/nd-repo:ro" "$BASH32" bash -n /nd-repo/start.sh /nd-repo/test.sh 2>&1)"
  assert_eq "bash 3.2 parses start.sh and test.sh" "0|" "$?|$out"
fi

# ============================================================================
# 3. The runner, tests/new-disk-start.test.sh, on fake apps
# ============================================================================
if wants 3; then
  echo
  echo "3. tests/new-disk-start.test.sh on fake apps"
  RUNNER="$REPO/tests/new-disk-start.test.sh"
  FA="$WORK/fa"
  mkdir -p "$FA" "$WORK/tmp"
  # Two more images: one that runs as uid 1000, and the old and new builds an upgrade check compares.
  printf 'FROM nd-test-image:latest\nUSER 1000\n' > "$WORK/img/Dockerfile.user"
  docker build -q -t nd-test-user:latest -f "$WORK/img/Dockerfile.user" "$WORK/img" >/dev/null
  # serve-200 etc.: an HTTP answer on :8080 for every connection, from busybox nc.
  serve() { printf "while true; do printf 'HTTP/1.1 %s\\\\r\\\\nLocation: http://elsewhere.invalid/\\\\r\\\\nContent-Length: 0\\\\r\\\\nConnection: close\\\\r\\\\n\\\\r\\\\n' | nc -l -p 8080 >/dev/null 2>&1; done" "$1"; }
  up_image() { # TAG MODE: nd-test-up:TAG whose start sets /data's owner (MODE chown-1000 or chown-0) or leaves it (keep)
    local cmd
    case "$2" in
      chown-1000) cmd="chown 1000:1000 /data && $(serve "200 OK")" ;;
      chown-0) cmd="chown 0:0 /data && $(serve "200 OK")" ;;
      keep) cmd="$(serve "200 OK")" ;;
    esac
    printf 'FROM %s\nCMD ["sh", "-c", "%s"]\n' "$ALPINE" "$(printf '%s' "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')" > "$WORK/img/Dockerfile.up"
    docker build -q -t "nd-test-up:$1" -f "$WORK/img/Dockerfile.up" "$WORK/img" >/dev/null
  }
  # fake NAME SERVICES_YAML MANIFEST_YAML: a fake app folder with its compose file and its manifest
  fake() {
    mkdir -p "$FA/$1"
    printf 'services:\n%s\nvolumes:\n  data:\n' "$2" > "$FA/$1/docker-compose.yml"
    printf 'services:\n%s\n' "$3" > "$FA/$1/clv-docker-compose.yml"
  }
  # app_svc COMMAND [EXTRA]: the YAML of one service "app" on nd-test-image with the data volume
  app_svc() {
    printf '  app:\n    image: %s\n    command: ["sh", "-c", "%s"]\n    volumes: ["data:/data"]\n%s' \
      "${IMG:-nd-test-image:latest}" "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')" "${2:-}"
  }
  # probe TYPE PATH PORT DELAY INTERVAL THRESHOLD [ENABLED]: the manifest entry for service "app"
  probe() {
    printf '  app:\n    x-clouve-metadata: {containerName: app, isPublic: true, memoryBase: 1, cpuBase: 0.5}\n'
    printf '    x-clouve-healthcheck: {enabled: %s, type: %s, path: "%s", port: %s, initialDelay: %s, interval: %s, timeout: 2, failureThreshold: %s, successThreshold: 1}\n' \
      "${7:-true}" "$1" "$2" "$3" "$4" "$5" "$6"
  }
  run_fake() { # NAME [RUNNER ARGS...]: the runner on a fake app, quickly
    local name="$1"
    shift
    NEW_DISK_PROJECT_PREFIX=ndt9 NEW_DISK_PROBE_EVERY=1 TMPDIR="$WORK/tmp" \
      timeout 300 bash "$RUNNER" --no-build --settle 3 "$@" "$FA/$name" 2>&1
  }
  project_of() { sed -n 's/^== .* (project \(ndt9-[a-z0-9_-]*\))$/\1/p' <<< "$1" | head -n 1; }

  if [[ ! -f "$RUNNER" ]]; then
    fail "tests/new-disk-start.test.sh exists"
  else
    # 1. A good app.
    fake good "$(app_svc "echo ok > /data/ok && $(serve "200 OK")")" "$(probe HTTP / 8080 1 3 10)"
    out="$(run_fake good)"
    rc=$?
    assert_eq "1. a good app: exit 0" 0 "$rc"
    assert_contains "... PASS line for the container" "$out" "  PASS app: healthy after"
    assert_contains "... and for the target" "$out" "PASS good"
    # 12. It leaves nothing behind.
    P="$(project_of "$out")"
    if [[ -n "$P" ]]; then pass "12. the run names its project ($P)"; else fail "12. the run names its project"; fi
    assert_eq "12. no container, volume or network of the run is left" "||" \
      "$(docker ps -aq --filter "label=com.docker.compose.project=$P")|$(docker volume ls -q --filter "label=com.docker.compose.project=$P")|$(docker network ls -q --filter "label=com.docker.compose.project=$P")"
    assert_eq "12. nor its prober or its override file" "|" \
      "$(docker ps -aq --filter "name=^$P-ndprobe\$")|$(ls -A "$WORK/tmp")"

    # 2. An app that needs a file its image keeps at the volume path.
    fake needscopy "$(app_svc "test -f /data/seed.txt || exit 3; $(serve "200 OK")")" "$(probe HTTP / 8080 1 3 10)"
    out="$(run_fake needscopy)"
    assert_eq "2. an app that needs the image's files in its volume: exit 1" 1 "$?"
    assert_contains "... it exited with code 3" "$out" "  FAIL app: exited with code 3"
    assert_contains "... FAIL for the target" "$out" "FAIL needscopy"

    # 3. An app that runs as uid 1000 and writes to its volume.
    IMG=nd-test-user:latest fake nonroot "$(IMG=nd-test-user:latest app_svc "touch /data/x || exit 4; $(serve "200 OK")")" "$(probe HTTP / 8080 1 3 10)"
    out="$(run_fake nonroot)"
    assert_contains "3. an app that runs as uid 1000: it exited with code 4" "$out" "  FAIL app: exited with code 4"
    assert_contains "... and a permission line shows why" "$out" "    permission: "
    assert_contains "... with the error" "$out" "Permission denied"

    # 4. An app that answers after its deadline (1 + 2 x 3 = 7 s).
    fake slow "$(app_svc "sleep 20; $(serve "200 OK")")" "$(probe HTTP / 8080 1 3 2)"
    out="$(run_fake slow)"
    assert_contains "4. an app that answers too late: not healthy within its 7 s" "$out" "  FAIL app: not healthy within 7 s (last probe: "

    # 5. An app that passes, then exits, with a restart policy.
    fake crash "$(app_svc "($(serve "200 OK")) & sleep 2; exit 5" "    restart: unless-stopped
")" "$(probe HTTP / 8080 1 3 10)"
    out="$(run_fake crash)"
    assert_contains "5. an app that passes and then exits: it restarted" "$out" "  FAIL app: restarted"

    # 6. HTTP status codes: a redirect passes, a 500 fails.
    fake redirect "$(app_svc "$(serve "302 Found")")" "$(probe HTTP / 8080 1 3 10)"
    out="$(run_fake redirect)"
    assert_contains "6. HTTP 302: PASS (a redirect counts and is not followed)" "$out" "  PASS app: healthy after"
    fake err500 "$(app_svc "$(serve "500 Internal Server Error")")" "$(probe HTTP / 8080 1 3 2)"
    out="$(run_fake err500)"
    assert_contains "6. HTTP 500: FAIL with the status" "$out" "last probe: HTTP 500"

    # 7. Command probes.
    fake cmdbad "$(app_svc "sleep 600")" "$(probe Command "exit 1" 80 1 3 2)"
    out="$(run_fake cmdbad)"
    assert_contains "7. a command probe that exits 1: FAIL" "$out" "  FAIL app: not healthy within 7 s"
    fake cmdok "$(app_svc "sleep 600")" "$(probe Command "exit 0" 80 1 3 2)"
    out="$(run_fake cmdok)"
    assert_contains "7. a command probe that exits 0: PASS" "$out" "  PASS app: healthy after"

    # 8. A probe that is off: the container must run and not restart.
    fake offok "$(app_svc "sleep 600")" "$(probe HTTP / 8080 1 3 2 false)"
    out="$(run_fake offok)"
    assert_contains "8. probe off, the app runs: PASS" "$out" "  PASS app:"
    fake offexit "$(app_svc "sleep 2; exit 6")" "$(probe HTTP / 8080 1 3 2 false)"
    out="$(run_fake offexit)"
    assert_contains "8. probe off, the app exits: FAIL" "$out" "  FAIL app: exited with code 6"

    # 9. Published ports and fixed container names are dropped, so a run never collides with a local stack.
    docker run -d --name ndt9_fixed -p 18093:8080 nd-test-image:latest sleep 600 >/dev/null
    fake fixed "$(app_svc "$(serve "200 OK")" "    container_name: ndt9_fixed
    ports: [\"18093:8080\"]
")" "$(probe HTTP / 8080 1 3 10)"
    out="$(run_fake fixed)"
    assert_contains "9. next to a container with the same name and port: PASS" "$out" "PASS fixed"
    docker rm -f ndt9_fixed >/dev/null 2>&1

    # 10. The Magneto Agent's service is left out unless asked for.
    fake agent "$(app_svc "$(serve "200 OK")")
  magneto-agent:
    image: nd-test-image:latest
    command: [\"sleep\", \"600\"]" "$(probe HTTP / 8080 1 3 10)"
    out="$(run_fake agent)"
    assert_contains "10. magneto-agent is left out" "$out" "  skipped magneto-agent (--with-agent includes it)"
    assert_lacks "... and never judged" "$out" "magneto-agent: "
    out="$(run_fake agent --with-agent)"
    assert_contains "10. with --with-agent it runs too" "$out" "  PASS magneto-agent:"

    # 11. Each container gets its smallest plan's CPU and memory (cpuBase 0.5, memoryBase 1).
    out="$(run_fake good --keep)"
    P="$(project_of "$out")"
    assert_eq "11. cpus and memory from cpuBase and memoryBase, and no swap beyond it (GKE has none)" \
      "500000000 1073741824 1073741824" \
      "$(docker inspect -f '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' "$P-app-1" 2>&1)"
    docker compose -p "$P" -f "$FA/good/docker-compose.yml" down -v >/dev/null 2>&1

    # 13. --upgrade-from: the old build installs, the current one restarts on the same volumes.
    up_image old chown-1000
    up_image latest keep
    printf 'services:\n  app:\n    image: nd-test-up\n    volumes: ["data:/data"]\nvolumes:\n  data:\n' > "$WORK/up-compose.yml"
    mkdir -p "$FA/upgrade"
    cp "$WORK/up-compose.yml" "$FA/upgrade/docker-compose.yml"
    probe HTTP / 8080 1 3 10 > "$FA/upgrade/clv-docker-compose.yml.svc"
    printf 'services:\n%s\n' "$(cat "$FA/upgrade/clv-docker-compose.yml.svc")" > "$FA/upgrade/clv-docker-compose.yml"
    rm -f "$FA/upgrade/clv-docker-compose.yml.svc"
    out="$(run_fake upgrade --upgrade-from old)"
    assert_eq "13. --upgrade-from old, a new build that keeps the folder: exit 0" 0 "$?"
    assert_contains "... PASS" "$out" "PASS upgrade"
    up_image latest chown-0
    out="$(run_fake upgrade --upgrade-from old)"
    assert_contains "13. a new build that changes the folder's owner: FAIL" "$out" \
      "_data changed from 1000:1000 755 to 0:0 755"

    # 14. A probe that never passes ends at the deadline, and the run doesn't hang.
    fake never "$(app_svc "$(serve "200 OK")")" "$(probe TCP / 9999 1 3 2)"
    started=$SECONDS
    out="$(run_fake never)"
    assert_contains "14. a port nothing listens on: FAIL at the deadline" "$out" "  FAIL app: not healthy within 7 s (last probe: "
    if (( SECONDS - started < 60 )); then pass "14. ... in under 60 s ($((SECONDS - started)) s)"; else
      fail "14. ... in under 60 s (took $((SECONDS - started)) s)"; fi

    # 15-16. In the settle period, as on the platform, a probe may fail for less than failureThreshold x interval
    # (here 2 x 3 = 6 s) without harm. Nextcloud's does for a few seconds between its install and Apache's start.
    # $$ is Compose's escape for $.
    fake blip "$(app_svc "($(serve "200 OK")) & P=\$\$!; sleep 3; kill \$\$P; sleep 3; $(serve "200 OK")")" \
      "$(probe HTTP / 8080 1 3 2)"
    out="$(run_fake blip --settle 12)"
    assert_contains "15. a probe that fails for 3 s in the settle period: PASS" "$out" "PASS blip"
    assert_contains "... with a note" "$out" "  note: app failed its probe for "
    fake outage "$(app_svc "($(serve "200 OK")) & P=\$\$!; sleep 3; kill \$\$P; sleep 600")" "$(probe HTTP / 8080 1 3 2)"
    out="$(run_fake outage --settle 15)"
    assert_contains "16. a probe that keeps failing past its 6 s: FAIL" "$out" \
      "  FAIL app: kept failing its probe for "
    assert_contains "... naming the tolerance" "$out" "past the 6 s the platform tolerates"

    # 17. A probe that is failing when the settle period ends, still inside its tolerance (2 x 4 = 8 s), is probed on
    # until it passes again: the platform wouldn't act on it either.
    fake endblip "$(app_svc "($(serve "200 OK")) & P=\$\$!; sleep 3; kill \$\$P; pkill nc; sleep 5; $(serve "200 OK")")" \
      "$(probe HTTP / 8080 1 4 2)"
    out="$(run_fake endblip --settle 4)"
    assert_contains "17. a probe failing as the settle period ends, inside its tolerance: PASS" "$out" "PASS endblip"
    assert_contains "... with a note" "$out" "  note: app failed its probe for "

    # 18. A container whose first pass comes after its deadline fails, even when the start of the stack kept the
    # probes from running sooner: Compose waits here for db's own health check (it passes after 10 s), and db's
    # deadline is 1 + 2 x 3 = 7 s. Kubernetes starts every pod at once and would have restarted db by then.
    mkdir -p "$FA/late"
    printf '%s\n' 'services:' '  db:' '    image: nd-test-image:latest' \
      '    command: ["sh", "-c", "sleep 10; touch /tmp/ready; sleep 600"]' \
      '    healthcheck: {test: ["CMD", "test", "-f", "/tmp/ready"], interval: 1s, retries: 60}' \
      '    volumes: ["data:/data"]' '  app:' '    image: nd-test-image:latest' '    command: ["sleep", "600"]' \
      '    depends_on: {db: {condition: service_healthy}}' 'volumes:' '  data:' > "$FA/late/docker-compose.yml"
    printf '%s\n' 'services:' '  db:' \
      '    x-clouve-healthcheck: {enabled: true, type: Command, path: "test -f /tmp/ready", port: 1, initialDelay: 1, interval: 3, timeout: 2, failureThreshold: 2, successThreshold: 1}' \
      '  app:' '    x-clouve-healthcheck: {enabled: false, type: TCP, port: 1}' > "$FA/late/clv-docker-compose.yml"
    out="$(run_fake late)"
    assert_contains "18. a first pass after the deadline: FAIL" "$out" "  FAIL db: passed its probe only after "
    assert_contains "... naming the deadline" "$out" "past its 7 s deadline"

    # 19. HTTP as the kubelet probes it: it asks the container's IP (so the Host header is the IP, as with a pod), follows
    # redirects to the same host and judges the last answer. A small Python server answers / with a redirect to /next.
    mkdir -p "$WORK/py"
    cat > "$WORK/py/server.py" <<'PYSRV'
import http.server, ipaddress, os

MODE = os.environ.get("MODE", "")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get("Host", "").rsplit(":", 1)[0]
        try:
            ipaddress.ip_address(host)
            by_ip = True
        except ValueError:
            by_ip = False
        if MODE == "name-only" and by_ip:
            return self.answer(400)
        if self.path == "/":
            return self.answer(302, "/next")
        return self.answer(500 if MODE == "redirect-500" else 200)

    def answer(self, code, location=None):
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.HTTPServer(("", 8080), Handler).serve_forever()
PYSRV
    printf 'FROM mirror.gcr.io/library/python:3.12-alpine\nCOPY server.py /server.py\nCMD ["python", "/server.py"]\n' > "$WORK/py/Dockerfile"
    docker build -q -t nd-test-py:latest "$WORK/py" >/dev/null
    for mode in redirect-500 redirect-200 name-only; do
      fake "$mode" "$(printf '  app:\n    image: nd-test-py:latest\n    environment: {MODE: %s}\n    volumes: ["data:/data"]\n' "$mode")" \
        "$(probe HTTP / 8080 1 3 2)"
    done
    out="$(run_fake redirect-500)"
    assert_contains "19. a redirect to a page on the same host that answers 500: FAIL" "$out" "last probe: HTTP 500"
    out="$(run_fake redirect-200)"
    assert_contains "19. a redirect to a page on the same host that answers 200: PASS" "$out" "PASS redirect-200"
    out="$(run_fake name-only)"
    assert_contains "19. an app that refuses its IP as the Host (a pod's probe uses the IP): FAIL" "$out" "last probe: HTTP 400"

    # The deadline never passes the platform's 600 s, whatever the probe's settings add up to.
    assert_eq "the deadline is capped at 600 s" 600 "$(python3 -B - "$REPO/tests/lib/new_disk_start.py" <<'PYCAP' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("nd", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.Target.deadline(None, {"initialDelay": 100, "failureThreshold": 100, "interval": 100}))
PYCAP
)"
  fi
fi


# ============================================================================
# 4. Pass records and the push gate
# ============================================================================
if wants 4; then
  echo
  echo "4. lib/new-disk-passes.sh, the runner's records and build.sh's gate"
  PASSES_LIB="$REPO/lib/new-disk-passes.sh"
  G="$WORK/g"
  mkdir -p "$G/apps/alpha/image" "$G/apps/beta/image" "$G/apps/gamma/image" "$G/bundles/delta" "$G/tests/lib" \
    "$WORK/passes" "$WORK/gbin" "$WORK/tmp"
  cp "$REPO"/build.sh "$REPO"/build-uat.sh "$REPO"/build-prod.sh "$REPO"/build-dev.sh "$REPO"/build-e2e.sh "$G/"
  cp -R "$REPO/lib" "$G/lib"
  cp "$REPO/tests/new-disk-start.test.sh" "$G/tests/"
  cp "$REPO/tests/lib/new_disk_start.py" "$G/tests/lib/"
  for a in alpha beta gamma; do
    printf 'FROM scratch\n' > "$G/apps/$a/image/Dockerfile"
    printf 'APP_IMAGE="%s"\n' "$a" > "$G/apps/$a/image/build.config"
  done
  printf 'apps/alpha/ignored.txt\n' > "$G/.gitignore"
  # eps runs an image of the build's own registry that its build doesn't make (a pinned tag)
  mkdir -p "$G/apps/eps/image"
  printf 'FROM scratch\n' > "$G/apps/eps/image/Dockerfile"
  printf 'APP_IMAGE="nd-test-own"\n' > "$G/apps/eps/image/build.config"
  printf 'services:\n  app:\n    image: r.clv.zone/e2eorg/nd-test-own:pinned\n    command: ["sleep", "600"]\n' > "$G/apps/eps/docker-compose.yml"
  printf 'services:\n  app:\n    x-clouve-healthcheck: {enabled: false, type: TCP, port: 1}\n' > "$G/apps/eps/clv-docker-compose.yml"
  docker tag nd-test-image:latest r.clv.zone/e2eorg/nd-test-own:pinned
  # gamma and delta can really start: one container, its probe off, so it passes once it runs.
  for d in apps/gamma bundles/delta; do
    printf 'services:\n  app:\n    image: nd-test-image:latest\n    command: ["sleep", "600"]\n    volumes: ["data:/data"]\nvolumes:\n  data:\n' \
      > "$G/$d/docker-compose.yml"
    printf 'services:\n  app:\n    x-clouve-healthcheck: {enabled: false, type: TCP, port: 1}\n' > "$G/$d/clv-docker-compose.yml"
  done
  git -C "$G" init -q && git -C "$G" add -A &&
    git -C "$G" -c user.name=t -c user.email=t@example.invalid commit -qm init
  export MAGNETO_NEW_DISK_PASS_DIR="$WORK/passes"
  # in_g CODE: CODE in bash, in the throwaway repository, with lib/new-disk-passes.sh loaded
  # shellcheck source=/dev/null
  in_g() { (cd "$G" && . lib/new-disk-passes.sh && eval "$1"); }

  if [[ ! -f "$PASSES_LIB" ]]; then
    fail "lib/new-disk-passes.sh exists"
  else
    h1="$(in_g 'nd_source_hash apps/alpha')"
    if [[ "$h1" =~ ^[0-9a-f]{64}$ ]]; then pass "the source hash is a sha256"; else fail "the source hash is a sha256 (got $h1)"; fi
    assert_eq "the same source gives the same hash" "$h1" "$(in_g 'nd_source_hash apps/alpha')"
    echo '# edit' >> "$G/apps/alpha/image/Dockerfile"
    h2="$(in_g 'nd_source_hash apps/alpha')"
    git -C "$G" checkout -q -- apps/alpha/image/Dockerfile
    if [[ "$h2" != "$h1" ]]; then pass "an edited tracked file changes it"; else fail "an edited tracked file changes it"; fi
    echo new > "$G/apps/alpha/new.txt"
    h3="$(in_g 'nd_source_hash apps/alpha')"
    rm -f "$G/apps/alpha/new.txt"
    if [[ "$h3" != "$h1" ]]; then pass "a new untracked file changes it"; else fail "a new untracked file changes it"; fi
    echo ignored > "$G/apps/alpha/ignored.txt"
    assert_eq "an ignored file doesn't" "$h1" "$(in_g 'nd_source_hash apps/alpha')"
    echo '# edit' >> "$G/apps/beta/image/Dockerfile"
    assert_eq "nor a change in another app" "$h1" "$(in_g 'nd_source_hash apps/alpha')"
    git -C "$G" checkout -q -- apps/beta/image/Dockerfile
    # shellcheck source=/dev/null
    out="$(cd "$WORK" && . "$G/lib/new-disk-passes.sh" && nd_source_hash "$WORK/passes" 2>&1)"
    assert_eq "outside a git work tree: status 1 and a message" "1|yes" "$?|$([[ "$out" == *"✗"* ]] && echo yes)"

    in_g 'nd_has_pass alpha apps/alpha'
    assert_eq "no record: no pass" 1 "$?"
    in_g 'nd_record_pass alpha "$(nd_source_hash apps/alpha)" 90'
    in_g 'nd_has_pass alpha apps/alpha'
    assert_eq "a record for the current source: a pass" 0 "$?"
    assert_eq "the record holds the source, the time and the settle" "source time settle" \
      "$(cut -d= -f1 "$WORK/passes/alpha" | tr '\n' ' ' | sed 's/ $//')"
    echo '# edit' >> "$G/apps/alpha/image/Dockerfile"
    in_g 'nd_has_pass alpha apps/alpha'
    assert_eq "after an edit: no pass" 1 "$?"
    git -C "$G" checkout -q -- apps/alpha/image/Dockerfile

    # A git that fails to list the files is an error, never the hash of nothing (that would match any other failure).
    mkdir -p "$WORK/gitfail"
    printf '#!/bin/sh\ncase "$*" in *ls-files*) exit 128 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$WORK/gitfail/git"
    chmod +x "$WORK/gitfail/git"
    # shellcheck source=/dev/null
    out="$(cd "$G" && . lib/new-disk-passes.sh && PATH="$WORK/gitfail:$PATH" nd_source_hash apps/alpha 2>&1)"
    assert_eq "a git that can't list the files: status 1 and a message" "1|yes" "$?|$([[ "$out" == *"✗"* ]] && echo yes)"
    # A pass from a shortened run (a --settle below the full 90 s) doesn't count for a push.
    in_g 'nd_record_pass alpha "$(nd_source_hash apps/alpha)" 2'
    in_g 'nd_has_pass alpha apps/alpha'
    assert_eq "a pass from a run with a 2 s settle: no pass for a push" 1 "$?"
    in_g 'nd_record_pass alpha "$(nd_source_hash apps/alpha)" 90'
    in_g 'nd_has_pass alpha apps/alpha'
    assert_eq "... and with the full 90 s: a pass" 0 "$?"
  fi

  # build.sh with docker stubbed, as in tests/build-prune.test.sh: every call recorded, nothing built or pushed.
  {
    echo '#!/bin/bash'
    echo 'echo "docker $*" >> "$CALLS"'
    echo 'case "$1 $2" in'
    echo '  "buildx version") exit 0 ;;'
    echo '  "buildx inspect") [[ -f "$STATE/builder-$3" ]] ;;'
    echo '  "buildx create")  for a in "$@"; do [[ "${prev:-}" == "--name" ]] && touch "$STATE/builder-$a"; prev="$a"; done ;;'
    echo '  "context show")   echo default ;;'
    echo '  *) exit 0 ;;'
    echo 'esac'
  } > "$WORK/gbin/docker"
  chmod +x "$WORK/gbin/docker"
  # build SCRIPT ARGS...: the copy of SCRIPT in the throwaway repository; sets RC, OUT and CALLS_TXT
  build() {
    local script="$1" state
    shift
    state="$(mktemp -d "$WORK/state.XXXX")"
    touch "$state/builder-default" "$state/builder-multiplatform-builder" "$state/calls.log"
    RC=0
    CALLS="$state/calls.log" STATE="$state" PATH="$WORK/gbin:$PATH" bash "$G/$script" "$@" > "$state/out.log" 2>&1 || RC=$?
    OUT="$(cat "$state/out.log")"
    CALLS_TXT="$(cat "$state/calls.log")"
  }
  rm -f "$WORK/passes/"*
  NEW_DISK_GATE=1 build build.sh alpha --push
  assert_eq "the gate, no pass: exit 1" 1 "$RC"
  assert_contains "... it names the test to run" "$OUT" \
    "✗ alpha: no new-disk pass for its current source. Run: bash tests/new-disk-start.test.sh alpha"
  assert_contains "... and the override" "$OUT" "(or push anyway with --skip-new-disk-check)"
  assert_eq "... before any docker call" "" "$CALLS_TXT"
  in_g 'nd_record_pass alpha "$(nd_source_hash apps/alpha)" 90' 2>/dev/null
  NEW_DISK_GATE=1 build build.sh alpha --push
  assert_eq "with a pass for the current source: it builds" "0|1" "$RC|$([[ "$CALLS_TXT" == *"buildx build"* ]] && echo 1)"
  NEW_DISK_GATE=1 build build.sh beta --push --skip-new-disk-check
  assert_eq "--skip-new-disk-check: it builds" "0|1" "$RC|$([[ "$CALLS_TXT" == *"buildx build"* ]] && echo 1)"
  assert_contains "... and says so" "$OUT" "⚠ Pushing without the new-disk check (--skip-new-disk-check)"
  NEW_DISK_GATE=1 build build.sh --all --push
  assert_eq "--all with a pass for alpha only: exit 1" 1 "$RC"
  assert_contains "... naming beta" "$OUT" "✗ beta: no new-disk pass"
  assert_lacks "... not alpha" "$OUT" "✗ alpha:"
  assert_eq "... before any docker call" "" "$CALLS_TXT"
  NEW_DISK_GATE=1 build build.sh --all --push --skip-new-disk-check
  assert_eq "--all --skip-new-disk-check: every app builds" "0|4" "$RC|$(grep -c 'buildx build' <<< "$CALLS_TXT")"
  build build.sh beta --push
  assert_eq "no NEW_DISK_GATE: no gate" 0 "$RC"
  build build-dev.sh beta --push
  assert_eq "build-dev.sh: no gate" 0 "$RC"
  build build-e2e.sh beta --push
  assert_eq "build-e2e.sh: no gate" 0 "$RC"
  NEW_DISK_GATE=1 build build.sh beta
  assert_eq "no --push: no gate" 0 "$RC"
  # The wrappers turn the gate on: with a stub build.sh that prints it.
  W="$WORK/w"
  mkdir -p "$W"
  cp "$REPO"/build-uat.sh "$REPO"/build-prod.sh "$REPO"/build-dev.sh "$REPO"/build-e2e.sh "$W/"
  printf '#!/bin/bash\necho "gate=${NEW_DISK_GATE:-}"\n' > "$W/build.sh"
  chmod +x "$W/build.sh"
  assert_eq "build-uat.sh and build-prod.sh turn it on, the others don't" "gate=1 gate=1 gate= gate=" \
    "$(env -u NEW_DISK_GATE bash "$W/build-uat.sh" x) $(env -u NEW_DISK_GATE bash "$W/build-prod.sh" x) $(env -u NEW_DISK_GATE bash "$W/build-dev.sh" x) $(env -u NEW_DISK_GATE bash "$W/build-e2e.sh" x)"

  # The runner records a pass only for an app it built.
  printf '#!/bin/bash\necho "REGISTRY=${REGISTRY-unset}" > "%s/build-env"\necho "stub build $*"\n' "$WORK" > "$WORK/gbin/stub-build"
  chmod +x "$WORK/gbin/stub-build"
  rm -f "$WORK/passes/"*
  # gnd ARGS...: the copy of the runner in the throwaway repository, quickly
  gnd() { NEW_DISK_BUILD_CMD="$WORK/gbin/stub-build" NEW_DISK_PROJECT_PREFIX=ndt9 NEW_DISK_PROBE_EVERY=1 TMPDIR="$WORK/tmp" \
      timeout 300 bash "$G/tests/new-disk-start.test.sh" --settle 2 "$@" 2>&1; }
  out="$(gnd gamma)"
  assert_contains "the runner builds the app, it passes" "$out" "PASS gamma"
  assert_contains "... and it records the pass" "$out" "  Recorded a new-disk pass for gamma (source "
  if [[ -f "$PASSES_LIB" ]]; then
    assert_eq "... for the source it built" "$(in_g 'nd_source_hash apps/gamma')" \
      "$(sed -n 's/^source=//p' "$WORK/passes/gamma" 2>/dev/null)"
  fi
  rm -f "$WORK/passes/"*
  out="$(gnd --no-build gamma)"
  assert_eq "--no-build: it passes, and no record" "1|no" \
    "$(grep -c '^PASS gamma' <<< "$out")|$([[ -e "$WORK/passes/gamma" ]] && echo yes || echo no)"
  out="$(gnd delta)"
  assert_eq "a bundle: it passes, and no record" "1|" \
    "$(grep -c '^PASS delta' <<< "$out")|$(ls -A "$WORK/passes")"

  # The runner's python3 keeps the user's site-packages, where pip --user puts PyYAML (macOS's python3 does): no -I or -s.
  assert_eq "the runner's python3 keeps the user's site-packages" "" \
    "$(grep -nE 'python3 +-[A-Za-z]*[Is]' "$REPO/tests/new-disk-start.test.sh" || true)"
  # The build runs without REGISTRY, so it makes the images the compose file runs, whatever the caller's shell has.
  out="$(REGISTRY=demo.cr0.io/nd-test gnd gamma)"
  assert_eq "the build runs with REGISTRY unset" "REGISTRY=unset" "$(cat "$WORK/build-env" 2>/dev/null)"
  assert_contains "... and the shortened run's record says so" "$out" "too short for a UAT or prod push"
  assert_eq "... it holds the settle" "settle=2" "$(grep '^settle=' "$WORK/passes/gamma" 2>/dev/null)"
  rm -f "$WORK/passes/"*
  # An image the build makes (r.clv.zone/e2eorg/...) that isn't the one this run built: no pass is recorded.
  out="$(gnd eps)"
  assert_contains "a target that runs an own image the build didn't make: it passes" "$out" "PASS eps"
  assert_contains "... but no pass is recorded" "$out" \
    "No pass recorded: r.clv.zone/e2eorg/nd-test-own:pinned is not the image this run's build made"
  assert_eq "... and there is no record" "no" "$([[ -e "$WORK/passes/eps" ]] && echo yes || echo no)"

  # bash 3.2, the version macOS ships, for the library and build.sh.
  if [[ -f "$PASSES_LIB" ]]; then
    out="$(docker run --rm -v "$REPO:/nd-repo:ro" "$BASH32" bash -n /nd-repo/lib/new-disk-passes.sh /nd-repo/build.sh 2>&1)"
    assert_eq "bash 3.2 parses lib/new-disk-passes.sh and build.sh" "0|" "$?|$out"
    gate_fn="$(sed -n '/^new_disk_gate()/,/^}/p' "$REPO/build.sh")"
    assert_eq "they use nothing bash 3.2 lacks" "" \
      "$( (cat "$PASSES_LIB"; printf '%s\n' "$gate_fn") | grep -nE 'mapfile|readarray|declare -A|local -A|local -n|declare -n|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|\[\[ -v|\|&|&>>' || true)"
    mkdir -p "$WORK/stub32"
    printf '#!/bin/sh\ncase "$*" in *rev-parse*) exit 0 ;; *ls-files*) printf "a\\000" ;; esac\nexit 0\n' > "$WORK/stub32/git"
    printf '#!/bin/sh\necho "$STUB_HASH"\n' > "$WORK/stub32/python3"
    chmod +x "$WORK/stub32/git" "$WORK/stub32/python3"
    out="$(docker run --rm -v "$REPO/lib:/nd-lib:ro" -v "$WORK/stub32:/stub:ro" "$BASH32" bash -c '
      export PATH=/stub:$PATH MAGNETO_NEW_DISK_PASS_DIR=/tmp/p
      . /nd-lib/new-disk-passes.sh
      mkdir -p /tmp/app
      STUB_HASH=aaa nd_record_pass app aaa 90 && STUB_HASH=aaa nd_has_pass app /tmp/app; echo "same=$?"
      STUB_HASH=bbb nd_has_pass app /tmp/app; echo "changed=$?"' 2>&1)"
    assert_contains "under bash 3.2, with stubs: a record, then a pass" "$out" "same=0"
    assert_contains "... and no pass once the hash changes" "$out" "changed=1"
  fi

  bash "$REPO/tests/build-prune.test.sh" >/dev/null 2>&1
  assert_eq "tests/build-prune.test.sh still passes" 0 "$?"
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  printf '%sAll new-disk volume checks passed.%s\n' "$GREEN" "$NC"
else
  printf '%sNew-disk volume checks failed.%s\n' "$RED" "$NC"
  exit 1
fi
