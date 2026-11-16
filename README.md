# Azure Windows Server 2025 Image Lab

Every Monday, GitHub Actions builds a patched, CIS-hardened Windows Server 2025 image and publishes it to an Azure Compute Gallery. Anything deployed from the gallery's `latest` version is at most a week old.

~~~mermaid
flowchart LR
    Base["Newest Marketplace image"] --> Patch["Windows Update"]
    Patch --> Harden["CIS Level 1 script"]
    Harden --> Configure["Ansible playbook"]
    Configure --> Sysprep["Sysprep"]
    Sysprep --> Gallery["New gallery version"]
~~~

| File | Purpose |
| --- | --- |
| [windowsserver2025.pkr.hcl](windowsserver2025.pkr.hcl) | The whole build, top to bottom. |
| [ansible/configure.yml](ansible/configure.yml) | Settings enforced after hardening. Today it keeps automatic Windows updates on. |
| [scripts/Get-Lgpo.ps1](scripts/Get-Lgpo.ps1) | Downloads Microsoft's LGPO.exe for the hardening script. |
| [.github/workflows/windows-image.yml](.github/workflows/windows-image.yml) | Validates every push and scans the workflow with zizmor. Builds on Mondays and on **Run workflow**. |

The CIS script, `Harden-V2.ps1`, is private. The workflow downloads it from Azure Blob Storage and checks its SHA-256 before Packer runs.

## How the image stays fresh

A gallery image is a snapshot, so it cannot patch itself. Two things keep it current.

1. The weekly build starts from Microsoft's newest Marketplace image, installs every available update, and publishes a new version. The gallery's `latest` then points at it.
2. The CIS baseline sets Windows Update to install automatically every day, and the Ansible playbook enforces that setting, so a VM made from the image keeps patching itself.

## Setup

The build job runs in the GitHub environment **image-build-Azure-Packman-lab** and signs in to Azure with OIDC.

| Kind | Name | Value |
| --- | --- | --- |
| Secret | AZURE_CLIENT_ID | Application (client) ID of the app registration |
| Secret | AZURE_TENANT_ID | Directory (tenant) ID |
| Secret | AZURE_SUBSCRIPTION_ID | Lab subscription ID |
| Variable | AZURE_BUILD_RG | Resource group for the temporary build VM |
| Variable | AZURE_GALLERY_RG | Resource group of the Compute Gallery |
| Variable | AZURE_GALLERY_NAME | Compute Gallery name |
| Variable | AZURE_IMAGE_DEFINITION | Image definition name |
| Variable | BASELINE_STORAGE_ACCOUNT | Storage account holding `Harden-V2.ps1` |
| Variable | BASELINE_CONTAINER | Its container |
| Variable | BASELINE_BLOB | Its blob name |
| Variable | BASELINE_SHA256 | SHA-256 of the reviewed script |

The app's service principal needs these roles.

| Role | Scope |
| --- | --- |
| Contributor | The build resource group |
| Storage Blob Data Reader | The baseline container |
| Reader | The gallery |
| Contributor | The image definition |

The federated credential on the app registration must match the environment name. [GitHub OIDC for Azure](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-azure)

Create the gallery and a **Windows, generalized, x64, Gen2** image definition once.

~~~powershell
$region = az group show -n 'rg-packer-lab' --query location -o tsv
az group create -n 'rg-packer-images' -l $region -o none
az sig create -g 'rg-packer-images' --gallery-name 'packerLabImages' -l $region -o none
az sig image-definition create -g 'rg-packer-images' --gallery-name 'packerLabImages' --gallery-image-definition 'windows-server-2025-lab' --publisher PortfolioLab --offer WindowsServer2025 --sku Workgroup --os-type Windows --os-state Generalized --hyper-v-generation V2 --features SecurityType=TrustedLaunchSupported -o none
~~~

## Run it

Go to **Actions → Windows Server image → Run workflow**. Each run publishes version `1.0.<run number>`. The full Packer log is in the build step, so a failed run shows the exact error.

To run it from your own machine, install Packer, Azure CLI, Ansible and `pywinrm`, put `Harden-V2.ps1` next to the template, then run the build. Ansible needs Linux, macOS or WSL.

~~~bash
az login
packer init .
packer build .
~~~

Old gallery versions are not deleted automatically. Each one costs storage, so remove the ones you no longer deploy.

## Next

1. Security scanning of the image before a version is published. The workflow file itself is already scanned by [zizmor](https://docs.zizmor.sh/audits/).
2. Monitoring for VMs deployed from the image.
