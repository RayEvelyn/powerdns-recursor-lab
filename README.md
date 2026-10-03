# PowerDNS Recursor: a private caching resolver for your home lab

Start with [GitOps, the bootstrap order, and why the repos are separate](docs/START-HERE.md).

Learn what happens after a laptop asks “where is this name?” This lab runs a private recursive resolver, demonstrates caching, validates public DNSSEC answers, and explains conditional forwarding to your own authoritative DNS.


## Capacity and reachability before deployment

The checked-in VM input uses **2 vCPU and 2 GiB RAM**; the template helper expands its disk to **80 GiB**. Plan space for both template and clone, snapshots and backups. For learning DNS behavior on a smaller machine, start with the local Docker loopback/high-port demo; it does not require a Proxmox VM or serve LAN clients by default.

**No GPU is required** for this DNS, Kubernetes, Rancher, telemetry or tunnel lesson. AI inference is a separate optional workload: model size, precision, context and concurrency determine RAM/VRAM requirements; these examples do not reserve or promise that capacity. Account separately for the chosen runner, GitLab if self-hosted, host OS and existing services. Check `free -h`, `df -h`, and Proxmox `pvesm status`/`pvesh get /nodes/YOUR_NODE/status` on the actual intended machines. On an existing cluster compare allocatable and requested resources with `kubectl describe nodes` and storage/PVC inventory before adding LGTM.

| Initiator | Destination and port | Purpose / when needed |
| --- | --- | --- |
| Workstation | Selected GitHub or GitLab HTTPS 443 (or configured trusted local TLS port) | Clone, CLI API and pipeline control; not a substitute for runner network reach |
| Dedicated selected runner | Proxmox TLS API TCP 8006 | VM Terraform path only; trust its CA, keep management outside DMZ |
| Dedicated selected runner | Intended guest TCP 22 | Reviewed SSH/bootstrap paths; pin unique host keys |
| Runner / guests | Approved package and container registries TCP 443 | Downloads; add only repository-specific approved HTTP 80 sources if required |
| Workload runner | Intended Kubernetes TLS API TCP 6443, or configured KAS TLS route | Manifest/Helm paths only; scoped credentials and verified TLS |
| Trusted LAN DNS clients | Intended DNS server UDP and TCP 53 | DNS paths only; deliberate listener and narrow ACL/firewall, not demo high ports |
| DMZ tunnel host | Cloudflare UDP/TCP 7844 and approved HTTPS 443 | Cloudflare connector/install path only; no inbound router forward |

A hosted GitHub validation runner has **no assumed route to your private LAN**. Configure only the selected private execution runner with necessary routes, DNS and firewall permissions. Keep DMZ-to-LAN/admin denial intact; tunnel connectivity alone does not segment your network. Test the selected route from the actual runner with TLS-verifying `curl`, pinned-key SSH and the README runtime commands before deploying, rather than opening management broadly.


## Why run a caching resolver?

Your devices need someone to find DNS answers. PowerDNS **Recursor** performs that job. It remembers valid answers until their time-to-live (TTL) expires, which reduces repeated upstream queries and often reduces lookup latency. It also gives your lab one place to control internal forwarding and observe resolver health.

Caching does not make DNS changes instant. If a record has a 300-second TTL, an already-cached answer can remain for that period. Negative answers can be cached too. A working cache is useful during a brief upstream failure only for answers it already has and according to its configured behavior; it is not a guarantee that the whole internet stays resolvable offline.

DNSSEC verifies authenticity of signed DNS data. It does not encrypt DNS requests, hide the names you visit, or make an internal application secure. DoH/DoT transport privacy is another topic.

## Authoritative versus recursive DNS

| Component | Question it answers | Typical clients |
| --- | --- | --- |
| PowerDNS Authoritative | What records exist in a zone I own? | Recursive resolvers |
| PowerDNS Recursor | Find this name and cache the result | Your laptops, servers and workloads |
| Cloudflare authoritative DNS | Publish the public records for your registered domain | Internet resolvers |

