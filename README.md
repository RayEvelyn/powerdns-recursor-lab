# PowerDNS Recursor: a private caching resolver for your home lab

Learn what happens after a laptop asks “where is this name?” This lab runs a private recursive resolver, demonstrates caching, validates public DNSSEC answers, and explains conditional forwarding to your own authoritative DNS.

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
