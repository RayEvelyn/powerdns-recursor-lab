# Optional Proxmox VM provisioning

Terraform creates one guest from an existing Ubuntu 24.04 cloud-init template. It does not install Docker or deploy DNS. For bare metal, skip this directory.

## Why Terraform

A reviewed configuration records the intended CPU, memory, network and SSH public key. Terraform keeps state to map declarations to actual resources. Its plan helps you review consequences before changing a host. State is operational data: back it up privately and never commit it. A replacement plan can destroy a working DNS server.

## Prepare the template on a lab Proxmox node

Download the official Ubuntu cloud image from https://cloud-images.ubuntu.com/noble/current/. Verify it against the published SHA256SUMS before importing; for stronger provenance verify the signed checksum file against Ubuntu's documented image-signing keys. Prepare a copy with `qemu-guest-agent` installed using `virt-customize` on a separate image-preparation Linux machine. Transfer that prepared image to the Proxmox node. The source image alone does not meet this scaffold's guest-agent requirement.

```bash
# On a separate Ubuntu image-preparation machine:
sudo apt-get update
sudo apt-get install -y libguestfs-tools
cp noble-server-cloudimg-amd64.img noble-prepared.img
sudo virt-customize -a noble-prepared.img --install qemu-guest-agent
# On Proxmox, after transfer, choosing an UNUSED template ID:
bash create-template.sh 9000 local-lvm vmbr0 /var/tmp/noble-prepared.img
```

The helper refuses an existing VM ID. This example assumes single-node cloning from that template and an 80 GiB template disk. Choose storage and bridge names from `pvesm status` and `ip link`; never copy identifiers from another lab blindly.

## Create a dedicated API user/token using Proxmox CLI

Run administrative setup on the Proxmox node. This lab role is broad across VMs at `/` and is **not a production least-privilege policy**. It avoids full administrator rights but can modify other VMs. Prefer a dedicated lab node, and refine ACLs to your target pool, template, storage and SDN network before production use.

```bash
pveum user add terraform-lab@pve --comment 'Disposable lab Terraform user'
pveum role add TerraformLab --privs 'VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt Datastore.Audit Datastore.AllocateSpace Sys.Audit SDN.Use'
pveum acl modify / --users terraform-lab@pve --roles TerraformLab
pveum user token add terraform-lab@pve tutorial --privsep 1
pveum acl modify / --tokens 'terraform-lab@pve!tutorial' --roles TerraformLab
```

The token command displays its secret once. Keep it in your password manager. Privilege-separated tokens need both user and token ACLs; effective permissions are their intersection. If your Proxmox version rejects a privilege, inspect `pveum role list` and the official provider permission documentation; do not grant root to silence an error.

## Set credentials without putting secrets in Git

On your workstation, first trust the Proxmox CA using your operating system's certificate store. Verify its fingerprint independently. Do not disable TLS checks. The provider reads these environment variables directly:

```bash
export PROXMOX_VE_ENDPOINT='https://proxmox.example.test:8006/'
read -r -s -p 'Proxmox token value: ' PROXMOX_TOKEN_VALUE; printf '\n'
export PROXMOX_VE_API_TOKEN='terraform-lab@pve!tutorial='"${PROXMOX_TOKEN_VALUE}"
unset PROXMOX_TOKEN_VALUE
cp terraform.tfvars.example terraform.tfvars
# Edit every sample value to match YOUR lab; the 192.0.2.0/24 network is documentation-only.
terraform init
terraform fmt -check
terraform validate
terraform plan -out=lab.tfplan
terraform show lab.tfplan
# Only after reviewing the exact plan:
terraform apply lab.tfplan
unset PROXMOX_VE_API_TOKEN
```

In zsh, use `read -s 'PROXMOX_TOKEN_VALUE?Proxmox token value: '` instead of Bash's `-p` form. Keep the private SSH key on your workstation; Terraform reads only the `.pub` file. Ignored tfvars still must not contain token or password variables. Protect `.terraform`, saved plans and state too; do not upload them as public CI artifacts.

## Next step and cleanup

SSH to the `ssh_host` output as `ubuntu`, install Docker using the parent README, copy the sanitized repo and run its Compose project. The guest's address must be available and outside your DHCP allocation, with a reachable gateway and DNS resolver.

Before deletion, stop workloads and preserve all data needed for recovery. Review `terraform plan -destroy` before `terraform destroy`. Never run destroy to fix a DNS typo.

Official references: https://bpg.sh/docs/ and https://pve.proxmox.com/pve-docs/pve-admin-guide.html#chapter_user_management.