Do not configure the authoritative server as your laptop's general internet resolver. Do not publish this Recursor to everyone on the internet: that creates an **open resolver**, which attackers can abuse for amplification and other unwanted traffic.

## Bootstrap order and GitOps

Start with a router/firewall, working time and temporary DNS. Bring up local GitLab independently, then put sanitized configuration in repos. This resolver can replace temporary DNS after you have verified it. Keep an admin path and recovery resolver that do not depend on GitLab or this one container.

GitOps uses reviewed declarations and reconciliation to keep real systems aligned with Git. A push alone is not permission to destroy infrastructure. Protect deployment branches and jobs, review changes, and retain backups. Secrets stay in a password manager or Vault, outside Git.

## What the demo does

- Runs PowerDNS Recursor 5.3.11, pinned by image digest.
- Publishes TCP and UDP DNS **only at `127.0.0.1:15355`**.
- Uses current YAML configuration, with DNSSEC validation enabled.
- Allows requests only from loopback and the explicit `172.30.53.0/24` Docker demo bridge.
- Keeps the web API disabled and limits cache entries and TTLs.

The dedicated bridge lets Docker's translated localhost requests pass without permitting every private network. If your workstation already routes `172.30.53.0/24`, choose a nonconflicting subnet and update **both** Compose IPAM and `incoming.allow_from` before starting.

## Prerequisites and quick start

Use Docker with Compose v2 and `dig`. On a fresh Ubuntu 24.04 guest or bare-metal lab machine:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 dnsutils
sudo systemctl enable --now docker
```

Docker access is effectively root access. These commands belong on a guest or dedicated lab server, not the Proxmox hypervisor. On a workstation, Docker Desktop is sufficient for this loopback demo.

```bash
docker compose config --quiet
docker compose up -d
./scripts/verify.sh
```

The verification checks a public answer, TCP DNS, and rejection of `dnssec-failed.org`, a deliberately invalid DNSSEC test domain. These tests require outbound internet DNS connectivity. Network filtering or an upstream outage can cause failure even when the YAML parses correctly.

```bash
dig @127.0.0.1 -p 15355 example.com A
dig @127.0.0.1 -p 15355 example.com A
# Compare query time, but do not assume every second request is faster.
docker compose exec recursor rec_control get cache-hits cache-misses
dig @127.0.0.1 -p 15355 dnssec-failed.org A
```

A repeated answer and changing cache counters demonstrate caching more reliably than a single timing sample. SERVFAIL for the broken DNSSEC domain is expected. Do not fix it by disabling validation.

## Add internal conditional forwarding

First run an internal authoritative server and confirm it answers your private zone directly. Then merge `config/forward-zone.example.yml` into the existing `recursor` section in `config/recursor.yml`, replacing its documentation-only address. YAML must not contain duplicate top-level `recursor` keys.

```yaml
recursor:
  threads: 2
  forward_zones:
    - zone: home.arpa
      forwarders: [192.0.2.53:53]
