#!/usr/bin/env bash
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
: "${HOMELAB_SSH_HOST:?Existing dedicated host IP required}"
: "${SSH_PRIVATE_KEY:?}"
: "${SSH_KNOWN_HOSTS:?Trusted host keys required}"
export HOMELAB_KIND=recursor HOMELAB_ACTION=deploy
export HOMELAB_TFVARS_JSON='{}'
umask 077
export HOMELAB_RUNTIME_DIR
HOMELAB_RUNTIME_DIR=$(mktemp -d)
export HOMELAB_SSH_CONFIG="$HOMELAB_RUNTIME_DIR/ssh_config"
trap 'rm -rf "$HOMELAB_RUNTIME_DIR"' EXIT
python3 scripts/prepare-runtime.py
unset SSH_PRIVATE_KEY SSH_KNOWN_HOSTS
python3 scripts/prepare-ssh.py "$HOMELAB_SSH_HOST"
bash scripts/deploy-existing-host.sh
