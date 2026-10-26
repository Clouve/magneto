#!/bin/bash
# lib/new-disk-volumes.sh: Docker Compose volumes in the shape a cluster gives a new install.
#
# On a cluster, each volume of a new install is a new disk: an empty filesystem whose top folder is root's, mode 755,
# with lost+found (root's, mode 700) in it. None of the files the image keeps at that path are there. Docker fills a new
# named volume with a copy of the image's folder instead (its files, owner and mode) the first time a container mounts
# it, so a local start would hide what a first start on a cluster looks like. Making each missing volume here, before
# Compose creates the containers, gives local starts the cluster's volumes: Docker only copies into an empty volume, and
# these hold lost+found. A volume that exists already is never touched.
#
# Source this file. It only defines functions and changes no shell option. It runs on bash 3.2 (the version macOS ships)
# and needs Docker, Docker Compose v2 or later and python3 (its standard library only).
#
#   prepare_new_disk_volumes [COMPOSE_ARGS...]  makes each missing volume of the project as a new disk
#   nd_compose_volumes [COMPOSE_ARGS...]         lists the project's named volumes: full name, project, key
#   nd_make_new_disk FULL_NAME PROJECT KEY       makes one volume as a new disk
#   nd_shaper_ready                              fetches the image that shapes volumes, when it isn't here
#   nd_compose ARGS...                           docker compose, or docker-compose where the plugin is missing
#
# COMPOSE_ARGS are Compose's global options (-p NAME, -f FILE, ...), and the caller runs these functions from the folder
# Compose would run in. ND_SHAPER_IMAGE names the small image that shapes a volume (default
# mirror.gcr.io/library/alpine:3.20). Errors start with ✗ and go to stderr.

# nd_compose ARGS...: Compose, as the plugin when Docker has it, else as the standalone docker-compose.
nd_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# nd_compose_volumes [COMPOSE_ARGS...]: one line per named volume that a service mounts, each once, as
# "<full name><TAB><project><TAB><key>". Compose's own configuration names them, so a volume with an explicit name: is
# listed by that name. External volumes are not listed (they are not the project's to make), nor are anonymous ones.
# Status 1 when Compose can't read the configuration or python3 can't read Compose's answer.
nd_compose_volumes() {
    local json
    json="$(nd_compose "$@" config --format json)" || return 1
    printf '%s' "$json" | python3 -c '
import json, sys
config = json.load(sys.stdin)
project = config.get("name", "")
volumes = config.get("volumes") or {}
keys = []
for service in (config.get("services") or {}).values():
    for mount in service.get("volumes") or []:
        key = mount.get("source")
        if mount.get("type") != "volume" or not key or key in keys:
            continue
        if (volumes.get(key) or {}).get("external"):
            continue
        keys.append(key)
for key in keys:
    name = (volumes.get(key) or {}).get("name") or "%s_%s" % (project, key)
    print("%s\t%s\t%s" % (name, project, key))
'
}

# nd_shaper_image: the small image that shapes new volumes (ND_SHAPER_IMAGE, default alpine from mirror.gcr.io).
nd_shaper_image() {
    printf '%s\n' "${ND_SHAPER_IMAGE:-mirror.gcr.io/library/alpine:3.20}"
}

# nd_shaper_ready: makes sure the shaper image is on this machine, fetching it when it isn't. prepare_new_disk_volumes
# calls it before it makes any volume, so a fetch that fails, or is cut off, leaves no empty volume behind (Docker would
# fill an empty one with its copy of the image at the next start). Status 1 when it can't be fetched.
nd_shaper_ready() {
    local image err
    image="$(nd_shaper_image)"
    docker image inspect "$image" >/dev/null 2>&1 && return 0
    if ! err="$(docker pull -q "$image" 2>&1 >/dev/null)"; then
        printf '✗ could not fetch %s, the image that shapes new volumes: %s\n' "$image" "$err" >&2
        return 1
    fi
}

# nd_make_new_disk FULL_NAME PROJECT KEY: creates the volume with the labels Compose puts on its own volumes (so Compose
# adopts it without a warning, and down -v removes it), then shapes it like a new disk. The shaper refuses a volume
# that holds anything: then the volume existed after all (a docker volume inspect that failed, or a second start of the
# same project racing this one), and it is left exactly as it is. Status 0 when the volume is a new disk now, 2 when it
# held files and was left alone, 1 when it failed; a volume that holds nothing but what this call made is then removed
# again, so a later start never finds a half-made one. Callers make sure the shaper image is there (nd_shaper_ready).
nd_make_new_disk() {
    local name="$1" project="$2" key="$3" image version err status
    image="$(nd_shaper_image)"
    version="$(nd_compose version --short 2>/dev/null)" || version=""
    if ! err="$(docker volume create \
        --label "com.docker.compose.project=$project" \
        --label "com.docker.compose.volume=$key" \
        --label "com.docker.compose.version=$version" \
        "$name" 2>&1 >/dev/null)"; then
        printf '✗ could not create the volume %s: %s\n' "$name" "$err" >&2
        return 1
    fi
    err="$(docker run --rm --network none -v "$name:/v" "$image" \
        sh -c 'if [ -n "$(ls -A /v)" ]; then exit 3; fi; chown 0:0 /v && chmod 755 /v && mkdir -m 700 /v/lost+found' \
        2>&1 >/dev/null)"
    status=$?
    case "$status" in
        0) return 0 ;;
        3) return 2 ;;
    esac
    if docker run --rm --network none -v "$name:/v" "$image" \
        sh -c '[ -z "$(ls -A /v | grep -v "^lost+found$")" ]' >/dev/null 2>&1; then
        docker volume rm -f "$name" >/dev/null 2>&1
    fi
    printf '✗ could not shape the volume %s like a new disk: %s\n' "$name" "$err" >&2
    return 1
}

# prepare_new_disk_volumes [COMPOSE_ARGS...]: makes each of the project's volumes that doesn't exist yet as a new disk,
# with one line for each. Prints nothing when every volume exists. Status 1 at the first failure.
prepare_new_disk_volumes() {
    local list missing="" name project key
    if ! command -v python3 >/dev/null 2>&1; then
        printf '✗ python3 is needed to read the Compose configuration\n' >&2
        return 1
    fi
    if ! list="$(nd_compose_volumes "$@")"; then
        printf '✗ could not read the Compose configuration of this project\n' >&2
        return 1
    fi
    while IFS=$'\t' read -r name project key; do
        [ -n "$name" ] || continue
        if ! docker volume inspect "$name" >/dev/null 2>&1; then
            missing="$missing$name"$'\t'"$project"$'\t'"$key"$'\n'
        fi
    done <<EOF
$list
EOF
    [ -n "$missing" ] || return 0
    nd_shaper_ready || return 1
    while IFS=$'\t' read -r name project key; do
        [ -n "$name" ] || continue
        nd_make_new_disk "$name" "$project" "$key"
        case $? in
            0) printf "  New volume %s: shaped like a new cluster disk (root's top folder, lost+found, none of the image's files)\n" \
                "$name" ;;
            2) printf '  Volume %s already holds files; left as it is\n' "$name" ;;
            *) return 1 ;;
        esac
    done <<EOF
$missing
EOF
}