```

This sends the private zone to an **authoritative** server with recursion desired unset. `forward_zones_recurse` instead forwards to another **recursive** resolver with recursion desired set. Using the wrong one creates confusing failures or loops. Do not point two resolvers at each other for the same zone.

Restart and test:

```bash
docker compose restart recursor
dig @127.0.0.1 -p 15355 host.home.arpa A
dig @127.0.0.1 -p 15355 example.com A
```

`home.arpa` is reserved for home-network naming. The shipped config does not forward it until you add a real authoritative address. An NXDOMAIN from your internal authority is final; missing names do not automatically fall back to Cloudflare. If you shadow your entire registered domain, preserve all public records internal users still need, or choose a dedicated internal subdomain.

For unsigned private zones beneath signed public parents, DNSSEC may legitimately reject your internal answer. Design the signing/delegation correctly or add a narrowly scoped negative trust anchor using the official YAML documentation. Do not turn validation off globally. Make that security tradeoff explicit in your change review.

## Proxmox and bare-metal paths

The `terraform/` directory clones an existing Ubuntu cloud-init template into one VM using an environment-supplied Proxmox API token. Read its README for template preparation, TLS trust, token ACLs and plans. The token is not a variable in the Terraform configuration. The helper provisions a guest; Docker and this resolver are installed afterward.

For bare metal, skip VM provisioning, install Ubuntu on a dedicated host and use the same Compose files. No disk-wiping or operating-system installer is included. This keeps an example command from destroying someone's physical host.

To serve a real LAN, change the host binding from loopback/high port to your **specific trusted interface address** on port 53, then replace the Docker-only source ACL with the exact trusted client subnet(s). Docker's NAT can change the source visible to the application, so verify the source actually received and enforce source restrictions at the router/firewall too. An ACL permitting the NAT gateway is not proof that every original client is trusted.

Allow trusted clients to reach both UDP and TCP 53. Block all WAN, guest-network and untrusted DMZ clients unless separately intended. Do not use `0.0.0.0/0` or `::/0` in the allow list. IPv6 needs its own deliberate binding, ACL and firewall treatment. A NAT-only mental model is insufficient when hosts have global IPv6 addresses.

## Why separate infrastructure and workloads?

Terraform owns hosts, VM disks and network attachments. A manifests repo owns Kubernetes objects or, here, the Compose/YAML service declaration. An application repo owns source/builds. A Flyway repo owns ordered SQL changes. Separate review and credentials prevent a routine application change from gaining VM-destruction or database-owner access.

KAS connects a cluster-side GitLab agent to GitLab over an outbound connection, so authorized CI jobs can access Kubernetes without opening a public API port. Scope its CI authorization and Kubernetes RBAC. Agent tokens and admin kubeconfigs are secrets. KAS is unnecessary for this standalone Compose resolver.

## Operations and troubleshooting

```bash
docker compose logs --tail=100
docker compose exec recursor rec_control get questions unauthorized-udp cache-hits cache-misses
```

- **Timeouts:** check source ACL, bridge subnet, router rules and outbound UDP/TCP 53. The Recursor resolves directly from authoritative servers; it is not automatically using your workstation's configured upstream.
- **Unauthorized counters increase:** inspect the actual translated source and adjust the narrow intended network, rather than allowing all sources.
- **SERVFAIL:** check time synchronization, DNSSEC validity, delegation and forward-zone targets. A bad signature is different from a missing record.
- **Old answer:** inspect TTL, query authority directly and wait for expiry; use cache clearing only for the specific names involved in a verified change.
- **Resolver works but applications fail:** DNS only supplies addresses. Check routes, certificate names, service listeners and network policy separately.

Keep the configuration in Git, backed up privately. Cache data is disposable; authoritative zone data is not. A second independently placed resolver reduces a single-container outage, but two containers on one physical host do not provide host-level availability.

```bash
docker compose down
```

Review and back up any persistent data before destroying a Proxmox VM. Do not destroy infrastructure to clear a stale cache.

## Official references and validation scope

- [Recursor getting started](https://docs.powerdns.com/recursor/getting-started.html)
- [Current YAML settings and forwarding](https://docs.powerdns.com/recursor/yamlsettings.html)
- [Recursor security settings](https://docs.powerdns.com/recursor/settings.html)
- [PowerDNS authoritative views](https://doc.powerdns.com/authoritative/views.html)

See `VALIDATION.md` for observed local results. Tests on a developer workstation do not prove that your LAN ACLs, DNSSEC policy or Proxmox network are configured correctly.

## Choose one CI provider before configuring deployment

GitHub and GitLab are **alternative complete paths**. [CI-PATHS.md](CI-PATHS.md) provides the runner setup, GitLab CLI inputs and job controls alongside the GitHub commands below. Choose one owner for each lab. A source-control server stores code and schedules jobs; the selected **runner machine** executes Terraform, SSH, Ansible or Helm and needs the documented network access. Cloning this repository does not install a runner or create a route to Proxmox.

| Choice | Source and job scheduler | Execution machine | Kubernetes access |
| --- | --- | --- | --- |
| GitHub | Your private GitHub repository and Actions | Your dedicated self-hosted Linux runner | Scoped kubeconfig where needed; GitLab/KAS not required |
| GitLab | Your private GitLab project and GitLab CI | Your dedicated protected GitLab Linux runner | Scoped kubeconfig; GitLab agent/KAS is an optional separately configured route |

The public upstream runs unprivileged hosted validation only. A local GitLab is useful if you want to host your own source and scheduler, but is **not** a prerequisite for the GitHub path. KAS does not provision VMs and is not a general-purpose Terraform runner.

## Actual CI deployment: use your private deployment copy

The public source is `https://github.com/RayEvelyn/powerdns-recursor-lab.git`. Public examples run **hosted validation only**. The deployment job is intentionally ineligible in the public repository. Clone the code, review it, and create your **own private** repository/project for access to a dedicated homelab runner:

