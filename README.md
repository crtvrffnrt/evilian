# evilian
Azure VM Installation Script for latest Debian 

One-shot Bash script that provisions an Azure VM, locks SSH to a single IP/CIDR, converts the host to Kali rolling, and installs evilginx. Designed for quick disposable labs; everything is tagged so you can track and clean up easily.

## What it does
- Validates required tools (`az`) and your Azure login.
- Creates a resource group, VM, NSG, and Standard public IP prefixed with `evilian-<project>`.
- Restricts SSH to the IP/CIDR you supply; HTTP/HTTPS are open; all other inbound traffic is denied.
- Deploys the image you choose (defaults to Debian 13), then switches APT to Kali rolling and installs evilginx/evilginx2.
- Generates random admin username/password and prints SSH connection details (auto-SSH if `sshpass` is available).

## Prerequisites
- Bash environment with Azure CLI installed.
- Azure subscription access and permission to create resource groups/VMs.
- Logged in via `az login --use-device-code` (or other supported auth).
- Optional: `sshpass` if you want the script to auto-open SSH.

## Usage
```bash
./evilian.sh -r <allowed-ip-or-cidr> -name <project-name> [--location <azure-region>] [--vm-size <sku>] [--image <urn>]
```

Example:
```bash
./evilian.sh -r 203.0.113.5/32 -name evil123
```

Key options:
- `-r|--range`: Required. IP/CIDR allowed for SSH.
- `-name|--name`: Required. Project name; must be alphanumeric/hyphen. Used as `evilian-<name>-*`.
- `--location`: Azure region (default `germanywestcentral`).
- `--vm-size`: VM SKU (default `Standard_B4s_v2`).
- `--image`: Image URN (default `Debian:debian-13:13-gen2:latest`).

## What to expect
1) Script shows existing resource groups tagged `createdBy=evilian` so you can decide on cleanup.
2) If a resource group named `evilian-<project>-rg` already exists, the script aborts.
3) VM boots, switches to Kali rolling, installs evilginx (falls back to evilginx2), reboots, and prints:
   - Resource group, VM name, location, public IP, generated username/password.
   - Suggested SSH command; auto-connects if `sshpass` is installed.

## Cleanup
Delete everything the script created with:
```bash
az group delete --name evilian-<project>-rg --yes --no-wait
```

## Notes and cautions
- Running this incurs Azure costs until you delete the resource group.
- SSH is restricted to the IP/CIDR you provide; HTTP/HTTPS remain open. Review NSG rules before exposing services.
- Keep the generated credentials secure; regenerate by redeploying if needed.
- Use responsibly and within the terms of your cloud provider and local laws.
