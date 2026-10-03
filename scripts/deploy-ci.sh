#!/usr/bin/env bash
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
: "${HOMELAB_KIND:?}"
: "${HOMELAB_REPOSITORY_ID:?Persistent unique private repository ID required}"
: "${TF_STATE_ROOT:?Use a dedicated persistent runner state root}"
: "${HOMELAB_TFVARS_JSON:?}"
HOMELAB_ACTION=${HOMELAB_ACTION:-plan}
export HOMELAB_ACTION
case "$HOMELAB_ACTION" in plan|provision|deploy) ;; *) echo 'Unknown action.' >&2; exit 2;; esac
if [[ "$HOMELAB_KIND" == cloudflare && "$HOMELAB_ACTION" == provision ]]; then echo 'Cloudflare example does not provision a VM; choose plan/deploy.' >&2; exit 2; fi
if [[ "$HOMELAB_ACTION" == deploy ]]; then
 : "${SSH_PRIVATE_KEY:?}"
 : "${SSH_KNOWN_HOSTS:?Preverified host keys required}"
fi
[[ "$HOMELAB_REPOSITORY_ID" =~ ^(github|gitlab)-[0-9]+$ ]] || exit 2
[[ "$TF_STATE_ROOT" == /* && "$TF_STATE_ROOT" != /tmp* && "$TF_STATE_ROOT" != /var/tmp* ]] || { echo 'State root must be persistent, not temporary.' >&2; exit 2; }
command -v flock >/dev/null
umask 077
state_dir="$TF_STATE_ROOT/$HOMELAB_REPOSITORY_ID"
mkdir -p "$state_dir/backups"
chmod 700 "$state_dir" "$state_dir/backups"
# One operator/process for this state even outside CI concurrency.
exec 9>"$state_dir/deploy.lock"
flock -n 9 || { echo 'Another deployment owns this persistent state.' >&2; exit 1; }
export HOMELAB_RUNTIME_DIR
HOMELAB_RUNTIME_DIR=$(mktemp -d)
export HOMELAB_SSH_CONFIG="$HOMELAB_RUNTIME_DIR/ssh_config"
trap 'rm -rf "$HOMELAB_RUNTIME_DIR"' EXIT
python3 scripts/prepare-runtime.py
unset SSH_PRIVATE_KEY SSH_KNOWN_HOSTS PROXMOX_CA_PEM
python3 - "$state_dir" "$PWD" <<'PATHCHECK'
from pathlib import Path
import sys
import os
state,workspace=map(lambda x:Path(x).resolve(),sys.argv[1:])
runner_temp=Path(os.environ.get("RUNNER_TEMP","/tmp")).resolve()
if state==runner_temp or runner_temp in state.parents:sys.exit("State must be outside RUNNER_TEMP")
if state==workspace or workspace in state.parents:sys.exit('State must be outside checkout/workspace')
PATHCHECK
if [[ -s "$HOMELAB_RUNTIME_DIR/ca.pem" ]]; then export SSL_CERT_FILE="$HOMELAB_RUNTIME_DIR/ca.pem"; fi
if [[ -f "$state_dir/terraform.tfstate" ]]; then cp -p "$state_dir/terraform.tfstate" "$state_dir/backups/$(date -u +%Y%m%dT%H%M%SZ)-terraform.tfstate"; fi
terraform -chdir=terraform init -input=false -reconfigure -backend-config="path=$state_dir/terraform.tfstate"
terraform -chdir=terraform validate
terraform -chdir=terraform plan -input=false -var-file="$HOMELAB_RUNTIME_DIR/inputs.tfvars.json" -out="$HOMELAB_RUNTIME_DIR/deploy.tfplan"
terraform -chdir=terraform show -json "$HOMELAB_RUNTIME_DIR/deploy.tfplan" > "$HOMELAB_RUNTIME_DIR/plan.json"
python3 - "$HOMELAB_RUNTIME_DIR/plan.json" <<'CHECK'
import json,sys
p=json.load(open(sys.argv[1]))
if any('delete' in x.get('change',{}).get('actions',[]) for x in p.get('resource_changes',[])):
 sys.exit('Delete/replacement refused. Review and execute destructive recovery separately.')
CHECK
if [[ "$HOMELAB_ACTION" == plan ]]; then echo 'Plan only; no changes executed.'; exit 0; fi
terraform -chdir=terraform apply -input=false "$HOMELAB_RUNTIME_DIR/deploy.tfplan"
if [[ "$HOMELAB_ACTION" == provision ]]; then
 terraform -chdir=terraform output -raw ssh_host
 echo 'VM provisioned. Verify its unique SSH host fingerprint through trusted Proxmox console/CLI, pin known_hosts, then run deploy.'
 exit 0
fi
if [[ "$HOMELAB_KIND" == cloudflare ]]; then
 : "${HOMELAB_SSH_HOST:?Existing DMZ host IP required; tunnel/bootstrap lives there}"
 target=$HOMELAB_SSH_HOST
else
 target=$(terraform -chdir=terraform output -raw ssh_host)
fi
python3 scripts/prepare-ssh.py "$target"
ready=false
for _attempt in $(seq 1 36); do
 if ssh -F "$HOMELAB_SSH_CONFIG" homelab true 2>/dev/null; then ready=true; break; fi
 sleep 5
done
[[ "$ready" == true ]] || { echo 'SSH unavailable/host key rejected. Inspect guest and independently verify keys; no bypass.' >&2; exit 1; }
bash scripts/deploy-existing-host.sh