```bash
git clone https://github.com/RayEvelyn/powerdns-recursor-lab.git
cd powerdns-recursor-lab
# Replace YOUR_ACCOUNT with your own account; preserve the upstream origin.
gh repo create YOUR_ACCOUNT/powerdns-recursor-lab --private --source . --remote deployment --push
```

This includes a functional deployment path, not a claim that CI has deployed your lab already. The GitHub workflow requires an explicit `workflow_dispatch`, your private repository, its default branch, `DEPLOY_ENABLED=true`, runner labels `self-hosted,linux,homelab`, and environment `homelab`. Never attach a LAN-capable self-hosted runner to the public source repo. Configure protected branch/environment controls and restrict runner use to this private copy. Environment approval features depend on your GitHub plan; verify enforced behavior rather than assuming an environment name creates approval.

### A persistent runner and explicit state ownership

Use a dedicated persistent Linux runner with Terraform, Python3, OpenSSH tools, GNU `flock`, and network reachability to the intended lab host. State is not a CI cache or disposable workspace. Provision a private directory owned by the runner service account:

```bash
# On the dedicated runner; use its actual service account instead of homelab-runner.
sudo install -d -m700 -o homelab-runner -g homelab-runner /var/lib/homelab-terraform
```

`TF_STATE_ROOT=/var/lib/homelab-terraform` and the private repository ID resolve to `/var/lib/homelab-terraform/<repository-id>/terraform.tfstate`. The local backend is explicit. A per-state `flock`, Terraform's local locking and CI per-repository concurrency serialize execution. This is **one persistent runner**, not a distributed locking design. Do not schedule the same state on multiple hosts. Back up this root independently; the helper preserves a timestamped private pre-apply state copy, which is not a substitute for off-host recovery. Never upload state or plans as public artifacts.

The helper defaults to `plan`. It generates protected temporary inputs, validates, creates a saved plan, and rejects delete/replacement actions. `plan` exits without changing infrastructure. `provision` applies that exact plan and returns without SSH/bootstrap. `deploy` applies the exact plan, then uses an isolated SSH configuration to install/update the reviewed sample. No automatic destroy is included. Planned replacements require separate deliberate recovery review.

### Configure inputs using CLI

Define your target with nonsecret JSON in repository variable `HOMELAB_TFVARS_JSON`; do not put tokens, passwords or private keys there. For the DNS VM examples, use the fields from `terraform/terraform.tfvars.example`, omitting `ssh_public_key_path`: the helper writes the provided public key to a temporary file and supplies the path. For Cloudflare, use `zone_id`, `hostname`, and the **existing** `tunnel_id`. An API token is provider environment input, never a Terraform credential variable.

