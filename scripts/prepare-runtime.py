#!/usr/bin/env python3
"""Prepare protected job files; never log secret values."""
import ipaddress,json,os,re,subprocess,sys
from pathlib import Path
runtime=Path(os.environ['HOMELAB_RUNTIME_DIR'])
private=os.environ.get('SSH_PRIVATE_KEY','')
public=os.environ.get('SSH_PUBLIC_KEY','')
if private:
 key=runtime/'id_ed25519';key.write_text(private+'\n');key.chmod(0o600)
 public=subprocess.check_output(['ssh-keygen','-y','-f',str(key)],text=True)
if os.environ['HOMELAB_KIND']!='cloudflare' and not public:sys.exit('SSH_PUBLIC_KEY variable or protected private key required for VM public-key initialization')
if public:(runtime/'id_ed25519.pub').write_text(public+'\n')
if os.environ.get('HOMELAB_ACTION')=='deploy':
 known=runtime/'known_hosts';known.write_text(os.environ['SSH_KNOWN_HOSTS']+'\n');known.chmod(0o600)
values=json.loads(os.environ['HOMELAB_TFVARS_JSON'])
if not isinstance(values,dict):sys.exit('TF input must be a JSON object')
for k in values:
 if re.search(r'token|password|secret|private_key',k,re.I):sys.exit('Credentials must not be tfvars')
if os.environ['HOMELAB_KIND']!='cloudflare':values['ssh_public_key_path']=str(runtime/'id_ed25519.pub')
(runtime/'inputs.tfvars.json').write_text(json.dumps(values));(runtime/'inputs.tfvars.json').chmod(0o600)
ca=os.environ.get('PROXMOX_CA_PEM','')
if ca:
 import ssl
 bundle=Path(ssl.get_default_verify_paths().cafile or '')
 if not bundle.is_file():sys.exit('No platform CA bundle; install trusted CA before deployment')
 (runtime/'ca.pem').write_text(bundle.read_text()+'\n'+ca+'\n')
