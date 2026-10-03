#!/usr/bin/env python3
import ipaddress,os,re,sys
from pathlib import Path
host=sys.argv[1]
# Only static IP targets; no untrusted SSH option or config injection.
ip=ipaddress.ip_address(host)
if ip.is_unspecified or ip.is_multicast or ip.is_loopback:sys.exit('Use actual guest/host IP')
user=(os.environ.get('HOMELAB_SSH_USER') or 'ubuntu');port=(os.environ.get('HOMELAB_SSH_PORT') or '22')
if not re.fullmatch(r'[a-z_][a-z0-9_-]*',user) or not port.isdigit() or not 1<=int(port)<=65535:sys.exit('Invalid SSH user/port')
r=Path(os.environ['HOMELAB_RUNTIME_DIR'])
cfg='Host homelab\n  HostName '+host+'\n  User '+user+'\n  Port '+port+'\n  IdentityFile '+str(r/'id_ed25519')+'\n  UserKnownHostsFile '+str(r/'known_hosts')+'\n  StrictHostKeyChecking yes\n  IdentitiesOnly yes\n  BatchMode yes\n  ConnectTimeout 10\n'
p=Path(os.environ['HOMELAB_SSH_CONFIG']);p.write_text(cfg);p.chmod(0o600)