```bash
# Run against your private repository. Files below belong outside the public checkout.
gh api --method PUT repos/YOUR_ACCOUNT/powerdns-recursor-lab/environments/homelab
gh variable set TF_STATE_ROOT --repo YOUR_ACCOUNT/powerdns-recursor-lab --body /var/lib/homelab-terraform
gh variable set HOMELAB_TFVARS_JSON --repo YOUR_ACCOUNT/powerdns-recursor-lab < /secure/local/inputs.json
# The public SSH key is not a secret; match the protected private key used for deployment.
gh variable set SSH_PUBLIC_KEY --repo YOUR_ACCOUNT/powerdns-recursor-lab < /secure/local/id_ed25519.pub
gh secret set SSH_PRIVATE_KEY --repo YOUR_ACCOUNT/powerdns-recursor-lab < /secure/local/id_ed25519
gh secret set SSH_KNOWN_HOSTS --repo YOUR_ACCOUNT/powerdns-recursor-lab < /secure/local/known_hosts
# Enable only after reviewing runner placement, inputs and permission boundaries.
gh variable set DEPLOY_ENABLED --repo YOUR_ACCOUNT/powerdns-recursor-lab --body true
gh workflow run homelab.yml --repo YOUR_ACCOUNT/powerdns-recursor-lab -f action=plan
```

Secret commands read stdin; credential values are not command-line arguments. Disable shell tracing and avoid logged terminals when handling secrets. Do not echo credentials for troubleshooting. Keep an independently verified host-key file rather than trusting an unauthenticated `ssh-keyscan` result.

DNS Terraform also needs `PROXMOX_VE_ENDPOINT` as a variable, `PROXMOX_VE_API_TOKEN` as a secret, and optionally `PROXMOX_CA_PEM` as a secret containing your trusted CA. Example input commands:

```bash
gh variable set PROXMOX_VE_ENDPOINT --repo YOUR_ACCOUNT/powerdns-recursor-lab --body https://proxmox.example.test:8006/
gh secret set PROXMOX_VE_API_TOKEN --repo YOUR_ACCOUNT/powerdns-recursor-lab < /secure/local/proxmox-token
gh secret set PROXMOX_CA_PEM --repo YOUR_ACCOUNT/powerdns-recursor-lab < /secure/local/proxmox-ca.pem
```

The optional CA is appended to the platform trust bundle and used through `SSL_CERT_FILE`; TLS verification stays enabled. Grant only intended lab permissions. SSH uses `SSH_PRIVATE_KEY` and preverified `SSH_KNOWN_HOSTS` in a mode600 temporary configuration. Every invocation explicitly passes `-F "$HOMELAB_SSH_CONFIG"`; no existing user SSH settings or hooks are replaced. The target user defaults to `ubuntu`, port22, and must have the intended passwordless `sudo` authority for this disposable guest. This is broad guest administration, not a production least-privilege deployment identity.

### Provision first; pin a unique guest host key; then deploy

For a new Proxmox guest, run `action=provision` before `action=deploy`. Provision needs only the public SSH key, Terraform inputs and provider credential; known-host keys are not required yet. The output identifies the static guest address. Use your trusted Proxmox CLI/guest-agent path to read the **new guest's** public host key and verify its fingerprint, then place that exact key in `SSH_KNOWN_HOSTS`. For example, on the trusted Proxmox node:

```bash
qm guest exec YOUR_VM_ID -- cat /etc/ssh/ssh_host_ed25519_key.pub
# Compare its fingerprint through your trusted administration path, then privately
# store "GUEST_IP ssh-ed25519 PUBLIC_KEY" in known_hosts (nondefault ports use [IP]:PORT).
```

