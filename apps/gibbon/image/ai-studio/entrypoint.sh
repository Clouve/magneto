#!/bin/sh
# gibbon-ai-studio entrypoint wrapper.
#
# Generates the per-pod clouve-ops ed25519 keypair on first boot, then
# chains to the upstream AI Studio entrypoint. The keypair lives in the
# `clouve_ops_keys` named volume mounted at /clouve/ops-keys/, which is
# also mounted into the gibbon and gibbon-mysql containers — their own
# entrypoints poll the public-key file and install it as the only
# authorized key for their pre-created clouve-ops user.
#
# Idempotent: a stop+start of just gibbon-ai-studio (without volume
# cleanup) reuses the existing key. A `--cleanup` redeploy wipes the
# volume and a fresh key is generated. Same key for the lifetime of the
# volume == same key for the lifetime of the deployment.
#
# Permissions on the in-volume key are 0644 root:root. ssh clients
# refuse identity keys with looser-than-0600 perms, so the per-user
# /etc/profile.d/clv-gibbon-skill.sh drop-in copies the key into
# $HOME/.ssh/clouve-ops on each login (mode 0600, owned by the per-tenant
# user). That way the agent uses an owned key file and the in-volume
# original stays accessible to whichever shell user happens to be
# bootstrapping.

set -e

KEY_DIR=/clouve/ops-keys
PRIV_KEY="$KEY_DIR/id_ed25519"
PUB_KEY="$KEY_DIR/id_ed25519.pub"
PREFIX="[gibbon-ai-studio-init]"

mkdir -p "$KEY_DIR"
chmod 0755 "$KEY_DIR"

if [ ! -s "$PRIV_KEY" ] || [ ! -s "$PUB_KEY" ]; then
    echo "$PREFIX Generating per-pod clouve-ops ed25519 keypair at $PRIV_KEY"
    rm -f "$PRIV_KEY" "$PUB_KEY"
    ssh-keygen -t ed25519 -N "" -C "clouve-ops@gibbon-ai-studio (per-pod)" -f "$PRIV_KEY" >/dev/null
fi

chmod 0644 "$PUB_KEY" "$PRIV_KEY"
echo "$PREFIX ✓ Keypair ready at $PRIV_KEY (chaining to upstream init.sh)"

exec /clouve/busybox sh /clouve/ai-studio/installer/init.sh "$@"
