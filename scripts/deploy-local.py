#!/usr/bin/env python3
"""Install a reviewed sample on one intended Linux guest. Requires root."""
import datetime,ipaddress,json,os,shutil,subprocess,sys,tarfile,time
from pathlib import Path
os.umask(0o077)
if os.geteuid()!=0:sys.exit('Run with sudo on the intended guest, never a hypervisor')
stage=Path(sys.argv[1]).resolve();data=json.loads((stage/'deploy-input.json').read_text());kind=data['kind']
names={'authoritative':'powerdns-authoritative-lab','recursor':'powerdns-recursor-lab','cloudflare':'cloudflare-homelab-tunnel'}
if kind not in names:sys.exit('Unknown deployment kind')
if kind=='cloudflare':
 config=Path('/etc/cloudflared-homelab/config.yml')
 if not config.is_file() or not shutil.which('cloudflared'):sys.exit('Bootstrap existing DMZ tunnel/config before CI deployment')
name=names[kind];base=Path('/opt/homelab')/name;stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
# Preserve existing release before changing workload configuration.
backup=Path('/var/backups/homelab')/name;backup.mkdir(parents=True,exist_ok=True,mode=0o700)
if (base/'current').exists():
 with tarfile.open(backup/(stamp+'.tar.gz'),'w:gz') as out:out.add((base/'current').resolve(),arcname='previous-release')
subprocess.run(['apt-get','update'],check=True)
subprocess.run(['apt-get','install','-y','docker.io','docker-compose-v2','dnsutils'],check=True)
subprocess.run(['systemctl','enable','--now','docker'],check=True)
release=base/'releases'/stamp;release.parent.mkdir(parents=True,exist_ok=True);shutil.copytree(stage,release)
if kind=='recursor':
 allowed=['127.0.0.0/8','172.30.53.0/24']+data['allowed_cidrs']
 (release/'config/recursor.yml').write_text('incoming:\n  listen: [0.0.0.0]\n  port: 53\n  allow_from: '+json.dumps(allowed)+'\ndnssec:\n  validation: validate\nrecursor:\n  threads: 2\nrecordcache:\n  max_entries: 10000\n  max_ttl: 3600\n  max_negative_ttl: 300\npacketcache:\n  max_entries: 10000\nwebservice:\n  webserver: false\n')
compose=json.loads(subprocess.check_output(['docker','compose','-f',str(release/'compose.yaml'),'config','--format','json'],text=True))
if kind!='cloudflare':
 service='internal' if kind=='authoritative' else 'recursor'
 compose['services'][service]['ports']=[{'target':53,'published':'53','host_ip':data['bind_ip'],'protocol':proto} for proto in ['tcp','udp']]
# JSON is valid Compose YAML; original localhost demo stays untouched.
(release/'compose.deploy.json').write_text(json.dumps(compose,indent=2))
project='homelab-'+kind
cmd=['docker','compose','-p',project,'-f',str(release/'compose.deploy.json')]
subprocess.run(cmd+['config','--quiet'],check=True)
subprocess.run(cmd+['up','-d','--remove-orphans'],check=True)
if kind=='cloudflare':
 config=Path('/etc/cloudflared-homelab/config.yml')
 binary=shutil.which('cloudflared')
 if not config.is_file() or not binary:sys.exit('Existing DMZ tunnel credential/config and cloudflared binary required; bootstrap separately, never create in CI')
 subprocess.run([binary,'tunnel','--config',str(config),'ingress','validate'],check=True)
 unit=Path('/etc/systemd/system/homelab-cloudflared.service')
 if unit.exists():shutil.copy2(unit,backup/(stamp+'-homelab-cloudflared.service'))
 unit.write_text('[Unit]\nDescription=Homelab website tunnel\nAfter=network-online.target docker.service\nWants=network-online.target\n[Service]\nExecStart='+binary+' tunnel --config '+str(config)+' run\nRestart=on-failure\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\n')
 subprocess.run(['systemctl','daemon-reload'],check=True)
 subprocess.run(['systemctl','enable','--now','homelab-cloudflared'],check=True)
 subprocess.run(['systemctl','restart','homelab-cloudflared'],check=True)
 subprocess.run(['curl','--fail','--silent','http://127.0.0.1:8080/'],check=True,stdout=subprocess.DEVNULL)
else:
 # Assert a local real-interface answer; external-client/firewall acceptance remains separate.
 query='www.example.test' if kind=='authoritative' else 'example.com'
 result=''
 for attempt in range(20):
  result=subprocess.run(['dig','@'+data['bind_ip'],query,'A','+short'],text=True,capture_output=True)
  if result.returncode==0 and result.stdout.strip():break
  time.sleep(2)
 else:sys.exit('DNS returned no A answer; deployment acceptance failed')
tmp=base/'current.next'
if tmp.is_symlink():tmp.unlink()
tmp.symlink_to(release);tmp.replace(base/'current')
print('Deployed reviewed sample:',name,'release:',stamp)
print('Verify from approved and denied client networks; firewall isolation is not installed by this helper.')
