#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HOMELAB_SSH_CONFIG:?Prepared isolated SSH config required}"
: "${HOMELAB_KIND:?}"
# Inputs cross the boundary as JSON, never embedded in remote shell commands.
python3 - <<'INPUT'
import ipaddress,json,os
from pathlib import Path
kind=os.environ['HOMELAB_KIND'];data={'kind':kind}
if kind!='cloudflare':
 ip=ipaddress.ip_address(os.environ['DNS_BIND_IP'])
 if ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_link_local:raise SystemExit('DNS_BIND_IP must be actual trusted guest interface')
 if ip.version!=4:raise SystemExit('This deployment helper supports IPv4; separately design/test IPv6 before publishing a v6 listener')
 data['bind_ip']=str(ip)
 if kind=='recursor':
  nets=[ipaddress.ip_network(x.strip(),strict=True) for x in os.environ['DNS_ALLOWED_CIDRS'].split(',')]
  if not nets or any(n.prefixlen==0 for n in nets):raise SystemExit('Explicit trusted subnets required; open resolver denied')
  data['allowed_cidrs']=[str(n) for n in nets]
Path(os.environ['HOMELAB_RUNTIME_DIR'],'deploy-input.json').write_text(json.dumps(data))
INPUT
remote=$(ssh -F "$HOMELAB_SSH_CONFIG" homelab mktemp -d)
[[ "$remote" =~ ^/tmp/tmp\.[a-zA-Z0-9]+$ ]] || { echo 'Unexpected staging path.' >&2; exit 1; }
trap 'ssh -F "$HOMELAB_SSH_CONFIG" homelab "rm -rf -- $remote" >/dev/null 2>&1 || true' EXIT
if [[ "$HOMELAB_KIND" == cloudflare ]]; then payload=(compose.yaml site scripts/deploy-local.py); else payload=(compose.yaml config scripts/deploy-local.py); [[ ! -d zones ]] || payload+=(zones); fi
tar -cf - "${payload[@]}" | ssh -F "$HOMELAB_SSH_CONFIG" homelab "tar -xf - -C $remote"
cat "$HOMELAB_RUNTIME_DIR/deploy-input.json" | ssh -F "$HOMELAB_SSH_CONFIG" homelab "cat > $remote/deploy-input.json"
ssh -F "$HOMELAB_SSH_CONFIG" homelab "sudo -n python3 $remote/scripts/deploy-local.py $remote"
