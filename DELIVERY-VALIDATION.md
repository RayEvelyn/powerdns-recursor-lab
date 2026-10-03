# CI deployment implementation verification

Static verification completed locally:

- Terraform formatted and initialized with backend disabled for validation; provider schemas validate all resources. No API plan/apply performed.
- Original Compose demos parse, preserve localhost bindings, and all Bash/Python deployment helpers pass syntax checks.
- GitHub workflows pass actionlint with the declared custom homelab runner label. Hosted validation must pass before the private-copy manual deployment job.
- Private-repository/default-branch/DEPLOY_ENABLED/manual dispatch gates, isolated SSH config and persistent state ownership inspected.
- Mocked plan/provision tests exercise five paths: both DNS plan/provision and Cloudflare plan. They succeed without SSH private keys/known-host material; the provision branch invokes only a mocked saved-plan apply and exits before SSH. No real Terraform apply occurred.

The first mock attempt stopped because this Mac has no GNU flock; the mock harness then supplied a fake flock. Actual Linux lock contention and persistent runner recovery are not claimed by this test. Linux flock is a documented runner prerequisite.

Deployment onto a new VM, SSH host-key discovery, package bootstrap, actual port53 LAN queries/denied-client firewall checks, tunnel service startup and CI with reader credentials remain reader-environment runtime acceptance gates. Existing loopback DNS tests establish the sample services, not the new deployment path or network policy. Review and execute these phases deliberately in your private lab copy.
