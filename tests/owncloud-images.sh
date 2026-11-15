#!/bin/bash

# ============================================================================
# The ownCloud pin gate's input: every ownCloud and owncloud-mariadb image an
# environment's ownCloud deployments run, paused ones included
# ============================================================================
# Read-only: kubectl get (no exec) on each cluster context given, asking for
# image references only, and a registry lookup per image (docker buildx
# imagetools inspect, with a login that can read the registry). For each
# context it prints:
#   spec <context> <ref>      the image in a Deployment's or StatefulSet's pod
#                             template, init containers included; a paused
#                             deployment keeps its spec at 0 replicas, so it
#                             is listed too
#   running <context> <ref>   a running pod's image ID (what it pulled, which
#                             can be older than its tag names now)
#   running <context> <ref> unreadable
#                             an ownCloud container whose image ID names no
#                             repository (an image loaded straight into the
#                             node), so nothing can pull what it runs
# and then, once per spec reference:
#   digest <ref> <sha256:...|unreadable>   what the tag names now, which a
#                             stopped pod pulls when it starts again
# It prints references and digests only: no namespace and no deployment name.
# An image counts when its repository's last part is exactly owncloud or
# owncloud-mariadb, in any registry project. So a publisher's own image with
# one of those names is listed too, and the gate reads its version like any
# other (NOT ok when it can't).
#
# Then pull each image by digest and give the gate every one by digest:
#   docker pull <ref>@<digest>     a spec line's reference, with the digest
#                                  its digest line gives
#   docker pull <ref>              a running line's reference, or a spec
#                                  reference that already has @sha256:
#   bash tests/owncloud-pin-check.sh --owncloud <ref>@<digest>... --mariadb <ref>@<digest>...
# The gate gets <ref>@<digest>, or the reference as printed when it already
# has @sha256:. Never the tag alone: pulling by digest doesn't move a local
# tag, so the gate would read whatever that tag names on this machine.
# Give it every cluster the environment's organizations deploy to (cluster-1
# and each registered or created cluster). A deployment with no Deployment or
# StatefulSet left at all isn't seen here: add the images its listing version
# names.
#
# Usage: bash tests/owncloud-images.sh <kube context>...
# Exit status: 0 when every context and image was read; 1 when a context
# couldn't be read (stderr names it, and no list is printed) or a line says
# unreadable (stderr gives the count); 2 with no context.
# ============================================================================

set -uo pipefail

if [ $# -eq 0 ]; then
  sed -n 's/^# \{0,1\}//; /^Usage:/p' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

# An ownCloud or owncloud-mariadb image: the repository's last part is exactly one of the two.
OWNCLOUD='(^|/)owncloud(-mariadb)?([:@]|$)'
DIGEST='^sha256:[0-9a-f]{64}$'
# Images only: each pod template's containers and init containers, and each started container's image and image ID.
WORKLOADS='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}'
PODS='{range .items[*]}{range .status.containerStatuses[*]}{.image}{"\t"}{.imageID}{"\n"}{end}{range .status.initContainerStatuses[*]}{.image}{"\t"}{.imageID}{"\n"}{end}{end}'

lines=()
specs=""
failed=0
declare -A seen=()
for ctx in "$@"; do
  # A failed read is told apart from "no ownCloud here": the filter below runs only on a read that worked.
  if ! images="$(kubectl --context "$ctx" get deployments,statefulsets -A -o "jsonpath=$WORKLOADS")"; then
    echo "ERROR: couldn't read the Deployments and StatefulSets of context $ctx" >&2
    failed=$((failed + 1))
    continue
  fi
  if ! statuses="$(kubectl --context "$ctx" get pods -A -o "jsonpath=$PODS")"; then
    echo "ERROR: couldn't read the pods of context $ctx" >&2
    failed=$((failed + 1))
    continue
  fi
  while IFS= read -r ref; do
    [[ $ref =~ $OWNCLOUD ]] || continue
    lines+=("spec $ctx $ref")
    specs+="$ref"$'\n'
  done < <(sort -u <<< "$images")
  while IFS=$'\t' read -r image id; do
    [[ $id =~ ^[a-z-]+://(.*)$ ]] && id="${BASH_REMATCH[1]}"
    [[ $image =~ $OWNCLOUD || $id =~ $OWNCLOUD ]] || continue
    if [[ $id == *@* && ${id%%@*} != "" && ${id##*@} =~ $DIGEST ]]; then
      line="running $ctx $id"
    elif [ -n "$id" ]; then
      line="running $ctx $image unreadable"
    else
      continue # no image ID yet: the container hasn't started, so it has run nothing
    fi
    [ -n "${seen[$line]:-}" ] && continue
    seen[$line]=1
    lines+=("$line")
  done < <(sort -u <<< "$statuses")
done

if [ "$failed" -gt 0 ]; then
  echo "ERROR: $failed read(s) failed. No list is printed: one without those contexts would look complete." >&2
  exit 1
fi

unreadable=0
for line in "${lines[@]}"; do
  echo "$line"
  [[ $line == *" unreadable" ]] && unreadable=$((unreadable + 1))
done
while IFS= read -r ref; do
  case "$ref" in
    *@sha256:*) digest="${ref##*@}" ;;
    *) digest="$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest.Digest}}' 2>/dev/null < /dev/null |
      tr -d '"')" ;;
  esac
  if ! [[ $digest =~ $DIGEST ]]; then
    digest=unreadable
    unreadable=$((unreadable + 1))
  fi
  echo "digest $ref $digest"
done < <(printf '%s' "$specs" | sort -u)

if [ "$unreadable" -gt 0 ]; then
  if [ "$unreadable" -eq 1 ]; then n="1 line says"; else n="$unreadable lines say"; fi
  echo "ERROR: $n unreadable. The gate can't check an image this list can't name by digest:" \
    "log in to its registry and run this again, or find out what that pod runs." >&2
  exit 1
fi