Never clone host private keys into multiple VMs. Prepare templates with guest-agent installed, remove template host keys and clean cloud-init identity before converting to a template; ensure each clone generates fresh host keys. A login public key identifies the deploy user; it is different from the server host key. Host-key failures are not fixed by disabling verification.

The DNS deploy phase bootstraps Docker inside the new Linux guest, uploads only reviewed Compose/config/zone/helper files, preserves previous release configuration under `/var/backups/homelab/powerdns-recursor-lab/`, and starts the new release under `/opt/homelab/powerdns-recursor-lab/releases/`. No existing user configuration is replaced. Container data and host backups still require your separate backup policy. No firewall is disabled.

### Real DNS clients need a deliberate listener and ACL

The hosted/local demo stays loopback/high-port. For actual DNS deployment, set nonsecret variable `DNS_BIND_IP` to the guest's **specific intended IPv4 LAN address**; deployment exposes TCP/UDP53 on that address. `DNS_ALLOWED_CIDRS` is required for the Recursor and is a comma-separated list of explicitly trusted client CIDRs. `0.0.0.0/0` and `::/0` are refused. The helper supports an IPv4 listener; design and test IPv6 separately instead of claiming it is configured.

```bash
gh variable set DNS_BIND_IP --repo YOUR_ACCOUNT/powerdns-recursor-lab --body YOUR_GUEST_LAN_IP
# Recursor only: replace with your narrow intended client networks.
gh variable set DNS_ALLOWED_CIDRS --repo YOUR_ACCOUNT/powerdns-recursor-lab --body YOUR_TRUSTED_CIDR
gh workflow run homelab.yml --repo YOUR_ACCOUNT/powerdns-recursor-lab -f action=provision
# Pin independently verified guest keys, then:
gh workflow run homelab.yml --repo YOUR_ACCOUNT/powerdns-recursor-lab -f action=deploy
```

The application sees the translated Docker bridge source in some paths; the deployed Recursor also permits its dedicated bridge. That does not prove every original client is authorized. Enforce allowed/denied client networks at your router/firewall and test from both. Authoritative DNS should be restricted to your intended internal resolver clients. The helper does not automatically set router ACLs, change DHCP client DNS, expose WAN services, or prove Proxmox network isolation. Those are explicit acceptance checks.

### Existing bare-metal or VM target

The same workload upload is available through `scripts/deploy-existing-host.sh` for a dedicated Linux host without Terraform provisioning. Supply the isolated `HOMELAB_SSH_CONFIG`, runtime directory and deployment inputs exactly as the CI helper does. It requires the same preverified keys, sudo authority and network policy. Review `scripts/deploy-local.py` before running it directly on the intended host; never on a Proxmox hypervisor. Package installation and container restart are actual changes.

### GitLab option

The included `.gitlab-ci.yml` runs hosted/shared validation and exposes a **manual** homelab job only for a private project, protected default branch and `DEPLOY_ENABLED=true`. Register a dedicated Linux runner tagged `homelab`, assign protected variables/secrets with the same names, and protect the `homelab` environment as your GitLab plan supports. It invokes the same helpers. Default `HOMELAB_ACTION=plan`; deliberately select `provision` or `deploy` only after reviewing the previous stage. Do not attach this runner to untrusted forks or public pipelines.

Repository/runner access controls and token permissions are part of your lab setup; example YAML cannot enforce a router policy or your hosting account's approval settings by itself.

For a complete existing-host command path, load `SSH_PRIVATE_KEY` and `SSH_KNOWN_HOSTS` from your protected local secret facility, set `HOMELAB_SSH_HOST` (and DNS binding/ACL variables for the DNS repos), then run:

```bash
bash scripts/deploy-bare-metal.sh
```

This creates its own temporary isolated SSH files and performs the reviewed guest deployment, with no Terraform apply or VM creation. The existing host must be dedicated to this lab and already have the intended network segmentation and unique host keys. It installs packages and restarts only the named example workload; inspect the helper before using it on a host with existing services.
